--!strict
-- Robango survivors (plan G23 / A6, L6): every player is a game-supplied adult survivor, never their
-- own Roblox avatar. Pure model (engine-free): the preset catalog, the HumanoidDescription values a
-- preset dresses, and the saved choice inside the actor's `robango-exp-v1` document.
--
-- L6: every preset is kind "rig": the pack's own survivor meshes (assets/blender/gen_survivors.py,
-- package `mesh-survivors`), four period work outfits on two body types. The server loads the package
-- once, relays the R15 joints to the preset's body type and welds each mesh piece to its R15 body part;
-- the blank R15 parts turn invisible. L6b: every preset carries one painted colour atlas (cloth
-- patterns, leather, hair, painted face); MeshTexture.bake moves it onto MeshPart.TextureContent, so no
-- SurfaceAppearance reaches the client. Untextured pieces keep the per-slot `palette` colour. When the package does not load,
-- the preset falls back to the catalog look below, so a player never spawns as a blank body.
--
-- Every catalog id below was checked on 2026-10-27 through
-- https://economy.roblox.com/v2/assets/<id>/details: creator Roblox (id 1), PriceInRobux 0 or part
-- of a free Roblox bundle (Man 238, Woman 239; catalog isFree = true). No paid or UGC item is used.
local CosmeticVisual = require("../../../../genres/survival-coop/module/CosmeticVisual")
local M = {}

export type Rgb = { r: number, g: number, b: number }
export type Body = {
	torso: number,
	leftArm: number,
	rightArm: number,
	leftLeg: number,
	rightLeg: number,
	head: number,
	mood: number,
}
export type Preset = {
	id: string,
	kind: "catalog" | "rig",
	-- Rig presets: mesh body type (BODIES) and the colour/material of every mesh slot.
	rigBody: string?,
	palette: { [string]: Rgb }?,
	body: Body,
	hair: number?,
	hat: number?,
	shirt: number,
	pants: number,
	skin: Rgb,
	-- Game-made look that renders without any asset load: body colours under the clothing (torso =
	-- top, legs = bottom) and the colour of the composed hair cap used when the hair/hat fails.
	top: Rgb,
	bottom: Rgb,
	hairColor: Rgb,
	scale: { height: number, width: number },
}

M.VERSION = 1

-- Verified catalog ids: id -> name and Roblox asset type id.
local CATALOG: { [number]: { name: string, assetType: number } } = {
	[86500008] = { name = "Man Torso", assetType = 27 },
	[86500036] = { name = "Man Right Arm", assetType = 28 },
	[86500054] = { name = "Man Left Arm", assetType = 29 },
	[86500064] = { name = "Man Left Leg", assetType = 30 },
	[86500078] = { name = "Man Right Leg", assetType = 31 },
	[10725826963] = { name = "Man Face - Head", assetType = 79 },
	[10725833199] = { name = "Man Face - Mood", assetType = 78 },
	[86499666] = { name = "Woman Torso", assetType = 27 },
	[86499698] = { name = "Woman Right Arm", assetType = 28 },
	[86499716] = { name = "Woman Left Arm", assetType = 29 },
	[86499753] = { name = "Woman Left Leg", assetType = 30 },
	[86499793] = { name = "Woman Right Leg", assetType = 31 },
	[10725626210] = { name = "Woman Face - Head", assetType = 79 },
	[10725638029] = { name = "Woman Face - Mood", assetType = 78 },
	[62234425] = { name = "Brown Hair", assetType = 41 },
	[62724852] = { name = "Chestnut Bun", assetType = 41 },
	[376548738] = { name = "Brown Charmer Hair", assetType = 41 },
	[1772336109] = { name = "Down to Earth Hair", assetType = 8 },
	[144076436] = { name = "Grey Striped Shirt with Denim Jacket", assetType = 11 },
	[398633584] = { name = "Denim Jacket with White Hoodie", assetType = 11 },
	[398635081] = { name = "Blue Plaid Shirt", assetType = 11 },
	[4047884046] = { name = "Guitar Tee with Black Jacket", assetType = 11 },
	[144076760] = { name = "Dark Green Jeans", assetType = 12 },
	[382537569] = { name = "Black Jeans", assetType = 12 },
	[398633812] = { name = "Black Jeans with White Shoes", assetType = 12 },
}
M.CATALOG = CATALOG

local MAN: Body = {
	torso = 86500008,
	rightArm = 86500036,
	leftArm = 86500054,
	leftLeg = 86500064,
	rightLeg = 86500078,
	head = 10725826963,
	mood = 10725833199,
}
local WOMAN: Body = {
	torso = 86499666,
	rightArm = 86499698,
	leftArm = 86499716,
	leftLeg = 86499753,
	rightLeg = 86499793,
	head = 10725626210,
	mood = 10725638029,
}

-- Original survivor outfits in period work wear (L6 meshes: ranger waistcoat and rolled sleeves,
-- scout braces and tall boots, forager field coat and brimmed hat, drifter bib overalls and cap). The
-- catalog ids are the fallback look; they are verified above. Order is the picker order.
M.PRESETS = {
	{
		id = "ranger",
		kind = "rig",
		rigBody = "A",
		palette = {
			skin = { r = 186, g = 142, b = 104 },
			shirt = { r = 205, g = 194, b = 168 },
			vest = { r = 84, g = 62, b = 44 },
			trousers = { r = 128, g = 112, b = 82 },
			belt = { r = 58, g = 42, b = 28 },
			boots = { r = 70, g = 50, b = 36 },
			hair = { r = 74, g = 50, b = 34 },
		},
		body = MAN,
		hair = 62234425,
		shirt = 144076436,
		pants = 144076760,
		skin = { r = 186, g = 142, b = 104 },
		top = { r = 74, g = 96, b = 128 },
		bottom = { r = 52, g = 74, b = 54 },
		hairColor = { r = 92, g = 60, b = 36 },
		scale = { height = 1.05, width = 1 },
	},
	{
		id = "scout",
		kind = "rig",
		rigBody = "B",
		palette = {
			skin = { r = 228, g = 190, b = 158 },
			shirt = { r = 214, g = 206, b = 186 },
			braces = { r = 64, g = 44, b = 30 },
			trousers = { r = 104, g = 98, b = 76 },
			belt = { r = 58, g = 42, b = 28 },
			boots = { r = 62, g = 44, b = 32 },
			hair = { r = 110, g = 66, b = 38 },
		},
		body = WOMAN,
		hair = 62724852,
		shirt = 398633584,
		pants = 382537569,
		skin = { r = 234, g = 196, b = 164 },
		top = { r = 88, g = 114, b = 152 },
		bottom = { r = 38, g = 38, b = 44 },
		hairColor = { r = 122, g = 72, b = 42 },
		scale = { height = 1, width = 0.92 },
	},
	{
		id = "forager",
		kind = "rig",
		rigBody = "B",
		palette = {
			skin = { r = 124, g = 86, b = 62 },
			shirt = { r = 200, g = 190, b = 164 },
			jacket = { r = 146, g = 112, b = 62 },
			trousers = { r = 96, g = 90, b = 70 },
			belt = { r = 58, g = 42, b = 28 },
			boots = { r = 66, g = 48, b = 34 },
			hair = { r = 40, g = 30, b = 24 },
			hat = { r = 96, g = 90, b = 78 },
			band = { r = 84, g = 58, b = 40 },
		},
		body = WOMAN,
		hat = 1772336109,
		shirt = 398635081,
		pants = 144076760,
		skin = { r = 124, g = 86, b = 62 },
		top = { r = 62, g = 86, b = 140 },
		bottom = { r = 52, g = 74, b = 54 },
		hairColor = { r = 112, g = 88, b = 60 },
		scale = { height = 0.98, width = 0.94 },
	},
	{
		id = "drifter",
		kind = "rig",
		rigBody = "A",
		palette = {
			skin = { r = 160, g = 112, b = 80 },
			shirt = { r = 196, g = 188, b = 170 },
			overall = { r = 72, g = 88, b = 106 },
			boots = { r = 70, g = 50, b = 36 },
			hair = { r = 70, g = 48, b = 32 },
			hat = { r = 84, g = 82, b = 76 },
		},
		body = MAN,
		hair = 376548738,
		shirt = 4047884046,
		pants = 398633812,
		skin = { r = 160, g = 112, b = 80 },
		top = { r = 44, g = 44, b = 50 },
		bottom = { r = 36, g = 36, b = 42 },
		hairColor = { r = 88, g = 58, b = 34 },
		scale = { height = 1.02, width = 1.04 },
	},
} :: { Preset }

M.DEFAULT = "ranger"

function M.find(id: any): Preset?
	for _, preset in M.PRESETS do
		if preset.id == id then
			return preset
		end
	end
	return nil
end

--- The saved preset id in an actor document, or nil when the player never chose one.
function M.chosen(document: any): string?
	local saved = if type(document) == "table" then document.survivor else nil
	local id = if type(saved) == "table" then saved.preset else nil
	return if M.find(id) then id else nil
end

--- The preset the actor wears: the saved choice, else the default survivor.
function M.presetOf(document: any): Preset
	return M.find(M.chosen(document) or M.DEFAULT) :: Preset
end

--- Records `id` in the document (a transaction transform result). Unknown ids change nothing.
function M.select(document: any, id: any): { ok: boolean, reason: string?, data: any? }
	if not M.find(id) then
		return { ok = false, reason = "UNKNOWN_SURVIVOR" }
	end
	document.survivor = { version = M.VERSION, preset = id }
	return { ok = true, data = { preset = id } }
end

--- The client snapshot: the worn preset and whether the first-join picker is done.
function M.view(document: any): { preset: string, chosen: boolean }
	return { preset = M.presetOf(document).id, chosen = M.chosen(document) ~= nil }
end

--- HumanoidDescription property values for a preset's catalog look (rig presets keep one as fallback). Every property the description
--- does not set stays at its blank default, so nothing from the player's own avatar remains.
function M.describe(preset: Preset): { properties: { [string]: any }, skin: Rgb, colors: { [string]: Rgb } }
	return {
		properties = {
			Torso = preset.body.torso,
			LeftArm = preset.body.leftArm,
			RightArm = preset.body.rightArm,
			LeftLeg = preset.body.leftLeg,
			RightLeg = preset.body.rightLeg,
			Head = preset.body.head,
			MoodAnimation = preset.body.mood,
			Face = 0,
			Shirt = preset.shirt,
			Pants = preset.pants,
			GraphicTShirt = 0,
			HairAccessory = if preset.hair then tostring(preset.hair) else "",
			HatAccessory = if preset.hat then tostring(preset.hat) else "",
			HeightScale = preset.scale.height,
			WidthScale = preset.scale.width,
			DepthScale = preset.scale.width,
			HeadScale = 1,
			BodyTypeScale = 0,
			ProportionScale = 0,
		},
		skin = preset.skin,
		-- Under the clothing the body already reads as dressed: a top and trousers in the outfit's
		-- colours, skin on head and arms. These are plain colours, so they show even when the
		-- shirt/pants templates fail to load on a live server (p134 v46: a skin-only blank body).
		colors = {
			HeadColor = preset.skin,
			LeftArmColor = preset.skin,
			RightArmColor = preset.skin,
			TorsoColor = preset.top,
			LeftLegColor = preset.bottom,
			RightLegColor = preset.bottom,
		},
	}
end

--- Persists `id` as the actor's survivor through an ActorDocumentStore (`robango-exp-v1`).
function M.choose(store: any, actor: string, id: any): any
	return store.transaction(actor, function(document)
		return M.select(document, id)
	end)
end

--- What a character wears, bottom to top: the survivor preset is the base body and outfit, and the
--- paid worn sets the actor selected (MonetizationExtension appearance) dress on top of it. Mount
--- skins never touch the survivor; they render on the ride.
function M.dress(document: any, appearance: { [string]: boolean }?, cosmetics: CosmeticVisual.Config): any
	local preset = M.presetOf(document)
	return { preset = preset, description = M.describe(preset), wear = CosmeticVisual.wear(cosmetics, appearance) }
end

--- Engine adapter: dresses `character` as `preset`. `ports.description()` returns a new
--- HumanoidDescription and `ports.color(rgb)` a Color3. Worn paid pieces are welded to the body
--- parts this replaces, so their folder is dropped and the world re-dresses them on the new body.
function M.apply(character: any, preset: Preset, ports: any): (boolean, string?)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false, "NO_HUMANOID"
	end
	local plan = M.describe(preset)
	local description = ports.description()
	for key, value in plan.properties do
		description[key] = value
	end
	for key, rgb in plan.colors do
		description[key] = ports.color(rgb)
	end
	local ok, err = pcall(function()
		humanoid:ApplyDescriptionReset(description)
	end)
	if not ok then
		return false, tostring(err)
	end
	character:SetAttribute("ForgeSurvivor", preset.id)
	local worn = character:FindFirstChild(CosmeticVisual.FOLDER)
	if worn then
		worn:Destroy()
	end
	return true, nil
end

M.FALLBACK = "ForgeSurvivorFallback"
M.APPLY_ATTEMPTS = 3

--- The outfit pieces a preset wears that are not on `character` (asset loads that failed live):
--- "Shirt", "Pants" and "Hair" (the preset's hair or hat accessory).
function M.missing(character: any, preset: Preset): { string }
	local result = {}
	if not character:FindFirstChildOfClass("Shirt") then
		table.insert(result, "Shirt")
	end
	if not character:FindFirstChildOfClass("Pants") then
		table.insert(result, "Pants")
	end
	if (preset.hair or preset.hat) and not character:FindFirstChildOfClass("Accessory") then
		table.insert(result, "Hair")
	end
	return result
end

--- Dresses `character` and checks the result: an apply that errors or leaves outfit pieces
--- unloaded is retried (`ports.wait` between attempts) up to APPLY_ATTEMPTS times. What still does
--- not load is replaced by game-made pieces that need no asset: the body colours from `describe`
--- already show the top and trousers, and a missing hair/hat gets a composed hair cap
--- (`ports.hairCap(head, color)` returns a welded Part). Returns the pieces that never loaded.
--- `ports.current()` is false once the character was replaced (respawn): stop dressing it.
function M.dressCharacter(character: any, preset: Preset, ports: any): (boolean, { string }, string?)
	local previous = character:FindFirstChild(M.FALLBACK)
	if previous then
		previous:Destroy()
	end
	local missing: { string } = {}
	local reason: string? = nil
	local applied = false
	for attempt = 1, M.APPLY_ATTEMPTS do
		local ok, err = M.apply(character, preset, ports)
		applied = applied or ok
		reason = err
		missing = if ok then M.missing(character, preset) else { "Shirt", "Pants", "Hair" }
		if ok and #missing == 0 then
			return true, missing, nil
		end
		if attempt < M.APPLY_ATTEMPTS then
			ports.wait(attempt * 2)
			if not ports.current() then
				return false, missing, "REPLACED"
			end
		end
	end
	if applied and table.find(missing, "Hair") and (preset.hair or preset.hat) then
		local head = character:FindFirstChild("Head")
		if head then
			local folder = ports.folder(M.FALLBACK)
			local cap = ports.hairCap(head, ports.color(preset.hairColor))
			cap.Parent = folder
			folder.Parent = character
		end
	end
	return applied, missing, reason
end

-- L6 survivor rigs ------------------------------------------------------------------------------
-- The mesh pieces of `mesh-survivors` are authored in rig space (HumanoidRootPart centre at the
-- origin, facing -Z, floor at y = -2.35, the blank R15 body's hip height). Each piece is named
-- "<R15Part>__<slot>__<preset>"; the piece "Anchor__anchor__<preset>" sits on the rig origin.
-- Body lane: each preset's body is ONE skinned MeshPart ("UpperTorso__body__<preset>": blended
-- joints, no seams) with one Bone per R15 part ("<R15Part>__bone__<preset>"); only worn hats stay
-- rigid pieces. On a character every Bone moves onto its R15 body part, so the Humanoid's own Motor6D
-- animation bends the skin (Roblox skins to Bones under connected parts of the same Model).
M.BONE_SLOT = "bone"
M.RIG_PACKAGE = "mesh-survivors"
M.RIG_FOLDER = "ForgeSurvivorRigs"
M.RIG_PIECES = "ForgeSurvivorRig"
M.HIP_HEIGHT = 1.35
-- HumanoidRootPart centre above the floor.
M.ROOT_HEIGHT = 2.35

-- Body types of gen_survivors.py BODY: arm and hip centre lines.
M.BODIES = {
	A = { armX = 0.56, hipX = 0.2 },
	B = { armX = 0.5, hipX = 0.2 },
} :: { [string]: { armX: number, hipX: number } }

-- Joint heights of gen_survivors.py (WAIST, NECK, SHOULDER, ELBOW, WRIST, HIP, KNEE, ANKLE).
local Y = { waist = 0.05, neck = 1.6, shoulder = 1.33, elbow = 0.685, wrist = -0.075 }
local LEG = { hip = -0.35, knee = -1.172, ankle = -2.098 }

export type Vec = { x: number, y: number, z: number }
export type Layout = {
	rest: { [string]: Vec },
	joints: { [string]: { parent: string, child: string, at: Vec } },
}

local function v(x: number, y: number, z: number?): Vec
	return { x = x, y = y, z = z or 0 }
end

--- Rest position (rig space) of every R15 body part and the pivot of every R15 joint for a body
--- type. The engine adapter moves the R15 rig attachments onto these pivots, so the joints bend
--- where the mesh's shoulders, elbows, hips and knees are.
function M.layout(bodyId: string): Layout
	local body = assert(M.BODIES[bodyId], "SURVIVOR_BODY_UNKNOWN")
	local rest: { [string]: Vec } = {
		HumanoidRootPart = v(0, 0),
		LowerTorso = v(0, (LEG.hip + Y.waist) / 2),
		UpperTorso = v(0, (Y.waist + Y.neck) / 2),
		Head = v(0, 1.95),
	}
	local joints = {
		Root = { parent = "HumanoidRootPart", child = "LowerTorso", at = v(0, LEG.hip) },
		Waist = { parent = "LowerTorso", child = "UpperTorso", at = v(0, Y.waist) },
		Neck = { parent = "UpperTorso", child = "Head", at = v(0, Y.neck) },
	}
	for _, side in { { name = "Left", sign = -1 }, { name = "Right", sign = 1 } } do
		local name, sign = side.name, side.sign
		local ax, hx = sign * body.armX, sign * body.hipX
		rest[name .. "UpperArm"] = v(ax, (Y.shoulder + Y.elbow) / 2)
		rest[name .. "LowerArm"] = v(ax, (Y.elbow + Y.wrist) / 2)
		rest[name .. "Hand"] = v(ax, -0.2)
		rest[name .. "UpperLeg"] = v(hx, (LEG.hip + LEG.knee) / 2)
		rest[name .. "LowerLeg"] = v(hx, (LEG.knee + LEG.ankle) / 2)
		rest[name .. "Foot"] = v(hx, -M.ROOT_HEIGHT + 0.15)
		joints[name .. "Shoulder"] =
			{ parent = "UpperTorso", child = name .. "UpperArm", at = v(sign * (body.armX - 0.03), Y.shoulder) }
		joints[name .. "Elbow"] = { parent = name .. "UpperArm", child = name .. "LowerArm", at = v(ax, Y.elbow) }
		joints[name .. "Wrist"] = { parent = name .. "LowerArm", child = name .. "Hand", at = v(ax, Y.wrist) }
		joints[name .. "Hip"] = { parent = "LowerTorso", child = name .. "UpperLeg", at = v(hx, LEG.hip) }
		joints[name .. "Knee"] = { parent = name .. "UpperLeg", child = name .. "LowerLeg", at = v(hx, LEG.knee) }
		joints[name .. "Ankle"] = { parent = name .. "LowerLeg", child = name .. "Foot", at = v(hx, LEG.ankle) }
	end
	return { rest = rest, joints = joints }
end

--- Splits a piece name "<R15Part>__<slot>__<preset>" (an importer ".001" suffix is ignored).
function M.piece(name: string): (string?, string?, string?)
	local part, slot, preset = string.match(name, "^(%w+)__(%w+)__(%w+)")
	return part, slot, preset
end

-- Face details shared by every preset.
local DETAIL: { [string]: Rgb } = {
	eye = { r = 42, g = 33, b = 28 },
	brow = { r = 58, g = 42, b = 30 },
	lip = { r = 150, g = 92, b = 76 },
}
--- Colour and material (Enum.Material name) of one mesh slot of a rig preset. Every slot is
--- SmoothPlastic: the engine Fabric and Leather textures read as a camouflage print on these small
--- pieces (Studio capture, L6), and camouflage must never read as a uniform.
function M.slotStyle(preset: Preset, slot: string): (Rgb, string)
	local palette: { [string]: Rgb } = preset.palette or {}
	local rgb = palette[slot] or DETAIL[slot] or { r = 128, g = 128, b = 128 }
	return rgb, "SmoothPlastic"
end

--- A stable preset for a named townsperson or castaway (no randomness: a string hash).
function M.figurePreset(name: string): Preset
	local hash = 0
	for index = 1, #name do
		hash = (hash * 31 + string.byte(name, index)) % 2147483647
	end
	return M.PRESETS[hash % #M.PRESETS + 1]
end

-- Engine side: one template Model per preset under ReplicatedStorage.ForgeSurvivorRigs (the picker
-- preview clones it on the client). Pieces are anchored, coloured and carry their rig-space offset.
local rigs: { [string]: Model }? = nil
local waiting: { () -> () } = {}

--- Prepares the loaded package: one Model per preset, pieces coloured per slot, WorldPivot on the
--- rig origin, attribute ForgeRigOffset = the piece's rig-space CFrame. Returns preset id -> Model.
function M.prepareRigs(package: any, folder: any, bake: (any) -> number): { [string]: Model }
	bake(package)
	local byPreset: { [string]: { any } } = {}
	local bonesOf: { [string]: { any } } = {}
	for _, item in package:GetDescendants() do
		-- The importer puts the skinned body's Bones under a separate "RootPart" (Studio probe, body
		-- lane); they are collected here and moved onto the preset's body piece below.
		local _, boneSlot, bonePreset = M.piece(item.Name)
		if item:IsA("Bone") and boneSlot == M.BONE_SLOT and bonePreset then
			bonesOf[bonePreset] = bonesOf[bonePreset] or {}
			table.insert(bonesOf[bonePreset], item)
		elseif item:IsA("MeshPart") then
			local part, _, preset = M.piece(item.Name)
			if part and preset and M.find(preset) then
				byPreset[preset] = byPreset[preset] or {}
				table.insert(byPreset[preset], item)
			end
		end
	end
	local result: { [string]: Model } = {}
	for id, pieces in byPreset do
		local preset = M.find(id) :: Preset
		local anchor: any = nil
		for _, item in pieces do
			if string.sub(item.Name, 1, 8) == "Anchor__" then
				anchor = item
			end
		end
		if not anchor then
			continue
		end
		local model = Instance.new("Model")
		model.Name = id
		-- The FBX importer turns the package half a turn about Y (Studio probe, L6: left pieces at +X,
		-- the face toward +Z); rig space faces -Z, so the anchor frame is turned back.
		local origin = anchor.CFrame * CFrame.Angles(0, math.pi, 0)
		for _, item in pieces do
			local part, slot = M.piece(item.Name)
			item:SetAttribute("ForgeRigOffset", origin:ToObjectSpace(item.CFrame))
			item.Anchored, item.CanCollide, item.CanQuery, item.CanTouch = true, false, false, false
			item.CastShadow, item.Massless = part ~= "Anchor", true
			if part == "Anchor" then
				item.Transparency = 1
			elseif item.TextureContent.Uri ~= nil and item.TextureContent.Uri ~= "" then
				-- L6b: the painted atlas carries the colour; a white base keeps it untinted.
				item.Color = Color3.new(1, 1, 1)
				item.Material = Enum.Material.SmoothPlastic
			else
				local rgb, material = M.slotStyle(preset, slot :: string)
				item.Color = Color3.fromRGB(rgb.r, rgb.g, rgb.b)
				item.Material = (Enum.Material :: any)[material]
			end
			item.Parent = model
			if slot == "body" then
				local bones: { any } = bonesOf[id] or {}
				for _, bone in bones do
					local world = bone.WorldCFrame
					bone:SetAttribute("ForgeRigOffset", origin:ToObjectSpace(world))
					bone.Parent = item
					bone.WorldCFrame = world
				end
			end
		end
		model.WorldPivot = origin
		model.Parent = folder
		result[id] = model
	end
	return result
end

--- Server: loads `mesh-survivors` once through InsertService. Never errors; on failure the presets
--- keep their catalog look.
function M.loadRigs(): { [string]: Model }
	if rigs then
		return rigs
	end
	local loaded: { [string]: Model } = {}
	local ok, err = pcall(function()
		local shared = game:GetService("ReplicatedStorage"):WaitForChild("Forge").games["robango-island"].src.shared
		local Assets = require(shared.Assets) :: any
		local id = tonumber(string.match(Assets[M.RIG_PACKAGE] or "", "%d+$"))
		local package = game:GetService("InsertService"):LoadAsset(assert(id, "MESH_PACKAGE_UNPUBLISHED"))
		local MeshTexture = require(shared.MeshTexture) :: any
		local folder = Instance.new("Folder")
		folder.Name = M.RIG_FOLDER
		loaded = M.prepareRigs(package, folder, function(root: any): number
			return MeshTexture.bake(root)
		end)
		folder.Parent = game:GetService("ReplicatedStorage")
		package:Destroy()
	end)
	if not ok then
		warn("SurvivorAvatar: " .. M.RIG_PACKAGE .. " not loaded, catalog looks stay: " .. tostring(err))
	end
	rigs = loaded
	for _, callback in waiting do
		task.spawn(callback)
	end
	table.clear(waiting)
	return loaded
end

--- Runs `callback` once the rig package finished loading (at once if it already has).
function M.onRigs(callback: () -> ())
	if rigs then
		callback()
	else
		table.insert(waiting, callback)
	end
end

--- Test seam: specs inject prepared templates (nil resets to "not loaded").
function M.setRigs(value: { [string]: Model }?)
	rigs = value
end

--- The rig template for a preset (nil until loaded, or if the package failed).
function M.rig(id: string): Model?
	return if rigs then rigs[id] else nil
end

local function vec(p: Vec): Vector3
	return Vector3.new(p.x, p.y, p.z)
end

--- Dresses `character` in its preset's mesh rig: a blank R15 body (no catalog asset loads), the R15
--- rig attachments moved onto the mesh's joints, the body parts hidden and every piece welded to
--- its body part. Returns false (and changes nothing) when the rig template is missing.
function M.dressRig(character: any, preset: Preset, ports: any): (boolean, string?)
	local template = M.rig(preset.id)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false, "NO_HUMANOID"
	end
	if not template or not preset.rigBody then
		return false, "RIG_NOT_LOADED"
	end
	local description = ports.description()
	description.BodyTypeScale, description.ProportionScale = 0, 0
	for _, key in { "HeadColor", "LeftArmColor", "RightArmColor", "TorsoColor", "LeftLegColor", "RightLegColor" } do
		description[key] = ports.color(preset.skin)
	end
	local applied, err = pcall(function()
		humanoid:ApplyDescriptionReset(description)
	end)
	if not applied then
		return false, tostring(err)
	end
	-- Automatic scaling re-places every rig attachment from its OriginalPosition after a rebuild
	-- (Studio probe, L6): turn it off and write both, or the joints snap back to the blank body.
	humanoid.AutomaticScalingEnabled = false
	local layout = M.layout(preset.rigBody)
	for name, joint in layout.joints do
		for _, partName in { joint.parent, joint.child } do
			local part = character:FindFirstChild(partName)
			local attachment = part and part:FindFirstChild(name .. "RigAttachment")
			if attachment then
				local at = vec(joint.at) - vec(layout.rest[partName])
				attachment.CFrame = CFrame.new(at)
				local original = attachment:FindFirstChild("OriginalPosition")
				if original then
					original.Value = at
				end
			end
		end
	end
	humanoid:BuildRigFromAttachments()
	humanoid.HipHeight = M.HIP_HEIGHT
	for _, item in character:GetChildren() do
		if item:IsA("Accessory") or item:IsA("Clothing") or item:IsA("ShirtGraphic") then
			item:Destroy()
		elseif item:IsA("BasePart") and item.Name ~= "HumanoidRootPart" then
			item.Transparency = 1
			for _, decal in item:GetChildren() do
				if decal:IsA("Decal") then
					decal:Destroy()
				end
			end
		end
	end
	for _, name in { M.RIG_PIECES, M.FALLBACK, CosmeticVisual.FOLDER } do
		local previous = character:FindFirstChild(name)
		if previous then
			previous:Destroy()
		end
	end
	-- Bones of an earlier skinned body live on the body parts (below).
	for _, item in character:GetDescendants() do
		if item:IsA("Bone") and select(2, M.piece(item.Name)) == M.BONE_SLOT then
			item:Destroy()
		end
	end
	local folder = Instance.new("Folder")
	folder.Name = M.RIG_PIECES
	for _, source in template:GetChildren() do
		local partName = M.piece(source.Name)
		local body = if partName and layout.rest[partName] then character:FindFirstChild(partName) else nil
		if not body then
			continue
		end
		local piece = source:Clone() :: any
		piece.Anchored = false
		local offset: CFrame = piece:GetAttribute("ForgeRigOffset")
		local weld = Instance.new("Weld")
		weld.Part0, weld.Part1 = body, piece
		weld.C0 = CFrame.new(vec(layout.rest[partName :: string])):Inverse() * offset
		weld.Parent = piece
		piece.Parent = folder
		M.mountBones(piece, layout, function(name: string): Instance?
			return character:FindFirstChild(name)
		end)
	end
	folder.Parent = character
	character:SetAttribute("ForgeSurvivor", preset.id)
	return true, nil
end

--- Moves every Bone of a skinned body piece onto the character's R15 part of the same name, at the
--- Bone's rest offset (attribute ForgeRigOffset, rig space), so the part's Motor6D drives it.
function M.mountBones(piece: Instance, layout: Layout, part: (string) -> Instance?)
	local found = {}
	for _, item in piece:GetDescendants() do
		if item:IsA("Bone") then
			table.insert(found, item)
		end
	end
	for _, bone in found do
		local partName = M.piece(bone.Name)
		local target = partName and layout.rest[partName] and part(partName :: string)
		local offset = bone:GetAttribute("ForgeRigOffset")
		if target and typeof(offset) == "CFrame" then
			bone.Parent = target
			bone.CFrame = CFrame.new(vec(layout.rest[partName :: string])):Inverse() * offset
		end
	end
end

--- A static survivor figure (townsperson, castaway) standing on `handle`'s floor and welded to it,
--- so moving the handle moves the figure. Returns nil until the rig package loaded.
--- options.pose bends the rig (M.POSES: sit, carry, work, vend, stand); options.scale enlarges the
--- figure (town folk read at the play camera); options.seat is the seat height above the floor for
--- `sit` (the hips rest on it, the shins hang to the floor).
function M.figure(name: string, handle: BasePart, options: { pose: string?, scale: number?, seat: number? }?): Model?
	local preset = M.figurePreset(name)
	local template = M.rig(preset.id)
	if not template then
		return nil
	end
	local pose = options and options.pose or "stand"
	local scale = options and options.scale or 1
	local model = template:Clone()
	model.Name = "ForgeSurvivorFigure"
	model:SetAttribute("ForgeFigurePose", pose)
	local lift = M.rootLift(pose, scale, options and options.seat)
	local origin = handle.CFrame * CFrame.new(0, -handle.Size.Y / 2 + lift, 0)
	local bends = M.poseFrames(preset.rigBody or "A", pose)
	for _, piece in model:GetChildren() do
		if piece:IsA("BasePart") then
			local offset: CFrame = (piece :: any):GetAttribute("ForgeRigOffset")
			local part = M.piece(piece.Name)
			local bend = part and bends[part]
			if bend then
				offset = bend * offset
			end
			if scale ~= 1 then
				offset = CFrame.new(offset.Position * scale) * offset.Rotation
				piece.Size *= scale
			end
			piece.CFrame = origin * offset
			-- Skinned body: each Bone takes its part's bend; bone positions do not follow a Size
			-- change, so they are scaled here too. Parents first (the rig's bones are flat).
			for _, bone in piece:GetDescendants() do
				local rest = bone:GetAttribute("ForgeRigOffset")
				if bone:IsA("Bone") and typeof(rest) == "CFrame" then
					local bonePart = M.piece(bone.Name)
					local boneBend = bonePart and bends[bonePart]
					local at: CFrame = if boneBend then boneBend * rest else rest
					bone.WorldCFrame = origin * CFrame.new(at.Position * scale) * at.Rotation
				end
			end
			piece.Anchored = false
			local weld = Instance.new("Weld")
			weld.Part0, weld.Part1, weld.C0 = handle, piece, handle.CFrame:ToObjectSpace(piece.CFrame)
			weld.Parent = piece
		end
	end
	model.Parent = handle
	return model
end

-- Idle poses for town folk: joint bends (degrees about the rig's X axis; + swings the limb toward the
-- front, -Z), applied parent first. The rig's limbs are rigid per R15 part, so a bend is a rotation
-- of the child part and everything below it about the joint pivot (M.layout).
M.POSES = table.freeze({
	stand = { { "LeftShoulder", 6 }, { "RightShoulder", -6 } },
	sit = {
		{ "LeftHip", 90 },
		{ "RightHip", 84 },
		{ "LeftKnee", -90 },
		{ "RightKnee", -78 },
		{ "LeftShoulder", 28 },
		{ "RightShoulder", 34 },
		{ "LeftElbow", 30 },
		{ "RightElbow", 24 },
	},
	carry = { { "LeftShoulder", 62 }, { "RightShoulder", 62 }, { "LeftElbow", 58 }, { "RightElbow", 58 } },
	work = {
		{ "RightShoulder", 150 },
		{ "RightElbow", 25 },
		{ "LeftShoulder", 48 },
		{ "LeftElbow", 40 },
		{ "LeftHip", 14 },
		{ "LeftKnee", -14 },
	},
	vend = { { "LeftShoulder", 42 }, { "RightShoulder", 46 }, { "LeftElbow", 48 }, { "RightElbow", 44 } },
} :: { [string]: { { any } } })

-- Hip centre to the underside of the thigh when seated (studs, unscaled).
M.SEAT_CLEARANCE = 0.25

--- Height of the rig origin (HumanoidRootPart centre) above the floor for a pose: ROOT_HEIGHT standing,
--- else for `sit` the hips rest on a seat `seat` studs high.
function M.rootLift(pose: string, scale: number, seat: number?): number
	if pose == "sit" then
		local hip = -M.layout("A").joints.LeftHip.at.y
		return (seat or 1.65) + (M.SEAT_CLEARANCE + hip) * scale
	end
	return M.ROOT_HEIGHT * scale
end

-- Every R15 part below a joint's child (the bend moves the whole chain).
local BELOW: { [string]: { string } } = {
	LeftUpperLeg = { "LeftUpperLeg", "LeftLowerLeg", "LeftFoot" },
	RightUpperLeg = { "RightUpperLeg", "RightLowerLeg", "RightFoot" },
	LeftLowerLeg = { "LeftLowerLeg", "LeftFoot" },
	RightLowerLeg = { "RightLowerLeg", "RightFoot" },
	LeftUpperArm = { "LeftUpperArm", "LeftLowerArm", "LeftHand" },
	RightUpperArm = { "RightUpperArm", "RightLowerArm", "RightHand" },
	LeftLowerArm = { "LeftLowerArm", "LeftHand" },
	RightLowerArm = { "RightLowerArm", "RightHand" },
}

--- Rig-space CFrame per R15 part for a pose (parts missing from the map stay at rest).
function M.poseFrames(bodyId: string, pose: string): { [string]: CFrame }
	local layout = M.layout(bodyId)
	local frames: { [string]: CFrame } = {}
	local bends: { { any } } = M.POSES[pose] or {}
	for _, bend in bends do
		local joint = layout.joints[bend[1]]
		local chain = joint and BELOW[joint.child]
		if chain then
			local at = (frames[joint.child] or CFrame.new()) * vec(joint.at)
			local turn = CFrame.new(at) * CFrame.Angles(math.rad(bend[2]), 0, 0) * CFrame.new(-at)
			for _, part in chain do
				frames[part] = turn * (frames[part] or CFrame.new())
			end
		end
	end
	return frames
end

-- Server engine adapter (SurvivorWardrobe): dresses every character as its saved survivor on each
-- spawn and right after the picker saves a choice. The place loads no player avatar
-- (StarterPlayer.LoadCharacterAppearance = false). Paid worn sets are re-dressed on top by
-- SurvivalWorld's cosmetic sync after every apply.
-- ports: players, store (the robango-exp-v1 ActorDocumentStore), world (gains dressSurvivor).
function M.wardrobe(ports: any)
	local ApplyPorts = {
		description = function()
			return Instance.new("HumanoidDescription")
		end,
		color = function(rgb)
			return Color3.fromRGB(rgb.r, rgb.g, rgb.b)
		end,
		folder = function(name: string)
			local folder = Instance.new("Folder")
			folder.Name = name
			return folder
		end,
		hairCap = function(head: BasePart, color: Color3)
			local cap = Instance.new("Part")
			cap.Name = "HairCap"
			cap.Size = Vector3.new(head.Size.X * 1.08, head.Size.Y * 0.45, head.Size.Z * 1.08)
			cap.CFrame = head.CFrame * CFrame.new(0, head.Size.Y * 0.32, head.Size.Z * 0.04)
			cap.Color, cap.Material = color, Enum.Material.SmoothPlastic
			cap.CanCollide, cap.CanQuery, cap.CanTouch, cap.Massless = false, false, false, true
			local weld = Instance.new("WeldConstraint")
			weld.Part0, weld.Part1, weld.Parent = head, cap, cap
			return cap
		end,
		wait = function(seconds: number)
			task.wait(seconds)
		end,
	}
	local function dress(player: Player)
		local character = player.Character
		if not character then
			return
		end
		-- The saved document can be briefly busy or not yet resumed on join: retry, then fall
		-- back to the default survivor so a player never keeps the blank starter body.
		local document: any = nil
		for _ = 1, 10 do
			local snapshot = ports.store.snapshot(tostring(player.UserId))
			if snapshot then
				document = snapshot
				break
			end
			task.wait(1)
			if player.Character ~= character then
				return
			end
		end
		-- ApplyDescription needs the character in the DataModel; CharacterAdded can fire before the
		-- spawn gate parents it.
		while not character:IsDescendantOf(workspace) do
			if player.Character ~= character or player.Parent == nil then
				return
			end
			character.AncestryChanged:Wait()
		end
		-- The rig package loads once per server; a player joining first waits for it (bounded).
		for _ = 1, 20 do
			if rigs or player.Character ~= character then
				break
			end
			task.wait(1)
		end
		local dressPorts = table.clone(ApplyPorts) :: any
		dressPorts.current = function(): boolean
			return player.Character == character and player.Parent ~= nil
		end
		local preset = M.presetOf(document)
		if preset.kind == "rig" then
			local dressed, why = M.dressRig(character, preset, dressPorts)
			if dressed then
				return
			end
			warn("SURVIVOR_RIG:" .. tostring(why) .. " (catalog look)")
		end
		local ok, missing, reason = M.dressCharacter(character, preset, dressPorts)
		if not ok or #missing > 0 then
			-- Readable in the live server log: which pieces fell back to the game-made look.
			warn("SURVIVOR_APPLY:" .. tostring(reason) .. " missing=" .. table.concat(missing, ","))
		end
	end
	local rigsRequested = false
	local function watch(player: Player)
		-- The rig package loads once, when the first player arrives (dress waits for it, bounded).
		if not rigsRequested then
			rigsRequested = true
			task.spawn(M.loadRigs)
		end
		player.CharacterAdded:Connect(function()
			task.spawn(dress, player)
		end)
		if player.Character then
			task.spawn(dress, player)
		end
	end
	ports.players.PlayerAdded:Connect(watch)
	for _, player in ports.players:GetPlayers() do
		watch(player)
	end
	ports.world.dressSurvivor = function(actor: string)
		local player = ports.players:GetPlayerByUserId(tonumber(actor) or 0)
		if player then
			task.spawn(dress, player)
		end
	end
end

-- First-join survivor picker. Shown once, when the saved document has no choice yet; a pick
-- persists through `survival-coop:mission-action { "survivor", <presetId> }` (the pack's archipelago
-- extension stores it in the robango-exp-v1 actor document) and the server re-dresses the character.
-- Copy comes from the cli.survivor.* rows of locale/strings.csv.
M.PICK_ACTION = "survival-coop:mission-action"

-- p134 v60: the first confirm tap did nothing and the second closed the picker. The live session
-- refuses a command while another one for the actor is in flight (COMMAND_PENDING: here a trade
-- settlement that surfaced right after the close) and the expedition document answers DOCUMENT_BUSY
-- during a concurrent read; the confirm dropped any non-ok result. Transient refusals are retried.
M.CONFIRM_ATTEMPTS = 8
M.CONFIRM_RETRY_SECONDS = 0.5
local TRANSIENT = {
	COMMAND_PENDING = true,
	DOCUMENT_BUSY = true,
	SERVER_EVENT_PENDING = true,
	COMMAND_UNAVAILABLE = true,
}

--- True when a send result is a refusal that clears by itself (retry the same pick).
function M.transient(result: any): boolean
	if type(result) ~= "table" or result.ok == true then
		return false
	end
	local reason = tostring(result.reason or "")
	return TRANSIENT[reason] == true
		or string.sub(reason, 1, 16) == "TRANSPORT_FAILED"
		or (type(result.data) == "table" and result.data.status == "recovering")
end

--- Sends the survivor pick, retrying transient refusals (`wait(seconds)` between attempts) up to
--- CONFIRM_ATTEMPTS sends. Returns the last result.
function M.confirmPick(send: (string, { any }) -> any, id: string, wait: (number) -> ()): any
	local result: any = nil
	for attempt = 1, M.CONFIRM_ATTEMPTS do
		result = send(M.PICK_ACTION, { "survivor", id })
		if not M.transient(result) or attempt == M.CONFIRM_ATTEMPTS then
			break
		end
		wait(M.CONFIRM_RETRY_SECONDS)
	end
	return result
end

--- Picker rows: { id, text } per preset, the worn one marked. `text(key)` resolves cli.survivor.*.
function M.pickerRows(presets: { any }, view: any, text: (string) -> string): { { string } }
	local rows = {}
	local current = if type(view) == "table" then view.preset else nil
	for _, preset in presets do
		local label = text(preset.id) .. " - " .. text(preset.id .. "_note")
		if preset.id == current then
			label = label .. " (" .. text("current") .. ")"
		end
		table.insert(rows, { preset.id, label })
	end
	return rows
end

--- True when the picker must open: the server says no survivor was chosen yet.
function M.pickerNeeded(view: any): boolean
	return type(view) == "table" and view.chosen == false
end

export type Rect = { x: number, y: number, width: number, height: number }

--- L6b (R02-1/R02-3): character-creation screen geometry for a gui of width x height whose top `top`
--- pixels belong to the Roblox top bar; `left` (TopbarInset.Min.X) is where the free part of that band
--- starts. When the band is tall enough the header lives inside it, right of the Roblox buttons. Landscape: a large 3D stage on the left, a 2x2 grid of
--- archetype cards on the right and one wide confirm button under the cards. Portrait: stage on top,
--- cards and confirm below. Pure: the picker and the layout spec use the same rectangles.
function M.pickerLayout(width: number, height: number, top: number, left: number?): any
	local compact = math.min(width, height) < 500
	local pad = if compact then 8 else 16
	local inBand = left ~= nil and top >= 44 and left < width / 2
	local headerHeight = if inBand then top elseif compact then 40 else 52
	local headerY = if inBand then 0 else top
	local header = { x = 0, y = headerY, width = width, height = headerHeight }
	local close = { x = width - pad - 44, y = headerY + (headerHeight - 44) // 2, width = 44, height = 44 }
	local titleX = if inBand then (left :: number) + pad else pad
	local title = { x = titleX, y = headerY, width = close.x - pad - titleX, height = headerHeight }
	local bodyY = headerY + headerHeight + pad
	local bodyHeight = height - bodyY - pad
	local confirmHeight = if compact then 48 else 60
	local stage: Rect, panel: Rect
	if width >= height then
		local stageWidth = math.floor((width - 3 * pad) * 0.42)
		stage = { x = pad, y = bodyY, width = stageWidth, height = bodyHeight }
		local px = 2 * pad + stageWidth
		panel = { x = px, y = bodyY, width = width - px - pad, height = bodyHeight }
	else
		local stageHeight = math.floor((bodyHeight - pad) * 0.45)
		stage = { x = pad, y = bodyY, width = width - 2 * pad, height = stageHeight }
		local py = bodyY + stageHeight + pad
		panel = { x = pad, y = py, width = width - 2 * pad, height = height - pad - py }
	end
	local confirm =
		{ x = panel.x, y = panel.y + panel.height - confirmHeight, width = panel.width, height = confirmHeight }
	local gridHeight = confirm.y - pad - panel.y
	local cardWidth = (panel.width - pad) // 2
	local cardHeight = (gridHeight - pad) // 2
	local cards = {}
	for index = 0, 3 do
		table.insert(cards, {
			x = panel.x + (index % 2) * (cardWidth + pad),
			y = panel.y + (index // 2) * (cardHeight + pad),
			width = cardWidth,
			height = cardHeight,
		})
	end
	local art = math.min(cardHeight - 8, math.floor(cardWidth * 0.45))
	return {
		compact = compact,
		header = header,
		title = title,
		close = close,
		stage = stage,
		cards = cards,
		confirm = confirm,
		-- Inside a card: portrait art on the left, name and outfit note on the right.
		art = { x = 4, y = 4, width = art, height = art },
		name = { x = art + 12, y = 6, width = cardWidth - art - 18, height = if compact then 20 else 26 },
		note = {
			x = art + 12,
			y = if compact then 28 else 36,
			width = cardWidth - art - 18,
			height = cardHeight - (if compact then 32 else 42),
		},
		text = {
			title = if compact then 20 else 26,
			name = if compact then 17 else 22,
			note = if compact then 12 else 15,
			confirm = if compact then 20 else 24,
			stageName = if compact then 22 else 32,
		},
	}
end

--- Panel factory (ExtensionPanels context plus `presets` and `text`). L6b: a full-screen
--- character-creation screen (R02): a large turning 3D preview, archetype cards with a live
--- portrait of each painted survivor and one clear confirm button.
function M.picker(ctx: any): any
	local player = game:GetService("Players").LocalPlayer
	local replicated = game:GetService("ReplicatedStorage")
	local guiService = game:GetService("GuiService")
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = "ForgeSurvivorPicker", false, 26, false
	gui.IgnoreGuiInset, gui.ZIndexBehavior = true, Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	local INK, CREAM, GOLD = Color3.fromRGB(16, 13, 10), Color3.fromRGB(240, 230, 210), Color3.fromRGB(242, 182, 48)
	local function box(class: string, name: string, parent: Instance, color: Color3?): any
		local item = Instance.new(class) :: any
		item.Name, item.BorderSizePixel = name, 0
		if color then
			item.BackgroundColor3 = color
		else
			item.BackgroundTransparency = 1
		end
		item.Parent = parent
		return item
	end
	local function text(name: string, parent: Instance, color: Color3): TextLabel
		local item = box("TextLabel", name, parent) :: TextLabel
		item.Font, item.TextColor3, item.TextXAlignment = Enum.Font.GothamBold, color, Enum.TextXAlignment.Left
		item.TextWrapped, item.TextTruncate = true, Enum.TextTruncate.AtEnd
		return item
	end
	local function round(item: Instance, radius: number)
		local corner = Instance.new("UICorner")
		corner.CornerRadius, corner.Parent = UDim.new(0, radius), item
	end
	local function put(item: any, rect: Rect)
		item.Position, item.Size = UDim2.fromOffset(rect.x, rect.y), UDim2.fromOffset(rect.width, rect.height)
	end
	-- Root: a dedicated screen over the world (HudShell.sheetOpen sees Header > Close and hides the HUD).
	local root = box("Frame", "SurvivorPicker", gui, Color3.fromRGB(26, 22, 18))
	root.Size = UDim2.fromScale(1, 1)
	local header = box("Frame", "Header", root, INK)
	local title = text("Title", header, CREAM)
	title.Text, title.TextWrapped, title.TextYAlignment = ctx.text("title"), false, Enum.TextYAlignment.Center
	local close = box("TextButton", "Close", header, Color3.fromRGB(176, 52, 40)) :: TextButton
	close.Text, close.Font, close.TextColor3, close.TextSize = "X", Enum.Font.GothamBold, CREAM, 20
	round(close, 22)
	-- Stage: warm backdrop, floor disc and the highlighted survivor turning slowly in a 3/4 view.
	local backdrop = box("Frame", "Backdrop", root, Color3.fromRGB(255, 255, 255))
	round(backdrop, 8)
	local shade = Instance.new("UIGradient")
	shade.Color = ColorSequence.new(Color3.fromRGB(92, 76, 56), Color3.fromRGB(28, 24, 20))
	shade.Rotation, shade.Parent = 90, backdrop
	local stage = box("ViewportFrame", "SurvivorPreview", backdrop) :: ViewportFrame
	stage.Size = UDim2.fromScale(1, 1)
	stage.Ambient, stage.LightColor, stage.LightDirection =
		Color3.fromRGB(150, 140, 128), Color3.fromRGB(255, 242, 222), Vector3.new(-0.5, -0.7, 0.5)
	local camera = Instance.new("Camera")
	camera.FieldOfView, camera.Parent = 30, stage
	-- Framed from the first frame (the sway below only moves it; a busy client may skip ticks).
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 0.7, -9.6), Vector3.new(0, -0.1, 0))
	stage.CurrentCamera = camera
	local floor = Instance.new("Part")
	floor.Shape, floor.Anchored, floor.Size = Enum.PartType.Cylinder, true, Vector3.new(0.2, 4.2, 4.2)
	floor.CFrame = CFrame.new(0, -2.46, 0) * CFrame.Angles(0, 0, math.pi / 2)
	floor.Color, floor.Material, floor.Parent = Color3.fromRGB(64, 52, 40), Enum.Material.SmoothPlastic, stage
	local stageName = text("StageName", backdrop, CREAM)
	stageName.TextYAlignment = Enum.TextYAlignment.Bottom
	local stageStroke = Instance.new("UIStroke")
	stageStroke.Color, stageStroke.Thickness, stageStroke.Parent = Color3.fromRGB(0, 0, 0), 2, stageName
	local confirm = box("TextButton", "Survivor-confirm", root, GOLD) :: TextButton
	confirm.Text, confirm.Font, confirm.TextColor3 = ctx.text("confirm"), Enum.Font.GothamBold, INK
	round(confirm, 8)
	local shown: Model? = nil
	local clock = 0
	local focus: string? = nil
	local view: any = nil
	local asked = false
	local sending = false
	local connections = {}
	local cards: { [string]: any } = {}
	local function template(id: string): Model?
		local folder = replicated:FindFirstChild(M.RIG_FOLDER)
		return if folder then folder:FindFirstChild(id) :: any else nil
	end
	local function render()
		local current = if view then view.preset else nil
		for id, card in cards do
			local picked = id == focus
			card.frame.BackgroundColor3 = if picked then Color3.fromRGB(78, 64, 42) else Color3.fromRGB(48, 42, 34)
			card.stroke.Color = if picked then GOLD else Color3.fromRGB(96, 84, 66)
			card.stroke.Thickness = if picked then 3 else 1
			card.name.Text = ctx.text(id) .. (if id == current then " (" .. ctx.text("current") .. ")" else "")
		end
		stageName.Text = if focus then ctx.text(focus) else ""
	end
	local function preview(id: string)
		focus = id
		if shown then
			shown:Destroy()
			shown = nil
		end
		local source = template(id)
		if source then
			local model = source:Clone()
			model:PivotTo(CFrame.new())
			model.Parent = stage
			shown = model
		end
		render()
	end
	local function portraits()
		for id, card in cards do
			if card.figure then
				continue
			end
			local source = template(id)
			if source then
				local model = source:Clone()
				model:PivotTo(CFrame.new())
				model.Parent = card.art
				card.figure = model
			end
		end
		if focus and not shown then
			preview(focus)
		end
	end
	for index, preset in ctx.presets do
		local id = preset.id
		local frame = box("TextButton", "Survivor-" .. id, root, Color3.fromRGB(48, 42, 34)) :: TextButton
		frame.Text, frame.AutoButtonColor = "", true
		round(frame, 8)
		local stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode, stroke.Parent = Enum.ApplyStrokeMode.Border, frame
		local art = box("ViewportFrame", "Portrait", frame, Color3.fromRGB(70, 58, 44)) :: ViewportFrame
		art.Ambient, art.LightColor, art.LightDirection =
			Color3.fromRGB(150, 140, 128), Color3.fromRGB(255, 242, 222), Vector3.new(-0.5, -0.6, 0.6)
		round(art, 6)
		local lens = Instance.new("Camera")
		-- Head and shoulders, a little to the side (R02-1 portrait tile).
		lens.FieldOfView = 30
		lens.CFrame = CFrame.lookAt(Vector3.new(0.9, 1.95, -2.7), Vector3.new(0, 1.62, 0))
		lens.Parent, art.CurrentCamera = art, lens
		local name = text("Name", frame, CREAM)
		local note = text("Note", frame, Color3.fromRGB(206, 192, 166))
		note.Text, note.Font, note.TextYAlignment = ctx.text(id .. "_note"), Enum.Font.Gotham, Enum.TextYAlignment.Top
		cards[id] = { frame = frame, stroke = stroke, art = art, name = name, note = note, order = index }
		table.insert(
			connections,
			frame.Activated:Connect(function()
				preview(id)
			end)
		)
	end
	local function layout()
		local size = gui.AbsoluteSize
		local inset = guiService.TopbarInset
		local L = M.pickerLayout(size.X, size.Y, if inset then inset.Max.Y else 0, if inset then inset.Min.X else nil)
		-- The header bar always starts at the screen top (behind the Roblox buttons when it sits below
		-- the band); title and X keep their own rectangles.
		header.Position = UDim2.fromOffset(0, 0)
		header.Size = UDim2.fromOffset(L.header.width, L.header.y + L.header.height)
		put(title, L.title)
		put(close, L.close)
		title.TextSize, close.TextSize = L.text.title, L.text.title
		put(backdrop, L.stage)
		put(stageName, {
			x = 12,
			y = L.stage.height - L.text.stageName - 14,
			width = L.stage.width - 24,
			height = L.text.stageName + 4,
		})
		stageName.TextSize = L.text.stageName
		put(confirm, L.confirm)
		confirm.TextSize = L.text.confirm
		for _, card in cards do
			put(card.frame, L.cards[card.order])
			put(card.art, L.art)
			put(card.name, L.name)
			put(card.note, L.note)
			card.name.TextSize, card.note.TextSize = L.text.name, L.text.note
		end
	end
	layout()
	table.insert(connections, gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout))
	table.insert(connections, guiService:GetPropertyChangedSignal("TopbarInset"):Connect(layout))
	-- The rig templates replicate after the server loads the package: fill the art when they arrive.
	local function watch(folder: Instance)
		table.insert(connections, folder.ChildAdded:Connect(portraits))
		task.defer(portraits)
	end
	table.insert(
		connections,
		replicated.ChildAdded:Connect(function(child)
			if child.Name == M.RIG_FOLDER then
				watch(child)
			end
		end)
	)
	local existing = replicated:FindFirstChild(M.RIG_FOLDER)
	if existing then
		watch(existing)
	end
	table.insert(
		connections,
		game:GetService("RunService").RenderStepped:Connect(function(dt: number)
			if gui.Enabled and shown then
				clock += dt
				-- 3/4 front view, the whole figure on its floor disc (R02-1), swaying slowly between
				-- both 3/4 sides so the face and the outfit front stay in view.
				local yaw = 0.55 * math.sin(clock * 0.45)
				local eye = Vector3.new(math.sin(yaw) * 9.6, 0.7, -math.cos(yaw) * 9.6)
				camera.CFrame = CFrame.lookAt(eye, Vector3.new(0, -0.1, 0))
			end
		end)
	)
	table.insert(
		connections,
		confirm.Activated:Connect(function()
			if sending then
				return -- one pick in flight; a repeat tap must not queue a second request
			end
			sending = true
			confirm.AutoButtonColor, confirm.BackgroundTransparency = false, 0.35
			local id = focus or (if view then view.preset else M.DEFAULT)
			local result = M.confirmPick(ctx.send, id, task.wait)
			sending = false
			confirm.AutoButtonColor, confirm.BackgroundTransparency = true, 0
			if result and result.ok then
				view = { preset = id, chosen = true }
				render()
				gui.Enabled = false
			end
		end)
	)
	table.insert(
		connections,
		close.Activated:Connect(function()
			gui.Enabled = false
		end)
	)
	local function maybeOpen()
		if M.pickerNeeded(view) and not asked and not (ctx.held and ctx.held()) then
			asked = true
			gui.Enabled = true
			if not shown and view then
				preview(focus or view.preset)
			end
		end
	end
	-- A closed picker holds no preview rig.
	table.insert(
		connections,
		gui:GetPropertyChangedSignal("Enabled"):Connect(function()
			if not gui.Enabled and shown then
				shown:Destroy()
				shown = nil
			end
		end)
	)
	local stop = ctx.onSnapshot(function(snapshot)
		local trip = if type(snapshot) == "table" then snapshot.archipelago else nil
		local next = if type(trip) == "table" then trip.survivor else nil
		if next then
			view = next
			-- Rebuild the 3D preview only when shown and its survivor changes: re-cloning the rig on
			-- every per-second snapshot churned ~26 MeshParts/s for the whole session (p134 v59 memory).
			if gui.Enabled and (not focus or (not shown and view.preset ~= focus)) then
				preview(view.preset)
			end
			render()
			maybeOpen()
		end
	end)
	-- R01: the picker waits for the title screen's Start (`held`), then opens on `onRelease`.
	local release = if ctx.onRelease then ctx.onRelease(maybeOpen) else nil
	return {
		destroy = function()
			stop()
			if release then
				release()
			end
			for _, connection in connections do
				connection:Disconnect()
			end
			gui:Destroy()
		end,
	}
end

return M
