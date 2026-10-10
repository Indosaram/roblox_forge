import { createHash } from 'node:crypto';

// Serializes measured evidence only. Missing actor-specific durable loads or
// backend instance identity is an error, never a fabricated capability claim.
export async function writeRejoin(outcome, buildIdentity, artifactWriter) {
  const proof = async (name, document) => {
    const bytes=Buffer.from(JSON.stringify(document));
    return {path:await artifactWriter(name,bytes),sha256:createHash('sha256').update(bytes).digest('hex')};
  };
  const contexts=[];
  const epochs=[];
  for(const epoch of outcome.epochs || []) {
    const observed=epoch.backendObservation;
    if(observed?.configConsumed!==true || !observed.identity?.instanceId || observed.overflow)throw new Error('REJOIN_RUNTIME_BACKEND_UNOBSERVED');
    const context={observed:true,configConsumed:true,backendIdentity:observed.identity.instanceId,hostOwnership:observed.identity.instanceId,sessionOwnership:epoch.actorMappings[0].processIdentity,sessionId:epoch.runtime.server.sessionId,mode:observed.identity.mode,namespace:observed.identity.namespace};
    if(epoch.hostReady?.listening!==true || epoch.installation?.succeeded!==true)throw new Error('REJOIN_RAW_OWNERSHIP_REQUIRED');
    context.backendEpoch=observed.identity.epoch;
    context.backendServerSessionId=observed.identity.serverSessionId;
    const prefix=`rejoin-epoch-${epoch.epoch}`;
    const snapshot=await proof(prefix+'-snapshot.json',observed);
    context.hostReady=await proof(prefix+'-host.json',{ready:true,hostOwnership:context.hostOwnership,databaseIdentity:context.backendIdentity,backendIdentity:context.backendIdentity});
    context.resourceOwnership=await proof(prefix+'-resource.json',{owned:true,exclusiveDatabase:true,databaseIdentity:context.backendIdentity,hostOwnership:context.hostOwnership,sessionOwnership:context.sessionOwnership,processIdentity:context.sessionOwnership});
    context.snapshot=snapshot;
    context.loadedHandshake=await proof(prefix+'-handshake.json',epoch.runtime);
    context.installation=await proof(prefix+'-installation.json',epoch.installation);
    context.consumedObservation=await proof(prefix+'-consumed.json',{folderAbsent:observed.configConsumed,snapshotObserved:true,sessionOwnership:context.sessionOwnership,sessionId:context.sessionId,buildIdentity,snapshotSha256:snapshot.sha256,invocation:'execute_luau/Server:ForgePersistence.snapshot+config-folder-absence'});
    contexts.push(context);
    const {backendObservation,hostReady,installation,...publicEpoch}=epoch;
    epochs.push({...publicEpoch,backendEvidence:await proof(`rejoin-epoch-${epoch.epoch}-backend.json`,context)});
  }
  const transitions=[];
  for(const transition of outcome.transitions || []) {
    const backend=transition.backendIdentity;
    if(!backend?.instanceId)throw new Error('REJOIN_BACKEND_INSTANCE_IDENTITY_REQUIRED');
    const load=transition.loadEvidence.find(entry=>entry.profileKey==='player-'+transition.actor || entry.profileKey.endsWith(':'+transition.actor));
    if(!load)throw new Error('REJOIN_ACTOR_LOAD_REQUIRED');
    const committed=JSON.parse(load.committed.serialized),previous=JSON.parse(load.loaded.previousSerialized);
    const data=committed.data?.envelope || committed.data;
    const bag=data?.genres?.['survival-coop']?.data?.inventory?.bag?.items;
    if(!bag || !Number.isSafeInteger(committed.revision) || !Number.isSafeInteger(previous?.revision))throw new Error('REJOIN_DURABLE_ITEMS_REQUIRED');
    const retainedItems=Object.fromEntries(Object.entries(bag).map(([id,item])=>[id,item.quantity]));
    const loadedData=previous.data?.envelope || previous.data;
    const loadedBag=loadedData?.genres?.['survival-coop']?.data?.inventory?.bag?.items;
    if(!loadedBag)throw new Error('REJOIN_LOADED_ITEMS_REQUIRED');
    const loadedItems=Object.fromEntries(Object.entries(loadedBag).map(([id,item])=>[id,item.quantity]));
    const canonical=items=>JSON.stringify(Object.fromEntries(Object.entries(items).sort(([a],[b])=>a.localeCompare(b))));
    if(canonical(loadedItems)!==canonical(retainedItems))throw new Error('REJOIN_LOADED_ITEMS_CHANGED');
    const before=outcome.epochs[transition.fromEpoch-1],after=outcome.epochs[transition.toEpoch-1];
    const old=before.actorMappings.find(actor=>actor.actor===transition.actor),next=after.actorMappings.find(actor=>actor.actor===transition.actor);
    if(!old || !next || transition.closeEvidence.released!==true)throw new Error('REJOIN_CLOSE_OR_MAPPING_REQUIRED');
    const prefix=`rejoin-${transition.fromEpoch}-${transition.actor}`;
    const identity=backend.instanceId;
    const recordTime=(epoch,record)=>{
      if(!Number.isFinite(epoch.clockAnchor?.runtimeMillis)||!Number.isFinite(epoch.clockAnchor?.elapsedSeconds)||!Number.isFinite(record.endedAtMs))throw new Error('REJOIN_RECORD_CLOCK_ANCHOR_REQUIRED');
      return epoch.clockAnchor.elapsedSeconds+(record.endedAtMs-epoch.clockAnchor.runtimeMillis)/1000;
    };
    const wrapperRef=(name,record,epoch)=>proof(name,{...record,identity:epoch.backendObservation.identity,hostOwnership:epoch.backendObservation.identity.instanceId,sessionOwnership:epoch.actorMappings[0].processIdentity,buildIdentity,handshakeSessionId:epoch.runtime.server.sessionId});
    const commitWrapper=await wrapperRef(prefix+'-commit-wrapper.json',load.committed,before);
    const loadWrapper=await wrapperRef(prefix+'-load-wrapper.json',load.loaded,after);
    transitions.push({...transition,backendIdentity:identity,profileKey:load.profileKey,committedRevision:committed.revision,loadedRevision:previous.revision,retainedItems,
      commitEvidence:await proof(prefix+'-commit.json',{...contexts[transition.fromEpoch-1],wrapperEvidence:commitWrapper,observedPersistedWrapper:true,updateAsyncReturned:true,durable:true,actor:transition.actor,profileKey:load.profileKey,backendIdentity:identity,revision:committed.revision,items:retainedItems,elapsedSeconds:recordTime(before,load.committed),record:load.committed}),
      closeEvidence:await proof(prefix+'-close.json',{exited:true,processIdentity:old.processIdentity,clientSessionId:old.clientSessionId,elapsedSeconds:transition.closedSeconds,job:transition.closeEvidence}),
      loadEvidence:await proof(prefix+'-load.json',{...contexts[transition.toEpoch-1],wrapperEvidence:loadWrapper,observedPersistedWrapper:true,physicalReconnect:true,shortcut:false,restore:false,actor:transition.actor,profileKey:load.profileKey,backendIdentity:identity,clientSessionId:next.clientSessionId,processIdentity:next.processIdentity,revision:previous.revision,items:loadedItems,elapsedSeconds:recordTime(after,load.loaded),record:load.loaded}),
    });
  }
  if(!transitions.length || !outcome.ok)throw new Error('REJOIN_SUCCESS_EVIDENCE_REQUIRED');
  const capability=await proof('rejoin-capability.json',{verified:true,physicalClose:true,physicalReconnect:true,durableBackend:true,api:'owned-job-restart-and-observed-backend-load',backendIdentity:transitions[0].backendIdentity,hostOwnership:contexts[0].hostOwnership,mode:contexts[0].mode,namespace:contexts[0].namespace});
  const document={schemaVersion:1,kind:'physical-rejoin',buildIdentity,capability,epochs,transitions,actions:outcome.steps.filter(step=>step.op!=='rejoin'),captures:outcome.captures};
  return proof('physical-rejoin.json',document);
}
