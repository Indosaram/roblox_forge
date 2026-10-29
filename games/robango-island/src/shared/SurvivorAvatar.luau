--!strict
-- Robango survivors (plan G23 / A6, L6): every player is a game-supplied adult survivor, never their
-- own Roblox avatar. Pure model (engine-free): the preset catalog, the HumanoidDescription values a
-- preset dresses, and the saved choice inside the actor's `robango-exp-v1` document.
--
-- L6: every preset is kind "rig": the pack's own survivor meshes (assets/blender/gen_survivors.py,
-- package `mesh-survivors`), four period work outfits on two body types. The server loads the package
-- once, relays the R15 joints to the preset's body type and welds each mesh piece to its R15 body part;
-- the blank R15 parts turn invisible. The pieces are untextured and coloured per slot from `palette`
-- (MeshPart.Color + Material): no SurfaceAppearance reaches the client. When the package does not load,
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
	for _, item in package:GetDescendants() do
		if item:IsA("MeshPart") then
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
			else
				local rgb, material = M.slotStyle(preset, slot :: string)
				item.Color = Color3.fromRGB(rgb.r, rgb.g, rgb.b)
				item.Material = (Enum.Material :: any)[material]
			end
			item.Parent = model
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
	end
	folder.Parent = character
	character:SetAttribute("ForgeSurvivor", preset.id)
	return true, nil
end

--- A static survivor figure (townsperson, castaway) standing on `handle`'s floor and welded to it,
--- so moving the handle moves the figure. Returns nil until the rig package loaded.
function M.figure(name: string, handle: BasePart): Model?
	local preset = M.figurePreset(name)
	local template = M.rig(preset.id)
	if not template then
		return nil
	end
	local model = template:Clone()
	model.Name = "ForgeSurvivorFigure"
	local origin = handle.CFrame * CFrame.new(0, -handle.Size.Y / 2 + M.ROOT_HEIGHT, 0)
	for _, piece in model:GetChildren() do
		if piece:IsA("BasePart") then
			local offset: CFrame = (piece :: any):GetAttribute("ForgeRigOffset")
			piece.CFrame = origin * offset
			piece.Anchored = false
			local weld = Instance.new("Weld")
			weld.Part0, weld.Part1, weld.C0 = handle, piece, handle.CFrame:ToObjectSpace(piece.CFrame)
			weld.Parent = piece
		end
	end
	model.Parent = handle
	return model
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

--- Panel factory (ExtensionPanels context plus `presets` and `text`).
function M.picker(ctx: any): any
	local player = game:GetService("Players").LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = "ForgeSurvivorPicker", false, 26, false
	gui.Parent = player:WaitForChild("PlayerGui")
	local sheet = ctx.ui.components.modalSheet(ctx.ui.theme.default, {
		name = "SurvivorPicker",
		title = ctx.text("title"),
		parent = gui,
	})
	assert(ctx.fitSheet, "SURVIVOR_SHEET_REQUIRED")(sheet.frame)
	sheet.frame.Visible = true
	local intro = ctx.ui.components.label(ctx.ui.theme.default, {
		text = ctx.text("intro"),
		size = UDim2.new(1, 0, 0, 40),
		parent = sheet.scroll,
	})
	intro.TextWrapped, intro.LayoutOrder = true, 0
	-- L6 (R02-1): a turning 3D preview of the highlighted survivor above the rows. A row tap
	-- previews; the confirm button under the preview saves the choice.
	local stage = Instance.new("ViewportFrame")
	stage.Name, stage.LayoutOrder, stage.Size = "SurvivorPreview", 0, UDim2.new(1, 0, 0, 220)
	stage.BackgroundColor3, stage.BorderSizePixel = Color3.fromRGB(46, 40, 34), 0
	stage.Ambient, stage.LightColor, stage.LightDirection =
		Color3.fromRGB(196, 186, 172), Color3.fromRGB(255, 244, 228), Vector3.new(-0.4, -0.8, 0.6)
	stage.Parent = sheet.scroll
	local camera = Instance.new("Camera")
	camera.FieldOfView, camera.Parent = 30, stage
	stage.CurrentCamera = camera
	local shown: Model? = nil
	local yaw = 0
	local focus: string? = nil
	local confirm = ctx.ui.components.button(ctx.ui.theme.default, {
		text = ctx.text("confirm"),
		size = UDim2.new(1, 0, 0, 48),
		parent = sheet.scroll,
	})
	confirm.Name, confirm.LayoutOrder = "Survivor-confirm", #ctx.presets + 1
	local function preview(id: string)
		focus = id
		if shown then
			shown:Destroy()
			shown = nil
		end
		local rigFolder = game:GetService("ReplicatedStorage"):FindFirstChild(M.RIG_FOLDER)
		local template = rigFolder and rigFolder:FindFirstChild(id)
		if template then
			local model = template:Clone()
			model:PivotTo(CFrame.new())
			model.Parent = stage
			shown = model
		end
		stage.Visible = shown ~= nil
	end
	local view: any = nil
	local asked = false
	local connections = {}
	local buttons: { [string]: TextButton } = {}
	local function render()
		for _, row in M.pickerRows(ctx.presets, view, ctx.text) do
			local button = buttons[row[1]]
			if button then
				button.Text = row[2]
				button.BorderSizePixel = if row[1] == focus then 2 else 0
			end
		end
	end
	table.insert(
		connections,
		game:GetService("RunService").RenderStepped:Connect(function(dt: number)
			if gui.Enabled and shown then
				yaw += dt * 0.6
				-- 3/4 view about two body heights away (R02-1), turning slowly.
				local eye = Vector3.new(math.sin(yaw) * 12, 0.8, -math.cos(yaw) * 12)
				camera.CFrame = CFrame.lookAt(eye, Vector3.new(0, -0.1, 0))
			end
		end)
	)
	for index, row in M.pickerRows(ctx.presets, view, ctx.text) do
		local id = row[1]
		local button = ctx.ui.components.button(ctx.ui.theme.default, {
			text = row[2],
			size = UDim2.new(1, 0, 0, 48),
			parent = sheet.scroll,
		})
		button.Name, button.LayoutOrder, button.TextWrapped = "Survivor-" .. id, index, true
		buttons[id] = button
		table.insert(
			connections,
			button.Activated:Connect(function()
				preview(id)
				render()
			end)
		)
	end
	table.insert(
		connections,
		confirm.Activated:Connect(function()
			local id = focus or (if view then view.preset else M.DEFAULT)
			local result = ctx.send(M.PICK_ACTION, { "survivor", id })
			if result and result.ok then
				view = { preset = id, chosen = true }
				render()
				gui.Enabled = false
			end
		end)
	)
	table.insert(
		connections,
		sheet.close.Activated:Connect(function()
			gui.Enabled = false
		end)
	)
	local function maybeOpen()
		if M.pickerNeeded(view) and not asked and not (ctx.held and ctx.held()) then
			asked = true
			gui.Enabled = true
		end
	end
	local stop = ctx.onSnapshot(function(snapshot)
		local trip = if type(snapshot) == "table" then snapshot.archipelago else nil
		local next = if type(trip) == "table" then trip.survivor else nil
		if next then
			view = next
			if not focus or not gui.Enabled then
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
