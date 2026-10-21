// Run from the repository root with Bun. Prints the authored YAML; it never
// writes generated files. catalog-tables.json preserves the approved tables and
// every legacy definition, including superseded recipe identities.
// All authored quantities, effects, geometry and dialogue are RECONSTRUCTED.
import { readFileSync } from 'node:fs';

const provenance = { classification: 'RECONSTRUCTED' };
const row = value => ({ ...value, provenance: { ...provenance } });
const clean = value => value.replaceAll('`', '').replaceAll('**', '').trim();
const title = id => id.replace(/([a-z])([A-Z])/g, '$1 $2').replaceAll('-', ' ').replaceAll('_', ' ').replace(/\b\w/g, s => s.toUpperCase());
const point = (x, y, z) => ({ x, y, z });
const points = text => [...text.matchAll(/\((-?\d+),(-?\d+),(-?\d+)\)/g)].map(m => point(...m.slice(1).map(Number)));
const quantities = text => [...clean(text).matchAll(/([a-z][a-z0-9-]*)\s*[×]\s*(\d+)/g)].map(m => ({ item: m[1], quantity: Number(m[2]) }));
const effect = (id, value, unit) => ({ id, value, unit: unit.replaceAll('pioneer', 'development') });
const objective = (id, action, target, quantity = 1, extra = {}) => ({ id, action, target, quantity, ...extra });
const prefixes = { p: 'processing', w: 'weapon_tool', t: 'tailoring', k: 'cooking', f: 'farming', g: 'gathering', c: 'construction', s: 'survival' };
const nodes = text => [...text.matchAll(/([pwtkfgcs])(\d)/g)].map(m => `${prefixes[m[1]]}_${m[2]}`);
const station = text => {
  text = clean(text);
  const tier = text.match(/[BK]([123])/);
  if (tier) return { station: text.includes('B') ? 'workbench' : 'kiln', stationTier: Number(tier[1]) };
  return ['hand', 'direct build'].includes(text) ? {} : { station: text };
};

export function buildCatalog(snapshot) {
  const d = structuredClone(snapshot.legacy);
  const tables = snapshot.tables;
  // Empty YAML sequences in the old Lune emitter deserialize as null in Bun.
  for (const item of d.items) item.tags ??= [];
  d.survival_content = 2;
  d.limits.slots = 30;
  d.limits.tribeMaxMembers = 50;
  for (const name of ['skillCategories', 'skillNodes', 'materials', 'operations', 'recipeDetails', 'wildlifeDetails', 'layouts', 'stages', 'supportRegions', 'missions', 'guides', 'chapters']) d[name] = [];
  const locale = new Map();
  const legacyMappings = {};
  const addString = (key, text) => locale.set(key, text.replaceAll('reed', 'fiber').replaceAll('samphire', 'onion').replaceAll('pioneer', 'development').replaceAll('tier-two pick or better', 'tier-one pick or better'));
  const addItem = (id, kind = 'raw') => {
    if (d.items.some(i => i.id === id)) return;
    const gear = ['gear', 'instrument'].includes(kind);
    d.items.push({ id, name: title(id), stackMax: gear || kind === 'kit' ? 1 : kind === 'food' ? 20 : 50, weightMilli: 500, tags: [], ...(gear ? { maxDurabilityMilli: 100000 } : {}) });
    addString(`item_${id.replaceAll('-', '_')}`, title(id));
  };
  const addStructure = (id, kit, isStation = true) => {
    if (d.structures.some(s => s.id === id)) return;
    addItem(kit, 'kit');
    d.structures.push({ id, footprintX: 2, footprintZ: 2, station: isStation, cost: [{ item: kit, quantity: 1 }], ...(isStation ? { tier: 1 } : {}) });
  };
  for (const [id, kit] of Object.entries({ kiln: 'kiln-kit', 'tanning-frame': 'tanning-frame-kit', refrigerator: 'refrigerator-kit', tent: 'tent-kit', bed: 'bed-kit', well: 'well-kit', 'communication-station': 'communication-station-kit', laboratory: 'laboratory-kit', 'clan-hall': 'clan-hall-kit', 'animal-pen': 'animal-pen' })) addStructure(id, kit);
  for (const id of ['wall', 'stairs', 'door', 'roof', 'pillar', 'volcanic-wall']) addStructure(id, ['roof', 'pillar', 'volcanic-wall'].includes(id) ? id : `${id}-kit`, false);
  const requiredRows = tables.recipe.filter(r => /^[PTWCFAHLVS]\d\d$/.test(r[0]));
  for (const r of requiredRows) {
    const [number, id, inputText] = r;
    const cooking = number.startsWith('F');
    const [, , , count, stationText, gate, nodeText, seconds] = cooking ? r : [r[0], r[1], r[2], 1, r[3], r[4], r[5], r[6]];
    const [left, outputText] = inputText.split('→');
    const [primaryText, auxiliaryText = ''] = left.split(';');
    const primary = quantities(primaryText), auxiliary = quantities(auxiliaryText);
    const outputs = outputText ? quantities(outputText) : [{ item: id, quantity: Number(count) }];
    const recipe = { id, craftMillis: Number(seconds) * 1000, inputs: [...primary, ...auxiliary], outputs, ...(station(stationText).station ? { station: station(stationText).station } : {}) };
    const old = d.recipes.find(x => x.id === id);
    if (old) {
      // Keep old recipe data available under an explicit compatibility identity;
      // old saved items retain their exact original ID and definition.
      old.id = `legacy-${id}`;
      legacyMappings[id] = old.id;
    }
    for (const q of recipe.inputs) addItem(q.item);
    for (const q of recipe.outputs) addItem(q.item, cooking ? 'food' : /^[TWC SHV]/.test(number[0]) ? 'gear' : number.startsWith('L') ? 'kit' : 'processed');
    d.recipes.push(recipe);
    const levels = clean(gate).match(/(\d+)\/(\d+|—)/);
    const species = inputText.match(/sourceSpeciesId=([a-zA-Z]+)/)?.[1];
    d.recipeDetails.push(row({ id, minCharacterLevel: Number(levels[1]), primaryMaterialLevel: levels[2] === '—' ? 0 : Number(levels[2]), primaryInputs: primary.map(q => q.item), auxiliaryInputs: auxiliary.map(q => q.item), skillNodes: nodes(nodeText), seconds: Number(seconds), ...(station(stationText).stationTier ? { stationTier: station(stationText).stationTier } : {}), ...(species ? { sourceSpeciesId: species } : {}) }));
    addString(`recipe_${id.replaceAll('-', '_')}`, `${title(id)} recipe`);
  }
  const operation = (id, kind, inputText, outputText, seconds, gates = {}, where = {}, extra = {}) => {
    const [primaryText, auxiliaryText = ''] = inputText.split(';');
    const primary = quantities(primaryText), auxiliary = quantities(auxiliaryText), outputs = quantities(outputText);
    for (const q of [...primary, ...auxiliary, ...outputs]) addItem(q.item, kind === 'instrument' ? 'instrument' : 'processed');
    d.operations.push(row({ id, kind, inputs: [...primary, ...auxiliary], outputs, seconds, gates, effects: [], primaryInputs: primary.map(q => q.item), auxiliaryInputs: auxiliary.map(q => q.item), ...where, ...extra }));
  };
  operation('practice-fiber-stitch', 'practice', 'fiber×2', 'practice-stitch×1', 3, { characterLevel: 1 }, {}, { effects: [effect('tailoring-xp', 10, 'xp')] });
  operation('practice-seedbed', 'practice', 'fiber×2;water×1', 'practice-seedbed×1', 3, { characterLevel: 1 }, {}, { effects: [effect('farming-xp', 10, 'xp')] });
  // The existing berry-meal recipe already has the exact tutorial input/time.
  d.recipeDetails.push(row({ id: 'berry-meal', minCharacterLevel: 1, primaryMaterialLevel: 0, primaryInputs: ['berry'], auxiliaryInputs: [], skillNodes: [], seconds: 3 }));
  for (const r of tables['auxiliary-material'].filter(r => r[0].startsWith('instrument-') && r.length === 4)) operation(r[0], 'instrument', r[1], `${r[0]}×1`, Number(r[3]), { characterLevel: 20, skillNodes: ['weapon_tool_1'] }, { station: 'workbench', stationTier: 1 }, { primaryMaterialLevel: 20 });
  for (const [id, input, output, where, gate, seconds] of tables['auxiliary-material'].filter(r => /^(build-|upgrade-)/.test(r[0]))) {
    const isUpgrade = id.startsWith('upgrade');
    const tier = isUpgrade ? Number(id.at(-1)) : undefined;
    const stationId = id.includes('workbench') ? 'workbench' : 'kiln';
    operation(id, isUpgrade ? 'upgrade' : 'processing', input, isUpgrade ? '' : `${id.replace('build-', '')}×1`, Number(seconds), { characterLevel: Number(gate.match(/\d+/)[0]), skillNodes: [gate.match(/construction_\d/)[0]] }, isUpgrade ? { station: stationId, stationTier: tier - 1 } : station(where), { primaryMaterialLevel: gate.includes('/—') ? 0 : Number(gate.match(/\/(\d+)/)[1]), ...(isUpgrade ? { tier } : {}) });
  }
  for (const r of tables['auxiliary-material'].filter(r => /^research-(life|light|heavy)-\d$/.test(r[0]))) {
    const tier = Number(r[0].at(-1)), line = r[0].split('-')[1];
    operation(r[0], 'research', r[1], '', Number(r[3]), { characterLevel: 30, developmentRank: 3, ...(tier > 1 ? { completed: [r[0].replace(/\d$/, String(tier - 1))] } : {}) }, { station: 'laboratory' }, { tier, cost: Number(r[1].match(/Coins (\d+)/)[1]), effects: [effect(`${line}-reduction`, -(line === 'heavy' ? 3 : 2) * tier, 'percent')] });
  }
  for (const r of tables['auxiliary-material'].filter(r => /^modify-/.test(r[0]))) operation(r[0], 'modifier', r[1], '', 10, { characterLevel: 30 }, { station: 'workbench', stationTier: 2 }, { targetConsumed: false, eligibleTags: [r[0] === 'modify-sharpness' ? 'weapon-tool' : 'clothing'], effects: [effect(r[0].replace('modify-', ''), 2, 'attribute')] });
  for (const r of tables['auxiliary-material'].filter(r => /^support-tier-/.test(r[0]))) {
    const tier = Number(r[0].at(-1));
    operation(r[0], 'support-tier', r[1], '', Number(r[3]), { characterLevel: 60, ...(tier > 1 ? { completed: [`support-tier-${tier - 1}`] } : {}) }, { station: 'communication-station' }, { tier, cost: Number(r[1].match(/Coins (\d+)/)[1]), effects: [effect('base-performance', tier * 5, 'percent')], eligibleTags: ['weapon-tool', 'clothing'], targetConsumed: false });
  }
  for (const r of tables['auxiliary-material'].filter(r => /^clan-research-/.test(r[0]))) operation(r[0], 'clan-research', '', '', Number(r[4]), { clanLevel: Number(r[2].match(/\d+/)[0]), capability: 'research-spending' }, { station: 'clan-hall' }, { cost: Number(r[1].match(/\d+/)[0]), effects: [effect(r[0].replace('clan-research-', ''), r[0].includes('advanced') ? 1 : -5, r[0].includes('advanced') ? 'unlock' : 'percent')] });
  operation('repair-equipment', 'repair', '', '', 5, {}, { station: 'workbench' }, { targetConsumed: false, eligibleTags: ['weapon-tool', 'clothing', 'saddle', 'instrument', 'sprinkler'], effects: [effect('durability', 100, 'maximum'), effect('material-per-missing-durability', 25, 'durability')] });
  // Spoilage is age settlement, not a free zero-input producer.
  operation('food-spoilage', 'food', 'berry×1', 'spoiled-food×1', 172800, {}, {}, { effects: [effect('refrigeration-age-rate', 0.25, 'multiplier')] });
  for (const [id, inputs, output, level] of [
    ['assemble-bandage', 'fiber×2', 'bandage', 1],
    ['assemble-signal-lens', 'stone×2+fiber×2', 'signal-lens', 20],
    ['assemble-sample-case', 'branch×3+fiber×3', 'sample-case', 30],
    ['assemble-research-bundle', 'iron-ore×3+fiber×3', 'research-bundle', 40],
    ['assemble-shelter-liner', 'fur×3+fiber×3', 'shelter-liner', 50],
    ['assemble-heat-brace', 'volcanic-bone×1+iron-ore×2', 'heat-brace', 60],
    ['assemble-rescue-transponder', 'iron-ore×2+cord×2+signal-fragment×1', 'rescue-transponder', 60],
  ]) operation(id, 'processing', inputs, `${output}×1`, output === 'bandage' ? 3 : 5, { characterLevel: level, capability: output === 'bandage' ? 'active-guide-g20' : `active-chapter-${output}` }, output === 'bandage' ? {} : { station: 'workbench', stationTier: 1 });
  for (const [process, deltas] of Object.entries({ dry: { hardness: 1, flexibility: -1 }, tan: { flexibility: 2 }, polish: { sharpness: 2 }, smelt: { hardness: 2 }, ferment: { nutrition: 2 }, compost: { fertility: 2 } })) {
    // Effects on canonical recipes are expressed as a non-producing policy row;
    // this does not create an alternative producer that bypasses recipe gates.
    operation(`processing-policy-${process}`, 'processing', '', '', 1, {}, {}, { effects: [effect('processing-budget-consumed', 1, 'budget'), ...Object.entries(deltas).map(([id, value]) => effect(id, value, 'attribute-clamp-0-10'))] });
  }
  for (const r of tables['auxiliary-material'].filter(r => r.length === 4 && /^(corn|potato|wheat|onion|flax|banana|fig|apple)-seed$/.test(r[0]))) {
    const plant = r[0].replace('-seed', '');
    operation(`plant-${plant}`, 'food', `${r[0]}×1;water×1`, '', 1, { skillNodes: [r[2]] }, {}, { effects: [effect('growth-minutes', Number(r[3]), 'minutes'), effect('harvest-yield', 3, 'items')] });
  }
  for (const food of ['corn-porridge', 'wheat-flatbread', 'banana-mash', 'onion-meat-skewer', 'onion-soup', 'fig-stew', 'meat-potato-stew', 'baked-apple', 'rex-meat-stew']) {
    const family = ['onion-soup', 'fig-stew', 'meat-potato-stew'].includes(food) ? 'recovery' : ['baked-apple', 'rex-meat-stew'].includes(food) ? 'resistance' : 'stamina';
    operation(`eat-${food}`, 'food', `${food}×1`, '', 1, {}, {}, { effects: [effect('duration', 300, 'seconds'), effect(family, family === 'stamina' ? -5 : family === 'recovery' ? 1 : 2, family === 'stamina' ? 'percent-cost' : family === 'recovery' ? 'hp-per-second' : 'heat-and-cold-resistance')] });
  }

  const entryActions = { survival: ['feeding', 'firstjourney'], butchering: ['defaultmeat'], gathering: ['hand'], processing: ['dry-twig'], weapon_tool: ['starter-axe'], ranged: ['basicbowhit'], melee: ['basicclubhit'], construction: ['starterplacement'], farming: ['practice-seedbed'], tailoring: ['practice-fiber-stitch'], cooking: ['berry-meal'], defense: ['basicblock'] };
  const skillRows = tables['skill-node'].filter(r => Object.hasOwn(entryActions, r[0]));
  for (const r of skillRows) {
    const id = r[0];
    addString(`skills.${id}`, title(id));
    d.skillCategories.push(row({ id, nameKey: `skills.${id}`, entryActions: entryActions[id] }));
    for (let rank = 1; rank <= 6; rank++) {
      // The prose is kept as the effect unit, alongside numeric machine values.
      const text = r[rank], first = text.match(/[+-]?\d+(?:\.\d+)?/);
      d.skillNodes.push(row({ id: `${id}_${rank}`, category: id, rank, cost: rank * 2, proficiency: [1, 10, 20, 30, 45, 60][rank - 1], prerequisites: rank === 1 ? [] : [`${id}_${rank - 1}`], effects: [effect(`${id}-${rank}`, first ? Number(first[0]) : 1, text)] }));
      addString(`skills.${id}_${rank}`, text);
    }
  }

  const animalRows = tables.wildlife.filter(r => /^\d+$/.test(r[2]) && r.length === 10);
  const dropRows = tables.wildlife.filter(r => r.length === 4 && /^(meat\d)/.test(r[1]));
  for (const r of animalRows) {
    const [id, biome, levelText, hpx, dx, speeds, sensing, attackText, policy, cargo] = [r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[10] ?? r[9]];
    const level = Number(levelText), damage = Math.floor((5 + level) * Number(dx)), speed = speeds.match(/(\d+)\/(\d+)/), sense = sensing.split('/').map(Number);
    const drop = dropRows.find(x => x[0] === id);
    const reservoirs = [...drop[1].matchAll(/([a-z-]+)(\d+)/g)].map(m => {
      addItem(m[1]);
      const rank = m[1] === 'meat' ? 1 : ['hide', 'fur', 'feather', 'sinew'].includes(m[1]) ? 2 : ['bone', 'plate', 'shell-fragment', 'volcanic-bone'].includes(m[1]) ? 3 : 4;
      return { item: m[1], quantity: Number(m[2]), skillNode: `butchering_${rank}` };
    });
    if (damage > 0) { addItem('skull'); reservoirs.push({ item: 'skull', quantity: 1, skillNode: 'butchering_5' }); }
    const attackValues = attackText === 'none' ? [] : attackText.split('/').map(Number);
    const base = { id, behavior: policy.startsWith('F') ? 'grazer' : 'hunter', ...(policy.startsWith('F') ? { senseStuds: sense[0], fleeStuds: sense[1] } : { warnStuds: sense[0], attackStuds: attackValues[1], leashStuds: sense[1], telegraphMillis: attackValues[0] * 1000, cooldownMillis: attackValues[2] * 1000 }) };
    d.wildlife.push(base);
    const enabled = drop[3] !== 'none';
    d.wildlifeDetails.push(row({ id, level, health: Math.floor((50 + 10 * level) * Number(hpx)), damage, walkSpeed: Number(speed[1]), runSpeed: Number(speed[2]), biomes: biome.split(','), behaviour: ({ F: 'flee', R: 'retaliate', T: 'territorial', P: 'predator' })[policy[0]], sense: sense[0], leash: sense[1], attacks: attackValues.length ? [{ id: 'primary', damage, windupSeconds: attackValues[0], range: attackValues[1], recoverySeconds: attackValues[2], shape: id === 'brachiosaurus' ? 'circle' : 'cone' }] : [], dropReservoirs: reservoirs, captureClass: drop[2], mount: { enabled, cargoSlots: Number(cargo), walkSpeed: Number(speed[1]), runSpeed: Number(speed[2]), stamina: 100, effects: enabled ? [effect('ability', 1, drop[3])] : [] }, effects: [effect('group-policy', 1, policy)] }));
    addString(`wildlife_${id}`, title(id));
  }

  const aliases = id => ({ reed: 'fiber', samphire: 'onion' })[id] ?? id;
  const mineralGate = item => {
    if (['basalt', 'volcanic-ore'].includes(item)) return { gates: { skillNodes: ['gathering_4'] }, tool: 'pickaxe-t2' };
    if (item === 'iron-ore') return { gates: { skillNodes: ['gathering_3'] }, tool: 'pickaxe-t1' };
    if (item === 'granite') return { gates: { skillNodes: ['gathering_3'] }, tool: 'pickaxe-t2' };
    if (item === 'copper-ore') return { gates: { skillNodes: ['gathering_1'] }, tool: 'pickaxe-t1' };
    if (item === 'flint') return { gates: { skillNodes: ['gathering_1'] }, tool: 'starter-pickaxe' };
    if (item === 'wood') return { tool: 'starter-axe' };
    if (item === 'fish') return { tool: 'starter-club' };
    return {};
  };
  const resource = (layout, suffix, item, pos, stock, level) => {
    item = aliases(item); addItem(item);
    const id = `${layout.id}.${suffix}`;
    layout.resourceNodes.push({ id, item, position: pos, stock, level, yield: item === 'fish' || item === 'flaxseed' ? 2 : 3, respawnSeconds: 120, ...mineralGate(item) });
  };
  const path = (layout, id, list, width = 16) => layout.paths.push({ id: `${layout.id}.${id}`, points: list, width });
  const refuge = (layout, id, center, width = 40) => layout.refuges.push({ id: `${layout.id}.${id}`, bounds: { min: point(center.x - width / 2, center.y, center.z - width / 2), max: point(center.x + width / 2, center.y + 30, center.z + width / 2) } });
  const layout = (id, width, depth, ymax, biomes, anchors) => {
    const l = row({ id, bounds: { min: point(-width / 2, 0, -depth / 2), max: point(width / 2, ymax, depth / 2) }, biomes, anchors: ['entry', 'resources', 'hazard', 'objective', 'exit'].map((id, i) => ({ id, position: anchors[i] })), resourceNodes: [], spawns: [], hazards: [], refuges: [], paths: [] });
    d.layouts.push(l); return l;
  };
  const anchor = (l, name) => l.anchors.find(a => a.id === name).position;
  const worldRows = tables.world.filter(r => /^`rw\.a\d\.s\d`$/.test(r[0]) && r.length === 8);
  for (const r of worldRows) {
    const id = clean(r[0]), index = Number(id.match(/a(\d)/)[1]), stageN = Number(id.at(-1));
    const l = layout(id, 768, 640, Number(r[2].split('–')[1]), r[1].split(' + '), r.slice(3).map(s => points(s)[0]));
    const E = anchor(l, 'entry'), R = anchor(l, 'resources'), O = anchor(l, 'objective'), X = anchor(l, 'exit'), A = point(0, E.y, 80), B = point(64, E.y, 0);
    path(l, 'main', [E, A, R, O, X]); path(l, 'bypass', [X, B, A, E]); path(l, 'habitat-approach', [O, point(-160, O.y, -100), point(-200, O.y, -100), point(-200, O.y, 0)]);
    path(l, 'station-yard', [R, point(0, R.y, 100), point(48, R.y, 100)]);
    for (const [i, item] of ['branch', 'stone', 'fiber', 'berry', 'water'].entries()) resource(l, item, item, point([-66, -54, -42, -30, -66][i], R.y, i < 4 ? 88 : 100), [40, 24, 40, 12, 12][i], [0, 30, 30, 40, 50, 60][index]);
    const resources = tables.world.find(t => t[0] === id.replace('rw.', '') && t.length === 6);
    for (const [slot, text, pos] of [['material', resources[1], point(-54, R.y, 100)], ['cargo', resources[2], point(-42, R.y, 100)], ['chapter', resources[3], point(-30, R.y, 100)], ['seed', resources[4], point(-54, R.y, 112)]]) {
      for (const match of text.matchAll(/([a-z][a-z-]*)(\d+)/g)) {
        let item = aliases(match[1]);
        if (item === 'volcanic-bone') item = 'volcanic-ash';
        resource(l, `${slot}.${item}`, item, pos, Number(match[2]), [0, 30, 30, 40, 50, 60][index]);
      }
    }
    const htext = resources[5], radius = Number(htext.match(/r(\d+)/)[1]);
    const kind = htext.split(';')[0].replace(/^r\d+ /, '').replaceAll(' ', '-');
    const H = id === 'rw.a5.s1' ? point(240, 18, 0) : anchor(l, 'hazard');
    if (id === 'rw.a5.s1') l.anchors.find(a => a.id === 'hazard').position = H;
    l.hazards.push({ id: `${id}.hazard`, kind, position: H, radius, intensity: kind === 'cold' ? 10 : kind === 'heat' ? 8 : 1, effects: [effect(kind === 'lava' ? 'max-health-loss' : 'hazard-rule', kind === 'lava' ? 25 : 1, kind === 'lava' ? 'percent-per-second' : htext)] });
    for (const a of [E, R, O, X]) refuge(l, `safe-${a === E ? 'entry' : a === R ? 'yard' : a === O ? 'objective' : 'exit'}`, a);
    if (index === 4 && stageN === 1) { const f = point(-96, 14, 160); refuge(l, 'fringe-refuge', f); path(l, 'fringe-path', [E, point(0, 2, 160), f]); path(l, 'hunt-approach', [f, point(-160, 14, 160), point(-200, 14, 96)]); }
    if (index === 5) { const spring = point(-48, R.y, 140); refuge(l, 'spring', spring, 24); path(l, 'spring-link', [R, spring]); l.hazards.push({ id: `${id}.hot-spring`, kind: 'hot-spring', position: spring, radius: 12, intensity: 5, effects: [effect('fatigue-recovery', 5, 'per-second')] }); }
    if (id === 'rw.a5.s1') {
      l.resourceNodes = l.resourceNodes.filter(n => !['branch', 'stone', 'fiber', 'berry', 'water'].includes(n.id.split('.').at(-1)));
      for (const [i, item, stock] of [[0, 'basalt', 12], [1, 'volcanic-ore', 8], [2, 'iron-ore', 20], [3, 'branch', 20], [4, 'fiber', 20]]) resource(l, `fringe-${item}.01`, item, point([-66, -54, -42, -30, -66][i], 18, i < 4 ? 88 : 100), stock, 60);
      resource(l, 'fringe-charcoal', 'charcoal', point(-48, 18, 140), 7, 60); resource(l, 'fringe-water', 'water', point(-48, 18, 140), 12, 60);
      const f = point(-96, 18, 0); refuge(l, 'rex-refuge', f); refuge(l, 'rex-arena', point(-280, 18, 0), 128); path(l, 'rex-link', [R, point(-96, 18, 100), f]); path(l, 'rex-approach', [f, point(-160, 18, 0), point(-208, 18, 0)]);
    }
    const transform = tables.world.find(t => t[0] === id.replace('rw.', '') && t.length === 5);
    l.rotationDegrees = Number(transform[1]); l.mirrorX = transform[2] === 'true';
  }
  const addPopulation = (l, speciesId, level, homes) => {
    homes.forEach((p, i) => {
      l.spawns.push({ id: `${l.id}.${speciesId}.${String(l.spawns.filter(s => s.speciesId === speciesId).length + 1).padStart(2, '0')}`, speciesId, level, position: p, count: 1, radius: 8 });
      path(l, `habitat-${speciesId}-${i + 1}`, [point(-200, p.y, 0), point(-200, p.y, p.z), p]);
    });
  };
  for (const r of tables.world.filter(r => /^a\d\.s\d$/.test(r[0]) && r.length === 5 && /^\d+\//.test(r[2]))) addPopulation(d.layouts.find(l => l.id === `rw.${r[0]}`), r[1], Number(r[2].split('/')[0]), points(r[4]));
  const supports = tables['quests-support'].filter(r => /^`rw\.(onboarding|home|harbor|explore10|explore20|brawl|team-outpost)`$/.test(r[0]));
  for (const r of supports) {
    const id = clean(r[0]), dims = r[1].match(/(\d+)×(\d+)/), ymax = Number(r[1].match(/2–(\d+)/)[1]);
    const ps = points(r[2]); if (id === 'rw.brawl') ps.splice(3, 0, ps[2]);
    const l = layout(id, Number(dims[1]), Number(dims[2]), ymax, r[1].includes('beach') ? ['beach'] : ['grassland'], ps);
    const E = anchor(l, 'entry'), R = anchor(l, 'resources'), O = anchor(l, 'objective'), X = anchor(l, 'exit');
    path(l, 'main', [E, point(0, E.y, id.includes('explore') ? 80 : 24), R, O, X]);
    if (id.includes('explore')) path(l, 'bypass', [X, point(64, 2, 0), E]);
    if (id === 'rw.home') { path(l, 'dock-home', [E, point(0, 2, 120), O]); path(l, 'resource-link', [E, point(-132, 2, 120), R]); }
    if (id === 'rw.harbor') path(l, 'cross-street', [point(-120, 4, 0), point(120, 4, 0)]);
    if (id === 'rw.team-outpost') for (const z of [-64, 0, 64]) path(l, `lane-${z < 0 ? 'north' : z > 0 ? 'south' : 'center'}`, [point(-152, 2, z), point(-64, 4, z), point(0, 4, z), point(64, 4, z), point(152, 2, z)]);
    if (id === 'rw.brawl') for (const [i, p] of [point(96, 2, 0), point(-96, 2, 0), point(0, 2, 96), point(0, 2, -96)].entries()) path(l, `spoke-${i}`, [O, p]);
    const level = id.endsWith('20') ? 20 : id.endsWith('10') ? 10 : 1;
    const stocks = tables['quests-support'].find(t => t[0] === id.replace('rw.', '') && t.length === 3 && /^\d+,/.test(t[1]));
    const amounts = stocks[1].split(',').map(Number);
    if (amounts.some(n => n > 0)) {
      const offsets = [[-18, -12], [-6, -12], [6, -12], [18, -12], [-18, 0], [-6, 0], [6, 0], [18, 0], [-6, 12], [6, 12]];
      for (const [i, item] of ['branch', 'stone', 'fiber', 'berry', 'water'].entries()) resource(l, item, item, point(R.x + offsets[i][0], R.y, R.z + offsets[i][1]), amounts[i], level);
      const extra = [...stocks[2].matchAll(/([a-z][a-z-]*)(\d+)/g)];
      extra.forEach((m, i) => { if (m[1] !== 'B' && m[1] !== 'K') resource(l, `extra-${i}`, m[1], point(R.x + offsets[i + 5][0], R.y, R.z + offsets[i + 5][1]), Number(m[2]), level); });
    }
    d.supportRegions.push(row({ id, layout: id, gates: { characterLevel: level }, role: id.replace('rw.', '') }));
  }
  for (const band of [30, 40, 50, 60]) {
    const y = ({ 30: 8, 40: 12, 50: 16, 60: 20 })[band], id = `rw.frontier${band}`;
    const l = layout(id, 768, 640, ({ 30: 40, 40: 48, 50: 64, 60: 72 })[band], ({ 30: ['tropical', 'desert'], 40: ['snow', 'desert'], 50: ['volcano', 'tropical', 'snow'], 60: ['volcano'] })[band], [point(96, 2, 260), point(96, y, 96), point(band === 60 ? 240 : -280, y, 0), point(96, y, -96), point(96, y, -260)]);
    const E = anchor(l, 'entry'), R = anchor(l, 'resources'), O = anchor(l, 'objective'), X = anchor(l, 'exit');
    path(l, 'main', [E, R, O, X]); path(l, 'bypass', [E, point(160, 2, 160), point(160, y, -160), X]); path(l, 'combat', [O, point(-160, y, -96), point(-200, y, -96)]);
    const items = band < 50 ? ['branch', 'stone', 'fiber', 'flint', 'iron-ore', band === 30 ? 'clay' : 'fiber'] : ['branch', 'basalt', 'fiber', 'volcanic-ore', 'iron-ore', 'stone'];
    const stocks = band < 50 ? [40, 30, 40, 30, 30, 30] : [40, 30, 40, 20, 40, 30];
    items.forEach((item, i) => resource(l, `N${i + 1}`, item, point([80, 96, 112][i % 3], y, i < 3 ? 80 : 112), stocks[i], band));
    for (const [item, x, z, stock] of [['water', 128, 96, 30], ['wood', 128, 112, 40], ['berry', 144, 112, 20], ['leaves', 144, 128, 20], [band === 30 ? 'copper-ore' : band === 50 ? 'clay' : 'granite', 144, 80, 30]]) resource(l, `${item}.01`, item, point(x, y, z), stock, band);
    if ([30, 50, 60].includes(band)) resource(l, 'renewable-charcoal', 'charcoal', point(160, y, 128), 30, band);
    if (band === 30) { resource(l, 'flax', 'flax', point(128, y, 128), 20, band); resource(l, 'flaxseed', 'flaxseed', point(128, y, 128), 12, band); }
    if (band === 40) { resource(l, 'apple', 'apple', point(128, y, 144), 12, band); refuge(l, 'wolf-refuge', point(-96, 12, -96)); refuge(l, 'wolf-arena', point(-280, 12, -96), 144); path(l, 'wolf-approach', [O, point(-96, 12, -96), point(-160, 12, -96), point(-208, 12, -96)]); }
    refuge(l, 'yard', R);
    if (band >= 50) { const p = point(96, y, 136); refuge(l, 'spring', p, 24); path(l, 'spring-link', [R, p]); l.hazards.push({ id: `${id}.spring`, kind: 'hot-spring', position: p, radius: 12, intensity: 5, effects: [effect('fatigue-recovery', 5, 'per-second')] }); }
    if (band === 60) { refuge(l, 'rex-arena', point(-280, 20, 0), 128); refuge(l, 'rex-refuge', point(-96, 20, 0)); path(l, 'rex-approach', [O, point(-96, 20, -96), point(-96, 20, 0), point(-160, 20, 0), point(-208, 20, 0)]); }
    d.supportRegions.push(row({ id, layout: id, gates: { characterLevel: band }, role: 'frontier' }));
  }
  const getLayout = id => d.layouts.find(l => l.id === id);
  const extraNodes = [
    ['explore10', 'clay', -80, 4, 144, 20, 10], ['explore10', 'leaves', -80, 4, 128, 20, 10], ['explore20', 'flint', -96, 6, 128, 20, 20], ['explore20', 'flax', -80, 6, 128, 20, 20], ['explore20', 'flaxseed', -80, 6, 128, 12, 20], ['explore20', 'fish', -80, 6, 144, 12, 20], ['explore20', 'clam', -96, 6, 144, 12, 20],
    ...['potato', 'onion', 'corn', 'wheat'].map(item => ['explore10', item, 32, 4, 128, 12, 10]),
    ...['corn', 'wheat', 'banana', 'fig'].map(item => ['explore20', item, 32, 6, 128, item === 'corn' || item === 'wheat' ? 12 : 6, 20]),
  ];
  for (const [region, item, x, y, z, stock, level] of extraNodes) resource(getLayout(`rw.${region}`), `additional-${item}`, item, point(x, y, z), stock, level);
  for (const r of tables['quests-support'].filter(r => r.length >= 3 && /^(onboarding|explore10|explore20|frontier30|frontier40|frontier50|frontier60)$/.test(r[0]) && /^[a-zA-Z]+\d+\//.test(r[1]))) {
    const [, species, level] = r[1].match(/^([a-zA-Z]+)(\d+)\//);
    addPopulation(getLayout(`rw.${r[0]}`), species, Number(level), points(r[2]));
  }
  // Legacy wildlife remains placeable, without impersonating a new species.
  const legacyHabitat = getLayout('rw.explore10');
  snapshot.legacy.wildlife.forEach((w, i) => addPopulation(legacyHabitat, w.id, 10, [point(-240 - (i % 3) * 16, 4, -192 + Math.floor(i / 3) * 64)]));
  // Preserve acquisition for every original item used by retained recipes.
  for (const n of snapshot.legacy.nodes) for (const q of n.harvest) if (!d.layouts.some(l => l.resourceNodes.some(r => r.item === q.item))) {
    // Retired raw aliases still have an acquisition path for legacy recipes;
    // ordinary new objectives use only the corrected canonical IDs.
    legacyHabitat.resourceNodes.push({ id: `rw.explore10.legacy-${n.id}-${q.item}`, item: q.item, position: point(-48, 4, 100), stock: q.quantity, level: 10, yield: 3, respawnSeconds: 120 });
  }

  // Deterministic raw profiles and actual acquisition bands.
  const attrNames = ['hardness', 'flexibility', 'sharpness', 'insulation', 'nutrition', 'fertility'];
  for (const r of tables['auxiliary-material'].filter(r => r.length === 2 && /^\d\s*\//.test(r[1]))) {
    const values = r[1].split('/').map(Number);
    for (const id of r[0].split(',').map(clean)) {
      addItem(id);
      const acquired = d.layouts.flatMap(l => l.resourceNodes.filter(n => n.item === id).map(n => ({ level: n.level, id: l.id })));
      const animal = d.wildlifeDetails.filter(w => w.dropReservoirs.some(q => q.item === id));
      const levels = [...new Set([...acquired.map(n => n.level), ...animal.map(w => w.level)])].sort((a, b) => a - b);
      d.materials.push(row({ id: `${id}-profile`, item: id, attributes: Object.fromEntries(attrNames.map((k, i) => [k, values[i]])), levels: levels.length ? levels : [10, 20, 30, 40, 50, 60], quality: 0, processingBudget: 3, sources: [...new Set([...acquired.map(n => n.id), ...animal.map(w => w.id)])] }));
    }
  }

  const indexLevels = [0, 30, 35, 40, 50, 60];
  const stageRows = tables.world.filter(r => /^`rw\.a\d\.s\d\.(gather|craft|survey|rescue|hunt|transport)`$/.test(r[0]));
  for (const r of stageRows) {
    const id = clean(r[0]), [, indexText, stageText, action] = id.match(/^rw\.a(\d)\.s(\d)\.(.+)$/), index = Number(indexText), stageN = Number(stageText), layoutId = `rw.a${index}.s${stageN}`;
    let target = action === 'craft' ? 'dry-twig' : action === 'gather' ? ['wood', 'fiber', 'iron-ore', 'iron-ore', 'basalt'][index - 1] : action === 'hunt' ? r[2].match(/Kill ([a-zA-Z]+)/)[1] : action === 'survey' ? `${layoutId}.survey` : action === 'rescue' ? `${layoutId}.castaway` : 'relief-unit';
    const count = Number(r[3].match(/\d+/)[0]);
    const gates = { characterLevel: indexLevels[index], developmentRank: index * 2 };
    if (stageN > 1) gates.completed = stageRows.filter(t => clean(t[0]).startsWith(`rw.a${index}.s${stageN - 1}.`)).map(t => clean(t[0]));
    if (action === 'gather' && index >= 3) gates.skillNodes = [index === 5 ? 'gathering_4' : 'gathering_3'];
    d.stages.push(row({ id, layout: layoutId, gates, objectives: [objective(id, action, target, count)] }));
  }
  const missionRows = tables['quests-support'].filter(r => /^`rw\.m\d\.(gather|craft|survey|rescue|hunt|transport)`$/.test(r[0]));
  for (const r of missionRows) {
    const id = clean(r[0]), index = Number(id.match(/m(\d)/)[1]);
    const instances = stageRows.filter(t => clean(t[1]) === id);
    const objectives = instances.map(t => { const s = d.stages.find(s => s.id === clean(t[0])); return { ...s.objectives[0], stageId: s.id }; });
    const keys = [`${id}.offer`, `${id}.complete`];
    d.missions.push(row({ id, gates: { characterLevel: indexLevels[index], developmentRank: index * 2 }, objectives, rewards: { xp: Number(r[4]), coins: Number(r[5]), development: 50, reputation: [effect(r[6].replace('20', '').toLowerCase(), 20, 'reputation')] }, dialogueKeys: keys }));
  }
  const guideRows = tables['quests-support'].filter(r => /^`rw\.g\d\d\./.test(r[0]));
  const guideSpecs = [
    [['gather', 'branch', 5], ['gather', 'stone', 3], ['gather', 'fiber', 3]], [['craft', 'campfire-kit', 1], ['place', 'campfire', 1]], [['rest', 'rw.onboarding.rest-mat', 1]], [['craft', 'dry-twig', 1]],
    [['expand', 'rw.home', 1]], [['visit', 'rw.home-demo', 1]], [['craft', 'berry-meal', 1], ['eat', 'berry-meal', 1]], [['list', 'fiber', 1], ['settle-return-or-sale', 'fiber', 1]],
    [['practice', 'practice-seedbed', 1], ['purchase', 'farming_1', 1], ['plant', 'corn', 1], ['water', 'corn', 1], ['harvest', 'corn', 1]], [['practice', 'practice-fiber-stitch', 1], ['purchase', 'tailoring_1', 1], ['craft', 'temperate-gloves', 1]], [['preview-refund', 'skills', 1], ['cancel-preview', 'skills', 1]], [['invite-training', 'rw.training-recipient', 1], ['revoke', 'rw.training-recipient', 1]],
    [['inspect', 'laboratory', 1]], [['place-training', 'dodo', 1], ['feed', 'herbivore-feed', 3], ['tame', 'dodo', 1]], [['preview-role', 'clan', 1], ['draft-membership', 'clan', 1], ['cancel-draft', 'clan', 1]], [['deposit', 'berry', 1], ['inspect-rate', 'refrigerator', 1], ['retrieve', 'berry', 1]],
    [['equip-loan', 'cold-head', 1], ['inspect', 'cold-head', 1], ['return-loan', 'cold-head', 1]], [['preview', 'support-tier-1', 1], ['acknowledge-level-gate', 'support-tier-1', 1]], [['equip-loan', 'lava-protection-boots', 1], ['inspect', 'lava-protection-boots', 1], ['return-loan', 'lava-protection-boots', 1]], [['assemble', 'bandage', 2], ['activate', 'rw.harbor.rescue-beacon', 1]],
  ];
  for (const [i, r] of guideRows.entries()) {
    const id = clean(r[0]), band = Math.floor(i / 4), gates = { characterLevel: [1, 30, 35, 40, 50][band], developmentRank: band * 2 };
    const rewardItems = quantities(r[3].replace(/([a-z-]+)(\d+)/g, '$1×$2')).filter(q => q.item !== 'dodo').map(q => ({ ...q, item: aliases(q.item) }));
    for (const q of rewardItems) addItem(q.item);
    d.guides.push(row({ id, gates, objectives: guideSpecs[i].map(([action, target, count], n) => objective(`${id}.${n + 1}`, action, target, count)), rewards: { xp: Number(r[1].match(/;(\d+)/)[1]), coins: 25, development: 50, items: rewardItems }, dialogueKeys: [`${id}.offer`, `${id}.complete`] }));
  }
  const chapterRows = tables['quests-support'].filter(r => /^`rw\.c\d\d\./.test(r[0]));
  const chapterSpecs = [
    [['survey', 'rw.explore20.objective', 1], ['assemble', 'signal-lens', 1], ['activate', 'rw.harbor.relay', 1], ['speak', 'bram', 1]],
    [['inspect', 'rw.explore20.wreck', 1], ['craft', 'communication-station-kit', 1], ['deploy', 'communication-station', 1], ['tune', 'communication-station', 1], ['speak', 'hop', 1]],
    [['survey', 'rw.a1.s1.survey', 1], ['survey', 'rw.a1.s4.survey', 1], ['assemble', 'sample-case', 1], ['deposit', 'survey-sample', 3], ['speak', 'bram', 1]],
    [['survey', 'rw.a2.s2.survey', 1], ['survey', 'rw.a2.s3.survey', 1], ['craft', 'onion-soup', 1], ['eat', 'onion-soup', 1], ['administer', 'quest-remedy', 1], ['speak', 'ines', 1]],
    [['survey', 'rw.a3.s1.survey', 1], ['inspect', 'rw.team-outpost.objective', 1], ['assemble', 'research-bundle', 1], ['submit', 'research-bundle', 1], ['speak', 'marit', 1]],
    [['survey', 'rw.a4.s1.survey', 1], ['survey', 'rw.a4.s4.survey', 1], ['assemble', 'shelter-liner', 1], ['install', 'shelter-liner', 1], ['speak', 'ines', 1]],
    [['survey', 'rw.a5.s3.survey', 1], ['fresh-kill', 'tyrannosaurus', 1], ['assemble', 'heat-brace', 1], ['install', 'heat-brace', 1], ['speak', 'bram', 1]],
    [['survey', 'rw.a5.s4.survey', 5], ['assemble', 'rescue-transponder', 1], ['activate', 'rw.a5.s4.beacon', 1], ['escort', 'rw.a5.s4.survivor', 1], ['return', 'rw.a5.s4.exit', 1], ['speak', 'marit', 1]],
  ];
  for (const [i, r] of chapterRows.entries()) {
    const id = clean(r[0].split(';')[0]), gates = { characterLevel: [20, 20, 30, 35, 40, 50, 60, 60][i], ...(i ? { completed: [clean(chapterRows[i - 1][0].split(';')[0])] } : {}) };
    addItem(`rw-journal-seal-${i + 1}`);
    d.chapters.push(row({ id, gates, objectives: chapterSpecs[i].map(([action, target, count], n) => objective(`${id}.${n + 1}`, action, target, count)), rewards: { xp: Number(r[4]), coins: 100, items: [{ item: `rw-journal-seal-${i + 1}`, quantity: 1 }] }, dialogueKeys: [`${id}.offer`, `${id}.complete`] }));
  }
  for (const r of tables['quests-support'].filter(r => /^m\d\.(gather|craft|survey|rescue|hunt|transport)$/.test(r[0]) && r.length === 4)) {
    const id = `rw.${r[0]}`;
    const quoted = text => [...text.matchAll(/"([^"]+)"/g)].map(m => m[1]);
    const offers = quoted(r[2]), completion = quoted(r[3])[0];
    addString(`${id}.offer`, offers[0]); addString(`${id}.complete`, completion);
    if (offers.length > 1) { addString(`${id}.offer.s3`, offers[0]); addString(`${id}.offer.s4`, offers[1]); d.missions.find(m => m.id === id).dialogueKeys.push(`${id}.offer.s3`, `${id}.offer.s4`); }
    addString(`npc.${r[1].toLowerCase()}`, r[1]);
  }
  for (const r of tables['quests-support'].filter(r => /^(g\d\d|c\d\d)$/.test(r[0]) && r.length === 4)) {
    const list = r[0].startsWith('g') ? d.guides : d.chapters, quest = list.find(q => q.id.startsWith(`rw.${r[0]}.`));
    addString(`${quest.id}.offer`, r[2].replace(/^"|"$/g, '')); addString(`${quest.id}.complete`, r[3].replace(/^"|"$/g, '')); addString(`npc.${r[1].toLowerCase()}`, r[1]);
  }
  for (const [key, text] of Object.entries({ before: 'I can hear your signal. Activate the beacon so I can find the marked route.', follow: 'The route is visible. I will follow you to the arrival dock.', aboard: 'I am aboard. Return home when you are ready.' })) addString(`rw.c08.survivor.${key}`, text);
  const harbor = getLayout('rw.harbor');
  for (const [id, x, z] of [['marit', 0, 24], ['tuck', 0, -24], ['hop', -64, 0], ['sella', 64, 0], ['bram', -64, -48], ['ines', 64, -48], ['pip', 64, 48]]) {
    harbor.anchors.push({ id: `npc.${id}`, position: point(x, 4, z) });
    addString(`npc.${id}`, title(id));
  }
  for (const [id, x, z] of [['practice-seedbed', 96, 80], ['practice-fiber-stitch', 96, 64], ['visitor-portal', 96, 48], ['rescue-beacon', 96, -48]]) harbor.anchors.push({ id, position: point(x, 4, z) });
  for (const [id, x, z] of [['rest-mat', 16, -32], ['drying-campfire', -24, -32], ['npc.marit', 0, -48]]) getLayout('rw.onboarding').anchors.push({ id, position: point(x, 2, z) });
  for (const [id, x, z] of [['station-pad', 0, -16], ['campfire-pad', 16, -16], ['laboratory-pad', -16, -16], ['farm-pad', 16, 16], ['pen-pad', -16, 16]]) getLayout('rw.home').anchors.push({ id, position: point(x, 2, z) });
  for (const l of d.layouts) {
    const R = anchor(l, 'resources');
    const publicStations = l.id.startsWith('rw.a') ? ['campfire', 'workbench', 'kiln', 'tanning-frame'] : l.id.startsWith('rw.frontier') ? ['workbench', 'kiln', 'tanning-frame'] : ['rw.onboarding', 'rw.home', 'rw.explore10'].includes(l.id) ? ['campfire', 'workbench'] : l.id === 'rw.explore20' ? ['campfire', 'workbench', 'kiln'] : l.id === 'rw.harbor' ? ['workbench', 'kiln', 'tanning-frame', 'laboratory', 'communication-station', 'clan-hall'] : [];
    const index = Number(l.id.match(/^rw\.a(\d)/)?.[1] ?? 0);
    publicStations.forEach((id, i) => {
      const tier = ['workbench', 'kiln'].includes(id) ? index ? index <= 2 ? 1 : index <= 4 ? 2 : 3 : l.id.includes('frontier') ? (Number(l.id.match(/\d+/)[0]) >= 50 ? 3 : 2) : 1 : 1;
      l.anchors.push({ id: `station.${id}.t${tier}`, position: l.id.startsWith('rw.a') ? point([24, 40, 56, 72][i], R.y, i % 2 ? 108 : 92) : l.id.startsWith('rw.frontier') ? point([96, 112, 128][i], R.y, 144) : l.id === 'rw.harbor' ? point([-104, -80, -56, 0, 24, 48][i], 4, [-48, -48, -48, 80, 80, 80][i]) : point(R.x + i * 16, R.y, R.z - 28) });
    });
    // Every ordinary patch branches from the safe graph; geometry consumers
    // use the same authored points as the resource interaction positions.
    for (const n of l.resourceNodes) path(l, `resource-${l.paths.length}`, [R, n.position], 8);
  }
  for (const l of d.layouts) {
    // Coordinate transforms are baked once. Runtime must not apply them again;
    // rotationDegrees/mirrorX retain the authored transform as descriptive data.
    const angle = (l.rotationDegrees ?? 0) * Math.PI / 180, c = Math.round(Math.cos(angle)), s = Math.round(Math.sin(angle));
    const transform = p => { let x = p.x * c - p.z * s, z = p.x * s + p.z * c; if (l.mirrorX) x = -x; return point(x, p.y, z); };
    const transformBounds = b => { const ps = [b.min, b.max, point(b.min.x, b.min.y, b.max.z), point(b.max.x, b.max.y, b.min.z)].map(transform); return { min: point(Math.min(...ps.map(p => p.x)), b.min.y, Math.min(...ps.map(p => p.z))), max: point(Math.max(...ps.map(p => p.x)), b.max.y, Math.max(...ps.map(p => p.z))) }; };
    l.bounds = transformBounds(l.bounds);
    for (const collection of [l.anchors, l.resourceNodes, l.spawns, l.hazards]) for (const entry of collection) entry.position = transform(entry.position);
    for (const r of l.refuges) r.bounds = transformBounds(r.bounds);
    for (const p of l.paths) p.points = p.points.map(transform);
  }
  for (const [section, prefix] of [['items', 'item_'], ['recipes', 'recipe_'], ['structures', 'structure_']]) for (const entry of d[section]) {
    addString(`${prefix}${entry.id.replaceAll('-', '_')}`, `${title(entry.id)}${section === 'recipes' ? ' recipe' : ''}`);
  }
  // Original Robango terminology is applied to both machine references and
  // player copy, keeping quest targets, stations and locale keys in lockstep.
  const original = text => text.replaceAll('communication-station', 'signal-relay').replaceAll('Communication Station', 'Signal Relay').replaceAll('communication_station', 'signal_relay').replaceAll('skill-return', 'skill-reclaim').replaceAll('Pioneers', 'Wayfarers').replaceAll('pioneers', 'wayfarers');
  const rewrite = value => typeof value === 'string' ? original(value) : Array.isArray(value) ? value.map(rewrite) : value && typeof value === 'object' ? Object.fromEntries(Object.entries(value).map(([key, child]) => [key, rewrite(child)])) : value;
  const document = rewrite(d);
  document.skillNodes.find(node => node.id === 'weapon_tool_4').effects[0].unit = 'equipment adjustment unlocked';
  const copy = {
    'skills.weapon_tool_4': 'Unlock equipment adjustments',
    'rw.g11.skill-reclaim.offer': 'Check which learned skills a refund would remove. Close the preview without confirming.',
    'rw.c08.collapse-return.complete': 'Our passenger reached home. The passage is sealed, and your journal now records the whole journey. You can sail again whenever you wish.',
    'rw.m1.craft.complete': 'Your first batch has dried. Take the finished wood.',
    'rw.m2.craft.complete': 'Both batches are dry and ready to collect.',
    'rw.m4.craft.complete': 'All four batches have finished drying.',
  };
  const originalLocale = new Map([...locale].map(([key, text]) => [original(key), copy[original(key)] ?? original(text)]));
  return { document, locale: originalLocale, legacyMappings };
}

// JSON is valid YAML 1.2, but the forge YAML reader targets block YAML. Emit
// plain keys, quoted text and explicit empty sequences for portable input.
export function yaml(value, indent = 0) {
  const pad = ' '.repeat(indent);
  const scalar = v => v === null ? 'null' : typeof v === 'string' ? JSON.stringify(v) : String(v);
  if (Array.isArray(value)) return value.length ? value.map(v => typeof v === 'object' && v !== null ? `${pad}-\n${yaml(v, indent + 2)}` : `${pad}- ${scalar(v)}`).join('\n') : `${pad}[]`;
  return Object.entries(value).map(([k, v]) => {
    if (Array.isArray(v) && !v.length) return `${pad}${k}: []`;
    if (v && typeof v === 'object') return Object.keys(v).length ? `${pad}${k}:\n${yaml(v, indent + 2)}` : `${pad}${k}: {}`;
    return `${pad}${k}: ${scalar(v)}`;
  }).join('\n');
}

if (import.meta.main) {
  const snapshot = JSON.parse(readFileSync('games/robango-island/tools/catalog-tables.json', 'utf8'));
  const { document, legacyMappings } = buildCatalog(snapshot);
  console.log(`# RECONSTRUCTED catalog. Legacy recipe mappings: ${JSON.stringify(legacyMappings)}\n${yaml(document)}`);
}
