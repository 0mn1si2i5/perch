import fs from 'node:fs';import path from 'node:path';
import {safeID,readJSON,atomicJSON,withLock} from './storage.js';
import {requireValue as check} from './protocol.js';
export const terminal = r => ['ended','failed','cancelled'].includes(r.state);
export const runDirectory=(root,id)=>path.join(root,'runs',safeID(id));
export function readRun(root,id) {const r=readJSON(path.join(runDirectory(root,id),'run.json'));check(r,'notFound','Run not found');return r;}
export function updateRun(root,id,fn) {return withLock(path.join(runDirectory(root,id),'.lock'),()=>{const r=readRun(root,id);fn(r);r.revision++;r.updatedAt=new Date().toISOString();atomicJSON(path.join(runDirectory(root,id),'run.json'),r);return r;});}
export function listRuns(root) {const dir=path.join(root,'runs');if(!fs.existsSync(dir))return [];return fs.readdirSync(dir).filter(id=>/^[a-zA-Z0-9_-]+$/.test(id)).map(id=>readRun(root,id)).sort((a,b)=>b.createdAt.localeCompare(a.createdAt));}
