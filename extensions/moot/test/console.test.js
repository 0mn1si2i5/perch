import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import os from 'node:os';import path from 'node:path';
import {validateConfig,saveConfig} from '../lib/config.js';import {resolveRoute} from '../lib/routing.js';import {verifySubscription} from '../lib/adapters/index.js';import {handleRequest} from '../lib/rpc.js';import {startRun,readRun} from '../lib/runner.js';import {startMeeting} from '../lib/meeting.js';
// A Claude Code account signed in to a Console organization (API Usage Billing): the CLI keeps the login, usage is billed to the organization's prepaid credits.
function fakeClaude(root,authMethod='oauth_token'){
 const p=path.join(root,'fake claude');
 fs.writeFileSync(p,`#!/bin/sh
if [ "$1" = auth ]; then
 if [ "$3" = --text ]; then printf 'Profile: credentials-file \\302\\267 user_oauth \\302\\267 profile default\\nOrganization: Test Org \\302\\267 00000000-0000-4000-8000-000000000000\\n'; exit 0; fi
 echo '{"loggedIn":true,"authMethod":"${authMethod}"}'; exit 0
fi
printf '{"type":"result","is_error":false,"result":"%s|%s"}\\n' "$ANTHROPIC_CONFIG_DIR" "\${CLAUDE_CODE_SIMPLE:-unset}"
`,{mode:0o700});
 return p;
}
function fakeCodex(root){const p=path.join(root,'fake codex');fs.writeFileSync(p,'#!/bin/sh\nif [ "$1" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi\necho \'{"type":"item.completed","item":{"type":"agent_message","text":"codex"}}\'\necho \'{"type":"turn.completed"}\'\n',{mode:0o700});return p;}
function config(root){
 return {schemaVersion:1,revision:0,apiEnabled:false,automaticRoundtable:false,
  connections:[{id:'sub',adapter:'codex',authMode:'subscription',enabled:true,executable:fakeCodex(root),accountRoot:root,defaultModel:'a',tools:[]},
   {id:'org',adapter:'claude',authMode:'console',enabled:true,executable:fakeClaude(root),accountRoot:path.join(root,'org'),defaultModel:'',tools:[]}],
  capabilities:[{id:'general',enabled:true,primaryConnectionID:'sub',completionMode:'delegate',requiredTools:[],fallbackConnectionIDs:[],instructions:''}],
  meetingPreset:{maxRounds:1,allowEarlyFinish:false,seats:[{seatID:'a',connectionID:'sub',model:'a',role:'a'},{seatID:'b',connectionID:'org',model:'',role:'b'}]}};
}
const temp=()=>fs.mkdtempSync(path.join(os.tmpdir(),'moot-console-'));
async function wait(root,id,states){for(let i=0;i<150;i++){const r=readRun(root,id);if(states.includes(r.state))return r;await new Promise(r=>setTimeout(r,50));}throw Error('Timed out');}
test('Console is a Claude Code login mode that is never a fallback',()=>{const root=temp();try{
 const c=config(root);assert.doesNotThrow(()=>validateConfig(structuredClone(c)));
 const codex=structuredClone(c);codex.connections[0].authMode='console';assert.throws(()=>validateConfig(codex),/mismatch/i);
 const fallback=structuredClone(c);fallback.capabilities[0].fallbackConnectionIDs=['org'];assert.throws(()=>validateConfig(fallback),/fallback/i);
 const primary=structuredClone(c);primary.capabilities[0].primaryConnectionID='org';assert.doesNotThrow(()=>validateConfig(primary));
}finally{fs.rmSync(root,{recursive:true,force:true});}});
test('Console connection runs only when selected explicitly or as a primary',()=>{const root=temp();try{
 const c=config(root);
 assert.equal(resolveRoute(c,{capabilityID:'general'},{}).connectionID,'sub');
 assert.throws(()=>resolveRoute(c,{capabilityID:'general'},{sub:false}),/No available/);
 const explicit=resolveRoute(c,{capabilityID:'general',explicitConnectionID:'org'},{});assert.equal(explicit.connectionID,'org');assert.equal(explicit.authMode,'console');
 c.capabilities[0].primaryConnectionID='org';assert.equal(resolveRoute(c,{capabilityID:'general'},{}).connectionID,'org');
}finally{fs.rmSync(root,{recursive:true,force:true});}});
test('login check matches the declared billing',async()=>{const root=temp();try{
 const org={id:'org',adapter:'claude',authMode:'console',executable:fakeClaude(root),accountRoot:path.join(root,'org')};
 assert.doesNotThrow(()=>verifySubscription(org));
 assert.throws(()=>verifySubscription({...org,authMode:'subscription'}),/subscription/i);
 const checked=await handleRequest({protocolVersion:1,requestID:'check',operation:'connection.check',payload:{connection:org}},{root});
 assert.equal(checked.data.status,'loginDetected');assert.match(checked.data.message,/Test Org/);
 fs.rmSync(org.executable);fakeClaude(root,'claude.ai');
 assert.throws(()=>verifySubscription(org),/Console/);
}finally{fs.rmSync(root,{recursive:true,force:true});}});
test('selected Console run and roundtable seat use the account profile directory, not the host session',async()=>{const root=temp();const saved=process.env.CLAUDE_CODE_SIMPLE;try{
 const c=config(root);saveConfig(root,c,0);const briefPath=path.join(root,'brief');fs.writeFileSync(briefPath,'Answer');
 process.env.CLAUDE_CODE_SIMPLE='1';
 const task={requestID:'console',mode:'delegate',trigger:'userRequested',capabilityID:'general',explicitConnectionID:'org',briefPath,workdir:root,hostRef:'test'};
 const r=await wait(root,(await startRun(root,task)).id,['ended','failed','cancelled']);
 assert.equal(r.state,'ended',r.error);assert.equal(r.output,path.join(root,'org','anthropic')+'|unset');
 const m=await wait(root,(await startMeeting(root,{...task,requestID:'meeting',mode:'roundtable',explicitConnectionID:undefined})).id,['awaitingHost','ended','failed','cancelled']);
 assert.equal(m.state,'awaitingHost',m.error);assert.equal(m.rounds[0].seats.find(s=>s.seatID==='b').output,path.join(root,'org','anthropic')+'|unset');
}finally{if(saved===undefined)delete process.env.CLAUDE_CODE_SIMPLE;else process.env.CLAUDE_CODE_SIMPLE=saved;fs.rmSync(root,{recursive:true,force:true});}});
