import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs';import {spawnSync} from 'node:child_process';
import {requireValue as check} from '../protocol.js';
// Billing and provider overrides, and the host's Claude Code session (CLAUDE_CODE_SIMPLE bare mode, CLAUDE_CODE_ENTRYPOINT, account and messaging hints, ANTHROPIC_PROFILE): a child CLI uses only its own login.
const inherited=/(API_KEY|AUTH_TOKEN|BASE_URL|ENDPOINT|VERTEX|BEDROCK|FOUNDRY|GOOGLE_APPLICATION_CREDENTIALS|APIKEYHELPER)|^(CLAUDE|ANTHROPIC_)|^(AI_AGENT|USE_LOCAL_OAUTH|USE_STAGING_OAUTH)$/i;
export function subscriptionEnv(source=process.env) {
  return Object.fromEntries(Object.entries(source).filter(([k])=>!inherited.test(k)));
}
// Claude Code keeps a Console (API Usage Billing) login in an Anthropic profile directory, by default the shared ~/.config/anthropic,
// which any Claude Code without a login of its own would use. Like Perch, give every other account its own inside its config directory.
export function providerEnv(connection,source=process.env) {
  const env=subscriptionEnv(source);
  if(connection.adapter==='codex')env.CODEX_HOME=connection.accountRoot;
  if(connection.adapter==='claude'&&path.resolve(connection.accountRoot)!==path.join(os.homedir(),'.claude')){env.CLAUDE_CONFIG_DIR=connection.accountRoot;env.ANTHROPIC_CONFIG_DIR=path.join(connection.accountRoot,'anthropic');}
  return env;
}
export function buildInvocation(connection,route,context) {
  const env=providerEnv(connection); let args;
  if(connection.adapter==='codex') {
    args=['exec','--ignore-user-config','--skip-git-repo-check','-s',context.readOnly?'read-only':'workspace-write','--json','-C',context.workdir];
    if(route.model)args.push('-m',route.model);args.push(context.prompt);
  } else if(connection.adapter==='claude') {
    args=['-p',context.prompt,'--output-format','stream-json','--verbose','--permission-mode','acceptEdits','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--setting-sources','','--settings','{"disableAllHooks":true}'];
    args.push('--tools',context.readOnly?'Read,Glob,Grep':'Read,Glob,Grep,Edit,Write,Bash','--allowedTools',context.readOnly?'Read,Glob,Grep':'Read,Glob,Grep,Edit,Write,Bash');
    if(route.model)args.push('--model',route.model);
  } else if(connection.adapter==='agy') {
    // agy has no supported per-account flag. Never silently route a different root.
    check(path.resolve(connection.accountRoot)===path.join(os.homedir(),'.gemini','antigravity-cli'),'accountBindingUnavailable','Antigravity currently supports the explicitly selected local CLI account only');
    args=['-p',context.prompt,'--output-format','stream-json','--print-timeout','8m','--sandbox'];
    if(route.model)args.push('--model',route.model);
  } else throw Error('Unsupported subscription adapter');
  let executable=connection.executable;
  if(process.platform==='darwin'&&connection.adapter!=='codex'&&fs.existsSync('/usr/bin/sandbox-exec')) {
    const q=p=>JSON.stringify(fs.realpathSync(p));
    const allowed=[connection.accountRoot,context.outputRoot];
    if(!context.readOnly)allowed.push(context.workdir);
    // Keep auth owned by the CLI. Only workspace, output and CLI state can be written in the home directory.
    let policy=`(version 1)(allow default)(deny file-write* (subpath ${q(os.homedir())}))`;
    for(const p of allowed) {fs.mkdirSync(p,{recursive:true});policy+=`(allow file-write* (subpath ${q(p)}))`;}
    if(context.readOnly)policy+=`(deny file-write* (subpath ${q(context.workdir)}))`;
    args=['-p',policy,executable,...args];executable='/usr/bin/sandbox-exec';
  }
  return {executable,args,env,cwd:context.workdir};
}
export function parseEvent(adapter,o) {
  const events=[];
  if(adapter==='codex') {
    if(o.type==='thread.started')events.push({kind:'session',text:o.thread_id});
    if(o.type==='item.completed'&&o.item?.type==='agent_message')events.push({kind:'message',text:o.item.text});
    else if(o.type==='item.completed')events.push({kind:'tool',text:o.item?.command||o.item?.type||'tool',detail:o.item?.aggregated_output});
    if(o.type==='turn.completed')events.push({kind:'completed',usage:o.usage});
    if(o.type==='turn.failed'||o.type==='error')events.push({kind:'error',text:o.error?.message||o.message||'Codex failed'});
  } else if(adapter==='claude') {
    if(o.type==='assistant')for(const b of o.message?.content||[]) {if(b.type==='text')events.push({kind:'message',text:b.text});if(b.type==='tool_use')events.push({kind:'tool',text:b.name});}
    if(o.type==='result') {events.push({kind:o.is_error?'error':'completed',text:o.result||'',usage:o.usage});if(!o.is_error&&o.result)events.push({kind:'final',text:o.result});}
  } else {
    if(o.event==='init')events.push({kind:'session',text:o.conversation_id,tools:o.init?.tools});
    const s=o.step_update;
    if(s?.step_type==='agent_response'&&s.text_delta)events.push({kind:'delta',text:s.text_delta});
    if(s?.step_type==='tool')events.push({kind:'tool',text:s.tool_name,detail:s.tool_info?.error?.message||s.tool_info?.output,state:s.state});
    if(o.event==='result') {const r=o.result||{};events.push({kind:r.status==='SUCCESS'?'completed':'error',text:r.response||r.error?.message||r.status,usage:r.usage});if(r.response)events.push({kind:'final',text:r.response});}
  }
  return events;
}

const loginArgs={codex:['login','status'],claude:['auth','status'],agy:['models']};
// The login a connection must have: a ChatGPT or claude.ai subscription, or for authMode console a Console organization sign-in,
// which Claude Code reports as an OAuth token from its Anthropic profile.
const expectedLogin=c=>c.adapter==='codex'?/using ChatGPT/i:c.adapter==='claude'?(c.authMode==='console'?/"authMethod"\s*:\s*"oauth_token"/:/"authMethod"\s*:\s*"claude.ai"/):null;
export function checkLogin(connection,timeout=15000) {
 const result=spawnSync(connection.executable,loginArgs[connection.adapter],{env:providerEnv(connection),encoding:'utf8',timeout,maxBuffer:1024*1024});
 const output=(result.stdout||'')+(result.stderr||''),expected=expectedLogin(connection);
 return {valid:result.status===0&&(!expected||expected.test(output)),output};
}
// The organization a Console connection bills, as `claude auth status --text` names it.
export function consoleOrganization(connection) {
 const result=spawnSync(connection.executable,['auth','status','--text'],{env:providerEnv(connection),encoding:'utf8',timeout:15000,maxBuffer:1024*1024});
 return /^Organization:\s*(.+?)\s+·\s+[0-9a-f-]{36}\s*$/m.exec(result.stdout||'')?.[1];
}
export function verifySubscription(connection) {
 if(connection.adapter==='agy')return;
 check(checkLogin(connection).valid,'subscriptionUnavailable',connection.authMode==='console'?'Selected Console organization login could not be verified; sign in to the Console account in this CLI account directory':'Selected CLI subscription login could not be verified; check login and host permission to read credentials');
}
