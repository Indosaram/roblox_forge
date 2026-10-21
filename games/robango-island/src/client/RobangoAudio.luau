--!strict
-- Product adapter; the server/UI bridges call the returned director after authoritative edges.
local M = {}
function M.start(SoundBank: any, Director: any, assets: { [string]: string }, config: any)
	local bank = SoundBank.new(config.groups)
	local missing: { string } = {}
	local loops: { [string]: Sound } = {}
	local voices: { Sound } = {}
	for name, slot in config.slots do
		local id = assets[slot.asset]
		if id and string.match(id, "^rbxassetid://[1-9]%d*$") then
			bank:define(name, { soundId = id, group = slot.group, looped = slot.looped })
		else
			table.insert(missing, name)
		end
	end
	table.sort(missing)
	local director = Director.new(config, {
		play = function(name, slot)
			local sound = bank:play(name)
			if not sound then
				return
			end
			if slot.looped then
				loops[name] = sound
			else
				-- A bounded voice pool also bounds failed audio loads.
				if #voices >= 16 then
					local oldest = assert(table.remove(voices, 1), "voice pool nonempty")
					oldest:Destroy()
				end
				table.insert(voices, sound)
			end
		end,
		stop = function(name)
			if loops[name] then
				loops[name]:Destroy()
				loops[name] = nil
			end
		end,
		volume = function(group, gain)
			bank:setGroupVolume(group, gain)
		end,
	})
	local player = game:GetService("Players").LocalPlayer
	local function mute()
		director.setMuted(player:GetAttribute("ForgeAudioMuted") == true)
	end
	local connection = player:GetAttributeChangedSignal("ForgeAudioMuted"):Connect(mute)
	mute()
	local connections: { RBXScriptConnection } = {}
	local function region()
		local role = workspace:GetAttribute("ForgeWorldRole")
		local value = if role == "archipelago"
			then workspace:GetAttribute("ForgeWorldBiome")
			elseif role == "harbor" then "market"
			else role
		if type(value) == "string" then
			director.region(value)
		end
	end
	table.insert(connections, workspace:GetAttributeChangedSignal("ForgeWorldRole"):Connect(region))
	table.insert(connections, workspace:GetAttributeChangedSignal("ForgeWorldBiome"):Connect(region))
	region()
	local attached: { [Instance]: boolean } = {}
	local events = {
		["survival-coop:craft-complete"] = "craft-complete",
		["survival-coop:home-place"] = "build-place",
		["survival-coop:tame-mount"] = "mount",
	}
	local function attach(child: Instance)
		if attached[child] or not child:IsA("BindableEvent") then
			return
		end
		if child.Name == "ForgeHUDResult" or child.Name == "ForgeGatherResult" then
			attached[child] = true
			table.insert(
				connections,
				child.Event:Connect(function(packet)
					local request = packet.request
					local event = if type(request) == "table" then events[request.action] else nil
					if event then
						director.result(request, packet.result, event)
					end
				end)
			)
		end
	end
	table.insert(connections, player.ChildAdded:Connect(attach))
	for _, child in player:GetChildren() do
		attach(child)
	end
	local disposed = false
	return {
		director = director,
		missing = missing,
		destroy = function()
			if disposed then
				return
			end
			disposed = true
			connection:Disconnect()
			for _, subscribed in connections do
				subscribed:Disconnect()
			end
			table.clear(connections)
			table.clear(attached)
			director.destroy()
			for _, voice in voices do
				voice:Destroy()
			end
			table.clear(voices)
			bank:destroy()
		end,
	}
end
return M
