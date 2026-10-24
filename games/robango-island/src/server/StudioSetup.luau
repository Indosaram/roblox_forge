--!strict
-- Studio-only QA setup. Nothing here runs on a live server: every entry point is reached only
-- behind RunService:IsStudio() plus a ForgeStudio* workspace attribute.
local M = {}

--- What a fresh Studio profile must hold to open `templateId` and stand on `stage`: the highest
--- character level and development grade any stage up to it requires, the instability access of
--- the route index, and every objective of the earlier stages (their `completed` gates).
function M.stageGates(content: any, templateId: string, stage: number): any
	local need = { level = 1, rank = 0, index = tonumber(string.match(templateId, "%d+$")) or 1, completed = {} }
	for current = 1, stage do
		for _, row in content.stages do
			if row.layout == templateId .. ".s" .. current then
				local gates = row.gates or {}
				need.level = math.max(need.level, gates.characterLevel or 1)
				need.rank = math.max(need.rank, gates.developmentRank or 0)
				for _, objective in if current < stage then row.objectives else {} do
					need.completed[objective.id] = true
				end
			end
		end
	end
	return need
end

M.SPACING = 30
M.COLUMNS = 6
-- Walk, then two windup/strike attacks, repeated (DinosaurRig.pose via the client CreaturePose).
M.LOOP = {
	{ state = "walk", seconds = 4 },
	{ state = "windup", seconds = 0.6 },
	{ state = "strike", seconds = 1.2 },
	{ state = "windup", seconds = 0.6 },
	{ state = "strike", seconds = 1.2 },
}

--- Grid slots for every species in content.wildlifeDetails, sorted by id.
function M.galleryLayout(content: any): { any }
	local ids = {}
	for _, detail in content.wildlifeDetails do
		table.insert(ids, detail)
	end
	table.sort(ids, function(a, b)
		return a.id < b.id
	end)
	local slots = {}
	local rows = math.ceil(#ids / M.COLUMNS)
	for index, detail in ids do
		local column, row = (index - 1) % M.COLUMNS, (index - 1) // M.COLUMNS
		table.insert(slots, {
			detail = detail,
			x = (column - (M.COLUMNS - 1) / 2) * M.SPACING,
			z = (row - (rows - 1) / 2) * M.SPACING,
		})
	end
	return slots
end

--- ForgeStudioGallery=true (Studio only): all species on a flat grass pad at `center`, each with a
--- BillboardGui name, cycling the walk and attack clips. Returns the folder, or nil when inert.
function M.gallery(env: any): Instance?
	if not env.isStudio or env.workspace:GetAttribute("ForgeStudioGallery") ~= true then
		return nil
	end
	local center: Vector3 = env.center
	local slots = M.galleryLayout(env.content)
	local span = Vector3.new(M.COLUMNS * M.SPACING + 40, 4, math.ceil(#slots / M.COLUMNS) * M.SPACING + 40)
	env.workspace.Terrain:FillBlock(CFrame.new(center - Vector3.new(0, 2, 0)), span, Enum.Material.Grass)
	local folder = Instance.new("Folder")
	folder.Name = "ForgeSpeciesGallery"
	local models = {}
	for _, slot in slots do
		local detail = slot.detail
		local e = detail.renderEnvelope
		local at = center + Vector3.new(slot.x, e.y, slot.z)
		local model =
			env.rig.new(detail.id, "Gallery." .. detail.id, at, folder, Vector3.new(e.x, e.y, e.z), detail.visual)
		model.PrimaryPart.Anchored = true
		local label = Instance.new("BillboardGui")
		label.Name, label.Size, label.AlwaysOnTop = "ForgeGalleryName", UDim2.fromOffset(200, 30), true
		label.StudsOffsetWorldSpace, label.MaxDistance = Vector3.new(0, e.y + 3, 0), 400
		local text = Instance.new("TextLabel")
		text.Size, text.BackgroundTransparency, text.TextScaled = UDim2.fromScale(1, 1), 1, true
		text.TextColor3, text.TextStrokeTransparency, text.Text = Color3.new(1, 1, 1), 0.2, detail.id
		text.Parent = label
		label.Parent = model.PrimaryPart
		table.insert(models, model)
	end
	folder.Parent = env.parent or env.workspace
	env.workspace:SetAttribute("ForgeStudioGalleryCenter", center)
	for _, model in models do
		env.rig.ground(model)
	end
	env.spawn(function()
		while folder.Parent do
			for _, step in M.LOOP do
				for _, model in models do
					model:SetAttribute("ForgeWildlifeState", step.state)
				end
				env.wait(step.seconds)
			end
		end
	end)
	return folder
end

return M
