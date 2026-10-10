--!strict
-- AudioKit: the cue bindings the declarative spec declares.
--
-- Engine-free policy, injected playback. The policy classifies committed command
-- results and declared snapshot fields into cue emissions and never computes a
-- game outcome; playback is a separate concern, so the classification stays
-- deterministic and testable. Only Roblox-shipped content ids are accepted for
-- playback — a local filesystem path is not a content id.
--
-- collect-raid's hand-wired handlers (state diffs, notify/prompt classifiers,
-- siege-phase music swap) are the reference implementation of these bindings and
-- stay as its declared audio override; this kit is what the other genres use.
--
-- Two client shapes start it from the same declared document: the generated
-- client feeds the packets it already receives through `subscribe`, and a pack
-- whose client owns its own transport (a hand-written game pack) reports each
-- committed action with `result` and names no cue itself — the mapping stays the
-- spec's.

local M = {}

-- Four reusable one-shot voices plus one loop per looping cue.
M.VOICE_COUNT = 4
-- Bounded retained receipt window; never grows with play time.
M.RECEIPT_LIMIT = 256

export type Options = {
	genre: string,
	audio: any,
	contentIds: { [string]: string }?,
	-- Control id -> the action it drives. The server echoes the *control* id on a
	-- prompt trigger, which for a namespaced control is not the action id, so
	-- without this map an action-bound cue never fires for a world prompt.
	controlActions: { [string]: string }?,
	-- Optional: a pack that reports its own committed results through `result` has
	-- nothing to subscribe to.
	subscribe: ((packet: any) -> ())?,
	locale: string?,
	now: (() -> number)?,
	playback: ((cue: string, definition: any) -> ())?,
}

export type Controller = { receive: (any) -> (), destroy: () -> (), fired: () -> number }

--- True for a Roblox content id: a shipped `rbxasset://` file or an uploaded
--- `rbxassetid://<digits>` asset. Everything else is not playable.
function M.contentId(value: any): string?
	if type(value) ~= "string" then
		return nil
	end
	if string.match(value, "^rbxasset://") ~= nil or string.match(value, "^rbxassetid://[1-9]%d*$") ~= nil then
		return value
	end
	return nil
end

local function field(source: any, path: any): any
	if type(path) ~= "string" then
		return nil
	end
	local current = source
	for segment in string.gmatch(path, "[^%.]+") do
		if type(current) ~= "table" then
			return nil
		end
		local index = tonumber(segment)
		current = if index ~= nil then current[index] else current[segment]
	end
	return current
end

--- A change signature for a snapshot field: scalars by value, tables by their
--- sorted key list, so an unchanged snapshot fires nothing.
local function signature(value: any): string
	if type(value) ~= "table" then
		return tostring(value)
	end
	local keys: { string } = {}
	for key in value do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)
	return "[" .. table.concat(keys, ",") .. "]"
end

--- The pure policy: what a packet means for the spec's cue bindings. Returns a
--- controller whose `receive` consumes ForgeState packets and whose `fired`
--- counts emissions, which is what a spec asserts against.
function M.policy(options: Options): Controller
	local audio: any = options.audio or {}
	local cues: { any } = if type(audio.cues) == "table" then audio.cues else {}
	local bindings: { any } = if type(audio.bindings) == "table" then audio.bindings else {}
	local byCue: { [string]: any } = {}
	for _, cue in cues do
		if type(cue) == "table" and type(cue.key) == "string" then
			byCue[cue.key] = cue
		end
	end
	local actionBindings: { [string]: any } = {}
	local eventBindings: { any } = {}
	for _, binding in bindings do
		if type(binding) == "table" then
			local action = string.match(tostring(binding.on), "^action:(.+)$")
			if action ~= nil then
				actionBindings[action] = binding
			else
				table.insert(eventBindings, binding)
			end
		end
	end

	local now = options.now or os.clock
	local controlActions = if type(options.controlActions) == "table" then options.controlActions else {}
	local lastFired: { [string]: number } = {}
	local seen: { [string]: boolean } = {}
	local order: { string } = {}
	local previous: { [string]: string } = {}
	local lastRevision = -1
	local emissions = 0
	local disposed = false

	local function emit(cue: string, identity: string, dedupe: number): ()
		local definition = byCue[cue]
		if definition == nil or disposed then
			return
		end
		if dedupe > 0 then
			local at = now()
			local last = lastFired[cue]
			if last ~= nil and at - last < dedupe then
				return
			end
			lastFired[cue] = at
		end
		if identity ~= "" then
			if seen[identity] then
				return
			end
			seen[identity] = true
			table.insert(order, identity)
			if #order > M.RECEIPT_LIMIT then
				local oldest = table.remove(order, 1)
				if oldest ~= nil then
					seen[oldest] = nil
				end
			end
		end
		emissions += 1
		if options.playback ~= nil then
			options.playback(cue, definition)
		end
	end

	local controller: Controller = {
		fired = function(): number
			return emissions
		end,
		receive = function(packet: any): ()
			if disposed or type(packet) ~= "table" then
				return
			end
			-- A committed command result names the action that succeeded. One result envelope covers
			-- both paths: the generated client publishes the action it dispatched as `packet.action`
			-- beside the HUD result, and a world prompt publishes the echoed control id as
			-- `packet.control`. `action` is already the resolved action id, so it is read first; the
			-- control mapping and then `result.action` are the fallbacks for a packet that carries only
			-- a control or a bare result.
			local result = packet.result
			if type(result) == "table" and result.ok == true then
				local action = if type(packet.action) == "string"
					then packet.action
					elseif type(packet.control) == "string" then (controlActions[packet.control] or packet.control)
					else result.action
				local binding = if type(action) == "string" then actionBindings[action] else nil
				if binding ~= nil then
					local identity = if type(result.requestId) == "string" then result.requestId else ""
					emit(binding.cue, identity, if type(binding.dedupe) == "number" then binding.dedupe else 0)
				end
			end
			if type(packet.revision) ~= "number" or packet.revision <= lastRevision then
				return
			end
			lastRevision = packet.revision
			local snapshot = if type(packet.snapshots) == "table" then packet.snapshots[options.genre] else nil
			if type(snapshot) ~= "table" then
				return
			end
			for _, binding in eventBindings do
				if type(binding.field) == "string" then
					local key = tostring(binding.on)
					local value = signature(field(snapshot, binding.field))
					local prior = previous[key]
					previous[key] = value
					if prior ~= nil and prior ~= value then
						emit(binding.cue, "", if type(binding.dedupe) == "number" then binding.dedupe else 0)
					end
				end
			end
		end,
		destroy = function(): ()
			if disposed then
				return
			end
			disposed = true
			table.clear(seen)
			table.clear(order)
			table.clear(previous)
		end,
	}
	return controller
end

--- Starts the kit: the spec's bindings drive a small pool of one-shot voices
--- plus one loop per looping cue, in a named SoundService folder.
function M.start(options: Options): any
	local Players = game:GetService("Players")
	local SoundService = game:GetService("SoundService")
	local player = Players.LocalPlayer
	local folder = Instance.new("Folder")
	folder.Name, folder.Parent = "ForgeHudAudio", SoundService
	local voices: { [number]: Sound? } = {}
	local loops: { [string]: Sound? } = {}
	local slots = 0
	local muted = false
	local disposed = false
	local missing: { string } = {}
	local contentIds = options.contentIds or {}
	local audio: any = options.audio or {}
	local cues: { any } = if type(audio.cues) == "table" then audio.cues else {}
	local byCue: { [string]: any } = {}
	for _, cue in cues do
		if type(cue) == "table" and type(cue.key) == "string" then
			byCue[cue.key] = cue
			if M.contentId(contentIds[cue.key]) == nil then
				table.insert(missing, cue.key)
			end
		end
	end
	table.sort(missing)
	-- Visible to tooling without pretending a missing asset is playable.
	folder:SetAttribute("UnavailableCues", table.concat(missing, ","))

	local function playback(cue: string, definition: any): ()
		if disposed then
			return
		end
		local id = M.contentId(contentIds[cue])
		if id == nil then
			return
		end
		local looping = definition.kind == "music" or definition.kind == "ambience"
		local sound: Sound
		if looping then
			if loops[cue] ~= nil then
				return
			end
			sound = Instance.new("Sound")
			loops[cue] = sound
		else
			slots = slots % M.VOICE_COUNT + 1
			local reused = voices[slots]
			sound = if reused ~= nil then reused else Instance.new("Sound")
			voices[slots] = sound
			sound:Stop()
		end
		sound.Name, sound.SoundId, sound.Looped = cue, id, looping
		sound.Volume = if muted then 0 else 0.6
		sound:SetAttribute("CueVolume", 0.6)
		sound.Parent = folder
		sound:Play()
	end

	local controller = M.policy({
		genre = options.genre,
		audio = audio,
		contentIds = contentIds,
		controlActions = options.controlActions,
		subscribe = options.subscribe,
		now = options.now,
		playback = playback,
	})

	local function setMuted(value: boolean): ()
		muted = value
		for _, child in folder:GetChildren() do
			if child:IsA("Sound") then
				local volume = child:GetAttribute("CueVolume")
				if type(volume) == "number" then
					child.Volume = if muted then 0 else volume
				end
			end
		end
	end

	local connections: { RBXScriptConnection } = {}
	table.insert(
		connections,
		player:GetAttributeChangedSignal("ForgeAudioMuted"):Connect(function()
			setMuted(player:GetAttribute("ForgeAudioMuted") == true)
		end)
	)
	setMuted(player:GetAttribute("ForgeAudioMuted") == true)
	if options.subscribe ~= nil then
		options.subscribe(controller.receive)
	end

	return {
		missing = missing,
		controller = controller,
		setMuted = setMuted,
		-- Reports one committed action result. A pack whose client owns its own
		-- transport names the canonical action it just committed; the policy resolves
		-- the cue from the spec's own binding, so the pack declares no cue mapping.
		result = function(actionId: string, committed: any): ()
			controller.receive({ result = committed, action = actionId })
		end,
		-- One-shot playback of a declared cue by key, so a caller that observes a
		-- committed change itself (the world-feedback layer) plays the same cue the
		-- bindings would, through the same voices and the same content-id guard.
		play = function(cue: string): ()
			local definition = byCue[cue]
			if definition == nil then
				return
			end
			playback(cue, definition)
		end,
		destroy = function(): ()
			if disposed then
				return
			end
			disposed = true
			for _, connection in connections do
				connection:Disconnect()
			end
			controller.destroy()
			folder:Destroy()
		end,
	}
end

return M
