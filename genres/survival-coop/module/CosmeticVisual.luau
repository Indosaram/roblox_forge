--!strict
-- CosmeticVisual: what a selected paid cosmetic looks like. Pure planning (`supported`, `slot`,
-- `mount`, `wear`) plus one engine adapter (`dressWear`) that welds worn pieces onto a character.
-- A pack supplies the config (mount skins and worn sets); nothing here changes speed, carry or
-- any other gameplay value, so a cosmetic is appearance only.
local M = {}

M.FOLDER = "ForgeCosmetics"

export type Rgb = { r: number, g: number, b: number }
export type MountSkin = {
	species: string,
	body: Rgb,
	accent: Rgb?,
	belly: Rgb?,
	marking: Rgb?,
	sheen: number?,
	parts: { string }?,
}
export type Piece = {
	id: string,
	part: string,
	fallback: string,
	size: { number },
	offset: { number },
	color: Rgb,
	material: string,
}
export type WearSet = { slot: string, pieces: { Piece } }
export type Config = { mountSkins: { [string]: MountSkin }, wear: { [string]: WearSet } }

--- True when the cosmetic id has a renderer (a mount skin or a worn set).
function M.supported(config: Config, id: string): boolean
	return config.mountSkins[id] ~= nil or config.wear[id] ~= nil
end

--- Selection slot: one mount skin per species, one worn set per body slot.
function M.slot(config: Config, id: string): string
	local skin = config.mountSkins[id]
	if skin then
		return "mount:" .. skin.species
	end
	local set = config.wear[id]
	return if set then "wear:" .. set.slot else id
end

--- The species visual dressed in a mount skin: palette, sheen and extra trim parts.
function M.mount(visual: any, skin: MountSkin?): any
	if skin == nil then
		return visual
	end
	local result = table.clone(visual or {})
	result.body = skin.body
	result.accent = skin.accent or result.accent
	result.belly = skin.belly or result.belly
	result.marking = skin.marking or result.marking
	result.sheen = skin.sheen
	local parts = table.clone(result.parts or {})
	local trim: { string } = skin.parts or {}
	for _, token in trim do
		if not table.find(parts, token) then
			table.insert(parts, token)
		end
	end
	result.parts = parts
	return result
end

--- Worn pieces for the selected cosmetics (a set of ids), ordered by set id.
function M.wear(config: Config, appearance: { [string]: boolean }?): { any }
	local ids = {}
	local selected: { [string]: boolean } = appearance or {}
	for id, on in selected do
		if on and config.wear[id] then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	local plan = {}
	for _, id in ids do
		for _, piece in config.wear[id].pieces do
			table.insert(plan, {
				set = id,
				id = piece.id,
				part = piece.part,
				fallback = piece.fallback,
				size = piece.size,
				offset = piece.offset,
				color = piece.color,
				material = piece.material,
			})
		end
	end
	return plan
end

--- Engine adapter: rebuilds the character's cosmetic folder when the plan changed. Returns
--- true when it changed anything. Pieces are physics-inert and welded to their body part.
function M.dressWear(character: any, plan: { any }): boolean
	local keys = {}
	for _, piece in plan do
		table.insert(keys, piece.set .. ":" .. piece.id)
	end
	local signature = table.concat(keys, ",")
	local folder = character:FindFirstChild(M.FOLDER)
	if (folder and folder:GetAttribute("ForgeCosmeticSignature") == signature) or (not folder and #plan == 0) then
		return false
	end
	if folder then
		folder:Destroy()
	end
	if #plan == 0 then
		return true
	end
	local fresh = Instance.new("Folder")
	fresh.Name = M.FOLDER
	fresh:SetAttribute("ForgeCosmeticSignature", signature)
	for _, entry in plan do
		local body = character:FindFirstChild(entry.part) or character:FindFirstChild(entry.fallback)
		if not body or not body:IsA("BasePart") then
			continue
		end
		local piece = Instance.new("Part")
		piece.Name = "Cosmetic-" .. entry.id
		piece.Size = Vector3.new(entry.size[1], entry.size[2], entry.size[3])
		piece.Color = Color3.fromRGB(entry.color.r, entry.color.g, entry.color.b)
		piece.Material = (Enum.Material :: any)[entry.material]
		piece.CanCollide, piece.CanQuery, piece.CanTouch, piece.Massless = false, false, false, true
		piece.CFrame = body.CFrame * CFrame.new(entry.offset[1], entry.offset[2], entry.offset[3])
		piece:SetAttribute("ForgeCosmetic", entry.set)
		local weld = Instance.new("WeldConstraint")
		weld.Part0, weld.Part1, weld.Parent = body, piece, piece
		piece.Parent = fresh
	end
	fresh.Parent = character
	return true
end

return M
