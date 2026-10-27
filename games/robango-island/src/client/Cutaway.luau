--!strict
-- G24 indoor cut-away. Roof and wall meshes carry the ForgeCutaway tag (StructureMeshes). While
-- the local character stands inside a building footprint, the cut-away parts of that building
-- and of every module within NEAR studs (a house built from separate wall/roof cells) fade to
-- FADE through LocalTransparencyModifier, which is client-local and never replicates.
-- plan() is pure: it takes the character point and the tagged groups and returns what to fade.
local M = {}

M.FADE = 0.85
M.NEAR = 10
M.STEP = 0.15

export type Box = { cframe: CFrame, size: Vector3 }
export type Group = { key: any, box: Box }

--- True when `point` lies inside the box footprint (object-space XZ, with a margin) and below
--- its top, so a player on a roof or flying over never counts as inside.
function M.inside(point: Vector3, box: Box, margin: number?): boolean
	local localPoint = box.cframe:PointToObjectSpace(point)
	local m = margin or 0.5
	local half = box.size / 2
	return math.abs(localPoint.X) <= half.X - m
		and math.abs(localPoint.Z) <= half.Z - m
		and localPoint.Y <= half.Y
		and localPoint.Y >= -half.Y - 12
end

-- Horizontal distance from `point` to the box footprint (0 inside).
local function reach(point: Vector3, box: Box): number
	local localPoint = box.cframe:PointToObjectSpace(point)
	local half = box.size / 2
	local dx = math.max(math.abs(localPoint.X) - half.X, 0)
	local dz = math.max(math.abs(localPoint.Z) - half.Z, 0)
	return math.sqrt(dx * dx + dz * dz)
end

--- Keys of the groups to fade: none unless the point is inside at least one group footprint;
--- then that group plus every group whose footprint lies within NEAR studs.
function M.plan(point: Vector3, groups: { Group }): { [any]: boolean }
	local fade: { [any]: boolean } = {}
	local indoors = false
	for _, group in groups do
		if group.box.size.X > 2 and group.box.size.Z > 2 and M.inside(point, group.box) then
			indoors = true
			break
		end
	end
	if not indoors then
		return fade
	end
	for _, group in groups do
		if reach(point, group.box) <= M.NEAR then
			fade[group.key] = true
		end
	end
	return fade
end

-- The building a cut-away part belongs to: its row Model (mesh visual or structure kit clone).
local function owner(part: Instance): Instance
	local model = part:FindFirstAncestorWhichIsA("Model")
	return model or part
end

--- Runs the cut-away for the local player. Returns a stop function.
function M.start(player: Player): () -> ()
	local CollectionService = game:GetService("CollectionService")
	local parts: { [BasePart]: boolean } = {}
	local faded: { [BasePart]: boolean } = {}
	local function add(object: Instance)
		if object:IsA("BasePart") then
			parts[object] = true
		end
	end
	for _, object in CollectionService:GetTagged("ForgeCutaway") do
		add(object)
	end
	local added = CollectionService:GetInstanceAddedSignal("ForgeCutaway"):Connect(add)
	local removed = CollectionService:GetInstanceRemovedSignal("ForgeCutaway"):Connect(function(object)
		parts[object :: BasePart] = nil
		faded[object :: BasePart] = nil
	end)
	local elapsed = 0
	local heartbeat = game:GetService("RunService").Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < M.STEP then
			return
		end
		elapsed = 0
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local groups: { Group } = {}
		local members: { [Instance]: { BasePart } } = {}
		if root then
			for part in parts do
				if not part.Parent then
					parts[part] = nil
					continue
				end
				if not part:IsDescendantOf(workspace) then
					-- ForgeStructureKits templates in ReplicatedStorage never fade.
					continue
				end
				-- Only buildings near the character are measured each step.
				if (part.Position - root.Position).Magnitude > 96 then
					continue
				end
				local key = owner(part)
				if not members[key] then
					members[key] = {}
					local cframe, size
					if key:IsA("Model") then
						cframe, size = key:GetBoundingBox()
					else
						cframe, size = (key :: BasePart).CFrame, (key :: BasePart).Size
					end
					table.insert(groups, { key = key, box = { cframe = cframe, size = size } })
				end
				table.insert(members[key], part)
			end
		end
		local fade: { [any]: boolean } = {}
		if root then
			fade = M.plan(root.Position, groups)
		end
		local now: { [BasePart]: boolean } = {}
		for key in pairs(fade) do
			local list: { BasePart } = members[key] or {}
			for _, part in list do
				now[part] = true
				part.LocalTransparencyModifier = M.FADE
			end
		end
		for part in faded do
			if not now[part] and part.Parent then
				part.LocalTransparencyModifier = 0
			end
		end
		faded = now
	end)
	return function()
		heartbeat:Disconnect()
		added:Disconnect()
		removed:Disconnect()
		for part in faded do
			part.LocalTransparencyModifier = 0
		end
	end
end

return M
