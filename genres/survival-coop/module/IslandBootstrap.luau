--!strict
-- Engine ports and actor facts are injected. Neither client destination data
-- nor TeleportData supplies progression or ownership authority.
local Topology = require("../../../core/domain/island/Topology")
local Expedition = require("../../../core/domain/island/Expedition")
local M = {}
M.KEY_FAILED = "island_route_failed"
M.KEY_RETRY = "island_route_retry"

function M.select(env: any): (string, boolean)
	if env.isStudio then
		assert(Topology.ROLES[env.studioRole] ~= nil, "studio_single_role_required")
		return env.studioRole, false
	end
	local role, reason = Topology.resolveRole(env.roles, env.placeId)
	assert(role, reason)
	return role :: string, env.privateServerId == "" and role == "home"
end

function M.start(env: any): any
	local role, routingOnly = M.select(env)
	if env.isStudio then
		return { mode = "studio-single", role = role, gameplay = true }
	end
	assert(env.teleportService and env.players, "missing_travel_services")
	local departing: { [string]: boolean } = {}
	local function travel(player: any, destination: string): (boolean, string?)
		if Topology.ROLES[destination] == nil then
			return false, "unknown_target_role"
		end
		local id = env.roles[destination]
		if id == nil or id <= 0 then
			return false, "unconfigured_destination"
		end
		local facts = if env.facts then env.facts(player.UserId, destination) else nil
		if type(facts) ~= "table" or type(facts.level) ~= "number" then
			return false, "missing_actor_facts"
		end
		local allowed, reason = Topology.validateRoleTransition(role, destination, facts.level)
		if not allowed then
			return false, reason
		end
		if destination == "archipelago" then
			if env.admitExpedition then
				allowed, reason = env.admitExpedition(tostring(player.UserId))
			else
				allowed, reason = Expedition.admitStage(facts.expedition, env.now())
			end
			if not allowed then
				return false, reason
			end
		end
		assert(env.prepareHandoff and env.resumeHandoff and env.completeHandoff, "missing_handoff_contract")
		local actor = tostring(player.UserId)
		local ready = env.prepareHandoff(actor)
		if not ready.ok then
			return false, ready.reason or "handoff_refused"
		end
		departing[actor] = true
		local options = env.newTeleportOptions()
		if destination == "home" then
			if type(facts.homeAccessCode) ~= "string" or facts.homeAccessCode == "" then
				env.resumeHandoff(actor)
				departing[actor] = nil
				return false, "missing_home_reservation"
			end
			options.ReservedServerAccessCode = facts.homeAccessCode
		end
		local ok = pcall(function()
			env.teleportService:TeleportAsync(id, { player }, options)
		end)
		if not ok then
			local resumed = env.resumeHandoff(actor)
			departing[actor] = nil
			return false, if resumed.ok then "teleport_failed" else resumed.reason
		end
		return true, nil
	end
	-- Accepted teleports complete only when the actor actually leaves. An async
	-- initialization failure restores the source fence through Session.
	local connections = {}
	if env.players.PlayerRemoving then
		table.insert(
			connections,
			env.players.PlayerRemoving:Connect(function(player)
				if departing[tostring(player.UserId)] and env.completeHandoff then
					env.completeHandoff(tostring(player.UserId))
					departing[tostring(player.UserId)] = nil
				end
			end)
		)
	end
	if env.teleportService.TeleportInitFailed then
		table.insert(
			connections,
			env.teleportService.TeleportInitFailed:Connect(function(player)
				if departing[tostring(player.UserId)] and env.resumeHandoff then
					env.resumeHandoff(tostring(player.UserId))
					departing[tostring(player.UserId)] = nil
				end
			end)
		)
	end
	return {
		mode = "live",
		role = role,
		gameplay = not routingOnly,
		travel = travel,
		stop = function()
			for _, connection in connections do
				connection:Disconnect()
			end
			table.clear(connections)
		end,
	}
end
return M
