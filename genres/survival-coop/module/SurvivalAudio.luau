--!strict
-- Presentation only: committed command results and authoritative vitals drive cues.
-- Local filesystem WAV paths are not Roblox content IDs.
local M = {}
-- Exact Roblox-shipped files, also referenced by shipped RbxCharacterSounds.lua.
-- No arbitrary local paths or asset-directory traversal is accepted.
local BUILTINS: { [string]: boolean } = {
	["rbxasset://sounds/action_footsteps_plastic.mp3"] = true,
	["rbxasset://sounds/action_get_up.mp3"] = true,
	["rbxasset://sounds/action_jump.mp3"] = true,
	["rbxasset://sounds/action_jump_land.mp3"] = true,
	["rbxasset://sounds/action_swim.mp3"] = true,
	["rbxasset://sounds/action_falling.ogg"] = true,
}
local ACTIONS = {
	["survival-coop:gather"] = "gather",
	["survival-coop:craft-complete"] = "craft",
	["survival-coop:food"] = "eat",
	["survival-coop:attack"] = "hit",
}

function M.contentId(value: any): string?
	if type(value) == "string" and (BUILTINS[value] or string.match(value, "^rbxassetid://[1-9]%d*$")) then
		return value
	end
	return nil
end

-- Engine-free event policy; playback is injected for deterministic specs.
function M.new(emit: (string, boolean) -> ()): any
	local disposed, resting, ambient = false, false, false
	local revision = -1
	local seen: { [string]: boolean } = {}
	local order: { string } = {}
	local controller = {}
	function controller.result(request: any, result: any)
		if disposed or type(request) ~= "table" or type(result) ~= "table" or result.ok ~= true then
			return
		end
		local cue = ACTIONS[request.action]
		local confirmed = if request.action == "survival-coop:gather"
			then type(result.data) == "table" and result.data.status == "confirmed"
			else type(result.stateVersion) == "number"
		if not cue or not confirmed or type(request.requestId) ~= "string" then
			return
		end
		local identity = tostring(request.sessionEpoch) .. ":" .. request.action .. ":" .. request.requestId
		if seen[identity] then
			return
		end
		seen[identity] = true
		table.insert(order, identity)
		-- Mirrors the finite retained receipt window; never grows with play time.
		if #order > 256 then
			local oldest = assert(table.remove(order, 1), "Survival audio receipt order must be nonempty")
			seen[oldest] = nil
		end
		emit(cue, true)
	end
	function controller.receive(packet: any)
		if disposed or type(packet) ~= "table" or type(packet.revision) ~= "number" or packet.revision <= revision then
			return
		end
		local snapshot = packet.snapshots and packet.snapshots["survival-coop"]
		if not snapshot or not snapshot.vitals then
			return
		end
		revision = packet.revision
		if not ambient then
			ambient = true
			emit("ambient", true)
		end
		local nextRest = snapshot.vitals.resting == true and snapshot.vitals.healthMilli > 0
		if resting ~= nextRest then
			resting = nextRest
			emit("rest", resting)
		end
	end
	function controller.destroy()
		if disposed then
			return
		end
		disposed = true
		emit("rest", false)
		emit("ambient", false)
		table.clear(seen)
		table.clear(order)
	end
	return controller
end

function M.start(config: any)
	local player = game:GetService("Players").LocalPlayer
	local storage = game:GetService("ReplicatedStorage")
	local soundService = game:GetService("SoundService")
	local folder = Instance.new("Folder")
	folder.Name, folder.Parent = "ForgeSurvivalAudio", soundService
	local connections: { RBXScriptConnection } = {}
	local slots: { Sound } = {}
	local loops: { [string]: Sound } = {}
	local missing: { string } = {}
	local nextSlot = 0
	local muted, disposed = false, false
	for cue, definition in config.cues do
		if not M.contentId(config.assets[definition.asset]) then
			table.insert(missing, cue .. ":" .. definition.asset)
		end
	end
	table.sort(missing)
	-- Visible to tooling without pretending a missing asset is playable.
	folder:SetAttribute("UnavailableCues", table.concat(missing, ","))
	local function emit(cue: string, active: boolean)
		local definition = config.cues[cue]
		local looping = cue == "rest" or cue == "ambient"
		if not active then
			if loops[cue] then
				loops[cue]:Destroy()
				loops[cue] = nil
			end
			return
		end
		local id = if definition then M.contentId(config.assets[definition.asset]) else nil
		if not id or (muted and not looping) then
			return
		end
		local sound: Sound
		if looping then
			if loops[cue] then
				return
			end
			sound = Instance.new("Sound")
			loops[cue] = sound
		else
			-- Four reusable one-shot voices plus two loops, including failed loads.
			nextSlot = nextSlot % 4 + 1
			sound = slots[nextSlot] or Instance.new("Sound")
			slots[nextSlot] = sound
			sound:Stop()
		end
		sound.Name, sound.SoundId, sound.Looped = cue, id, looping
		sound.PlaybackSpeed = definition.playbackSpeed or 1
		sound.Volume = if muted then 0 else definition.volume
		sound:SetAttribute("CueVolume", definition.volume)
		sound.Parent = folder
		sound:Play()
	end
	local controller = M.new(emit)
	local attached: { [Instance]: boolean } = {}
	local function attach(child: Instance)
		if attached[child] or not child:IsA("BindableEvent") then
			return
		end
		if child.Name == "ForgeHUDResult" then
			attached[child] = true
			table.insert(
				connections,
				child.Event:Connect(function(packet)
					controller.result(packet.request, packet.result)
				end)
			)
		elseif child.Name == "ForgeGatherResult" then
			attached[child] = true
			table.insert(
				connections,
				child.Event:Connect(function(packet)
					controller.result({ action = "survival-coop:gather", requestId = packet.requestId }, packet.result)
				end)
			)
		end
	end
	table.insert(connections, player.ChildAdded:Connect(attach))
	for _, child in player:GetChildren() do
		attach(child)
	end
	local state = storage:WaitForChild("ForgeState") :: RemoteEvent
	table.insert(connections, state.OnClientEvent:Connect(controller.receive))
	local function setMuted(value: boolean)
		muted = value
		for _, child in folder:GetChildren() do
			if child:IsA("Sound") then
				local volume = child:GetAttribute("CueVolume")
				assert(type(volume) == "number", "Survival audio cue volume must be numeric")
				child.Volume = if muted then 0 else volume
			end
		end
	end
	setMuted(player:GetAttribute("ForgeAudioMuted") == true)
	table.insert(
		connections,
		player:GetAttributeChangedSignal("ForgeAudioMuted"):Connect(function()
			setMuted(player:GetAttribute("ForgeAudioMuted") == true)
		end)
	)
	return {
		missing = missing,
		setMuted = setMuted,
		destroy = function()
			if disposed then
				return
			end
			disposed = true
			for _, connection in connections do
				connection:Disconnect()
			end
			controller.destroy()
			folder:Destroy()
			table.clear(connections)
			table.clear(attached)
		end,
	}
end
return M
