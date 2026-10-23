#!/usr/bin/env node
import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import {randomUUID} from 'node:crypto';
import {handleRequest} from '../lib/rpc.js';
const root=process.env.MOOT_ROOT||path.join(os.homedir(),'Library/Application Support/Perch/Extensions/Moot');
const [command,...args]=process.argv.slice(2);
let request;
try {
 if(command==='rpc') request=JSON.parse(fs.readFileSync(0,'utf8'));
 else if(['status','results','stop'].includes(command))request={protocolVersion:1,requestID:randomUUID(),operation:command==='stop'?'run.cancel':'run.read',payload:{runID:args[0]}};
 else if(command==='ls')request={protocolVersion:1,requestID:randomUUID(),operation:'run.list',payload:{}};
 else if(['delegate','audit'].includes(command)) {const option=n=>args[args.indexOf(n)+1];request={protocolVersion:1,requestID:randomUUID(),operation:command+'.start',payload:{requestID:randomUUID(),trigger:'userRequested',capabilityID:args.includes('--capability')?option('--capability'):'general',briefPath:option('--brief'),workdir:option('--workdir'),hostRef:'cli'}};}
 else throw Error('Usage: moot rpc | ls | status/results/stop RUN_ID | delegate/audit --brief FILE --workdir DIR [--capability ID]');
 const result=await handleRequest(request,{root});process.stdout.write(JSON.stringify(result)+'\n');if(!result.ok)process.exitCode=1;
}catch(e){process.stdout.write(JSON.stringify({protocolVersion:1,requestID:request?.requestID||'',ok:false,error:{code:'invalidInput',message:e.message}})+'\n');process.exitCode=1;}
