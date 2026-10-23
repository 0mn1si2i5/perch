import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs';import {spawnSync} from 'node:child_process';
import {requireValue as check} from '../protocol.js';
export function subscriptionEnv(source=process.env) {
  return Object.fromEntries(Object.entries(source).filter(([k])=>!/(API_KEY|AUTH_TOKEN|BASE_URL|ENDPOINT|VERTEX|BEDROCK|FOUNDRY|GOOGLE_APPLICATION_CREDENTIALS|CLAUDECODE|CLAUDE_CODE_OAUTH_TOKEN|APIKEYHELPER)/i.test(k)));
}
export function buildInvocation(connection,route,context) {
  const env=subscriptionEnv(); let args;
  if(connection.adapter==='codex') {
    env.CODEX_HOME=connection.accountRoot;
    args=['exec','--ignore-user-config','--skip-git-repo-check','-s',context.readOnly?'read-only':'workspace-write','--json','-C',context.workdir];
    if(route.model)args.push('-m',route.model);args.push(context.prompt);
  } else if(connection.adapter==='claude') {
    if(path.resolve(connection.accountRoot)===path.join(os.homedir(),'.claude'))delete env.CLAUDE_CONFIG_DIR;else env.CLAUDE_CONFIG_DIR=connection.accountRoot;
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

export function verifySubscription(connection) {
 if(connection.adapter==='agy')return;
 const env=subscriptionEnv();
 if(connection.adapter==='codex')env.CODEX_HOME=connection.accountRoot;
 if(connection.adapter==='claude'){if(path.resolve(connection.accountRoot)===path.join(os.homedir(),'.claude'))delete env.CLAUDE_CONFIG_DIR;else env.CLAUDE_CONFIG_DIR=connection.accountRoot;}
 const result=spawnSync(connection.executable,connection.adapter==='codex'?['login','status']:['auth','status'],{env,encoding:'utf8',timeout:15000});
 const output=(result.stdout||'')+(result.stderr||'');
 const valid=connection.adapter==='codex'?/using ChatGPT/i.test(output):/"authMethod"\s*:\s*"claude.ai"/.test(output);
 check(result.status===0&&valid,'subscriptionUnavailable','Selected CLI subscription login could not be verified; check login and host permission to read credentials');
}
