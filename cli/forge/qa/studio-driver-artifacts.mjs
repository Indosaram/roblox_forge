import {createHash} from 'node:crypto';
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
// Digest the immutable measured run before attaching external observations.
export const runDigest=outcome=>hash(JSON.stringify({scenario:outcome.scenario,runtime:outcome.runtime,clients:outcome.clients,steps:outcome.steps,inputs:outcome.inputs,calls:outcome.calls,captures:outcome.captures}));
export async function attachSupplement(outcome, supplement, readArtifact) {
  if(supplement.runSha256!==runDigest(outcome)) throw new Error('supplement run digest mismatch');
  const result=structuredClone(outcome);
  result.audio=[];
  for(const audio of supplement.audio || []) {
    if(typeof audio.path!=='string' || hash(await readArtifact(audio.path))!==audio.sha256) throw new Error('external audio digest mismatch');
    result.audio.push(structuredClone(audio));
  }
  // Preserve supplied observations, never infer unprompted, shortcut, approval,
  // goalDigest, or audio quality from scripted execution or a filename.
  result.firstPlay={goals:{}};
  for(const [id,goal] of Object.entries(supplement.firstPlay?.goals || {})) {
    const step=result.steps[goal.step-1];
    if(!step || step.index!==goal.step || !Number.isFinite(goal.elapsedSeconds) || goal.elapsedSeconds<step.startedSeconds || goal.elapsedSeconds>step.elapsedSeconds) throw new Error('goal time/action link mismatch');
    if(['advance_to','advance_elapsed','begin_clock','restore','server_command'].includes(step.op)) throw new Error('shortcut cannot establish firstplay goal');
    if(!Array.isArray(goal.actors) || !goal.actors.length || new Set(goal.actors).size!==goal.actors.length || goal.actors.some(actor=>!result.captures.some(c=>c.actor===actor) || !result.clients.some(c=>c.actor===actor))) throw new Error('goal actor/capture link mismatch');
    result.firstPlay.goals[id]=structuredClone(goal);
  }
  result.supplement={runSha256:supplement.runSha256,sha256:hash(JSON.stringify(supplement))};
  return result;
}
