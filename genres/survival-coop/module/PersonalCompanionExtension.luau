--!strict
-- V2 companion ownership, material debit and command receipt share the personal CAS.
local Companion = require("./CombatCompanion")
local Ecology = require("./CombatEcology")
local Rng = require("../../../core/domain/random/Rng")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Job = require("../../../core/domain/crafting/Job")
local Data = require("../../../core/domain/genre/SerializedData")
local M = {}

function M.factory(ctx: any, skins: { [string]: { species: string, paid: boolean } }?): any
	local rules = ctx.content.progressionPolicy.companion
	local catalog = Job.catalog(ctx.content)
	local function state(slice: any): any
		return slice.companions or Companion.new({}, ctx.nowMillis())
	end
	local function settle(actor: string): any
		local port = ctx.personalTransfer(actor)
		if not port then
			return { ok = false, reason = "PERSONAL_UNAVAILABLE" }
		end
		local token = port.profile()
		local companions = token.data.envelope.genres["survival-coop"].data.companions
		for id, capture in (if companions then companions.captures or {} else {}) do
			if not capture.settled then
				local reason = ctx.captureWild(id, capture.receipt, 2 ^ 53 - 1)
				if reason and reason ~= "ALREADY_DEAD" and reason ~= "ALREADY_CAPTURED" then
					return { ok = false, reason = reason }
				end
				local envelope = Data.clone(token.data.envelope)
				local slice = envelope.genres["survival-coop"].data
				slice.companions.captures[id].settled = true
				if reason then
					slice.companions.pets[id] = nil
					slice.companions.captures[id].reason = reason
					local bag = Inventory.fromSave(slice.inventory.bag, catalog)
					bag = assert(Inventory.add(bag, catalog, {
						itemId = "capture-refund:" .. capture.receipt,
						catalogId = rules.ropeItem,
						quantity = 1,
						qualityMilli = 1000,
						durabilityMilli = 0,
						attributes = {},
					}, bag.version))
					slice.inventory.bag = Inventory.save(bag)
				end
				local committed, err = port.personal:commit(token, token.data.stateRevision, envelope, nil)
				if not committed or err then
					return { ok = false, reason = err or "SAVE_FAILED" }
				end
				port.install(committed)
				token = committed
			end
		end
		return { ok = true }
	end
	return {
		id = "taming",
		handles = function(action: string): boolean
			return action == "survival-coop:companion-action"
				or action == "survival-coop:tame-hit"
				or action == "survival-coop:tame-capture"
		end,
		command = function(actor: string, action: string, args: any, context: any, _origin: string, admit: any): any
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			-- Defeat is a server event, not a player-controlled recovery shortcut.
			if args[1] == "defeat" then
				return { ok = false, reason = "SERVER_ONLY" }
			end
			local port = ctx.personalTransfer(actor)
			if not port then
				return { ok = false, reason = "PERSONAL_UNAVAILABLE" }
			end
			local token = port.profile()
			local envelope = Data.clone(token.data.envelope)
			local slice = envelope.genres["survival-coop"].data
			local current = state(slice)
			-- Reconnect rebases online hunger at load; stored animals do not decay.
			current = Companion.tick(current, ctx.nowMillis(), rules)
			local receipt = tostring(context.sessionEpoch) .. ":" .. context.requestId
			if action ~= "survival-coop:companion-action" then
				local binding = action .. ":" .. args[1]
				if current.receipts[receipt] then
					if current.receipts[receipt] ~= binding then
						return { ok = false, reason = "REQUEST_CONFLICT" }
					end
					local recovered = settle(actor)
					return {
						ok = recovered.ok,
						reason = recovered.reason,
						data = { captured = current.pets[args[1]] ~= nil },
					}
				end
				local wild = ctx.wildlife(args[1])
				local access = ctx.world.wildlifeAccess(actor, args[1])
				if not wild or not access or not access.alive or not access.lineOfSight then
					return { ok = false, reason = "TARGET_UNAVAILABLE" }
				end
				local delta = 0
				for _, axis in { "x", "y", "z" } do
					delta += (access.position[axis] - access.targetPosition[axis]) ^ 2
				end
				if delta > rules.stunRange ^ 2 then
					return { ok = false, reason = "TOO_FAR" }
				end
				local species = nil
				for _, row in ctx.content.wildlifeDetails do
					if row.id == wild.catalogId then
						species = row
						break
					end
				end
				if not species then
					return { ok = false, reason = "UNKNOWN_SPECIES" }
				end
				local tree = slice.progression
				if not tree then
					return { ok = false, reason = "PROGRESSION_UNAVAILABLE" }
				end
				local now = ctx.nowMillis()
				current.stuns = current.stuns or {}
				local captured = false
				if action == "survival-coop:tame-hit" then
					if not tree.paid.melee_2 or wild.healthMilli > species.health * 250 then
						return { ok = false, reason = "SUBDUE_GATED" }
					end
					if now < (current.stunReadyAt or 0) then
						return { ok = false, reason = "RECOVERY" }
					end
					local club = false
					for _, item in slice.inventory.bag.items do
						club = club
							or (string.find(item.catalogId, "club", 1, true) ~= nil and item.durabilityMilli > 0)
					end
					if not club then
						return { ok = false, reason = "CLUB_REQUIRED" }
					end
					current.stuns[args[1]], current.stunReadyAt = now + rules.stunMillis, now + rules.stunRecoveryMillis
				else
					local bag = Inventory.fromSave(slice.inventory.bag, catalog)
					local rope, ropeId = 0, nil
					for id, item in bag.items do
						if item.catalogId == rules.ropeItem and Inventory.available(bag, id) > 0 then
							rope += Inventory.available(bag, id)
							ropeId = id
						end
					end
					local occupied = 0
					for _ in current.pets do
						occupied += 1
					end
					local eligibility = ctx.world.captureEligibility
					local advanced = eligibility ~= nil and eligibility(actor)
					local success, _, reason = Ecology.rollCapture(species, {
						survival3 = tree.paid.survival_3 ~= nil,
						survival6 = tree.paid.survival_6 ~= nil,
						stunned = now < (current.stuns[args[1]] or 0),
						occupied = occupied,
						capacity = rules.capacity,
						rope = rope,
						survivalSkill = tree.mastery.survival.level,
						clanResearch = advanced,
						stronghold = advanced,
					}, rules, Rng.new(rules.seed):fork(actor .. ":" .. receipt):nextInteger(0, 2147483646))
					if reason then
						return { ok = false, reason = reason }
					end
					bag = assert(Inventory.consume(bag, assert(ropeId, "MISSING_CAPTURE_ROPE"), 1, bag.version))
					slice.inventory.bag = Inventory.save(bag)
					if success then
						current = assert(Companion.capture(current, args[1], species.id, rules))
						current.captures = current.captures or {}
						current.captures[args[1]] = { receipt = actor .. ":" .. receipt, settled = false }
						captured = true
					end
				end
				current.receipts[receipt] = binding
				slice.companions = current
				local committed, err = port.personal:commit(token, token.data.stateRevision, envelope, nil)
				if not committed or err then
					return { ok = false, reason = err or "SAVE_FAILED" }
				end
				port.install(committed)
				local recovered = settle(actor)
				return {
					ok = recovered.ok,
					reason = recovered.reason,
					stateVersion = committed.data.stateRevision,
					data = {
						captured = captured,
						species = species.id,
						level = if action == "survival-coop:tame-hit" then 1 else nil,
						max = 1,
						full = true,
					},
				}
			end
			local binding = args[1] .. ":" .. args[2]
			if current.captures and current.captures[args[2]] and not current.captures[args[2]].settled then
				return { ok = false, reason = "CAPTURE_PENDING" }
			end
			if current.receipts[receipt] then
				return {
					ok = current.receipts[receipt] == binding,
					reason = if current.receipts[receipt] ~= binding then "REQUEST_CONFLICT" else nil,
				}
			end
			local bag = Inventory.fromSave(slice.inventory.bag, catalog)
			current.materials = {}
			for id, item in bag.items do
				current.materials[item.catalogId] = (current.materials[item.catalogId] or 0)
					+ Inventory.available(bag, id)
			end
			local candidate, reason = Companion.command(current, receipt, args[1], args[2], ctx.nowMillis(), rules)
			if not candidate then
				return { ok = false, reason = reason }
			end
			local debit = {}
			for item, quantity in current.materials do
				local remaining = quantity - (candidate.materials[item] or 0)
				local ids = {}
				for id in bag.items do
					table.insert(ids, id)
				end
				table.sort(ids)
				for _, id in ids do
					if bag.items[id].catalogId == item and remaining > 0 then
						local amount = math.min(remaining, Inventory.available(bag, id))
						if amount > 0 then
							debit[id], remaining = amount, remaining - amount
						end
					end
				end
				assert(remaining == 0, "COMPANION_DEBIT_MISMATCH")
			end
			if next(debit) then
				bag = assert(Inventory.reserve(bag, receipt, debit, bag.version))
				bag = assert(Inventory.exchange(bag, catalog, receipt, {}, bag.version))
			end
			candidate.materials = {}
			slice.companions, slice.inventory.bag = candidate, Inventory.save(bag)
			local committed, err = port.personal:commit(token, token.data.stateRevision, envelope, nil)
			if not committed or err then
				return { ok = false, reason = err or "SAVE_FAILED" }
			end
			port.install(committed)
			return { ok = true, stateVersion = committed.data.stateRevision }
		end,
		recover = function(actor: string): any
			return settle(actor)
		end,
		snapshot = function(actor: string): (any?, string?)
			local port = ctx.personalTransfer(actor)
			if not port then
				return nil, "PERSONAL_UNAVAILABLE"
			end
			local slice = port.profile().data.envelope.genres["survival-coop"].data
			local tameable = {}
			local companions = state(slice)
			local ride = nil
			local speed = nil
			for _, row in ctx.content.wildlifeDetails do
				if row.captureClass ~= "never" then
					table.insert(tameable, row.id)
				end
				local pet = if companions.ride then companions.pets[companions.ride] else nil
				if pet and pet.species == row.id and row.mount.enabled then
					-- A worn paid skin of this species dresses the ride; speed stays the species value.
					local skin = nil
					for id in (if ctx.appearance then ctx.appearance(actor) else nil) or {} do
						local rule = (skins or {})[id]
						if rule and rule.species == row.id then
							skin = id
						end
					end
					ride = { species = row.id, id = pet.id, skin = skin }
					speed = row.mount.walkSpeed
				end
			end
			return {
				companions = Data.clone(companions),
				ride = ride,
				walkSpeedStuds = speed,
				animals = {},
				feeds = { rules.feedItem },
				tameable = tameable,
				v2 = true,
			},
				nil
		end,
	}
end
return M
