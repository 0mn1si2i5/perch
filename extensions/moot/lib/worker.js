import fs from 'node:fs';import path from 'node:path';import {spawn} from 'node:child_process';import {randomUUID} from 'node:crypto';
import {readRun,updateRun,runDirectory} from './runs.js';import {loadConfig} from './config.js';import {assertCurrentPermission,resolveRoute} from './routing.js';import {buildInvocation,parseEvent,verifySubscription} from './adapters/index.js';
const [root,id]=process.argv.slice(2);let child,providerStarted=false;
const modify=fn=>{for(let i=0;i<20;i++){try{return updateRun(root,id,r=>{if(r.state!=='cancelled')fn(r);});}catch(e){if(e.code!=='busy')throw e;Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,10);}}throw Error('Run remained busy');};
process.on('SIGTERM',()=>{child?.kill('SIGTERM');process.exit(0);});
async function execute() {
 providerStarted=false;
 const run=readRun(root,id);if(run.state==='cancelled')return;
 if(run.task.mode==='roundtable'){const {executeMeetingRound}=await import('./meeting.js');await executeMeetingRound(root,id);return;}
 const route=run.route;assertCurrentPermission(loadConfig(root),route);
 const connection=(route.authMode==='api'?loadConfig(root):run.configSnapshot).connections.find(c=>c.id===route.connectionID);
 const outputRoot=path.join(runDirectory(root,id),'output');
 const prompt=[run.brief,route.instructions,'Only perform the requested task. Do not push, publish, alter login settings or invoke another paid provider.',route.completionMode==='audit'?'Read-only independent review. Do not edit the target.':'',route.completionMode==='image'?'Use the built-in image generation tool; wait for its actual image output. Do not run commands to copy or convert images. Return the generated path. Text alone is not a completed image.':''].filter(Boolean).join('\n\n');
 if(route.authMode==='api') {
  const {generateImage}=await import('./adapters/google-image-api.js');
  providerStarted=true;
  const artifacts=await generateImage(loadConfig(root),route,prompt,outputRoot);
  modify(r=>{r.artifacts=artifacts;r.state='ended';r.output='Generated image through explicitly enabled API fallback';r.endedAt=new Date().toISOString();});return;
 }
 verifySubscription(connection);
 const inv=buildInvocation(connection,route,{workdir:run.task.workdir,outputRoot,prompt,readOnly:route.completionMode==='audit'});
 let complete=false,failure='',pending='',messages=[],sessionID;
 const saveEvents=raw=>{let o;try{o=JSON.parse(raw);}catch{return;}
  const events=parseEvent(connection.adapter,o);if(!events.length)return;
  for(const e of events){e.id=randomUUID();e.at=new Date().toISOString();if(e.kind==='completed')complete=true;if(e.kind==='error')failure=e.text;if(e.kind==='session')sessionID=e.text;if(e.kind==='message')messages.push(e.text);if(e.kind==='final')messages=[e.text];}
  modify(r=>{r.events.push(...events);r.output=messages.join('\n\n');if(sessionID)r.sessionID=sessionID;});
 };
 providerStarted=true;
 child=spawn(inv.executable,inv.args,{cwd:inv.cwd,env:inv.env,stdio:['ignore','pipe','pipe']});
 let stderr='';child.stderr.on('data',d=>{stderr=(stderr+d.toString()).slice(-4000);});
 child.stdout.on('data',d=>{pending+=d.toString();const lines=pending.split('\n');pending=lines.pop();for(const line of lines)saveEvents(line);});
 const timeout=setTimeout(()=>{failure='Execution timed out';child.kill('SIGTERM');setTimeout(()=>child.kill('SIGKILL'),5000).unref();},10*60*1000);timeout.unref();
 const code=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',resolve);});clearTimeout(timeout);if(pending)saveEvents(pending);
 if(code!==0||!complete||failure)throw Error(failure||`Provider exited without a successful result (${code}); ${stderr.slice(-500)}`);
 if(route.completionMode==='image') {
  const {collectImages}=await import('./image-task.js');
  const artifacts=await collectImages(connection,sessionID,outputRoot);
  if(!artifacts.length)throw Error('Image tool returned no readable image; API has not been invoked');
  modify(r=>{r.artifacts=artifacts;});
 }
 modify(r=>{r.state='ended';r.endedAt=new Date().toISOString();});
}
const unavailable={};
for(;;) {
 try {await execute();break;}catch(e) {
  const r=readRun(root,id);if(r.state==='cancelled')break;
  // Preflight has no task side effects. After execution only image requests may fall back.
  if(r.route&&(!providerStarted||r.route.completionMode==='image')&&!r.task.explicitConnectionID&&!r.task.explicitModel&&!r.artifacts.length) {
   unavailable[r.route.connectionID]=false;
   try {const route=resolveRoute(r.configSnapshot,r.task,unavailable);modify(x=>{x.events.push({id:randomUUID(),kind:'fallback',text:`${r.route.connectionID}: ${e.message}; switching to ${route.connectionID}`});x.route=route;});continue;}catch{}
  }
  modify(r=>{r.state='failed';r.error=String(e.message).slice(0,1200);r.endedAt=new Date().toISOString();});break;
 }
}
