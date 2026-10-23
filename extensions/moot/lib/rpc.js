import fs from 'node:fs';import os from 'node:os';import {fileURLToPath} from 'node:url';import path from 'node:path';import {spawn,spawnSync} from 'node:child_process';
import {validateRequest,requireValue as check} from './protocol.js';import {loadConfig,saveConfig} from './config.js';import {startRun,listRuns,readRun,cancelRun} from './runner.js';import {terminal} from './runs.js';import {startMeeting,submitHostSummary,advanceMeeting,retryMeeting} from './meeting.js';import {atomicJSON,readJSON} from './storage.js';import {subscriptionEnv} from './adapters/index.js';
export async function handleRequest(request,{root}) {
 try {
  validateRequest(request);const p=request.payload??{};let data;
  switch(request.operation) {
   case 'config.read':data=loadConfig(root);break;
   case 'config.write':data=saveConfig(root,p.config,p.expectedRevision);break;
   case 'delegate.start':case 'audit.start':data=await startRun(root,{...p,mode:request.operation==='audit.start'?'audit':'delegate'});break;
   case 'meeting.start':data=await startMeeting(root,{...p,mode:'roundtable'});break;
   case 'run.list':data=listRuns(root).filter(r=>!r.task.parentID);break;
   case 'run.read':data=readRun(root,p.runID);break;
   case 'run.cancel':data=await cancelRun(root,p.runID);break;
   case 'meeting.retry':data=await retryMeeting(root,p.runID);break;
   case 'meeting.summary':data=submitHostSummary(root,p.runID,p.summary);break;
   case 'meeting.advance':data=await advanceMeeting(root,p.runID,p.expectedRound);break;
   case 'runtime.quiesce':atomicJSON(path.join(root,'quiesce.json'),{at:new Date().toISOString()});data={activeRunIDs:listRuns(root).filter(r=>!terminal(r)).map(r=>r.id)};break;
   case 'runtime.uninstall':{
    check(fs.existsSync(path.join(root,'quiesce.json')),'notQuiescing','Quiesce before uninstall');
    const receipt=readJSON(path.join(root,'install-receipt.json'));check(receipt,'notInstalled','Extension not installed');receipt.state='pendingUninstall';atomicJSON(path.join(root,'install-receipt.json'),receipt);
    const worker=spawn(process.execPath,[fileURLToPath(new URL('./maintenance.js',import.meta.url)),root],{detached:true,stdio:'ignore'});worker.unref();data={state:'pendingUninstall'};break;
   }
   case 'connection.check':{
    const c=p.connection??loadConfig(root).connections.find(c=>c.id===p.connectionID);check(c,'missingConnection','Select a connection');
    if(c.authMode==='api'){data={status:'unverified',message:'API invocation requires opt in and an actual task'};break;}
    check(fs.existsSync(c.executable),'missingExecutable','Executable not found');
    const env=subscriptionEnv();if(c.adapter==='codex')env.CODEX_HOME=c.accountRoot;if(c.adapter==='claude'){if(path.resolve(c.accountRoot)===path.join(os.homedir(),'.claude'))delete env.CLAUDE_CONFIG_DIR;else env.CLAUDE_CONFIG_DIR=c.accountRoot;}
    const args=c.adapter==='codex'?['login','status']:c.adapter==='claude'?['auth','status']:['models'];
    const result=spawnSync(c.executable,args,{env,encoding:'utf8',timeout:20000,maxBuffer:1024*1024});
    const output=(result.stdout||'')+(result.stderr||'');
    const subscription=c.adapter==='codex'?/using ChatGPT/i.test(output):c.adapter==='claude'?/"authMethod"\s*:\s*"claude.ai"/.test(output):result.status===0;
    data={status:subscription?'loginDetected':'unavailable',message:subscription?'Login detected; use an actual task to verify model and tools':'Subscription login unavailable',models:c.adapter==='agy'?output.split('\n').filter(l=>l.includes('\t')).map(l=>l.split('\t')[0]):[]};break;
   }
   default:throw Object.assign(Error('Unknown operation'),{code:'unknownOperation'});
  }
  return {protocolVersion:1,requestID:request.requestID,ok:true,data};
 }catch(e){return {protocolVersion:1,requestID:request?.requestID??'',ok:false,error:{code:e.code||'executionError',message:String(e.message).slice(0,1500)}};}
}
