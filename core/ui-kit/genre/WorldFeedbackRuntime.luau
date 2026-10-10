--!strict
-- WorldFeedbackRuntime: applies the pure WorldFeedback policy to the world a place
-- already carries. It is the client-facing half of the layer, split from the policy
-- so the CLI (which validates the spec) never loads a module that names an engine
-- global, while the generated client loads both.
--
-- It computes nothing: every visual it applies and every cue it plays comes from
-- `WorldFeedback.state`/`WorldFeedback.deltas` and the spec's own declarations.

local WorldFeedback = require("./WorldFeedback")
local HudText = require("./HudText")

local M = {}

-- Engine services are looked up lazily, inside the functions that use them.
local function service(name: string): any
	return (game :: any):GetService(name)
end

export type Options = {
	spec: any,
	world: any?,
	subscribe: (packet: any) -> (),
	play: ((cue: string) -> ())?,
	parent: Instance?,
	-- The pack's locale table and the one language it renders, so the floating text and the health
	-- title are the spec's own declared copy in that language rather than a hard-coded English word.
	strings: { [string]: { [string]: string } }?,
	locale: string?,
}

-- Crop stages: an empty plot shows nothing, a growing crop a small sprout, a
-- ready crop a tall bright stand. The numbers are presentation only, and the
-- table is built on demand so this module names no engine global at require time.
local function growthStage(stage: number): any
	local stages = {
		[0] = { size = Vector3.new(0, 0, 0), color = Color3.fromRGB(90, 140, 70), offset = 0 },
		[1] = { size = Vector3.new(2.2, 2.2, 2.2), color = Color3.fromRGB(96, 176, 88), offset = 1.1 },
		[2] = { size = Vector3.new(3.4, 3.8, 3.4), color = Color3.fromRGB(244, 208, 92), offset = 1.9 },
	}
	return stages[stage] or stages[0]
end

local function worldRoot(options: Options): Instance?
	local parent = options.parent or workspace
	local world = options.world
	local name = if type(world) == "table"
			and type(world.name) == "string"
			and #world.name > 0
		then world.name
		else "World"
	return parent:FindFirstChild(name)
end

--- Applies one binding's state to its node part. Every visual is a child of the
--- part, so a rebuild is idempotent and a node without feedback is untouched.
local function apply(part: BasePart, binding: any, state: any, localized: (any, string) -> string): ()
	if binding.kind == "growth" then
		local stage = growthStage(state.stage or 0)
		local existing = part:FindFirstChild("ForgeCrop")
		if state.stage == 0 then
			if existing ~= nil then
				existing:Destroy()
			end
			return
		end
		local piece: BasePart
		if existing ~= nil and existing:IsA("BasePart") then
			piece = existing
		else
			if existing ~= nil then
				existing:Destroy()
			end
			piece = Instance.new("Part")
			piece.Name, piece.Anchored, piece.CanCollide, piece.CanQuery = "ForgeCrop", true, false, false
			piece.TopSurface, piece.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
			piece.Parent = part
		end
		piece.Size = stage.size
		piece.Color = stage.color
		piece.Material = if state.stage == 2 then Enum.Material.Neon else Enum.Material.Grass
		piece.CFrame = part.CFrame * CFrame.new(0, part.Size.Y / 2 + stage.offset, 0)
	elseif binding.kind == "health" then
		local billboard: BillboardGui
		local existing = part:FindFirstChild("ForgeHealth")
		if existing ~= nil and existing:IsA("BillboardGui") then
			billboard = existing
		else
			if existing ~= nil then
				existing:Destroy()
			end
			billboard = Instance.new("BillboardGui")
			billboard.Name, billboard.Size = "ForgeHealth", UDim2.fromOffset(140, 28)
			billboard.StudsOffsetWorldSpace, billboard.MaxDistance = Vector3.new(0, 4.5, 0), 240
			local track = Instance.new("Frame")
			track.Name, track.Size, track.Position = "Track", UDim2.new(1, 0, 0, 10), UDim2.fromOffset(0, 16)
			track.BackgroundColor3, track.BorderSizePixel = Color3.fromRGB(26, 26, 34), 0
			track.Parent = billboard
			local trackCorner = Instance.new("UICorner")
			trackCorner.CornerRadius, trackCorner.Parent = UDim.new(0, 4), track
			local fill = Instance.new("Frame")
			fill.Name, fill.Size, fill.BorderSizePixel = "Fill", UDim2.fromScale(1, 1), 0
			fill.BackgroundColor3 = Color3.fromRGB(214, 74, 74)
			fill.Parent = track
			local fillCorner = Instance.new("UICorner")
			fillCorner.CornerRadius, fillCorner.Parent = UDim.new(0, 4), fill
			local title = Instance.new("TextLabel")
			title.Name, title.Size, title.BackgroundTransparency = "Title", UDim2.new(1, 0, 0, 15), 1
			title.Font, title.TextSize = Enum.Font.GothamBold, 13
			title.TextColor3, title.TextStrokeTransparency = Color3.fromRGB(255, 255, 255), 0.3
			title.TextXAlignment = Enum.TextXAlignment.Center
			title.Parent = billboard
			billboard.Parent = part
		end
		local track = billboard:FindFirstChild("Track")
		local fill = if track ~= nil then track:FindFirstChild("Fill") else nil
		local title = billboard:FindFirstChild("Title")
		if fill ~= nil and fill:IsA("Frame") then
			fill.Size = UDim2.fromScale(state.fraction, 1)
			fill.BackgroundColor3 = if state.defeated then Color3.fromRGB(90, 90, 96) else Color3.fromRGB(214, 74, 74)
		end
		if title ~= nil and title:IsA("TextLabel") then
			-- The title is the spec's declared copy, resolved through the pack's locale table: a
			-- defeated enemy reads in the pack's own language instead of a hard-coded word.
			local display =
				localized(binding.labelKey, if type(binding.entity) == "string" then binding.entity else "Enemy")
			title.Text = if state.defeated then display else string.format("%s  %d/%d", display, state.value, state.max)
		end
		-- A defeated enemy reads as inert: the prop dims rather than disappearing, so
		-- the node a player walked to is still there to walk back to.
		part.Transparency = if state.defeated then 0.35 else 0
	elseif binding.kind == "lamp" then
		local lamp: PointLight
		local existing = part:FindFirstChild("ForgeLamp")
		if existing ~= nil and existing:IsA("PointLight") then
			lamp = existing
		else
			if existing ~= nil then
				existing:Destroy()
			end
			lamp = Instance.new("PointLight")
			lamp.Name, lamp.Range, lamp.Brightness = "ForgeLamp", 18, 2
			lamp.Color, lamp.Parent = Color3.fromRGB(255, 226, 140), part
		end
		lamp.Enabled = state.active
		part.Material = if state.active then Enum.Material.Neon else Enum.Material.Wood
		part.Color = if state.active then Color3.fromRGB(255, 226, 140) else Color3.fromRGB(150, 120, 80)
	end
end

--- Wears (or removes) one accessory on the local character. `Humanoid:AddAccessory`
--- needs a Handle and a HatAttachment, which is what makes the outfit visible
--- rather than a colour nobody sees.
---
--- The wear itself is applied on the SERVER (`core/infra/genre/OutfitPresenter`), so every client
--- receives the accessory through replication; a locally created accessory was visible only to its
--- wearer. This layer therefore renders no character accessory at all.

--- A transient floating-text popup over the node the action happened at.
local function popup(part: BasePart, text: string): ()
	local billboard = Instance.new("BillboardGui")
	billboard.Name, billboard.Size = "ForgePopup", UDim2.fromOffset(160, 32)
	billboard.StudsOffsetWorldSpace, billboard.MaxDistance, billboard.AlwaysOnTop = Vector3.new(0, 7, 0), 260, true
	billboard.Parent = part
	local label = Instance.new("TextLabel")
	label.Size, label.BackgroundTransparency = UDim2.fromScale(1, 1), 1
	label.Font, label.TextSize = Enum.Font.GothamBold, 18
	label.TextColor3, label.TextStrokeTransparency = Color3.fromRGB(255, 236, 150), 0.2
	label.TextStrokeColor3, label.Text = Color3.fromRGB(20, 18, 12), text
	label.Parent = billboard
	service("TweenService")
		:Create(
			billboard,
			TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ StudsOffsetWorldSpace = Vector3.new(0, 12, 0) }
		)
		:Play()
	task.delay(1.2, function()
		billboard:Destroy()
	end)
end

--- Starts the world feedback: applies the spec's declared state to the world the
--- place carries, and reacts to every state push with the node change, the
--- floating text and the bound cue.
function M.start(options: Options): any
	local spec: any = options.spec or {}
	local world: any = options.world or (if type(spec) == "table" then spec.world else nil)
	local bindings = WorldFeedback.bindings(world)
	local strings = if type(options.strings) == "table" then options.strings else {}
	local function localized(key: any, fallback: string): string
		return HudText.localized(strings, options.locale, key, fallback)
	end
	-- The locale key of every declared binding, so a popup's copy resolves through the same table
	-- the HUD renders from rather than staying in the spec's source language.
	local labelKeys: { [string]: string } = {}
	for _, binding in bindings do
		if type(binding.labelKey) == "string" then
			labelKeys[binding.nodeId .. ":" .. tostring(binding.kind) .. ":" .. tostring(binding.field)] =
				binding.labelKey
		end
	end
	local destroyed = false
	local previous: any = nil
	local parts: { [string]: BasePart? } = {}

	--- The floating-text line, with the declared label replaced by its translation at the pack's
	--- locale. The label is a prefix of the delta line, so only the prefix is substituted.
	local function feedbackText(reaction: any): string?
		local text = reaction.text
		if type(text) ~= "string" then
			return nil
		end
		local key = labelKeys[reaction.nodeId .. ":" .. tostring(reaction.kind) .. ":" .. tostring(reaction.field)]
		local source = if type(reaction.label) == "string" then reaction.label else ""
		if key ~= nil and #source > 0 and string.sub(text, 1, #source) == source then
			return localized(key, source) .. string.sub(text, #source + 1)
		end
		return text
	end

	local function refreshParts(): ()
		local root = worldRoot(options)
		if root == nil then
			return
		end
		for _, node in WorldFeedback.nodes(world) do
			if parts[node.id] == nil then
				local part = root:FindFirstChild("Node-" .. node.id)
				if part ~= nil and part:IsA("BasePart") then
					parts[node.id] = part
				end
			end
		end
	end

	-- The node props are baked with the place, but a pack whose world is built at
	-- runtime may not have them the first frame: re-resolve on demand rather than
	-- caching a miss forever.
	local function partFor(nodeId: string): BasePart?
		local part: BasePart? = parts[nodeId]
		if part ~= nil and part.Parent ~= nil then
			return part
		end
		refreshParts()
		return parts[nodeId]
	end

	local function receive(packet: any): ()
		if destroyed or type(packet) ~= "table" then
			return
		end
		local snapshot = if type(packet.snapshots) == "table" and type(spec.id) == "string"
			then packet.snapshots[spec.id]
			else nil
		if type(snapshot) ~= "table" then
			return
		end
		local reactions: { any } = if previous == nil then {} else WorldFeedback.deltas(world, previous, snapshot)
		previous = snapshot
		for _, binding in bindings do
			local part = partFor(binding.nodeId)
			-- An outfit's presentation is server-authoritative (OutfitPresenter); the client renders
			-- no character accessory of its own.
			if part ~= nil and binding.kind ~= "outfit" then
				apply(part, binding, WorldFeedback.state(binding, snapshot), localized)
			end
		end
		for _, reaction in reactions do
			local part = partFor(reaction.nodeId)
			local text = feedbackText(reaction)
			if part ~= nil and type(text) == "string" then
				popup(part, text)
			end
			if reaction.cue ~= nil and options.play ~= nil then
				options.play(reaction.cue)
			end
		end
	end

	local subscribe: (packet: any) -> () = options.subscribe
	subscribe(receive)
	refreshParts()
	return {
		bindings = #bindings,
		receive = receive,
		destroy = function(): ()
			destroyed = true
			table.clear(parts)
		end,
	}
end

return M
