import fs from 'node:fs';import path from 'node:path';import {spawn} from 'node:child_process';import {fileURLToPath} from 'node:url';import {randomUUID} from 'node:crypto';
import {loadConfig} from './config.js';import {resolveRoute,assertCurrentPermission} from './routing.js';import {atomicJSON,withLock} from './storage.js';import {readRun,listRuns,updateRun,runDirectory,terminal} from './runs.js';import {requireValue as check} from './protocol.js';
export {readRun,listRuns};
export const currentRuntime=()=>({node:fs.realpathSync(process.execPath),worker:fileURLToPath(new URL('./worker.js',import.meta.url))});
export function launchWorker(root,id) {
  const dir=runDirectory(root,id);const log=fs.openSync(path.join(dir,'worker.log'),'a',0o600);
  const runtime=readRun(root,id).runtime??currentRuntime();
  const worker=spawn(runtime.node,[runtime.worker,root,id],{detached:true,stdio:['ignore',log,log],env:process.env});
  fs.closeSync(log);worker.unref();return worker.pid;
}
export async function startRun(root,task,providedRoute,context={}) {
  check(task.requestID&&typeof task.requestID==='string','invalidRequest','Task request ID required');
  return withLock(path.join(root,'.start-lock'),()=>{
    const prior=listRuns(root).find(r=>r.requestID===task.requestID);if(prior)return prior;
    check((task.parentID&&!terminal(readRun(root,task.parentID)))||!fs.existsSync(path.join(root,'quiesce.json')),'quiescing','Extension is awaiting uninstall');
    check(path.isAbsolute(task.workdir)&&fs.statSync(task.workdir).isDirectory(),'invalidWorkspace','Workspace directory required');
    const brief=fs.readFileSync(task.briefPath,'utf8');check(brief.trim()&&brief.length<=200000,'invalidBrief','Brief must contain 1–200000 characters');
    const current=loadConfig(root),config=context.configSnapshot??current; const route=providedRoute??resolveRoute(config,task);
    assertCurrentPermission(current,route);
    const id=randomUUID(),now=new Date().toISOString();const dir=runDirectory(root,id);fs.mkdirSync(path.join(dir,'output'),{recursive:true,mode:0o700});
    const run={format:'perch-moot',schemaVersion:1,revision:1,id,requestID:task.requestID,runtimeVersion:'0.1.0',runtime:context.runtime??currentRuntime(),configSnapshot:config,hostRef:task.hostRef||'local',state:'running',createdAt:now,updatedAt:now,route,task,brief,rounds:[],artifacts:[],issues:[],events:[],output:''};
    atomicJSON(path.join(dir,'run.json'),run);
    try {const pid=launchWorker(root,id);return updateRun(root,id,r=>{r.pid=pid;});}catch(e){updateRun(root,id,r=>{r.state='failed';r.error=e.message;});throw e;}
  });
}
export async function cancelRun(root,id) {
  const r=readRun(root,id);if(terminal(r))return r;
  const next=updateRun(root,id,x=>{x.state='cancelled';x.endedAt=new Date().toISOString();});
  if(r.pid)try{process.kill(-r.pid,'SIGTERM');}catch{}
  for(const child of listRuns(root).filter(x=>x.task.parentID===id&&!terminal(x)))await cancelRun(root,child.id);
  return next;
}
