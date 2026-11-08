import fs from 'node:fs';import {fileURLToPath} from 'node:url';import path from 'node:path';import {spawn} from 'node:child_process';
import {validateRequest,requireValue as check} from './protocol.js';import {loadConfig,saveConfig} from './config.js';import {startRun,listRuns,readRun,cancelRun} from './runner.js';import {terminal} from './runs.js';import {startMeeting,submitHostSummary,advanceMeeting,retryMeeting} from './meeting.js';import {atomicJSON,readJSON} from './storage.js';import {checkLogin,consoleOrganization} from './adapters/index.js';
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
    const {valid,output}=checkLogin(c,20000),org=c.authMode==='console';
    const organization=valid&&org?consoleOrganization(c):undefined;
    const message=!valid?(org?'Console organization login unavailable':'Subscription login unavailable'):org?`Console organization login detected${organization?': '+organization:''}; usage is billed to its prepaid credits`:'Login detected; use an actual task to verify model and tools';
    data={status:valid?'loginDetected':'unavailable',message,models:c.adapter==='agy'?output.split('\n').filter(l=>l.includes('\t')).map(l=>l.split('\t')[0]):[]};break;
   }
   default:throw Object.assign(Error('Unknown operation'),{code:'unknownOperation'});
  }
  return {protocolVersion:1,requestID:request.requestID,ok:true,data};
 }catch(e){return {protocolVersion:1,requestID:request?.requestID??'',ok:false,error:{code:e.code||'executionError',message:String(e.message).slice(0,1500)}};}
}
