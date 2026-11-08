import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import os from 'node:os';import path from 'node:path';
import {subscriptionEnv,providerEnv,verifySubscription} from '../lib/adapters/index.js';import {handleRequest} from '../lib/rpc.js';
// What a Claude Code desktop session passes to its shell. CLAUDE_CODE_SIMPLE=1 and CLAUDE_CODE_ENTRYPOINT=claude-desktop each make a child CLI report "Not logged in".
const host={CLAUDECODE:'1',CLAUDE_CODE_SIMPLE:'1',CLAUDE_CODE_ENTRYPOINT:'claude-desktop',CLAUDE_CODE_CHILD_SESSION:'1',CLAUDE_CODE_ACCOUNT_UUID:'u',CLAUDE_CODE_ORGANIZATION_UUID:'o',CLAUDE_CODE_MESSAGING_TOKEN:'t',CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH:'1',CLAUDE_CONFIG_DIR:'/elsewhere',CLAUDE_EFFORT:'max',ANTHROPIC_PROFILE:'default',ANTHROPIC_CONFIG_DIR:'/shared',AI_AGENT:'claude-code',USE_STAGING_OAUTH:'1'};
test('host Claude Code session variables are not inherited',()=>{assert.deepEqual(subscriptionEnv({...host,HOME:'/tmp',PATH:'/bin'}),{HOME:'/tmp',PATH:'/bin'});});
test('each non-default Claude Code account uses its own Anthropic profile directory',()=>{
 const root='/Users/x/.perch/claude/org';
 assert.deepEqual(providerEnv({adapter:'claude',accountRoot:root},{...host,PATH:'/bin'}),{PATH:'/bin',CLAUDE_CONFIG_DIR:root,ANTHROPIC_CONFIG_DIR:root+'/anthropic'});
 assert.deepEqual(providerEnv({adapter:'claude',accountRoot:path.join(os.homedir(),'.claude')},{...host,PATH:'/bin'}),{PATH:'/bin'});
 assert.equal(providerEnv({adapter:'codex',accountRoot:'/c'},host).CODEX_HOME,'/c');
});
test('login check run from a Claude Code session sees the account login',async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'moot-claude-env-'));const keys=['CLAUDE_CODE_SIMPLE','CLAUDE_CODE_ENTRYPOINT'];const saved=Object.fromEntries(keys.map(k=>[k,process.env[k]]));
 try{
  const executable=path.join(root,'claude');
  fs.writeFileSync(executable,'#!/bin/sh\nif [ -n "$CLAUDE_CODE_SIMPLE$CLAUDE_CODE_ENTRYPOINT" ]; then echo \'{"loggedIn":false,"authMethod":"none"}\'; exit 1; fi\necho \'{"loggedIn":true,"authMethod":"claude.ai"}\'\n',{mode:0o700});
  Object.assign(process.env,{CLAUDE_CODE_SIMPLE:'1',CLAUDE_CODE_ENTRYPOINT:'claude-desktop'});
  const connection={id:'claude',adapter:'claude',authMode:'subscription',executable,accountRoot:path.join(root,'account')};
  assert.doesNotThrow(()=>verifySubscription(connection));
  const r=await handleRequest({protocolVersion:1,requestID:'check',operation:'connection.check',payload:{connection}},{root});
  assert.equal(r.data?.status,'loginDetected',JSON.stringify(r));
 }finally{for(const k of keys){if(saved[k]===undefined)delete process.env[k];else process.env[k]=saved[k];}fs.rmSync(root,{recursive:true,force:true});}
});
