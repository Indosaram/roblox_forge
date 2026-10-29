--!strict
-- L7: hand tools, weapons and worn gear render the uploaded `mesh-tools` package (RobangoTools,
-- assets/blender/gen_tools.py) through the survival-coop `visuals` hooks instead of the genre's
-- primitive Handle + wedge. Presentation only: the genre tools registry and gear state stay the
-- authority; a missing template (headless engine, failed load, unmapped item) returns false/nil
-- so the genre default stays.
-- Rows: a Model per key (`tool.<family>.t<n>` or `tool.<family>`) whose MeshParts carry a role
-- suffix: none = wood, `__head` = working part (tier look), `__bind` = lashing/cord, `__ember`.
-- The FBX has no textures (Open Cloud FBX imports leave SurfaceAppearance TexturePacks empty and
-- phone clients fail them), so every role is coloured here with plain Color + Material.
-- Row frame: the grip point is the origin and the haft runs along +Y (Blender +Z).
local M = {}

M.PACKAGE = "mesh-tools"

-- Material tiers: t1 knapped stone, t2 bone/antler, t3 copper.
local HEAD = {
	[1] = { color = { 112, 114, 116 }, material = "Slate" },
	[2] = { color = { 222, 210, 182 }, material = "SmoothPlastic" },
	[3] = { color = { 184, 112, 62 }, material = "Metal" },
}
local ROLE = {
	wood = { color = { 116, 80, 46 }, material = "Wood" },
	bind = { color = { 150, 126, 86 }, material = "Fabric" },
	ember = { color = { 255, 140, 50 }, material = "Neon" },
	wicker = { color = { 168, 128, 74 }, material = "Wood" },
	bundle = { color = { 92, 66, 42 }, material = "Fabric" },
}

-- Catalog item -> row key. Families without a row of their own borrow the nearest primitive
-- shape: swords read as long knives, crossbows as bows (scale in SCALE).
M.ITEMS = {
	["stone-axe"] = "tool.axe.t1",
	["starter-axe"] = "tool.axe.t1",
	["stone-pick"] = "tool.pick.t1",
	["starter-pickaxe"] = "tool.pick.t1",
	["starter-club"] = "tool.club.t1",
	["stone-maul"] = "tool.hammer.t1",
	["flint-knife"] = "tool.knife.t1",
	["bone-knife"] = "tool.knife.t2",
	spear = "tool.spear.t1",
	["capture-bola"] = "tool.bola",
} :: { [string]: string }
for _, family in { "axe", "pickaxe", "club", "hammer", "hoe", "knife", "spear", "bow", "sword", "crossbow" } do
	local row = if family == "pickaxe"
		then "pick"
		elseif family == "sword" then "knife"
		elseif family == "crossbow" then "bow"
		else family
	for tier = 1, 3 do
		M.ITEMS[family .. "-t" .. tier] = "tool." .. row .. ".t" .. tier
	end
end
-- Worn bags render as the back basket.
for _, climate in { "cold", "temperate", "tropical" } do
	M.ITEMS[climate .. "-bag"] = "tool.basket"
end
M.SCALE = { sword = 1.5 } :: { [string]: number }

-- Forward tilt (degrees) of the haft from upright in the engine tool-hold pose (R15 `toolnone`
-- raises the arm, so the grip's +Y is up and its -Z is forward). Bow, sling and bola hang upright.
local HOLD = { spear = 55, knife = 25, bow = 0, sling = 0, bola = 0, torch = 10 }
local DEFAULT_HOLD = 15

--- Row key for a catalog id (nil when the item has no tool row).
function M.row(catalogId: string): string?
	return M.ITEMS[catalogId]
end

--- Pure: colour + material for one mesh part of a row (`name` is the MeshPart name).
function M.look(key: string, name: string): { color: { number }, material: string }
	local suffix = string.match(name, "__(%a+)$")
	local tier = tonumber(string.match(key, "%.t(%d)$"))
	if suffix == "head" then
		return HEAD[tier or 1]
	elseif suffix == "ember" then
		return ROLE.ember
	elseif suffix == "bind" then
		return if key == "tool.basket" then ROLE.wood else ROLE.bind
	elseif key == "tool.basket" then
		return ROLE.wicker
	elseif key == "tool.torch" and suffix == nil then
		return ROLE.wood
	end
	return ROLE.wood
end

--- Pure: forward hold tilt in degrees for a row key.
function M.hold(key: string): number
	local family = string.match(key, "^tool%.(%a+)") or ""
	return HOLD[family] or DEFAULT_HOLD
end

local templates: { [string]: any }? = nil

--- Test seam: specs inject fake row Models (key -> Model) instead of InsertService.
function M.setTemplates(value: { [string]: any }?)
	templates = value
end

local function paint(key: string, model: any)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local look = M.look(key, part.Name)
			part.Color = Color3.fromRGB(look.color[1], look.color[2], look.color[3])
			part.Material = (Enum.Material :: any)[look.material]
			part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch, part.Massless =
				false, false, false, false, true
			part.CastShadow = false
		end
	end
end

--- Server: loads the package once (InsertService, yields) and returns key -> template Model.
--- Headless engines and failed loads give an empty table; the genre defaults then stay.
function M.load(assets: { [string]: any }?): { [string]: any }
	if templates then
		return templates
	end
	local loaded: { [string]: any } = {}
	templates = loaded
	local ok, insert = pcall(function()
		return game:GetService("InsertService")
	end)
	if not ok or not insert or not assets then
		return loaded
	end
	local id = tonumber(string.match(tostring(assets[M.PACKAGE] or ""), "%d+$") or "")
	if not id then
		return loaded
	end
	local success, result = pcall(insert.LoadAsset, insert, id)
	if not success then
		warn("ToolVisuals: " .. M.PACKAGE .. " not loaded, primitive tools stay: " .. tostring(result))
		return loaded
	end
	-- The FBX carries no textures today; baking keeps a future textured re-export off the
	-- SurfaceAppearance path phones cannot render (mesh-texture.spec guards every loader).
	local MeshTexture =
		require(game:GetService("ReplicatedStorage").Forge.games["robango-island"].src.shared.MeshTexture)
	MeshTexture.bake(result)
	local storage = Instance.new("Folder")
	storage.Name, storage.Parent = "ForgeToolTemplates", game:GetService("ServerStorage")
	for _, row in result:GetDescendants() do
		if row:IsA("Model") and row:FindFirstChildWhichIsA("MeshPart") then
			local key = string.gsub(row.Name, "%.%d%d%d$", "")
			for _, part in row:GetDescendants() do
				if part:IsA("BasePart") then
					part.Name = string.gsub(part.Name, "%.%d%d%d$", "")
				end
			end
			row.Name, row.WorldPivot, row.Parent = key, CFrame.new(), storage
			loaded[key] = row
		end
	end
	result:Destroy()
	return loaded
end

-- Clones row `key`: returns its main (wood) part and the other parts, or nil without a
-- template. Part CFrames are row-relative (the row origin is the grip point; load() pivots every
-- template at the identity).
local function assemble(key: string, scale: number): (any, { any })
	local template = templates and templates[key]
	if not template then
		return nil, {}
	end
	local model = template:Clone()
	paint(key, model)
	local main, rest = nil, {}
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			if part.Name == key then
				main = part
			else
				table.insert(rest, part)
			end
		end
	end
	main = main or table.remove(rest, 1)
	if scale ~= 1 then
		for _, part in { main, table.unpack(rest) } do
			part.Size *= scale
			part.CFrame = CFrame.new(part.CFrame.Position * scale) * part.CFrame.Rotation
		end
	end
	return main, rest
end

local function weldAll(main: any, rest: { any })
	for _, part in rest do
		local weld = Instance.new("WeldConstraint")
		weld.Part0, weld.Part1, weld.Parent = main, part, part
	end
end

--- Genre hook `visuals.tool`: dresses a fresh Tool with the row mesh. The wood part becomes the
--- Handle; Grip puts the row origin (the grip point) in the hand with the haft raised by `hold`.
function M.dressTool(tool: any, catalogId: string): boolean
	local key = M.row(catalogId)
	if not key or key == "tool.basket" then
		return false
	end
	local family = string.match(catalogId, "^(%a+)%-t%d$") or ""
	local main, rest = assemble(key, M.SCALE[family] or 1)
	if not main then
		return false
	end
	main.Name, main.Parent = "Handle", tool
	for _, part in rest do
		part.Parent = tool
	end
	weldAll(main, rest)
	tool.Grip = main.CFrame:Inverse() * CFrame.Angles(math.rad(M.hold(key)), 0, 0)
	tool:SetAttribute("ForgeToolRow", key)
	return true
end

-- Worn gear placement on the UpperTorso (Torso on R6): the basket sits on the back, a worn
-- weapon is slung diagonally across it. The character faces -Z, so the back is +Z.
local SLING = {
	bag = CFrame.new(0, 0.15, 1.05),
	weapon = CFrame.new(0.15, -0.1, 0.75) * CFrame.Angles(0, 0, math.rad(-35)) * CFrame.new(0, -0.6, 0),
}

--- Genre hook `visuals.gear`: the welded visual for one CharacterRules.dressing entry, or nil
--- (clothing slots, unmapped items, no template) so the genre's primitive part stays.
function M.dressGear(entry: any, character: any): any
	local place = SLING[entry.slot]
	local key = M.row(entry.catalogId)
	local body = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if not place or not key or not body or (entry.slot == "bag") ~= (key == "tool.basket") then
		return nil
	end
	local main, rest = assemble(key, 1)
	if not main then
		return nil
	end
	local model = Instance.new("Model")
	local target = body.CFrame * place
	for _, part in { main, table.unpack(rest) } do
		part.CFrame = target * part.CFrame
		part.Parent = model
	end
	weldAll(main, rest)
	local weld = Instance.new("WeldConstraint")
	weld.Part0, weld.Part1, weld.Parent = body, main, main
	model:SetAttribute("ForgeToolRow", key)
	return model
end

--- The survival-coop `visuals` config (SurvivalWorld.Visuals). Paid cosmetic pieces keep the
--- genre default (no `wear` builder yet).
function M.hooks(): any
	return { tool = M.dressTool, gear = M.dressGear }
end

return M
