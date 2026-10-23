import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { MootError } from './protocol.js';
export const readJSON = (file, fallback) => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch(e) { if(e.code==='ENOENT') return fallback; throw e; } };
export function atomicJSON(file, value) {
  fs.mkdirSync(path.dirname(file), {recursive:true,mode:0o700});
  const tmp = file + '.' + randomUUID();
  try { fs.writeFileSync(tmp, JSON.stringify(value,null,2)+'\n',{mode:0o600}); fs.renameSync(tmp,file); }
  finally { fs.rmSync(tmp,{force:true}); }
}
export function withLock(file, action) {
  fs.mkdirSync(path.dirname(file),{recursive:true,mode:0o700});
  try { fs.mkdirSync(file); } catch(e) { if(e.code!=='EEXIST')throw e; throw new MootError('busy','Another operation is saving this record; retry shortly'); }
  try { return action(); } finally { fs.rmdirSync(file); }
}
export function safeID(id) {
  if(typeof id!=='string'|| !/^[a-zA-Z0-9_-]{1,128}$/.test(id)) throw new MootError('invalidID','Invalid record ID');
  return id;
}
