import test from 'node:test';import assert from 'node:assert/strict';import {validateRequest} from '../lib/protocol.js';import {assertCurrentPermission} from '../lib/routing.js';
test('unknown protocol rejected',()=>assert.throws(()=>validateRequest({protocolVersion:2}),/protocol/));
test('API revocation beats an old run snapshot',()=>assert.throws(()=>assertCurrentPermission({apiEnabled:false,connections:[{id:'api',enabled:true,credentialRef:'k'}],capabilities:[{id:'image',enabled:true,fallbackConnectionIDs:['api']}]},{authMode:'api',connectionID:'api',capabilityID:'image'}),/revoked/));
