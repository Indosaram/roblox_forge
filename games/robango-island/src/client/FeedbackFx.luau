--!strict
-- L13 game-feel feedback (refs R05 gather puffs, R05-4 skill banner, R06 craft, R08 hits): painted
-- particle bursts on authoritative edges, never on a guess.
--   gather   - a confirmed ForgeGatherResult: material chips + sparks at the node, the picked item's
--              icon flies from the node into the bag (menu) token.
--   hit      - a wildlife health drop (the same edge CombatHud numbers): a short white flash on the
--              creature and sparks at its root. The numbers stay CombatHud's.
--   level    - a progression level or a mastery level rose in the snapshot: a golden burst.
--   craft    - a workshop job turned Committed: a pop at the character, a "+N item" toast and the
--              output icon flying into the bag.
--   toasts   - the gather picker's "+N item" toasts get the item icon at their left end.
--   ambient  - footstep dust by floor material, a splash on entering water and drops while
--              swimming, painted smoke and embers over the nearest camp fires.
-- Phone budget: one client-local host part carries every burst emitter (Rate 0, Emit only), a token
-- bucket caps particles per second per profile, fires get Rate-capped emitters on at most
-- `fires` hosts, flashes use two pooled Highlights, and icons a pool of six ImageLabels.
-- Reduced effects (ui.settings) drops the decorative part (dust, splash, fires); gameplay feedback
-- (gather, hit, level, craft) stays at its profile count.
local M = {}

-- Per profile: particles per second (bucket refill; capacity is one second), burst sizes, fires.
M.BUDGET = table.freeze({
	low = table.freeze({ rate = 60, chips = 6, sparks = 4, puffs = 2, level = 16, craft = 10, splash = 8, fires = 2 }),
	high = table.freeze({
		rate = 160,
		chips = 12,
		sparks = 8,
		puffs = 4,
		level = 32,
		craft = 18,
		splash = 14,
		fires = 4,
	}),
})
M.FIRE_STUDS = 90 -- fires farther than this from the camera focus keep no emitters
M.FIRE_SMOKE_RATE, M.FIRE_EMBER_RATE = 2.5, 3
M.STEP_SECONDS = 0.3 -- footstep dust interval while walking
M.SWIM_SECONDS = 0.4 -- drop interval while swimming and moving
M.HIT_STUDS = 60 -- hits farther than this from the character show nothing (CombatHud numbers too)
M.FLASH_SECONDS = 0.12
M.ICON_POOL = 6
M.FLY_SECONDS = 0.55
M.GATHER_MEMORY = 4 -- seconds a confirmed gather's item counts as just picked

-- Painted palette (Tideglass): chip tint per gather material (RobangoAudioCatalog gather events).
M.MATERIALS = table.freeze({
	wood = { 150, 104, 60 },
	stone = { 172, 166, 154 },
	plant = { 118, 168, 78 },
	shell = { 236, 226, 204 },
	clay = { 170, 118, 84 },
	meat = { 186, 74, 62 },
}) :: { [string]: { number } }
M.SPARK = { 255, 238, 196 }
M.GOLD = { 255, 204, 92 }
-- Footstep dust tone per floor material name; nil = no dust (water, air, built floors).
M.DUST = table.freeze({
	Sand = "sand",
	Sandstone = "sand",
	Ground = "earth",
	Mud = "earth",
	Grass = "earth",
	LeafyGrass = "earth",
	Rock = "earth",
	Slate = "earth",
	Basalt = "earth",
	CrackedLava = "earth",
	Limestone = "sand",
	Snow = "snow",
	Glacier = "snow",
	Ice = "snow",
}) :: { [string]: string }
M.TONES =
	table.freeze({ sand = { 222, 200, 156 }, earth = { 160, 138, 108 }, snow = { 240, 244, 248 } }) :: { [string]: { number } }

--- Gather material ("wood", "stone", ...) for a node kind / node item, through the audio catalog's
--- per-material gather events (gather-wood ...), so sound and chips always agree. Default "stone".
function M.material(audio: any, kind: string?, item: string?): string
	local event = (kind and audio.gather[kind]) or (item and audio.gatherItems and audio.gatherItems[item])
	local name = if type(event) == "string" then string.match(event, "^gather%-(%a+)$") else nil
	return if name and M.MATERIALS[name] then name else "stone"
end

--- Profile budget; nil-safe on an unknown name.
function M.budget(profile: string): any
	return M.BUDGET[profile] or M.BUDGET.low
end

--- Token bucket: `take(n, now)` returns how many of n particles fit (0..n) and spends them.
function M.bucket(rate: number): any
	local tokens, at = rate, nil :: number?
	local self = {}
	function self.take(n: number, now: number): number
		if at then
			tokens = math.min(rate, tokens + (now - at) * rate)
		end
		at = now
		local granted = math.max(0, math.min(n, math.floor(tokens)))
		tokens -= granted
		return granted
	end
	return self
end

--- Recipe outputs of workshop jobs owned by `actor` that turned Committed between two
--- survival-coop snapshots ({ { item, quantity } } sorted by item). A nil `before` is a baseline.
function M.crafted(before: any, after: any, actor: string): { { item: string, quantity: number } }
	local out: { { item: string, quantity: number } } = {}
	local old = type(before) == "table" and before.workshop
	local new = type(after) == "table" and after.workshop
	if type(old) ~= "table" or type(new) ~= "table" or new.actorId ~= actor or type(new.entries) ~= "table" then
		return out
	end
	local sums: { [string]: number } = {}
	for id, entry in new.entries do
		local job = type(entry) == "table" and entry.job
		local previous = type(old.entries) == "table" and old.entries[id]
		local was = type(previous) == "table" and type(previous.job) == "table" and previous.job.state or nil
		if type(job) == "table" and job.state == "Committed" and was ~= "Committed" and was ~= nil then
			for _, output in job.outputs or {} do
				if type(output.catalogId) == "string" then
					sums[output.catalogId] = (sums[output.catalogId] or 0) + (output.quantity or 1)
				end
			end
		end
	end
	for item, quantity in sums do
		table.insert(out, { item = item, quantity = quantity })
	end
	table.sort(out, function(a, b)
		return a.item < b.item
	end)
	return out
end

--- True when the character level or any mastery level rose between two survival-coop snapshots.
function M.leveled(before: any, after: any): boolean
	local old = type(before) == "table" and before.progression
	local new = type(after) == "table" and after.progression
	if type(old) ~= "table" or type(new) ~= "table" then
		return false
	end
	if type(old.level) == "number" and type(new.level) == "number" and new.level > old.level then
		return true
	end
	for id, entry in if type(new.mastery) == "table" then new.mastery else {} do
		local previous = type(old.mastery) == "table" and old.mastery[id]
		if type(entry) == "table" and type(previous) == "table" and entry.level > previous.level then
			return true
		end
	end
	return false
end

--- Lua pattern that reads the item name back out of a toast line built from `format` (one %d and
--- one %s, either order): "+%d %s" -> "^%+%d+ (.+)$".
function M.toastPattern(format: string): string
	local escaped = string.gsub(format, "[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
	escaped = string.gsub(escaped, "%%d", "%%d+")
	escaped = string.gsub(escaped, "%%s", "(.+)")
	return "^" .. escaped .. "$"
end

--- Item id of a toast line, through the reverse of the pack names table (nil = not an item gain).
function M.toastItem(line: string, pattern: string, byName: { [string]: string }): string?
	local name = string.match(line, pattern)
	return if name then byName[name] else nil
end

--- Footstep dust tone for a floor material name, or nil.
function M.dust(material: string): string?
	return M.DUST[material]
end

-- ---------------------------------------------------------------------------------------------
-- Runtime (Roblox only). Engine globals through the environment so Lune specs can load the pure
-- part above and drive the runtime with a stub engine.
local env: any = getfenv()

local function rgb(c: { number }): any
	return env.Color3.fromRGB(c[1], c[2], c[3])
end

export type Options = {
	assets: { [string]: string },
	audio: any, -- RobangoAudioCatalog (gather / gatherItems)
	profile: () -> string,
	reduced: () -> boolean,
	hidden: () -> boolean,
	icon: (string) -> string?,
	itemName: (string) -> string,
	toastFormat: string,
	toast: (string) -> (),
	toastGui: any, -- the gather fan ScreenGui holding Toast1..3
	names: { [string]: string },
	itemIds: { string },
	defaultOutput: (any) -> string?, -- first offered output of a node part
	bagPoint: () -> any?, -- Vector2 screen centre of the bag (menu) token
	clock: (() -> number)?, -- seconds; os.clock when nil (specs inject one)
}

function M.start(options: Options): () -> ()
	local game, workspace, Instance = env.game, env.workspace, env.Instance
	local Vector3, Vector2, UDim2, CFrame = env.Vector3, env.Vector2, env.UDim2, env.CFrame
	local NumberRange, NumberSequence, ColorSequence = env.NumberRange, env.NumberSequence, env.ColorSequence
	local Enum, task = env.Enum, env.task
	local players = game:GetService("Players")
	local run = game:GetService("RunService")
	local tags = game:GetService("CollectionService")
	local tween = game:GetService("TweenService")
	local player = players.LocalPlayer
	local connections: { any } = {}
	local disposed = false
	local function clock(): number
		return if options.clock then options.clock() else os.clock()
	end
	local buckets: { [string]: any } = {}
	local function allow(n: number): number
		local name = options.profile()
		buckets[name] = buckets[name] or M.bucket(M.budget(name).rate)
		return buckets[name].take(n, clock())
	end

	-- One host part; every burst emitter lives on it (Rate 0, LockedToPart false, Emit moves the
	-- host first so earlier particles stay where they were born).
	local folder = Instance.new("Folder")
	folder.Name = "ForgeFeedbackFx"
	local host = Instance.new("Part")
	host.Name, host.Anchored, host.Transparency, host.Size = "BurstHost", true, 1, Vector3.new(1, 1, 1)
	host.CanCollide, host.CanQuery, host.CanTouch, host.CastShadow = false, false, false, false
	host.Parent = folder
	local emitters: { [string]: any } = {}
	local function emitter(name: string, texture: string, tint: { number }, setup: (any) -> ()): any
		local value = Instance.new("ParticleEmitter")
		value.Name, value.Rate, value.LockedToPart = name, 0, false
		value.Texture = options.assets[texture] or ""
		value.Color, value.LightInfluence = ColorSequence.new(rgb(tint)), 0.6
		setup(value)
		value.Parent = host
		emitters[name] = value
		return value
	end
	for material, tint in M.MATERIALS do
		emitter("chip-" .. material, "fx-chip", tint, function(e)
			e.Size = NumberSequence.new(0.45, 0.2)
			e.Lifetime, e.Speed = NumberRange.new(0.45, 0.7), NumberRange.new(9, 15)
			e.SpreadAngle, e.Acceleration = Vector2.new(60, 60), Vector3.new(0, -45, 0)
			e.Rotation, e.RotSpeed = NumberRange.new(0, 360), NumberRange.new(-320, 320)
			e.EmissionDirection = Enum.NormalId.Top
		end)
	end
	local function spark(name: string, tint: { number })
		emitter(name, "fx-spark", tint, function(e)
			e.Size = NumberSequence.new(1.1, 0)
			e.Lifetime, e.Speed = NumberRange.new(0.25, 0.45), NumberRange.new(5, 10)
			e.SpreadAngle, e.LightEmission, e.LightInfluence = Vector2.new(180, 180), 0.7, 0
			e.Rotation = NumberRange.new(0, 90)
		end)
	end
	spark("spark", M.SPARK)
	spark("gold", M.GOLD)
	for tone, tint in M.TONES do
		emitter("puff-" .. tone, "fx-puff", tint, function(e)
			e.Size = NumberSequence.new(0.9, 2.2)
			e.Transparency = NumberSequence.new(0.35, 1)
			e.Lifetime, e.Speed = NumberRange.new(0.5, 0.8), NumberRange.new(1.5, 3)
			e.SpreadAngle, e.Drag = Vector2.new(80, 80), 4
			e.Rotation, e.RotSpeed = NumberRange.new(0, 360), NumberRange.new(-30, 30)
			e.EmissionDirection = Enum.NormalId.Top
		end)
	end
	emitter("drop", "fx-drop", { 220, 240, 246 }, function(e)
		e.Size = NumberSequence.new(0.45, 0.25)
		e.Lifetime, e.Speed = NumberRange.new(0.5, 0.75), NumberRange.new(11, 17)
		e.SpreadAngle, e.Acceleration = Vector2.new(35, 35), Vector3.new(0, -60, 0)
		e.Orientation = Enum.ParticleOrientation.VelocityParallel
		e.EmissionDirection = Enum.NormalId.Top
	end)
	folder.Parent = workspace

	local function burst(at: any, name: string, n: number)
		local granted = allow(n)
		local value = emitters[name]
		if granted > 0 and value then
			host.CFrame = CFrame.new(at)
			value:Emit(granted)
		end
	end
	local function counts(): any
		return M.budget(options.profile())
	end
	local function body(): (any, any)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		return humanoid, root
	end

	-- Icon fly into the bag token (a pool of six labels in a client ScreenGui).
	local flyGui = Instance.new("ScreenGui")
	flyGui.Name, flyGui.ResetOnSpawn, flyGui.IgnoreGuiInset, flyGui.DisplayOrder = "ForgeFeedbackFx", false, true, 21
	flyGui.Parent = player:WaitForChild("PlayerGui")
	local icons: { any } = {}
	for index = 1, M.ICON_POOL do
		local label = Instance.new("ImageLabel")
		label.Name, label.BackgroundTransparency, label.Visible = "FlyIcon" .. index, 1, false
		label.AnchorPoint, label.Size = Vector2.new(0.5, 0.5), UDim2.fromOffset(44, 44)
		label.Parent = flyGui
		icons[index] = label
	end
	local nextIcon = 0
	local function fly(item: string, from: any)
		local image, target = options.icon(item), options.bagPoint()
		local camera = workspace.CurrentCamera
		if not image or not target or not camera or options.hidden() then
			return
		end
		local point, visible = camera:WorldToViewportPoint(from)
		if not visible then
			return
		end
		nextIcon = nextIcon % M.ICON_POOL + 1
		local label = icons[nextIcon]
		label.Image, label.ImageTransparency, label.Visible = image, 0, true
		label.Position, label.Size = UDim2.fromOffset(point.X, point.Y), UDim2.fromOffset(30, 30)
		-- Pop up out of the node, then arc into the bag token and shrink into it.
		local up = tween:Create(label, env.TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.fromOffset(52, 52),
			Position = UDim2.fromOffset(point.X, point.Y - 28),
		})
		local into =
			tween:Create(label, env.TweenInfo.new(M.FLY_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Size = UDim2.fromOffset(26, 26),
				Position = UDim2.fromOffset(target.X, target.Y),
				ImageTransparency = 0.2,
			})
		local mine = nextIcon
		up.Completed:Connect(function()
			if icons[mine] == label and label.Visible then
				into:Play()
			end
		end)
		into.Completed:Connect(function()
			label.Visible = false
		end)
		up:Play()
	end

	-- Gather: the confirmed result edge GatheringClient publishes (the audio cue rides the same one).
	local nodeParts: { [any]: any } = {}
	local function nodePart(id: any): any
		local part = nodeParts[id]
		if part and part.Parent then
			return part
		end
		for _, candidate in tags:GetTagged("ForgeSurvivalNode") do
			nodeParts[candidate:GetAttribute("ForgeNodeId")] = candidate
		end
		return nodeParts[id]
	end
	local picked: { [string]: number } = {}
	local function onGather(packet: any)
		if type(packet) ~= "table" or type(packet.result) ~= "table" or packet.result.ok ~= true then
			return
		end
		local part = nodePart(packet.nodeId)
		if not part then
			return
		end
		local args = type(packet.request) == "table" and packet.request.args or {}
		local item = if type(args[3]) == "string" then args[3] else options.defaultOutput(part)
		local kind, nodeItem = part:GetAttribute("ForgeNodeKind"), part:GetAttribute("ForgeNodeItem")
		local material = M.material(options.audio, kind, nodeItem)
		local budget = counts()
		local at = part.Position + Vector3.new(0, math.min(part.Size.Y / 2, 2), 0)
		burst(at, "chip-" .. material, budget.chips)
		burst(at, "spark", budget.sparks)
		if item then
			picked[item] = clock()
			fly(item, at)
		end
	end
	local function attachResult(child: any)
		if child.Name == "ForgeGatherResult" and child:IsA("BindableEvent") then
			table.insert(connections, child.Event:Connect(onGather))
		end
	end
	local gatherSeen = player:FindFirstChild("ForgeGatherResult")
	if gatherSeen then
		attachResult(gatherSeen)
	else
		local waiting
		waiting = player.ChildAdded:Connect(function(child)
			if child.Name == "ForgeGatherResult" then
				waiting:Disconnect()
				attachResult(child)
			end
		end)
		table.insert(connections, waiting)
	end

	-- Hits: a health drop on a creature (the edge CombatHud's numbers read).
	local flashes: { any } = {}
	for index = 1, 2 do
		local light = Instance.new("Highlight")
		light.Name, light.Enabled = "HitFlash" .. index, false
		light.FillColor, light.OutlineColor = rgb({ 255, 250, 240 }), rgb({ 255, 250, 240 })
		light.FillTransparency, light.OutlineTransparency = 0.35, 1
		light.DepthMode = Enum.HighlightDepthMode.Occluded
		light.Parent = folder
		flashes[index] = light
	end
	local flashAt = { 0, 0 }
	local function flash(model: any)
		if model:FindFirstChild("AttackWindup") then
			return -- the windup telegraph owns the creature's highlight
		end
		local slot = if flashAt[1] <= flashAt[2] then 1 else 2
		local light = flashes[slot]
		flashAt[slot] = clock()
		light.Adornee, light.Enabled = model, true
		local stamp = flashAt[slot]
		task.delay(M.FLASH_SECONDS, function()
			if flashAt[slot] == stamp then
				light.Enabled, light.Adornee = false, nil
			end
		end)
	end
	local health: { [any]: number } = {}
	local watched: { [any]: any } = {}
	local function watch(model: any)
		if watched[model] or not model:IsA("Model") then
			return
		end
		health[model] = model:GetAttribute("ForgeWildlifeHealthMilli")
		watched[model] = model:GetAttributeChangedSignal("ForgeWildlifeHealthMilli"):Connect(function()
			local hp, previous = model:GetAttribute("ForgeWildlifeHealthMilli"), health[model]
			health[model] = hp
			if type(hp) ~= "number" or type(previous) ~= "number" or hp >= previous then
				return
			end
			local root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
			local _, me = body()
			if not root or not me or (root.Position - me.Position).Magnitude > M.HIT_STUDS then
				return
			end
			flash(model)
			local budget = counts()
			burst(root.Position + Vector3.new(0, 1, 0), "spark", budget.sparks)
			burst(root.Position, "puff-earth", budget.puffs)
		end)
	end
	local function unwatch(model: any)
		if watched[model] then
			watched[model]:Disconnect()
			watched[model], health[model] = nil, nil
		end
	end
	local wildlife: any = nil
	local function bindWildlife(folderFound: any)
		wildlife = folderFound
		table.insert(connections, folderFound.ChildAdded:Connect(watch))
		table.insert(connections, folderFound.ChildRemoved:Connect(unwatch))
		for _, model in folderFound:GetChildren() do
			watch(model)
		end
	end

	-- Level-up and craft completion from the survival-coop snapshot.
	local last: any = nil
	local actor = tostring(player.UserId)
	local function onState(packet: any)
		local snapshot = type(packet) == "table"
			and type(packet.snapshots) == "table"
			and packet.snapshots["survival-coop"]
		if type(snapshot) ~= "table" then
			return
		end
		local before = last
		last = snapshot
		local _, root = body()
		if not before or not root then
			return
		end
		local budget = counts()
		if M.leveled(before, snapshot) then
			burst(root.Position - Vector3.new(0, 1.5, 0), "gold", budget.level)
			burst(root.Position + Vector3.new(0, 1, 0), "spark", budget.sparks)
		end
		local made = M.crafted(before, snapshot, actor)
		if #made > 0 then
			burst(root.Position + Vector3.new(0, 1.5, 0), "gold", budget.craft)
			burst(root.Position, "puff-sand", budget.puffs)
			for _, output in made do
				options.toast(string.format(options.toastFormat, output.quantity, options.itemName(output.item)))
				fly(output.item, root.Position + Vector3.new(0, 2, 0))
			end
		end
	end
	local storage = game:GetService("ReplicatedStorage")
	local function attachState(child: any)
		if child.Name == "ForgeState" then
			table.insert(connections, child.OnClientEvent:Connect(onState))
			return true
		end
		return false
	end
	local stateRemote = storage:FindFirstChild("ForgeState")
	if not (stateRemote and attachState(stateRemote)) then
		local waiting
		waiting = storage.ChildAdded:Connect(function(child)
			if attachState(child) then
				waiting:Disconnect()
			end
		end)
		table.insert(connections, waiting)
	end

	-- Toast icons: the picker's Toast1..3 labels get the item icon at their left end.
	local pattern = M.toastPattern(options.toastFormat)
	local byName: { [string]: string } = {}
	for _, id in options.itemIds do
		local name = options.names[id]
		if name then
			byName[name] = id
		end
	end
	local function decorate(label: any)
		local item = label.Visible and M.toastItem(label.Text, pattern, byName) or nil
		local image = item and options.icon(item)
		local badge = label:FindFirstChild("ForgeToastIcon")
		if not image then
			if badge then
				badge.Visible = false
			end
			return
		end
		if not badge then
			badge = Instance.new("ImageLabel")
			badge.Name, badge.BackgroundTransparency = "ForgeToastIcon", 1
			badge.AnchorPoint, badge.Position = Vector2.new(0, 0.5), UDim2.new(0, 4, 0.5, 0)
			badge.Size, badge.SizeConstraint = UDim2.fromScale(0.9, 0.9), Enum.SizeConstraint.RelativeYY
			badge.Parent = label
		end
		badge.Image, badge.Visible = image, true
	end

	-- Ambient: footstep dust, water splash, camp fires.
	local fires: { any } = {}
	local function fireHost(index: number): any
		local entry = fires[index]
		if entry then
			return entry
		end
		local part = Instance.new("Part")
		part.Name, part.Anchored, part.Transparency, part.Size = "FireHost" .. index, true, 1, Vector3.new(2, 1, 2)
		part.CanCollide, part.CanQuery, part.CanTouch, part.CastShadow = false, false, false, false
		local smoke = Instance.new("ParticleEmitter")
		smoke.Name, smoke.Texture, smoke.Rate = "CampSmoke", options.assets["fx-puff"] or "", M.FIRE_SMOKE_RATE
		smoke.Color, smoke.LightInfluence = ColorSequence.new(rgb({ 120, 114, 108 })), 1
		smoke.Size, smoke.Transparency = NumberSequence.new(1.2, 4), NumberSequence.new(0.45, 1)
		smoke.Lifetime, smoke.Speed = NumberRange.new(2.5, 3.5), NumberRange.new(2.5, 4)
		smoke.SpreadAngle, smoke.Acceleration = Vector2.new(12, 12), Vector3.new(0.6, 0.4, 0)
		smoke.Rotation, smoke.RotSpeed = NumberRange.new(0, 360), NumberRange.new(-20, 20)
		smoke.Parent = part
		local ember = Instance.new("ParticleEmitter")
		ember.Name, ember.Texture, ember.Rate = "CampEmbers", options.assets["fx-ember"] or "", M.FIRE_EMBER_RATE
		ember.Color, ember.LightEmission, ember.LightInfluence = ColorSequence.new(rgb({ 255, 170, 70 })), 1, 0
		ember.Size, ember.Lifetime = NumberSequence.new(0.35, 0), NumberRange.new(1.2, 2)
		ember.Speed, ember.SpreadAngle = NumberRange.new(2, 4), Vector2.new(25, 25)
		ember.Acceleration = Vector3.new(0, 2, 0)
		ember.Parent = part
		part.Parent = folder
		entry = { part = part, smoke = smoke, ember = ember }
		fires[index] = entry
		return entry
	end
	local driftFire: any = nil
	local driftLook = -math.huge
	local function fireSweep()
		local camera = workspace.CurrentCamera
		local focus = camera and camera.Focus.Position
		local list = {}
		for _, part in tags:GetTagged("ForgeSurvivalStation") do
			local kind = part:GetAttribute("ForgeStationKind")
			if (kind == "campfire" or kind == "fireplace") and part:IsDescendantOf(workspace) then
				table.insert(list, part)
			end
		end
		if not (driftFire and driftFire:IsDescendantOf(workspace)) and clock() - driftLook > 10 then
			driftLook = clock()
			driftFire = workspace:FindFirstChild("DriftCamp.fire", true)
		end
		if driftFire and driftFire:IsDescendantOf(workspace) then
			table.insert(list, driftFire)
		end
		local near = {}
		for _, part in list do
			local d = if focus then (part.Position - focus).Magnitude else math.huge
			if d <= M.FIRE_STUDS then
				table.insert(near, { part = part, d = d })
			end
		end
		table.sort(near, function(a, b)
			return a.d < b.d
		end)
		local cap = if options.reduced() then 0 else counts().fires
		for index = 1, math.max(cap, #fires) do
			local chosen = near[index]
			if index <= cap and chosen then
				local entry = fireHost(index)
				local top = chosen.part.Position.Y + chosen.part.Size.Y / 2
				entry.part.CFrame = CFrame.new(chosen.part.Position.X, top + 0.6, chosen.part.Position.Z)
				entry.smoke.Enabled, entry.ember.Enabled = true, true
			elseif fires[index] then
				fires[index].smoke.Enabled, fires[index].ember.Enabled = false, false
			end
		end
	end
	local stepAt, swimAt, sweepAt = 0, 0, -math.huge
	local swimming = false
	table.insert(
		connections,
		run.Heartbeat:Connect(function()
			if disposed then
				return
			end
			local now = clock()
			if now - sweepAt >= 1 then
				sweepAt = now
				fireSweep()
				if not (wildlife and wildlife.Parent) then
					local found = workspace:FindFirstChild("ForgeWildlife", true)
					if found and found ~= wildlife then
						bindWildlife(found)
					end
				end
				for item, at in picked do
					if now - at > M.GATHER_MEMORY then
						picked[item] = nil
					end
				end
			end
			for _, name in { "Toast1", "Toast2", "Toast3" } do
				local label = options.toastGui:FindFirstChild(name)
				if label then
					decorate(label)
				end
			end
			local humanoid, root = body()
			if not humanoid or not root or options.reduced() then
				return
			end
			local moving = humanoid.MoveDirection.Magnitude > 0.1
			local inWater = humanoid:GetState() == Enum.HumanoidStateType.Swimming
			local budget = counts()
			if inWater and not swimming then
				burst(root.Position - Vector3.new(0, 1, 0), "drop", budget.splash)
				burst(root.Position - Vector3.new(0, 1, 0), "puff-snow", budget.puffs)
			end
			swimming = inWater
			if inWater then
				if moving and now - swimAt >= M.SWIM_SECONDS then
					swimAt = now
					burst(root.Position - Vector3.new(0, 1, 0), "drop", math.ceil(budget.splash / 4))
				end
				return
			end
			local tone = M.dust(humanoid.FloorMaterial.Name)
			if moving and tone and now - stepAt >= M.STEP_SECONDS then
				stepAt = now
				local feet = root.Position - Vector3.new(0, root.Size.Y / 2 + humanoid.HipHeight - 0.3, 0)
				burst(feet, "puff-" .. tone, math.max(1, math.floor(budget.puffs / 2)))
			end
		end)
	)

	return function()
		if disposed then
			return
		end
		disposed = true
		for _, connection in connections do
			connection:Disconnect()
		end
		for model in watched do
			unwatch(model)
		end
		folder:Destroy()
		flyGui:Destroy()
	end
end

return M
