import fs from 'node:fs';import path from 'node:path';import {randomUUID} from 'node:crypto';
import {loadConfig} from './config.js';import {assertTrigger} from './routing.js';import {readRun,listRuns,updateRun,runDirectory,terminal} from './runs.js';import {atomicJSON,withLock,safeID} from './storage.js';import {requireValue as check} from './protocol.js';import {launchWorker,startRun,currentRuntime} from './runner.js';import {meetingPrompt} from './meeting-prompts.js';
export function canAdvance(run,expectedRound) {
 const round=run.rounds.at(-1);
 check(round?.summary,'missingSummary','Host summary required before advancing');
 check(round.number===expectedRound,'roundConflict','Round changed');
 return round.number<run.meeting.maxRounds&&!run.stopEarly;
}
export function applySummary(run,summary) {
 const round=run.rounds.at(-1);
 if(round.summary&&JSON.stringify(round.summary)===JSON.stringify(summary))return;
 check(run.state==='awaitingHost','wrongState','Meeting is not awaiting its host');
 check(summary.inputRevision===run.revision,'revisionConflict','Summary input revision changed');
 check(summary.round===round.number,'roundConflict','Wrong summary round');
 const missing=round.seats.filter(s=>s.state!=='ended').map(s=>s.seatID);
 check(missing.every(id=>summary.missingSeats?.includes(id)),'missingCoverage','Summary must acknowledge missing seats');
 check(Array.isArray(summary.commonGround)&&typeof summary.hostJudgment==='string'&&Array.isArray(summary.issues),'invalidSummary','Common ground, host judgment and issues required');
 const issues=new Map(run.issues.map(i=>[i.issueID,i]));
 for(const issue of summary.issues) {
  check(issue.issueID&&['open','resolved'].includes(issue.status),'invalidIssue','Stable issue ID/status required');
  if(issue.status==='resolved')check(issue.evidence?.trim(),'invalidIssue','Resolution evidence required');
  for(const ref of issue.references||[])check(run.rounds.some(r=>r.number===ref.round&&r.seats.some(s=>s.seatID===ref.seatID&&s.messageID===ref.messageID)),'invalidReference','Issue reference does not identify an existing speech');
  issues.set(issue.issueID,issue);
 }
 run.issues=[...issues.values()];round.summary=summary;
 run.stopEarly=Boolean(summary.endEarly&&run.meeting.allowEarlyFinish);
 if(run.stopEarly||round.number>=run.meeting.maxRounds){run.state='ended';run.endedAt=new Date().toISOString();run.endReason=run.stopEarly?'hostEarlyFinish':'roundLimit';}else run.state='readyForNextRound';
}
export async function startMeeting(root,task) {
 return withLock(path.join(root,'.start-lock'),()=>{
  const prior=listRuns(root).find(r=>r.requestID===task.requestID);if(prior)return prior;
  check(!fs.existsSync(path.join(root,'quiesce.json')),'quiescing','Extension awaiting uninstall');
  const config=loadConfig(root);assertTrigger(config,{...task,mode:'roundtable'});
  const meeting=task.meetingOverride??config.meetingPreset;
  check(meeting.seats.length>=2&&meeting.seats.length<=6&&Number.isInteger(meeting.maxRounds)&&meeting.maxRounds>=1&&meeting.maxRounds<=10,'invalidMeeting','Use 2–6 seats and 1–10 rounds');
  check(new Set(meeting.seats.map(s=>s.seatID)).size===meeting.seats.length,'invalidMeeting','Seat IDs must be unique');
  for(const seat of meeting.seats)safeID(seat.seatID);
  for(const seat of meeting.seats)check(config.connections.some(c=>c.id===seat.connectionID&&c.enabled&&c.authMode==='subscription'),'unavailableSeat','Each meeting seat must use an enabled subscription connection');
  check(path.isAbsolute(task.workdir)&&fs.statSync(task.workdir).isDirectory(),'invalidWorkspace','Workspace required');
  const brief=fs.readFileSync(task.briefPath,'utf8');check(brief.trim()&&brief.length<=200000,'invalidBrief','Brief required');
  const id=randomUUID(),now=new Date().toISOString();const dir=runDirectory(root,id);fs.mkdirSync(dir,{recursive:true,mode:0o700});
  const run={format:'perch-moot',schemaVersion:1,revision:1,id,requestID:task.requestID,runtimeVersion:'0.1.0',runtime:currentRuntime(),configSnapshot:config,hostRef:task.hostRef||'local',state:'runningRound',createdAt:now,updatedAt:now,task:{...task,mode:'roundtable'},brief,meeting,rounds:[{number:1,seats:[]}],artifacts:[],issues:[],events:[],output:''};
  atomicJSON(path.join(dir,'run.json'),run);const pid=launchWorker(root,id);return updateRun(root,id,r=>{r.pid=pid;});
 });
}
export function submitHostSummary(root,id,summary){return updateRun(root,id,r=>applySummary(r,summary));}
export async function advanceMeeting(root,id,expectedRound) {
 return withLock(path.join(runDirectory(root,id),'.advance-lock'),()=>{
  const current=readRun(root,id);
  if(current.rounds.at(-1).number>expectedRound)return current;
  if(!canAdvance(current,expectedRound))return current;
  check(current.state==='readyForNextRound','wrongState','Meeting not ready');
  updateRun(root,id,r=>{r.rounds.push({number:expectedRound+1,seats:[]});r.state='runningRound';r.pid=null;});
  const pid=launchWorker(root,id);return updateRun(root,id,r=>{r.pid=pid;});
 });
}
export async function executeMeetingRound(root,id) {
 const run=readRun(root,id),round=run.rounds.at(-1);const dir=runDirectory(root,id);
 const seats=await Promise.all(run.meeting.seats.map(async seat=>{
  const old=round.seats.find(s=>s.seatID===seat.seatID);if(old?.state==='ended')return old;
  const attempt=(old?.attempt||0)+1;
  const previousAttempts=old?[...(old.previousAttempts||[]),{runID:old.runID,state:old.state,error:old.error,output:old.output}]:[];
  let result;
  try {
   const briefPath=path.join(dir,`round-${round.number}-${seat.seatID}.txt`);fs.writeFileSync(briefPath,meetingPrompt(run,seat,round.number),{mode:0o600});
   const route={connectionID:seat.connectionID,model:seat.model||run.configSnapshot.connections.find(c=>c.id===seat.connectionID).defaultModel,authMode:'subscription',completionMode:'audit',requiredTools:[],reason:'Configured roundtable seat',instructions:''};
   let child=await startRun(root,{requestID:`${id}-${round.number}-${seat.seatID}-${attempt}`,parentID:id,mode:'audit',trigger:run.task.trigger,capabilityID:'general',explicitConnectionID:seat.connectionID,explicitModel:seat.model,workdir:run.task.workdir,briefPath,hostRef:run.hostRef},route,{configSnapshot:run.configSnapshot,runtime:run.runtime});
   while(!terminal(child)){await new Promise(r=>setTimeout(r,500));if(readRun(root,id).state==='cancelled')break;child=readRun(root,child.id);}
   result={...seat,model:route.model,state:child.state,output:child.output,error:child.error,runID:child.id,messageID:randomUUID(),attempt,previousAttempts};
  } catch(error) {
   result={...seat,state:'failed',output:'',error:error.message,messageID:randomUUID(),attempt,previousAttempts};
  }
  // Persist each result as it arrives so a slow or failed seat cannot hide completed speech.
  updateRun(root,id,r=>{const current=r.rounds.at(-1);current.seats=current.seats.filter(s=>s.seatID!==seat.seatID);current.seats.push(result);});
  return result;
 }));
 updateRun(root,id,r=>{if(r.state==='cancelled')return;r.rounds.at(-1).seats=seats;r.state='awaitingHost';r.pid=null;});
}

export function prepareRetry(run) {
 check(run.state==='awaitingHost'&&!run.rounds.at(-1).summary,'wrongState','Retry requires awaiting host without summary');
 check(run.rounds.at(-1).seats.some(s=>s.state!=='ended'),'nothingToRetry','No failed seats');
 run.state='runningRound';
}
export async function retryMeeting(root,id) {
 return withLock(path.join(runDirectory(root,id),'.advance-lock'),()=>{
  const r=readRun(root,id);if(r.state==='runningRound')return r;
  updateRun(root,id,prepareRetry);const pid=launchWorker(root,id);return updateRun(root,id,r=>{r.pid=pid;});
 });
}
