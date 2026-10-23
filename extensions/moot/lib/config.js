import path from 'node:path';
import {atomicJSON,readJSON,withLock} from './storage.js';
import {requireValue as check} from './protocol.js';
export function defaultConfig() { return {schemaVersion:1,revision:0,apiEnabled:false,automaticRoundtable:false,connections:[],capabilities:[],meetingPreset:{seats:[],maxRounds:3,allowEarlyFinish:false}}; }
export function validateConfig(c) {
  check(c?.schemaVersion===1,'incompatibleConfig','Unsupported configuration version');
  check(typeof c.apiEnabled==='boolean'&&typeof c.automaticRoundtable==='boolean','invalidConfig','Permission switches required');
  check(Array.isArray(c.connections)&&Array.isArray(c.capabilities),'invalidConfig','Connections and capabilities required');
  const ids = new Set();
  for(const x of c.connections) {
    check(x.id && !ids.has(x.id),'invalidConfig','Duplicate connection');ids.add(x.id);
    check(['codex','claude','agy','google-image-api'].includes(x.adapter),'invalidConfig','Unsupported adapter');
    check(['subscription','api'].includes(x.authMode) && (x.authMode==='api')===(x.adapter==='google-image-api'),'invalidConfig','Adapter/authentication mismatch');
    check(Array.isArray(x.tools),'invalidConfig','Tool list required');
    if(x.authMode==='subscription')check(path.isAbsolute(x.executable)&&path.isAbsolute(x.accountRoot),'invalidConfig','Executable and account root must be absolute paths');
    check(!('secret' in x)&&!('apiKey' in x),'invalidConfig','Store credentials in Keychain');
  }
  const capabilities=new Set();
  for(const x of c.capabilities) {
    check(x.id&&!capabilities.has(x.id),'invalidConfig','Duplicate capability'); capabilities.add(x.id);
    check(!x.enabled || ids.has(x.primaryConnectionID),'invalidConfig','Unknown primary connection');
    check(Array.isArray(x.requiredTools)&&Array.isArray(x.fallbackConnectionIDs),'invalidConfig','Capability tools/fallbacks required');
    check(x.fallbackConnectionIDs.every(id=>ids.has(id)),'invalidConfig','Unknown fallback connection');
    check(['delegate','audit','draft','image'].includes(x.completionMode),'invalidConfig','Unknown completion mode');
    check(!x.enabled || c.connections.find(v=>v.id===x.primaryConnectionID)?.authMode==='subscription','invalidConfig','API is a fallback only');
  }
  const m=c.meetingPreset;
  check(m&&Number.isInteger(m.maxRounds)&&m.maxRounds>=1&&m.maxRounds<=10&&Array.isArray(m.seats)&&m.seats.length<=6,'invalidConfig','Meeting requires 1–10 rounds and up to 6 seats');
  const seats=new Set();
  for(const s of m.seats) {check(s.seatID&&!seats.has(s.seatID)&&ids.has(s.connectionID),'invalidConfig','Invalid meeting seat connection');seats.add(s.seatID);}
  return c;
}
export function loadConfig(root) { const c=readJSON(path.join(root,'config.json'),defaultConfig());return validateConfig(c); }
export function saveConfig(root,config,expectedRevision) {
  return withLock(path.join(root,'.config-lock'),()=>{
    const current=loadConfig(root); check(current.revision===expectedRevision,'revisionConflict','Configuration revision changed; reload before saving');
    const next=validateConfig(structuredClone(config));next.revision=current.revision+1;
    atomicJSON(path.join(root,'config.json'),next);return next;
  });
}
