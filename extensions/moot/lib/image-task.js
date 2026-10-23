import fs from 'node:fs';import path from 'node:path';import {execFileSync} from 'node:child_process';import {randomUUID} from 'node:crypto';
import {requireValue as check} from './protocol.js';
export async function validateImageArtifacts(paths,allowedOutputRoot) {
 const root=fs.realpathSync(allowedOutputRoot);const artifacts=[];
 for(const file of paths) {
  const resolved=fs.existsSync(file)?fs.realpathSync(file):path.resolve(file);check(resolved.startsWith(root+path.sep),'invalidArtifact','Image outside output root');
  if(!fs.existsSync(file)||fs.lstatSync(file).isSymbolicLink()||!fs.statSync(file).isFile())continue;
  const bytes=fs.readFileSync(file);const png=bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]));const jpg=bytes[0]===255&&bytes[1]===216&&bytes[2]===255;const webp=bytes.toString('ascii',0,4)==='RIFF'&&bytes.toString('ascii',8,12)==='WEBP';
  if(!png&&!jpg&&!webp)continue;
  try {const info=execFileSync('/usr/bin/sips',['-g','pixelWidth','-g','pixelHeight',file],{encoding:'utf8',stdio:['ignore','pipe','ignore']});if(!/pixelWidth: [1-9]\d*/.test(info)||!/pixelHeight: [1-9]\d*/.test(info))continue;}catch{continue;}
  artifacts.push({id:randomUUID(),path:resolved,name:path.basename(file),mimeType:png?'image/png':jpg?'image/jpeg':'image/webp',bytes:bytes.length});
 }
 return artifacts;
}
export async function collectImages(connection,sessionID,outputRoot) {
 check(/^[\da-f-]{36}$/i.test(sessionID||''),'missingSession','No image tool conversation ID returned');
 // Only the exact generated-artifact directory of this task. Never scan chat history.
 const source=path.join(connection.accountRoot,'brain',sessionID);
 if(!fs.existsSync(source))return [];
 const copied=[];
 for(const name of fs.readdirSync(source)) {
  if(!/\.(png|jpe?g|webp)$/i.test(name))continue;
  const from=path.join(source,name);if(!fs.lstatSync(from).isFile()||fs.lstatSync(from).isSymbolicLink())continue;
  const to=path.join(outputRoot,name);fs.copyFileSync(from,to);fs.chmodSync(to,0o600);copied.push(to);
 }
 return validateImageArtifacts(copied,outputRoot);
}
