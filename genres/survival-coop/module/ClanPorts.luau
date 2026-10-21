--!strict
local Clan = require("../../../core/domain/settlement/Clan")
local Data = require("../../../core/domain/genre/SerializedData")
local M = {}

-- config.content is the generated SurvivalContent table, never a second catalog.
function M.new(config: any): any
	local directory = config.directory
	local occupants: { [string]: boolean } = {}
	local activeMatch: string? = nil
	local flushOccupancy: any = nil
	local operations = {}
	for _, definition in config.content.operations do
		operations[definition.id] = definition
	end
	local function member(actor: string, id: string): boolean
		local actual, reason = directory.membership(actor)
		return reason == nil and actual == id
	end
	local clan = {
		store = function(): any
			return directory.store
		end,
		now = config.now,
		owner = config.owner,
		identity = function(actor: string, requested: string?): string?
			if requested then
				-- Joining must be possible before membership exists; Clan.apply checks invitation.
				local state, reason = directory.read("clan:" .. requested)
				return if state and not reason then requested else nil
			end
			return directory.membership(actor)
		end,
		visible = function(state: any, actor: string): boolean
			return Clan.allowed(state, actor, "view")
		end,
		facts = function(actor: string, id: string, operation: string, args: any, origin: string): any
			return {
				rules = config.content.clanPolicy,
				operations = operations,
				hall = config.hall(id),
				territoryAllowed = config.territoryAllowed(id, args.territory),
				hasProperty = config.hasProperty(id),
				contribution = if origin == "server" and operation == "contribute"
					then config.contribution(actor)
					else nil,
				-- Wallet settlement is a separate durable escrow, never a boolean supplied by a client.
				transferAuthorized = false,
			}
		end,
	}
	local outpost = {
		store = clan.store,
		now = config.now,
		owner = function(): string
			return ""
		end,
		identity = function(_actor: string, requested: string?): string?
			return if requested == nil or requested == config.outpostId then config.outpostId else nil
		end,
		facts = function(_actor: string, _id: string, _operation: string, _args: any, origin: string): any
			local present = {}
			for actor in occupants do
				if config.inZone(actor) then
					table.insert(present, actor)
				end
			end
			return {
				server = origin == "server",
				role = config.role,
				rules = config.content.outpostPolicy,
				teams = Data.clone(config.teams()),
				occupants = present,
				eligible = member,
				optedIn = config.optedIn,
			}
		end,
	}
	local api: any = {
		clan = clan,
		outpost = outpost,
		occupancy = function(actor: string, present: boolean)
			if activeMatch then
				local result = config.dispatch("outpost-advance", config.outpostId, { matchId = activeMatch })
				if not result.ok then
					return result
				end
			end
			if present then
				occupants[actor] = true
			else
				occupants[actor] = nil
			end
			return { ok = true }
		end,
		releaseActor = function(actor: string)
			if flushOccupancy then
				local result = flushOccupancy()
				if not result.ok then
					return result
				end
			end
			occupants[actor] = nil
			return { ok = true }
		end,
		captureEligibility = function(actor: string): boolean
			local id, reason = directory.membership(actor)
			if not id or reason then
				return false
			end
			local state = directory.read("clan:" .. id)
			local ownership = directory.read("outpost:" .. config.outpostId)
			return state ~= nil and Clan.effect(state, actor, "advanced-capture", config.now(), ownership)
		end,
	}
	function api.start(matchId: string): any
		local result = config.dispatch("outpost-start", config.outpostId, { matchId = matchId })
		if result.ok then
			activeMatch = matchId
		end
		return result
	end
	function api.tick(): any
		if not activeMatch then
			local state = directory.read("outpost:" .. config.outpostId)
			for id, match in if state then state.matches or {} else {} do
				if match.status == "active" then
					activeMatch = id
				end
			end
		end
		if not activeMatch then
			return { ok = true }
		end
		local result = config.dispatch("outpost-advance", config.outpostId, { matchId = activeMatch })
		if result.ok then
			local state = directory.read("outpost:" .. config.outpostId)
			if state and state.matches[activeMatch].status == "settled" then
				activeMatch = nil
			end
		end
		return result
	end
	flushOccupancy = api.tick
	return api
end

return M
