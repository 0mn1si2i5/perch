import {requireValue as check, MootError} from './protocol.js';
export function assertTrigger(config, task) {
  if(task.mode==='roundtable') {
    check(['userRequested','automatic'].includes(task.trigger),'invalidTrigger','Roundtable trigger required');
    check(task.trigger!=='automatic'||config.automaticRoundtable,'automaticDisabled','Automatic roundtable is disabled');
  }
}
export function resolveRoute(config,task,availability={}) {
  assertTrigger(config,task);
  const capability=config.capabilities.find(c=>c.id===task.capabilityID)??config.capabilities.find(c=>c.id==='general');
  check(capability?.enabled,'disabledCapability','No enabled capability configured');
  const explicit=Boolean(task.explicitConnectionID||task.explicitModel);
  let ids=[capability.primaryConnectionID,...capability.fallbackConnectionIDs];
  if(task.explicitConnectionID) ids=[task.explicitConnectionID];
  else if(task.explicitModel) ids=ids.filter(id=>{const c=config.connections.find(c=>c.id===id);return c?.defaultModel===task.explicitModel||c?.models?.includes(task.explicitModel)||capability.modelOverride===task.explicitModel;});
  const candidates=ids.map(id=>config.connections.find(c=>c.id===id)).filter(Boolean);
  candidates.sort((a,b)=>(a.authMode==='api')-(b.authMode==='api'));
  const chosen=candidates.find(c=>c.enabled&&availability[c.id]!==false&&capability.requiredTools.every(t=>c.tools.includes(t))&&(c.authMode==='subscription'||(task.mode!=='audit'&&capability.completionMode==='image'&&config.apiEnabled&&capability.fallbackConnectionIDs.includes(c.id)&&!!c.credentialRef)));
  if(!chosen)throw new MootError(explicit?'explicitUnavailable':'noAvailableConnection',explicit?'Explicit model/account unavailable; no substitution':'No available authorized connection');
  return {connectionID:chosen.id,model:task.explicitModel||(chosen.id===capability.primaryConnectionID?capability.modelOverride:null)||chosen.defaultModel,authMode:chosen.authMode,completionMode:task.mode==='audit'?'audit':capability.completionMode,requiredTools:capability.requiredTools,capabilityID:capability.id,reason:explicit?'Explicit selection':chosen.id===capability.primaryConnectionID?'Configured primary':'Configured fallback',instructions:capability.instructions||''};
}
export function assertCurrentPermission(config,route) {
  const connection=config.connections.find(c=>c.id===route.connectionID);
  check(connection?.enabled,'permissionRevoked','Connection no longer enabled');
  if(route.authMode==='api') {
    const cap=config.capabilities.find(c=>c.id===route.capabilityID);
    check(config.apiEnabled&&cap?.enabled&&cap.fallbackConnectionIDs.includes(connection.id)&&connection.credentialRef,'permissionRevoked','API permission revoked');
  }
}
