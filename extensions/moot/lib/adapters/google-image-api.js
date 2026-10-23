import fs from 'node:fs';import path from 'node:path';import {fileURLToPath} from 'node:url';import {spawnSync} from 'node:child_process';
import {assertCurrentPermission} from '../routing.js';import {validateImageArtifacts} from '../image-task.js';
function readCredential(ref) {
 const helper=fileURLToPath(new URL('../../PerchMootCredentials',import.meta.url));
 const result=spawnSync(helper,[],{input:JSON.stringify({operation:'read',ref}),encoding:'utf8',timeout:10000});
 if(result.status!==0||!result.stdout)throw Error('API credential unavailable; save it in Perch Keychain settings');return result.stdout;
}
export async function generateImage(config,route,prompt,outputRoot,dependencies={}) {
 assertCurrentPermission(config,route);
 const c=config.connections.find(c=>c.id===route.connectionID);
 const key=await (dependencies.readCredential??readCredential)(c.credentialRef);
 let response;
 try {response=await (dependencies.fetch??fetch)('https://generativelanguage.googleapis.com/v1beta/interactions',{method:'POST',headers:{'content-type':'application/json','x-goog-api-key':key},body:JSON.stringify({model:route.model||c.defaultModel,input:prompt,response_format:{type:'image'}}),signal:AbortSignal.timeout(120000),redirect:'error'});}catch{throw Error('Google image API network request failed');}
 if(!response.ok)throw Error(`Google image API returned HTTP ${response.status}`);
 const result=await response.json();const blocks=[];
 if(result.output_image)blocks.push(result.output_image);
 // REST interactions may expose image output as content blocks in generation steps.
 for(const step of result.steps||[])for(const block of step.content||[])if(block.type==='image')blocks.push(block);
 for(const block of result.outputs||[])if(block.type==='image')blocks.push(block);
 fs.mkdirSync(outputRoot,{recursive:true,mode:0o700});const files=[];
 for(const block of blocks)if(typeof block.data==='string'&&block.data.length<100*1024*1024){const ext=block.mime_type==='image/jpeg'?'jpg':block.mime_type==='image/webp'?'webp':'png';const file=path.join(outputRoot,`api-image-${files.length+1}.${ext}`);fs.writeFileSync(file,Buffer.from(block.data,'base64'),{mode:0o600});files.push(file);}
 const artifacts=await validateImageArtifacts(files,outputRoot);if(!artifacts.length)throw Error('Google API returned no readable image');return artifacts;
}
