import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import {createHash} from 'node:crypto';
import {handleRequest} from '../lib/rpc.js';import {atomicJSON,readJSON} from '../lib/storage.js';
test('pending uninstall outlives caller, preserves user changes and history',async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'moot lifecycle 中文 '));
 try {
  const version=path.join(root,'versions/v1');fs.mkdirSync(version,{recursive:true});fs.writeFileSync(path.join(version,'binary'),'owned');fs.symlinkSync('versions/v1',path.join(root,'current'));
  const own=path.join(root,'skills/owned/SKILL.md'),foreign=path.join(root,'skills/changed/SKILL.md');fs.mkdirSync(path.dirname(own),{recursive:true});fs.mkdirSync(path.dirname(foreign),{recursive:true});fs.writeFileSync(own,'owned');fs.writeFileSync(foreign,'manually changed');
  const hash=s=>createHash('sha256').update(s).digest('hex');atomicJSON(path.join(root,'install-receipt.json'),{version:'0.1.0',state:'installed',ownedFiles:[version],skillLinks:{[own]:hash('owned'),[foreign]:hash('original')},backupRefs:[]});
  atomicJSON(path.join(root,'runs/waiting/run.json'),{id:'waiting',state:'awaitingHost',createdAt:'2026',task:{}});fs.writeFileSync(path.join(root,'config.json'),'keep configuration');
  const call=(operation,payload={})=>handleRequest({protocolVersion:1,requestID:'life',operation,payload},{root});
  assert.deepEqual((await call('runtime.quiesce')).data.activeRunIDs,['waiting']);assert.equal((await call('runtime.uninstall')).ok,true);
  await new Promise(r=>setTimeout(r,250));assert.ok(fs.existsSync(version),'awaiting host still counts as active');
  atomicJSON(path.join(root,'runs/waiting/run.json'),{id:'waiting',state:'ended',createdAt:'2026',task:{}});
  for(let i=0;i<70&&readJSON(path.join(root,'install-receipt.json')).state!=='notInstalled';i++)await new Promise(r=>setTimeout(r,50));
  assert.equal(readJSON(path.join(root,'install-receipt.json')).state,'notInstalled');assert.equal(fs.existsSync(version),false);assert.equal(fs.existsSync(own),false);assert.equal(fs.readFileSync(foreign,'utf8'),'manually changed');assert.equal(fs.readFileSync(path.join(root,'config.json'),'utf8'),'keep configuration');assert.ok(fs.existsSync(path.join(root,'runs/waiting/run.json')));
 }finally{fs.rmSync(root,{recursive:true,force:true});}
});
