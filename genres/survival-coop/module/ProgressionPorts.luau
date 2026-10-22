--!strict
-- Authoritative progression owner (world.progression) for LateEquipmentPorts: reads tree, bag, coins and worn gear
-- from the personal slice, station facts from server-registered anchors, development from the
-- expedition document. Never client input. Also serves world.development for snapshots.
local Rules = require("./CharacterRules")
local Late = require("../../../core/domain/survival/LateEquipment")
local M = {}
-- Snapshots run every heartbeat, so they re-read the expedition document at most this often;
-- command facts always read it fresh.
local CACHE_SECONDS = 30

function M.bind(world: any, content: any, expeditionStore: any, seconds: () -> number): ()
	if not content.progressionPolicy then
		return
	end
	local cache: { [string]: any } = {}
	local function development(actor: string, fresh: boolean?): any
		local hit = cache[actor]
		if hit and not fresh and seconds() - hit.at < CACHE_SECONDS then
			return hit.value
		end
		local ok, document = pcall(expeditionStore.snapshot, actor)
		local value = if ok
				and document
				and document.development
			then { points = document.development.points or 0, definitions = document.development.definitions or {} }
			else if hit then hit.value else { points = 0, definitions = {} }
		cache[actor] = { at = seconds(), value = value }
		return value
	end
	world.development = development
	local function station(actor: string, kind: string?): (number, boolean)
		local spatial = world.services and world.services.survivalSpatial
		if not spatial or not kind then
			return 0, false
		end
		for tier = 3, 1, -1 do
			local found = spatial.station(actor, "station." .. kind .. ".t" .. tier)
			if found and found.kind == kind and found.reachable then
				return tier, true
			end
		end
		return 0, false
	end
	world.progression = {
		read = function(_actor: string, slice: any): any?
			local bag = slice.inventory and slice.inventory.bag
			if not slice.progression or not bag then
				return nil
			end
			return {
				coins = slice.balance or 0,
				bag = bag,
				tree = slice.progression,
				equipment = (function()
					local byItem = {}
					for _, record in Rules.worn(slice.gear or {}, bag) do
						byItem[record.itemId] = record
					end
					return byItem
				end)(),
				lateEquipment = slice.lateEquipment,
			}
		end,
		facts = function(actor: string, operationId: string?): any
			local row = if operationId then Late.operation(content, operationId) else nil
			local kind = if row then row.station else nil
			local tier, reachable = station(actor, kind)
			return {
				developmentRank = Rules.rank(development(actor, true).points),
				station = if reachable then kind else nil,
				stationTier = tier,
				reachable = reachable,
			}
		end,
		write = function(slice: any, aggregate: any)
			slice.balance = aggregate.coins
			slice.inventory.bag = aggregate.bag
			slice.lateEquipment = aggregate.lateEquipment
			local gear = slice.gear or { equipped = {}, equipment = {} }
			for itemId, record in aggregate.equipment or {} do
				gear.equipment[itemId] = record
			end
			slice.gear = gear
		end,
	}
end

return M
