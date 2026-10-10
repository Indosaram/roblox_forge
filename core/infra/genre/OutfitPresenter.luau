--!strict
-- OutfitPresenter: applies the spec's declared outfit feedback on the SERVER, so every client
-- receives the worn accessory through ordinary replication.
--
-- A LocalScript could only ever add an accessory to its own character: the wearer saw a hat and
-- nobody else did, which left an outfit-voting game without the shared visual state a vote is
-- about. The presentation is therefore server-authoritative, driven from each member's own
-- authoritative snapshot - the client still owns no equip state.
--
-- It computes nothing: the bindings come from the spec's own world-node feedback entries and the
-- snapshot the server already publishes.

local M = {}

--- The outfit bindings the spec declares, as `{ field = <snapshot path>, entity = <entity id> }`,
--- for every world node feedback entry of kind `outfit`.
function M.bindings(spec: any): { { field: string, entity: string } }
	local out: { { field: string, entity: string } } = {}
	local world = if type(spec) == "table" then spec.world else nil
	for _, node in (if type(world) == "table" and type(world.nodes) == "table" then world.nodes else {}) do
		if type(node) == "table" and type(node.feedback) == "table" then
			for _, entry in node.feedback do
				if type(entry) == "table" and entry.kind == "outfit" and type(entry.entity) == "string" then
					table.insert(out, {
						field = if type(entry.field) == "string" then entry.field else "equipped",
						entity = entry.entity,
					})
				end
			end
		end
	end
	return out
end

--- Reads a dotted snapshot field path (`equipped`, `genres.equipped`).
local function field(source: any, path: string): any
	local current = source
	for segment in string.gmatch(path, "[^%.]+") do
		if type(current) ~= "table" then
			return nil
		end
		current = current[segment]
	end
	return current
end

--- True when the equipped map says the entity is worn. The map is keyed by slot (so the entity id
--- is a *value*), but an entity-keyed map is accepted too: both shapes mean "this outfit is on".
local function worn(equipped: any, entity: string): boolean
	if type(equipped) ~= "table" then
		return false
	end
	if equipped[entity] ~= nil then
		return true
	end
	for _, value in equipped do
		if value == entity then
			return true
		end
	end
	return false
end

--- One presentation accessory: a Handle with a HatAttachment, which is what makes an accessory
--- visible rather than a colour nobody sees.
local function buildAccessory(entity: string): (Accessory, Attachment)
	local item = Instance.new("Accessory")
	item.Name = "ForgeOutfit-" .. entity
	local handle = Instance.new("Part")
	handle.Name, handle.Size = "Handle", Vector3.new(1.8, 1.1, 1.8)
	handle.Color, handle.Material, handle.CanCollide = Color3.fromRGB(240, 196, 96), Enum.Material.SmoothPlastic, false
	handle.Parent = item
	local attachment = Instance.new("Attachment")
	attachment.Name = "HatAttachment"
	attachment.Parent = handle
	return item, attachment
end

--- Applies one member's authoritative equipped state to that member's character. Called from the
--- server's state push, so the accessory replicates to every client like any other server instance.
--- A nil spec, an absent character or a missing humanoid is a no-op.
function M.apply(player: Player, snapshot: any, bindings: { { field: string, entity: string } }): ()
	if #bindings == 0 then
		return
	end
	local character = player.Character
	if character == nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	local head = character:FindFirstChild("Head")
	local headAttachment = if head ~= nil then head:FindFirstChild("HatAttachment") else nil
	for _, binding in bindings do
		local name = "ForgeOutfit-" .. binding.entity
		local existing = character:FindFirstChild(name)
		if worn(field(snapshot, binding.field), binding.entity) then
			if existing == nil then
				local item, attachment = buildAccessory(binding.entity)
				if headAttachment ~= nil and headAttachment:IsA("Attachment") then
					attachment.CFrame = headAttachment.CFrame
				end
				pcall(function()
					humanoid:AddAccessory(item)
				end)
				if item.Parent == nil then
					item:Destroy()
				end
			end
		elseif existing ~= nil then
			existing:Destroy()
		end
	end
end

return M
