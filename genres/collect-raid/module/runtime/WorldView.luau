--!strict
-- WorldView: client-side rendering of incubator eggs and parade-slot creatures.
-- Generic across packs: slot counts, the world folder name, and model builders
-- all come from `opts`.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Motion = require("../../../../core/domain/procgen/Motion")
local Animator = require("../../../../core/infra/render/Animator")

local player = Players.LocalPlayer

export type Models = {
	buildSource: (sourceId: string) -> Model,
	buildCreature: (creatureId: string) -> Model,
}

export type ProcSpecs = { [string]: { archetype: string?, seed: number? } }

export type Options = {
	remotes: { StateChanged: RemoteEvent },
	worldName: string,
	slotPrefix: string,
	incubatorPrefix: string,
	incubatorCount: number,
	slotCount: number,
	models: Models,
	procSpecs: ProcSpecs,
	teamYaw: { [string]: number },
	folderName: string,
}

local WorldView = {}

function WorldView.start(opts: Options): ()
	local StateChanged = opts.remotes.StateChanged

	local folder = Instance.new("Folder")
	folder.Name = opts.folderName
	folder.Parent = workspace

	local eggModels: { [number]: Model } = {}
	local eggIds: { [number]: string? } = {}
	local eggGen: { [number]: number } = {}
	local basePos: { [number]: Vector3 } = {}
	local creatureModels: { [number]: Model } = {}
	local creatureIds: { [number]: string? } = {}
	local creatureGen: { [number]: number } = {}
	local creatureHandles: { [number]: any } = {}

	local function profileFor(id: string?): any
		local entry = if id then opts.procSpecs[id] else nil
		return Motion.profileFor(if entry then entry.archetype else nil)
	end

	local function seedFor(id: string?): number
		local entry = if id then opts.procSpecs[id] else nil
		if entry and type(entry.seed) == "number" then
			return entry.seed
		end
		return 0
	end

	local function baseFolder(): Folder?
		local team = player.Team
		if not team then
			return nil
		end
		local world = workspace:FindFirstChild(opts.worldName)
		return world and world:FindFirstChild(team.Name .. "Base") :: Folder?
	end

	local function render(snapshot: any)
		local base = baseFolder()
		if not base then
			return
		end

		for i = 1, opts.incubatorCount do
			local incubator = snapshot.incubators[i]
			local desired: string? = if incubator then incubator.sourceId else nil
			if desired ~= eggIds[i] then
				-- Claim the slot before the (yielding) build so later StateChanged
				-- events see the desired id and do not start a second build.
				eggIds[i] = desired
				local gen = (eggGen[i] or 0) + 1
				eggGen[i] = gen

				local existing = eggModels[i]
				if existing then
					existing:Destroy()
					eggModels[i] = nil
					basePos[i] = nil
				end

				if desired then
					local id: string = desired
					local inc = base:FindFirstChild(opts.incubatorPrefix .. i) :: Model?
					local point = inc and inc.PrimaryPart and inc.PrimaryPart:FindFirstChild("EggPoint") :: Attachment?
					if point then
						local eggPoint = point.WorldPosition
						task.spawn(function()
							local m = opts.models.buildSource(id)
							if eggGen[i] ~= gen then
								m:Destroy()
								return
							end
							-- The pivot sits inside the egg, not at its base, so measure the
							-- built model and drop its bounding-box bottom 0.1 above the
							-- incubator's EggPoint. Bobbing then offsets from that rest pose.
							local pivot = m:GetPivot()
							local boxCenter, boxSize = m:GetBoundingBox()
							local pos = pivot.Position
								+ Vector3.new(
									eggPoint.X - boxCenter.X,
									eggPoint.Y + 0.1 + boxSize.Y / 2 - boxCenter.Y,
									eggPoint.Z - boxCenter.Z
								)
							m:PivotTo(CFrame.new(pos))
							m.Parent = folder
							eggModels[i] = m
							basePos[i] = pos
						end)
					end
				end
			end
		end

		for k = 1, opts.slotCount do
			local desired: string? = snapshot.creatures[k]
			if desired ~= creatureIds[k] then
				-- Claim the slot before the (yielding) build so later StateChanged
				-- events see the desired id and do not start a second build.
				creatureIds[k] = desired
				local gen = (creatureGen[k] or 0) + 1
				creatureGen[k] = gen

				local handle = creatureHandles[k]
				if handle then
					handle:stop()
					creatureHandles[k] = nil
				end
				local existing = creatureModels[k]
				if existing then
					existing:Destroy()
					creatureModels[k] = nil
				end

				if desired then
					local id: string = desired
					local slot = base:FindFirstChild(opts.slotPrefix .. k) :: BasePart?
					if slot then
						local slotPos = slot.Position
						task.spawn(function()
							local m = opts.models.buildCreature(id)
							if creatureGen[k] ~= gen then
								m:Destroy()
								return
							end
							local teamName = player.Team and player.Team.Name or ""
							local yaw = opts.teamYaw[teamName] or 0
							m:PivotTo(CFrame.new(slotPos + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, math.rad(yaw), 0))
							m.Parent = folder
							creatureModels[k] = m
							creatureHandles[k] = Animator.attach(m, profileFor(id), seedFor(id))
							Animator.play(m, "hatch")
						end)
					end
				end
			end
		end
	end

	RunService.RenderStepped:Connect(function()
		local t = os.clock()
		for i, m in eggModels do
			local pos = basePos[i]
			if pos then
				m:PivotTo(CFrame.new(pos + Vector3.new(0, math.sin(t * 2 + i) * 0.3, 0)) * CFrame.Angles(0, t * 0.8, 0))
			end
		end
	end)

	StateChanged.OnClientEvent:Connect(render)

	player:GetPropertyChangedSignal("Team"):Connect(function()
		-- Bump every slot's generation so builds already in flight cannot parent
		-- into the new team's world.
		for k = 1, opts.slotCount do
			creatureGen[k] = (creatureGen[k] or 0) + 1
		end
		for i = 1, opts.incubatorCount do
			eggGen[i] = (eggGen[i] or 0) + 1
		end
		for _, handle in creatureHandles do
			handle:stop()
		end
		for _, m in eggModels do
			m:Destroy()
		end
		for _, m in creatureModels do
			m:Destroy()
		end
		table.clear(eggModels)
		table.clear(eggIds)
		table.clear(basePos)
		table.clear(creatureModels)
		table.clear(creatureIds)
		table.clear(creatureHandles)
	end)
end

return WorldView
