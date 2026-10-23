import fs from 'node:fs';import path from 'node:path';import {createHash} from 'node:crypto';import {listRuns,terminal} from './runs.js';import {readJSON,atomicJSON} from './storage.js';
const root=process.argv[2];
while(listRuns(root).some(r=>!terminal(r)))await new Promise(r=>setTimeout(r,2000));
const file=path.join(root,'install-receipt.json'),receipt=readJSON(file);
if(receipt?.state==='pendingUninstall') {
 for(const [file,digest] of Object.entries(receipt.skillLinks||{})) {
  if(fs.existsSync(file)&&createHash('sha256').update(fs.readFileSync(file)).digest('hex')===digest){fs.unlinkSync(file);try{fs.rmdirSync(path.dirname(file));}catch{}}
 }
 for(const file of receipt.ownedFiles||[])if(path.resolve(file).startsWith(path.join(root,'versions')+path.sep))fs.rmSync(file,{recursive:true,force:true});
 const current=path.join(root,'current');if(fs.existsSync(current)||fs.lstatSync(current,{throwIfNoEntry:false}))fs.rmSync(current,{force:true});
 receipt.state='notInstalled';receipt.ownedFiles=[];receipt.skillLinks={};atomicJSON(path.join(root,'install-receipt.json'),receipt);
}
