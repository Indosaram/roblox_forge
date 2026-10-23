--!strict
-- Product adapter; the server/UI bridges call the returned director after authoritative edges.
local M = {}
-- Transport-level refusals are retries, not player-facing outcomes.
local SILENT_REASONS = {
	COMMAND_PENDING = true,
	REQUEST_EXPIRED = true,
	TRANSPORT_FAILED = true,
	COMMAND_UNAVAILABLE = true,
	HANDSHAKE_FAILED = true,
}

-- Engine-free: committed/refused command -> catalog event (nil = silent).
function M.commandEvent(config: any, request: any, result: any, nodeKind: string?, nodeItem: string?): string?
	if type(request) ~= "table" or type(result) ~= "table" or type(request.action) ~= "string" then
		return nil
	end
	local action = request.action
	if result.ok ~= true then
		if SILENT_REASONS[result.reason] then
			return nil
		end
		return config.refusals[action]
	end
	local data = if type(result.data) == "table" then result.data else {}
	if action == "survival-coop:gather" then
		local byKind = if nodeKind then config.gather[nodeKind] else nil
		return byKind or (if nodeItem and config.gatherItems then config.gatherItems[nodeItem] else nil)
	elseif action == "survival-coop:tame-capture" then
		return if data.captured == true then config.signals.tameSuccess else config.signals.tameFail
	elseif action == "survival-coop:party-action" and type(request.args) == "table" then
		local verb = request.args[1]
		return if verb == "depart"
			then config.signals.expeditionDepart
			elseif verb == "claim" then config.signals.expeditionClaim
			else nil
	end
	return config.actions[action]
end

-- Engine-free: previous/next authoritative snapshot facts -> signal names, in a stable order.
function M.snapshotEdges(previous: any, snapshots: any): ({ string }, any)
	local core = snapshots["survival-coop"] or {}
	local extensions = snapshots.survivalExtensions or {}
	local expedition = if type(extensions.expedition) == "table" then extensions.expedition else {}
	local results = expedition.results
	local arrival = expedition.arrival
	local shop = extensions.monetization
	local facts = {
		health = if core.vitals then core.vitals.healthMilli else nil,
		level = if core.progression then core.progression.level else nil,
		arrival = if type(arrival) == "table" then tostring(arrival.id) .. ":" .. tostring(arrival.stage) else nil,
		results = if type(results) == "table" and results.status ~= "active" then results.id else nil,
		hazard = expedition.hazard ~= nil,
		grants = if type(shop) == "table" then shop.grants else nil,
	}
	local out: { string } = {}
	if previous then
		if facts.health and previous.health then
			if facts.health == 0 and previous.health > 0 then
				table.insert(out, "knockout")
			elseif facts.health > 0 and previous.health == 0 then
				table.insert(out, "respawn")
			elseif facts.health < previous.health then
				table.insert(out, "playerHit")
			end
		end
		if facts.level and previous.level and facts.level > previous.level then
			table.insert(out, "levelUp")
		end
		if facts.arrival and facts.arrival ~= previous.arrival then
			table.insert(out, "expeditionArrive")
		end
		if facts.results and facts.results ~= previous.results then
			table.insert(out, "expeditionResults")
		end
		if facts.hazard and not previous.hazard then
			table.insert(out, "hazardEnter")
		end
		if facts.grants and previous.grants and facts.grants > previous.grants then
			table.insert(out, "shopReceipt")
		end
	end
	return out, facts
end

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
	local disposed = false
	local attached: { [Instance]: boolean } = {}
	local function signal(name: string)
		local event = config.signals[name]
		if event then
			director.event(event)
		end
	end
	-- Refusals bypass director.result (ok-only); dedupe them on the same request identity.
	local refused: { [string]: boolean } = {}
	local refusedOrder: { string } = {}
	local function command(request: any, result: any, nodeKind: string?, nodeItem: string?)
		local event = M.commandEvent(config, request, result, nodeKind, nodeItem)
		if not event then
			return
		end
		if result.ok == true then
			director.result(request, result, event)
			return
		end
		local identity = tostring(request.sessionEpoch) .. ":" .. request.action .. ":" .. tostring(request.requestId)
		if refused[identity] then
			return
		end
		refused[identity] = true
		table.insert(refusedOrder, identity)
		if #refusedOrder > config.receiptLimit then
			refused[table.remove(refusedOrder, 1) :: string] = nil
		end
		director.event(event)
	end
	local function nodeKind(nodeId: any): (string?, string?)
		for _, part in game:GetService("CollectionService"):GetTagged("ForgeSurvivalNode") do
			if part:GetAttribute("ForgeNodeId") == nodeId then
				local kind, item = part:GetAttribute("ForgeNodeKind"), part:GetAttribute("ForgeNodeItem")
				return if type(kind) == "string" then kind else nil, if type(item) == "string" then item else nil
			end
		end
		return nil, nil
	end
	local function attach(child: Instance)
		if attached[child] or not child:IsA("BindableEvent") then
			return
		end
		if child.Name == "ForgeHUDResult" or child.Name == "ForgeGatherResult" then
			local gather = child.Name == "ForgeGatherResult"
			attached[child] = true
			table.insert(
				connections,
				child.Event:Connect(function(packet)
					if type(packet) == "table" then
						if gather then
							command(packet.request, packet.result, nodeKind(packet.nodeId))
						else
							command(packet.request, packet.result)
						end
					end
				end)
			)
		end
	end
	table.insert(connections, player.ChildAdded:Connect(attach))
	for _, child in player:GetChildren() do
		attach(child)
	end
	-- Creature telegraph/strike follow the replicated wildlife feedback edge.
	local function watchCreature(model: Instance)
		if not model:IsA("Model") then
			return
		end
		table.insert(
			connections,
			model:GetAttributeChangedSignal("ForgeWildlifeFeedback"):Connect(function()
				local event = config.wildlife[model:GetAttribute("ForgeWildlifeFeedback")]
				if event then
					director.event(event)
				end
			end)
		)
	end
	task.spawn(function()
		local folder = workspace:WaitForChild("ForgeWildlife", math.huge)
		if disposed then
			return
		end
		table.insert(connections, folder.ChildAdded:Connect(watchCreature))
		for _, model in folder:GetChildren() do
			watchCreature(model)
		end
	end)
	-- Button clicks; header close buttons sound as a close.
	local function watchButton(object: Instance)
		if object:IsA("GuiButton") then
			table.insert(
				connections,
				object.Activated:Connect(function()
					signal(if object.Name == "Close" then "uiClose" else "uiClick")
				end)
			)
		end
	end
	local playerGui = player:WaitForChild("PlayerGui")
	table.insert(connections, playerGui.DescendantAdded:Connect(watchButton))
	for _, object in playerGui:GetDescendants() do
		watchButton(object)
	end
	local facts: any = nil
	local state = game:GetService("ReplicatedStorage"):WaitForChild("ForgeState")
	table.insert(
		connections,
		state.OnClientEvent:Connect(function(packet)
			if type(packet) == "table" and type(packet.snapshots) == "table" then
				local edges
				edges, facts = M.snapshotEdges(facts, packet.snapshots)
				for _, name in edges do
					signal(name)
				end
			end
			local settings = if type(packet) == "table"
					and packet.snapshots
					and packet.snapshots.survivalExtensions
				then packet.snapshots.survivalExtensions["audio-settings"]
				else nil
			if settings then
				director.setMuted(settings.muted)
				for group, gain in config.groups do
					director.setVolume(group, gain * settings.volume)
				end
			end
		end)
	)
	return {
		director = director,
		missing = missing,
		signal = signal,
		-- ExtensionPanels factory: panel command sends route through the same mapping.
		panel = function(ctx: any)
			local unsubscribe = ctx.onSend(function(actionId, args, result, requestId)
				command({ action = actionId, args = args, requestId = requestId }, result, nil)
			end)
			return { destroy = unsubscribe }
		end,
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
			table.clear(refused)
			table.clear(refusedOrder)
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
