import { test, expect } from 'bun:test';
import { writeRejoin } from './studio-driver-rejoin.mjs';

test('rejoin writer refuses missing measured backend identity before writing approval',async()=>{
  const writes=[];
  await expect(writeRejoin({ok:true,transitions:[{backendIdentity:{}}]},'build',async(name)=>{writes.push(name);return name;})).rejects.toThrow('REJOIN_BACKEND_INSTANCE_IDENTITY_REQUIRED');
  expect(writes).toEqual([]);
});

test('empty rejoin cannot create verified capability',async()=>{
  const writes=[];
  await expect(writeRejoin({ok:true,transitions:[]},'build',async(name)=>{writes.push(name);return name;})).rejects.toThrow('REJOIN_SUCCESS_EVIDENCE_REQUIRED');
  expect(writes).toEqual([]);
});
