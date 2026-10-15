// Capture layer control. A capture step may ask for only the owned UI ("ui"), only the 3D world
// ("world") or everything ("all", the default). The hidden layer is restored on the same client
// whether or not the screenshot succeeds.
//
// Previous values live on the instances themselves as attributes, because every `execute_luau`
// call is a separate chunk of code and nothing else survives between the hide and the restore.
export const LAYERS = ['all', 'world', 'ui'];

const CORE_SCREEN_GUIS = ['Chat', 'BubbleChat', 'TouchGui', 'Freecam', 'RobloxGui', 'ProximityPrompts', 'PlayerList', 'Health', 'Backpack', 'MainMenu', 'ErrorPrompt'];
const GUI_ATTRIBUTE = 'ForgeQALayerPrevEnabled';
const PART_ATTRIBUTE = 'ForgeQALayerPrevTransparency';

export function layersOf(step) {
  const layers = step.layers ?? 'all';
  if (!LAYERS.includes(layers)) throw new Error('CAPTURE_LAYERS_INVALID ' + JSON.stringify(layers));
  return layers;
}

// layers == "world": the owned ScreenGuis are switched off, so the frame shows the 3D world only.
export const hideUiCode = `local core={${CORE_SCREEN_GUIS.map(name => `['${name}']=true`).join(',')}}
local hidden=0
for _,gui in game:GetService('Players').LocalPlayer.PlayerGui:GetChildren() do
 if gui:IsA('ScreenGui') and not core[gui.Name] then
  if gui:GetAttribute('${GUI_ATTRIBUTE}')==nil then gui:SetAttribute('${GUI_ATTRIBUTE}',gui.Enabled) end
  gui.Enabled=false;hidden+=1
 end
end
local value={layer='world',hidden=hidden}`;

export const restoreUiCode = `local restored=0
for _,gui in game:GetService('Players').LocalPlayer.PlayerGui:GetChildren() do
 local previous=gui:GetAttribute('${GUI_ATTRIBUTE}')
 if gui:IsA('ScreenGui') and previous~=nil then gui.Enabled=previous;gui:SetAttribute('${GUI_ATTRIBUTE}',nil);restored+=1 end
end
local value={layer='world',restored=restored}`;

// layers == "ui": every part is made invisible to this client only (LocalTransparencyModifier is
// never replicated), so the camera keeps its real view and only the rendering of the world drops.
export const hideWorldCode = `local hidden=0
for _,part in workspace:GetDescendants() do
 if part:IsA('BasePart') then
  if part:GetAttribute('${PART_ATTRIBUTE}')==nil then part:SetAttribute('${PART_ATTRIBUTE}',part.LocalTransparencyModifier) end
  part.LocalTransparencyModifier=1;hidden+=1
 end
end
local value={layer='ui',hidden=hidden}`;

export const restoreWorldCode = `local restored=0
for _,part in workspace:GetDescendants() do
 local previous=part:IsA('BasePart') and part:GetAttribute('${PART_ATTRIBUTE}') or nil
 if previous~=nil then part.LocalTransparencyModifier=previous;part:SetAttribute('${PART_ATTRIBUTE}',nil);restored+=1 end
end
local value={layer='ui',restored=restored}`;

// Runs `capture` with the unwanted layer hidden on `client`: hide, capture, restore. The restore
// is in a finally so a throwing capture still puts the client back; when both fail the capture
// error is the one reported, since the restore error would only hide the cause.
export async function withLayers(layers, client, execute, capture) {
  if (layers === 'all') return capture();
  const [hide, restore] = layers === 'world' ? [hideUiCode, restoreUiCode] : [hideWorldCode, restoreWorldCode];
  let result, failure, failed = false;
  try {
    await execute(client.studioId, 'Client', hide);
    result = await capture();
  } catch (error) {
    failure = error;
    failed = true;
  }
  try {
    await execute(client.studioId, 'Client', restore);
  } catch (error) {
    if (!failed) throw error;
  }
  if (failed) throw failure;
  return result;
}
