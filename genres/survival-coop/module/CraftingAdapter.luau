--!strict
-- CraftingAdapter: the survival-coop `crafting` mode instance.
--
-- Personal inventory is backed by the pure Inventory transitions. Other
-- crafting features continue to fail closed until their mechanisms are bound.

local Shared = require("../../../core/domain/genre/Contract")
local Data = require("../../../core/domain/genre/SerializedData")
local Clock = require("../../../core/infra/genre/Clock")
local Wallet = require("../../../core/domain/economy/Wallet")
local Capability = require("../../../core/domain/survival/Capability")
local Content = require("../../../core/domain/survival/Content")
local Vitals = require("../../../core/domain/survival/Vitals")
local Consumption = require("../../../core/domain/survival/Consumption")
local DeathBundle = require("../../../core/domain/survival/DeathBundle")
local Inventory = require("../../../core/domain/inventory/Inventory")
local EntitlementEffects = require("./EntitlementEffects")
local ItemCatalog = require("../../../core/domain/inventory/ItemCatalog")
local Validation = require("../../../core/domain/genre/Validation")
local Workshop = require("./Workshop")
local Skills = require("./Skills")
local Combat = require("./Combat")
local SkillTree = require("../../../core/domain/progression/SkillTree")
local Progression = require("./ProgressionExtension")
local Events = require("../../../core/infra/analytics/Events")

local M = {}

local LIMIT = 1e9
type DeathState =
	{ bundles: DeathBundle.State, worldRevision: string, locations: { [string]: Shared.SurvivalPosition } }

local function catalogOf(content: Content.Document): ItemCatalog.Catalog
	local definitions: { ItemCatalog.Definition } = {}
	for _, item in content.items do
		table.insert(definitions, {
			id = item.id,
			stackMax = item.stackMax,
			weightMilli = item.weightMilli,
			maxDurabilityMilli = item.maxDurabilityMilli,
		})
	end
	return ItemCatalog.new(definitions)
end

export type Config = {
	mode: string,
	currency: string,
	startingBalance: number,
	contentVersion: number,
	survivalDeath: boolean?,
	-- Recorded seed for free craft-crit/latent rolls; absent keeps rolls off.
	craftSeed: number?,
	inventory: {
		content: any,
		carriedContainer: string,
		containers: { [string]: { Inventory.Item } },
		speedPenaltyMilli: number,
	}?,
}
export type Save = { saveVersion: number, balance: number? }
export type WalletPort = {
	balance: (Shared.PlayerId) -> number,
	debit: (Shared.PlayerId, number) -> boolean,
	credit: (Shared.PlayerId, number) -> (),
}

local function bounded(value: any, minimum: number, maximum: number, integer: boolean): boolean
	return type(value) == "number"
		and value == value
		and value >= minimum
		and value <= maximum
		and (not integer or value % 1 == 0)
end

local function copyVitals(raw: any): Vitals.State
	assert(type(raw) == "table" and type(raw.config) == "table", "invalid saved vitals")
	local state = Vitals.new(raw.clockMillis, raw.config)
	for key in raw do
		assert(state[key] ~= nil, "unknown saved vital")
	end
	for key, initial in state do
		assert(type(key) == "string", "invalid vital field")
		local value = raw[key]
		if key == "config" then
			for field in raw.config do
				assert(state.config[field] ~= nil, "unknown saved vital config")
			end
		elseif type(initial) == "boolean" then
			assert(type(value) == "boolean", "invalid saved vital flag")
		elseif key == "zone" then
			assert(value == "safe" or value == "danger", "invalid saved death zone")
		else
			local maximum = if table.find({ "healthMilli", "hungerMilli", "fatigueMilli" }, key)
				then 100000
				else 2 ^ 53 - 1
			assert(ItemCatalog.integer(value, 0, maximum), "invalid saved vital integer")
		end
	end
	assert(raw.hungerRemainder < state.config.hungerMillisPerUnit, "invalid hunger remainder")
	assert(raw.starvationRemainder < state.config.starvationMillisPerUnit, "invalid starvation remainder")
	assert(raw.restRemainder < 1000, "invalid rest remainder")
	local copied = table.clone(raw)
	copied.config = state.config
	return copied
end

--- Crafting config surface. Deliberately disjoint from the wave tuning fields:
--- a config carrying wave numbers in crafting mode is a selection mistake, not
--- a silently ignored leftover.
function M.validateConfig(data: Shared.ConfigData): { string }
	local errors: { string } = {}
	local allowed = {
		mode = true,
		currency = true,
		startingBalance = true,
		contentVersion = true,
		inventory = true,
		survivalDeath = true,
		craftSeed = true,
	}
	if data.craftSeed ~= nil and not bounded(data.craftSeed, 0, 2 ^ 53 - 1, true) then
		table.insert(errors, "craftSeed: invalid bounded integer")
	end
	if data.survivalDeath ~= nil and type(data.survivalDeath) ~= "boolean" then
		table.insert(errors, "survivalDeath: expected boolean")
	end
	if
		data.survivalDeath == true
		and (
			type(data.inventory) ~= "table"
			or type(data.inventory.content) ~= "table"
			or data.inventory.content.vitals == nil
		)
	then
		table.insert(errors, "survivalDeath: requires inventory vitals")
	end
	if data.mode ~= "crafting" then
		table.insert(errors, "mode: expected crafting")
	end
	if data.currency ~= "Coins" then
		table.insert(errors, "currency: expected Coins")
	end
	if not bounded(data.startingBalance, 0, LIMIT, true) then
		table.insert(errors, "startingBalance: invalid bounded integer")
	end
	if data.contentVersion ~= 1 and data.contentVersion ~= 2 then
		table.insert(errors, "contentVersion: unsupported content version")
	end
	if data.inventory ~= nil then
		local ok, reason = pcall(function()
			local input = data.inventory
			assert(type(input) == "table", "expected mapping")
			for key in input do
				assert(
					table.find({ "content", "carriedContainer", "containers", "speedPenaltyMilli" }, key),
					"unknown inventory key"
				)
			end
			local content, contentErrors = Content.canonicalize(input.content)
			assert(content ~= nil, table.concat(contentErrors, "; "))
			assert(content.version == data.contentVersion, "contentVersion: catalog version mismatch")
			assert(ItemCatalog.integer(input.speedPenaltyMilli, 0, 1000), "invalid speed penalty")
			local catalog = catalogOf(content)
			assert(type(input.containers) == "table", "containers: expected mapping")
			assert(
				ItemCatalog.identity(input.carriedContainer) and input.containers[input.carriedContainer] ~= nil,
				"carriedContainer: expected one configured container"
			)
			local count = 0
			local itemIds: { [string]: boolean } = {}
			for id, items in input.containers do
				count += 1
				assert(count <= 8 and ItemCatalog.identity(id), "invalid personal containers")
				assert(Validation.dense(items, content.limits.slots), "initial items: expected dense list")
				local state = Inventory.new(id, {
					contentVersion = if content.version == 2 then 2 else nil,
					slots = content.limits.slots,
					softWeightMilli = content.limits.softWeightMilli,
					hardWeightMilli = content.limits.hardWeightMilli,
					speedPenaltyMilli = input.speedPenaltyMilli,
				})
				for _, item in items do
					assert(not itemIds[item.itemId], "duplicate initial item identity")
					itemIds[item.itemId] = true
					local added, err = Inventory.add(state, catalog, item, state.version)
					assert(added ~= nil, err)
					state = added
				end
			end
			assert(count > 0, "containers: empty")
		end)
		if not ok then
			table.insert(errors, "inventory: " .. tostring(reason))
		end
	end
	for key in data do
		if not allowed[key] then
			table.insert(errors, key .. ": unknown config key")
		end
	end
	table.sort(errors)
	return errors
end

--- The previous crafting slice marker. A v2 save predates craft mastery: it
--- carries no `skills` field and upgrades losslessly to the current marker.
M.PREVIOUS_SAVE_VERSION = 2

--- Pure upgrade step: reads a v2 crafting save and yields the current (v3)
--- shape. Mastery starts empty (filled from content at load). A current save is
--- returned as an isolated copy; any other marker is returned unchanged so the
--- validator refuses it by name.
function M.upgradeSave(data: Shared.StateData): Shared.StateData
	local copy = table.clone(data)
	if data.saveVersion == M.PREVIOUS_SAVE_VERSION and data.skills == nil then
		copy.saveVersion = Capability.describe("crafting").saveVersion
	end
	return copy
end

--- Crafting saves carry their own `saveVersion`. A wave save (no marker) and a
--- crafting save can never be read as each other, and a save from a newer
--- crafting writer is refused rather than downgraded. A v2 save is read
--- through `upgradeSave`.
function M.validateSave(raw: Shared.StateData): { string }
	local errors: { string } = {}
	local descriptor = Capability.describe("crafting")
	if raw.saveVersion == M.PREVIOUS_SAVE_VERSION and raw.skills ~= nil then
		table.insert(errors, "skills: not valid in a v2 crafting save")
	end
	local data = M.upgradeSave(raw)
	if data.saveVersion ~= descriptor.saveVersion then
		table.insert(
			errors,
			string.format(
				"saveVersion: unsupported crafting save %s (this writer is %d)",
				tostring(data.saveVersion),
				descriptor.saveVersion
			)
		)
	end
	if data.balance ~= nil and not bounded(data.balance, 0, LIMIT, true) then
		table.insert(errors, "balance: invalid integer")
	end
	if data.inventory ~= nil and type(data.inventory) ~= "table" then
		table.insert(errors, "inventory: expected saved containers")
	end
	if data.vitals ~= nil then
		local ok, reason = pcall(copyVitals, data.vitals)
		if not ok then
			table.insert(errors, "vitals: " .. tostring(reason))
		end
	end
	if data.workshop ~= nil and type(data.workshop) ~= "table" then
		table.insert(errors, "workshop: expected saved jobs")
	end
	if data.death ~= nil and type(data.death) ~= "table" then
		table.insert(errors, "death: expected saved aggregate")
	end
	if data.skills ~= nil and (type(data.skills) ~= "table" or data.skills.saveVersion ~= Skills.SAVE_VERSION) then
		table.insert(errors, "skills: expected saved mastery")
	end
	if data.combat ~= nil then
		if
			type(data.combat) ~= "table"
			or data.combat.version ~= 1
			or not ItemCatalog.integer(data.combat.nextAttack, 0, 2 ^ 53 - 1)
			or type(data.combat.receipts) ~= "table"
		then
			table.insert(errors, "combat: invalid receipt state")
		else
			local count = 0
			for id, receipt in data.combat.receipts do
				count += 1
				if
					not ItemCatalog.identity(id)
					or type(receipt) ~= "table"
					or type(receipt.charged) ~= "boolean"
					or type(receipt.binding) ~= "string"
					or #receipt.binding > 256
					or (receipt.reason ~= nil and type(receipt.reason) ~= "string")
				then
					table.insert(errors, "combat: invalid charge receipt")
				end
			end
			if count > 4096 then
				table.insert(errors, "combat: receipt limit")
			end
		end
	end
	if data.progression ~= nil and (type(data.progression) ~= "table" or type(data.progression.mastery) ~= "table") then
		table.insert(errors, "progression: invalid specialization state")
	end
	for key in data do
		if
			key ~= "saveVersion"
			and key ~= "balance"
			and key ~= "inventory"
			and key ~= "vitals"
			and key ~= "workshop"
			and key ~= "death"
			and key ~= "combat"
			and key ~= "skills"
			and key ~= "progression"
			and key ~= "companions"
			and key ~= "journal"
			and key ~= "journalOutcomes"
			and key ~= "journalGrants"
			and key ~= "missionItems"
			and key ~= "multistorey"
			and key ~= "buildOutcomes"
			and key ~= "audioSettings"
			and key ~= "market"
			and key ~= "brawl"
		then
			table.insert(errors, key .. ": unknown save key")
		end
	end
	table.sort(errors)
	return errors
end

--- Maps a wave-mode action id to the crafting feature that would own it, so a
--- refusal names the missing mechanism instead of a bare "unknown action".
local ACTION_FEATURE: { [string]: string } = {
	["buy-defense"] = "placement",
	["defend-active"] = "wildlife",
}

-- analytics is optional: when supplied, committed craft completions and
-- survival deaths emit core analytics events after apply/notify.
function M.new(
	config: Config,
	services: Shared.Services,
	suppliedWallet: WalletPort?,
	analytics: Events.Emitter?
): Shared.Instance
	assert(#M.validateConfig(config :: any) == 0, "invalid crafting config")
	config = table.clone(config)
	assert(suppliedWallet == nil or config.startingBalance == 0, "composition requires zero crafting starting balance")
	local descriptor = Capability.describe("crafting")
	type Player = {
		wallet: Wallet.Wallet?,
		inventory: { [string]: Inventory.State }?,
		vitals: Vitals.State?,
		workshop: Workshop.State?,
		death: DeathState?,
		combat: any?,
		progression: any?,
		companions: any?,
		personalExtensions: { [string]: any }?,
		skills: Skills.State?,
	}
	local players: { [string]: Player } = {}
	local inventoryConfig = config.inventory
	local content = if inventoryConfig
		then services.survivalContent or Content.canonicalize(inventoryConfig.content)
		else nil
	local catalog = if content then catalogOf(content) else {}
	local mastery = if content then Skills.catalog(content) else nil
	local function inventories(saved: Shared.StateData?): { [string]: Inventory.State }?
		if not inventoryConfig or not content then
			assert(not saved or saved.inventory == nil, "inventory config missing")
			return nil
		end
		local result: { [string]: Inventory.State } = {}
		local ids: { [string]: boolean } = {}
		if saved then
			assert(type(saved.inventory) == "table", "inventory save missing")
			for id in saved.inventory do
				assert(inventoryConfig.containers[id] ~= nil, "unknown saved container")
			end
		end
		for id, items in inventoryConfig.containers do
			local state = Inventory.new(id, {
				contentVersion = if content.version == 2 then 2 else nil,
				kind = if content.version == 2 and id == "bag" then "bag" else nil,
				slots = content.limits.slots,
				softWeightMilli = content.limits.softWeightMilli,
				hardWeightMilli = content.limits.hardWeightMilli,
				speedPenaltyMilli = inventoryConfig.speedPenaltyMilli,
			})
			if saved then
				local raw = saved.inventory[id]
				if content.version == 2 and id == "bag" then
					raw = EntitlementEffects.migrateBag(raw, content.version, content.limits.slots)
				end
				local restored = Inventory.fromSave(raw, catalog)
				assert(restored.id == id, "container identity mismatch")
				for key, value in state.limits do
					assert(restored.limits[key] == value, "container limit mismatch")
				end
				state = restored
			else
				for _, item in items do
					local added, err = Inventory.add(state, catalog, item, state.version)
					assert(added ~= nil, err)
					state = added
				end
			end
			for itemId in state.items do
				assert(not ids[itemId], "duplicate saved item identity")
				ids[itemId] = true
			end
			result[id] = state
		end
		return result
	end
	local wallet: WalletPort = suppliedWallet
		or {
			balance = function(id)
				return (players[id].wallet :: Wallet.Wallet):balance(config.currency)
			end,
			debit = function(id, amount)
				return (players[id].wallet :: Wallet.Wallet):debit(config.currency, amount)
			end,
			credit = function(id, amount)
				(players[id].wallet :: Wallet.Wallet):credit(config.currency, amount)
			end,
		}
	local lastAt = services.now()
	assert(type(lastAt) == "number" and lastAt == lastAt and math.abs(lastAt) < math.huge, "invalid initial clock")
	-- Events observed while staging one command; emitted only once it commits.
	local observed: { { name: string, fields: Events.Fields } } = {}
	local function savePlayer(
		id: string,
		containers: { [string]: Inventory.State }?,
		vitals: Vitals.State?,
		workshop: Workshop.State?,
		skills: Skills.State?
	): Shared.StateData
		local saved: Shared.StateData = {
			saveVersion = descriptor.saveVersion,
			balance = if suppliedWallet then nil else wallet.balance(id),
			vitals = if vitals then copyVitals(vitals) else nil,
			workshop = if workshop then Workshop.save(workshop) else nil,
			combat = if players[id] and players[id].combat then Data.clone(players[id].combat) else nil,
			progression = if players[id] and players[id].progression then Data.clone(players[id].progression) else nil,
			companions = if players[id] and players[id].companions then Data.clone(players[id].companions) else nil,
			skills = if skills then Skills.save(skills) else nil,
		}
		if containers then
			saved.inventory = {}
			for name, state in containers do
				saved.inventory[name] = Inventory.save(state)
			end
		end
		local retained: { [string]: any } = if players[id] then players[id].personalExtensions or {} else {}
		for key, value in retained do
			saved[key] = Data.clone(value)
		end
		return saved
	end
	local function stageRaw(
		id: string,
		action: string,
		args: { any },
		context: Shared.CommandContext?,
		player: Player
	): Shared.CommandStage?
		if action == "combat-damage" then
			action = "vitals-damage"
		end
		if not player or not player.inventory then
			return nil
		end
		if action == "dodge" or action == "guard" or action == "skill-learn" or action == "skill-reset" then
			local policy = if content then (content :: any).progressionPolicy else nil
			local err: string? = nil
			local combat = table.clone(player.combat or { version = 1, nextAttack = 0, receipts = {} })
			local progression = player.progression
			local now = if context then context.nowMillis else nil
			if not policy or not progression then
				err = "PROGRESSION_NOT_CONFIGURED"
			elseif not now or not context or context.actorId ~= id then
				err = "DURABLE_COMMAND_REQUIRED"
			elseif not player.vitals or player.vitals.healthMilli == 0 then
				err = "NOT_ALIVE"
			elseif action == "skill-learn" then
				progression, err = SkillTree.learn(content, progression, args[1])
			elseif action == "skill-reset" then
				local jobs = 0
				for _, entry in pairs(if player.workshop then player.workshop.entries else {}) do
					if entry.job.state ~= "Committed" and entry.job.state ~= "Cancelled" then
						jobs += 1
					end
				end
				progression, err = SkillTree.reset(progression, args[1], now < combat.nextAttack, jobs)
			elseif not policy.combat then
				err = "COMBAT_NOT_CONFIGURED"
			elseif now < (combat.defenseReadyAt or 0) then
				err = "RECOVERY"
			elseif now < combat.nextAttack then
				err = "WINDUP_OR_RECOVERY"
			else
				local rule = policy.combat
				combat.defense = Combat.window(
					combat.defense or Combat.defense(),
					action,
					now,
					if action == "dodge" then rule.dodgeMillis else rule.guardMillis
				)
				combat.defense.guardPermille = rule.guardPermille
				combat.defenseReadyAt = now + rule.defenseRecoveryMillis
			end
			local saved = savePlayer(id, player.inventory, player.vitals, player.workshop, player.skills)
			if not err then
				saved.combat, saved.progression = combat, progression
			end
			return {
				result = { ok = err == nil, reason = err },
				data = saved,
				apply = function()
					if not err then
						player.combat, player.progression = combat, progression
					end
				end,
			}
		end
		if string.sub(action, 1, 6) == "craft-" then
			local candidate: Workshop.Candidate? = nil
			local err: string? = nil
			if not context or context.actorId ~= id or context.nowMillis == nil then
				err = "DURABLE_COMMAND_REQUIRED"
			elseif not content or not inventoryConfig or not player.workshop then
				err = "CRAFTING_NOT_CONFIGURED"
			elseif player.vitals and (not player.vitals.online or player.vitals.healthMilli == 0) then
				err = "NOT_ALIVE"
			else
				local jobs = if context.expiredBeforeEpoch ~= nil
					then Workshop.prune(player.workshop, context.expiredBeforeEpoch)
					else Workshop.snapshot(player.workshop)
				local bag = player.inventory[inventoryConfig.carriedContainer]
				if action == "craft-reserve" then
					if player.progression then
						for _, detail in (content :: any).recipeDetails do
							if detail.id == args[1] then
								if player.progression.level < detail.minCharacterLevel then
									err = "CHARACTER_LEVEL_GATE"
								end
								for _, node in detail.skillNodes do
									if not player.progression.paid[node] then
										err = "SKILL_NODE_GATE"
									end
								end
							end
						end
					end
					local port = services.survivalSpatial
					local station = if port and port.station then port.station(id, args[2]) else nil
					if not err then
						candidate, err = Workshop.reserve(
							jobs,
							bag,
							context,
							content,
							"content-v" .. tostring(config.contentVersion),
							args[1],
							context.nowMillis,
							{
								carriedContainer = inventoryConfig.carriedContainer,
								stationId = if station then args[2] else nil,
								stationKind = if station then station.kind else nil,
								inReach = station ~= nil and station.reachable,
							},
							-- Rolls read only the recorded seed and job inputs, never ownership.
							if config.craftSeed ~= nil then { seed = config.craftSeed } else nil
						)
					end
				else
					candidate, err =
						Workshop.transition(jobs, bag, context, args[1], string.sub(action, 7), context.nowMillis)
				end
				if candidate and not err and action == "craft-complete" and player.progression then
					local job = candidate.jobs.entries[candidate.jobId].job
					local inputs = {}
					local recorded = true
					for _, item in job.inputs do
						if not item.material then
							recorded = false
							break
						end
						local material = table.clone(item.material)
						material.quantity = item.quantity
						table.insert(inputs, material)
					end
					if recorded then
						local material
						material, err = Progression.craft(content, player.progression, job.recipeId, inputs)
						if material then
							for _, output in job.outputs do
								if output.catalogId == material.item then
									output.material = material
									candidate.inventory.items[output.itemId].material = material
								end
							end
						end
					end
					if err then
						candidate = nil
					end
				end
			end
			local states = table.clone(player.inventory)
			local jobs = player.workshop
			if candidate then
				states[candidate.inventory.id] = candidate.inventory
				jobs = candidate.jobs
				err = candidate.reason
			end
			local vitals = if candidate
					and err == nil
					and player.vitals
				then Vitals.action(player.vitals)
				else player.vitals
			-- Craft mastery: a completion that commits its job earns the recipe's
			-- content-declared XP, capped by the best usable tool in the bag.
			local skills = player.skills
			if
				candidate
				and err == nil
				and action == "craft-complete"
				and mastery
				and skills
				and content
				and candidate.jobs.entries[candidate.jobId].job.state == "Committed"
			then
				local recipeId = candidate.jobs.entries[candidate.jobId].job.recipeId
				for _, recipe in content.recipes do
					if recipe.id == recipeId and recipe.skill then
						local tier = Skills.toolTier(mastery, recipe.skill.id, candidate.inventory)
						skills = (Skills.award(mastery, skills, recipe.skill.id, recipe.skill.xp, tier))
					end
				end
			end
			if candidate and err == nil and action == "craft-complete" then
				local entry = candidate.jobs.entries[candidate.jobId]
				if entry and entry.job.state == "Committed" then
					table.insert(observed, {
						name = "craft",
						fields = {
							actorId = id,
							recipeId = entry.job.recipeId,
							jobId = candidate.jobId,
							atMillis = if context then context.nowMillis else nil,
						},
					})
				end
			end
			local data = savePlayer(id, states, vitals, jobs, skills)
			local progression = player.progression
			if progression and candidate and not err and action == "craft-complete" and content then
				local recipeId = candidate.jobs.entries[candidate.jobId].job.recipeId
				for _, category in (content :: any).skillCategories do
					local matches = table.find(category.entryActions, recipeId) ~= nil
					for _, detail in (content :: any).recipeDetails do
						if detail.id == recipeId then
							for _, node in detail.skillNodes do
								matches = matches or string.match(node, "^(.*)_%d+$") == category.id
							end
						end
					end
					if matches then
						progression = SkillTree.award(
							progression,
							(content :: any).progressionPolicy.tree,
							category.id,
							"craft:" .. candidate.jobId .. ":" .. category.id
						)
					end
				end
				data.progression = progression
			end
			return {
				result = {
					ok = candidate ~= nil and err == nil,
					reason = err,
					data = if candidate then { jobId = candidate.jobId } else nil,
				},
				data = data,
				apply = function()
					if candidate then
						player.inventory = states
						player.workshop = jobs
						player.vitals = vitals
						player.skills = skills
						player.progression = progression
					end
				end,
			}
		end
		if
			action == "food"
			or action == "rest"
			or action == "respawn"
			or action == "vitals-damage"
			or action == "rest-stop"
		then
			local nextVitals: Vitals.State? = nil
			local nextBag: Inventory.State? = nil
			local err: string? = nil
			if not player.vitals or not content or not inventoryConfig then
				err = "VITALS_NOT_CONFIGURED"
			else
				local nowMillis = if context and context.nowMillis then context.nowMillis else Clock.millis(lastAt)
				local advanced = Vitals.advance(player.vitals, nowMillis)
				if action == "vitals-damage" or action == "rest-stop" then
					if not advanced.online or advanced.healthMilli == 0 then
						err = "NOT_ALIVE"
					else
						local damage = args[1]
						local defense = if player.combat then player.combat.defense else nil
						local strikeAt = args[2] or nowMillis
						if action == "vitals-damage" and defense then
							if
								defense.dodgeStart
								and strikeAt >= defense.dodgeStart
								and strikeAt < defense.dodgeEnd
							then
								damage = 0
							elseif
								defense.guardStart
								and strikeAt >= defense.guardStart
								and strikeAt < defense.guardEnd
							then
								damage = damage * defense.guardPermille // 1000
							end
						end
						nextVitals = if action == "vitals-damage"
							then Vitals.damage(advanced, damage)
							else Vitals.stopRest(advanced)
						if nextVitals and nextVitals.healthMilli == 0 then
							table.insert(observed, {
								name = "death",
								fields = { actorId = id, cause = action, atMillis = nowMillis },
							})
						end
					end
				elseif action == "food" then
					nextBag, nextVitals, err = Consumption.consume(
						player.inventory[inventoryConfig.carriedContainer],
						advanced,
						content,
						args[1]
					)
				elseif action == "rest" then
					local fire = if services.survivalSpatial
						then services.survivalSpatial.campfire(id, args[1])
						else nil
					if not advanced.online or advanced.healthMilli == 0 then
						err = "NOT_ALIVE"
					elseif not fire or not fire.reachable then
						err = "CAMPFIRE_UNREACHABLE"
					else
						nextVitals = Vitals.rest(advanced, { campfireId = args[1], reachable = true })
					end
				elseif not advanced.online or advanced.healthMilli ~= 0 then
					err = "NOT_DEAD"
				else
					nextVitals = Vitals.respawn(advanced, {
						healthMilli = args[1],
						hungerMilli = args[2],
						fatigueMilli = args[3],
					})
				end
			end
			local accepted = nextVitals ~= nil and err == nil
			local candidate = table.clone(player.inventory)
			if nextBag and inventoryConfig then
				candidate[inventoryConfig.carriedContainer] = nextBag
			end
			local progression = player.progression
			if accepted and action == "food" and progression and content and context then
				progression = SkillTree.award(
					progression,
					(content :: any).progressionPolicy.tree,
					"survival",
					tostring(context.sessionEpoch) .. ":" .. context.requestId
				)
			end
			local saved = savePlayer(
				id,
				candidate,
				if accepted then nextVitals else player.vitals,
				player.workshop,
				player.skills
			)
			saved.progression = progression
			return {
				result = { ok = accepted, reason = err },
				data = saved,
				apply = function()
					if accepted then
						player.inventory = candidate
						player.vitals = nextVitals
						player.progression = progression
					end
				end,
			}
		end
		if string.sub(action, 1, 10) ~= "inventory-" then
			return nil
		end
		local states = table.clone(player.inventory)
		local source = states[args[1]]
		local nextState: Inventory.State? = nil
		local err: string? = nil
		if not source then
			err = "UNKNOWN_CONTAINER"
		elseif action == "inventory-move" then
			local target = states[args[2]]
			if not target then
				err = "UNKNOWN_CONTAINER"
			else
				local moved: Inventory.State?
				nextState, moved, err =
					Inventory.move(source, target, catalog, args[3], args[4], args[5], args[6], args[7])
				if moved then
					states[args[2]] = moved
				end
			end
		elseif action == "inventory-split" then
			nextState, err = Inventory.split(source, catalog, args[2], args[3], args[4], args[5])
		elseif action == "inventory-merge" then
			nextState, err = Inventory.merge(source, catalog, args[2], args[3], args[4], args[5])
		elseif action == "inventory-reserve" then
			nextState, err = Inventory.reserve(source, args[2], { [args[3]] = args[4] }, args[5])
		elseif action == "inventory-release" then
			nextState, err = Inventory.release(source, args[2], args[3])
		elseif action == "inventory-consume" then
			nextState, err = Inventory.consume(source, args[2], args[3], args[4])
		else
			return nil
		end
		if nextState then
			states[args[1]] = nextState
			-- Stable identities are unique across this player's personal containers.
			local seen: { [string]: boolean } = {}
			for _, state in states do
				for itemId in state.items do
					if seen[itemId] then
						err = "DUPLICATE_ITEM_ID"
					end
					seen[itemId] = true
				end
			end
		end
		local accepted = nextState ~= nil and err == nil
		local candidate = if accepted then states else player.inventory
		return {
			result = { ok = accepted, reason = err },
			data = savePlayer(id, candidate, player.vitals, player.workshop, player.skills),
			apply = function()
				if accepted then
					player.inventory = candidate
				end
			end,
		}
	end
	local function stage(
		id: string,
		action: string,
		args: { any },
		context: Shared.CommandContext?
	): Shared.CommandStage?
		local live = players[id]
		if not live then
			return nil
		end
		if not config.survivalDeath then
			return stageRaw(id, action, args, context, live)
		end
		local port = services.survivalDeath
		if action == "combat-damage" then
			action = "vitals-damage"
		end
		if
			not context
			or context.actorId ~= id
			or not context.serverId
			or not context.nowMillis
			or not port
			or not live.vitals
			or not live.inventory
			or not inventoryConfig
		then
			return nil
		end
		local now = context.nowMillis
		local candidate: Player = table.clone(live)
		candidate.inventory = table.clone(live.inventory)
		local priorDeath = live.death
		local bundles = if priorDeath
			then DeathBundle.snapshot(priorDeath.bundles)
			else DeathBundle.new(id, context.serverId, inventoryConfig.carriedContainer, now)
		local locations: { [string]: Shared.SurvivalPosition } = {}
		if priorDeath then
			if priorDeath.worldRevision ~= port.worldRevision then
				return nil
			end
			for key, position in priorDeath.locations do
				locations[key] = table.clone(position)
			end
		end
		-- Session supplies this identity only after the profile ownership lock.
		-- Same revision preserves world coordinates; mismatches never discard data.
		bundles.serverId = context.serverId
		local authority = { ownerId = id, serverId = context.serverId }
		local advanced = Vitals.advance(live.vitals, now)
		local damageResult: Shared.Result? = nil
		if action == "vitals-damage" then
			if not advanced.online or advanced.healthMilli == 0 then
				damageResult = { ok = false, reason = "NOT_ALIVE" }
			else
				local damage = args[1]
				local defense = if live.combat then live.combat.defense else nil
				local strikeAt = args[2] or now
				if defense then
					if defense.dodgeStart and strikeAt >= defense.dodgeStart and strikeAt < defense.dodgeEnd then
						damage = 0
					elseif defense.guardStart and strikeAt >= defense.guardStart and strikeAt < defense.guardEnd then
						damage = damage * defense.guardPermille // 1000
					end
				end
				advanced = Vitals.damage(advanced, damage)
				damageResult = { ok = true }
			end
		end
		local bag = live.inventory[inventoryConfig.carriedContainer]
		if live.vitals.healthMilli > 0 and advanced.healthMilli == 0 then
			local equipment, position = port.equipment(id), port.position(id)
			if not equipment or not position then
				return nil
			end
			for _, axis in { "x", "y", "z" } do
				if not Validation.finite(position[axis]) or math.abs(position[axis]) > 1000000 then
					return nil
				end
			end
			local dropped, remaining =
				DeathBundle.drop(bundles, bag, catalog, advanced, authority, bundles.lastSequence + 1, equipment, now)
			if not dropped or not remaining then
				return nil
			end
			bundles, bag = dropped, remaining
			local deathId = "death:" .. tostring(bundles.lastSequence)
			local droppedItems = 0
			if bundles.bundles[deathId] then
				locations[deathId] = table.clone(position)
				for _ in bundles.bundles[deathId].inventory.items do
					droppedItems += 1
				end
			end
			table.insert(observed, {
				name = "death",
				fields = {
					actorId = id,
					cause = action,
					deathId = deathId,
					droppedItems = droppedItems,
					atMillis = now,
				},
			})
		end
		local expired = DeathBundle.expire(bundles, authority, now)
		if not expired then
			return nil
		end
		bundles = expired
		for deathId in locations do
			if not bundles.bundles[deathId] then
				locations[deathId] = nil
			end
		end
		local result: Shared.Result? = damageResult
		if action == "death-pickup" then
			local position = locations[args[1]]
			if not position or not port.reachable(id, position) then
				result = { ok = false, reason = "BUNDLE_UNREACHABLE" }
			else
				local picked, carried, err =
					DeathBundle.pickup(bundles, bag, catalog, advanced, authority, args[1], now)
				result = { ok = picked ~= nil, reason = err }
				if picked and carried then
					bundles, bag = picked, carried
					locations[args[1]] = nil
				end
			end
		elseif action == "server-vitals-tick" or action == "death-drop" or action == "death-expire" then
			result = { ok = true }
		end
		(candidate.inventory :: { [string]: Inventory.State })[inventoryConfig.carriedContainer] = bag
		candidate.vitals = advanced
		candidate.death = { bundles = bundles, worldRevision = port.worldRevision, locations = locations }
		local inner = if result then nil else stageRaw(id, action, args, context, candidate)
		if not result and not inner then
			return nil
		end
		local data = if inner
			then inner.data
			else savePlayer(id, candidate.inventory, candidate.vitals, candidate.workshop, candidate.skills)
		data.death = { bundles = DeathBundle.save(bundles), worldRevision = port.worldRevision, locations = locations }
		return {
			result = if inner then inner.result else result :: Shared.Result,
			data = data,
			apply = function()
				if inner then
					inner.apply()
				end
				players[id] = candidate
			end,
		}
	end
	-- Emits what one staged command observed exactly once, after Session commits
	-- it (apply on the legacy lane, notify on the fenced personal lane).
	local function tracked(
		id: string,
		action: string,
		args: { any },
		context: Shared.CommandContext?
	): Shared.CommandStage?
		table.clear(observed)
		local candidate = stage(id, action, args, context)
		local events = table.clone(observed)
		table.clear(observed)
		if not candidate or not analytics or #events == 0 or not candidate.result.ok then
			return candidate
		end
		local emitter = analytics
		local sent = false
		local function flush()
			if sent then
				return
			end
			sent = true
			for _, event in events do
				emitter:emit(event.name, event.fields)
			end
		end
		local apply, notify = candidate.apply, candidate.notify
		candidate.apply = function()
			apply()
			flush()
		end
		candidate.notify = function()
			if notify then
				notify()
			end
			flush()
		end
		return candidate
	end
	local function pendingServerEvent(id: string, nowMillis: number): string?
		local player = players[id]
		if not config.survivalDeath or not player or not player.vitals then
			return nil
		end
		local projected = Vitals.advance(player.vitals, nowMillis)
		if player.vitals.healthMilli > 0 and projected.healthMilli == 0 then
			return "death:" .. tostring(if player.death then player.death.bundles.lastSequence + 1 else 1)
		end
		if player.death then
			local expired: { string } = {}
			for deathId, bundle in player.death.bundles.bundles do
				if nowMillis >= bundle.expiresMillis then
					table.insert(expired, deathId)
				end
			end
			table.sort(expired)
			if expired[1] then
				return "expiry:"
					.. expired[1]
					.. ":"
					.. tostring(player.death.bundles.bundles[expired[1]].expiresMillis)
			end
		end
		return nil
	end
	local function loadPlayer(id: string, saved: Shared.StateData?, rebase: boolean): Shared.Result
		if saved ~= nil then
			if
				#M.validateSave(saved) > 0
				or (suppliedWallet == nil and saved.balance == nil)
				or (suppliedWallet ~= nil and saved.balance ~= nil)
			then
				return { ok = false, reason = "invalid save or currency owner" }
			end
		end
		local loaded, containers = pcall(inventories, saved)
		if not loaded then
			return { ok = false, reason = tostring(containers) }
		end
		local validVitals, vitals = pcall(function(): Vitals.State?
			if not content or not content.vitals then
				assert(not saved or saved.vitals == nil, "vitals config missing")
				return nil
			end
			local nowMillis = Clock.millis(lastAt)
			if not saved then
				return Vitals.new(nowMillis, content.vitals)
			end
			local restored = copyVitals(saved.vitals)
			for field, value in content.vitals do
				assert(restored.config[field] == value, "vitals config mismatch")
			end
			-- A saved monotonic origin belongs to its old process. Preserve the
			-- remaining combat cooldown, never simulate unobserved offline time.
			if rebase then
				restored.combatUntilMillis = nowMillis + math.max(0, restored.combatUntilMillis - restored.clockMillis)
				restored.clockMillis = nowMillis
				restored.online = true
				restored.resting = false
			elseif nowMillis > restored.clockMillis then
				local projected = Vitals.advance(restored, nowMillis)
				if not config.survivalDeath or restored.healthMilli == 0 or projected.healthMilli > 0 then
					restored = projected
				end
			end
			return restored
		end)
		if not validVitals then
			return { ok = false, reason = tostring(vitals) }
		end
		local validWorkshop, workshop = pcall(function(): Workshop.State?
			if not containers then
				assert(not saved or saved.workshop == nil, "workshop inventory missing")
				return nil
			end
			return if saved and saved.workshop
				then Workshop.fromSave(saved.workshop, id, containers)
				else Workshop.new(id)
		end)
		if not validWorkshop then
			return { ok = false, reason = tostring(workshop) }
		end
		local validSkills, skills = pcall(function(): Skills.State?
			if not mastery then
				assert(not saved or saved.skills == nil, "skills config missing")
				return nil
			end
			return if saved and saved.skills then Skills.fromSave(saved.skills, mastery) else Skills.new(mastery)
		end)
		if not validSkills then
			return { ok = false, reason = tostring(skills) }
		end
		local validDeath, death = pcall(function(): DeathState?
			if not saved or saved.death == nil then
				return nil
			end
			assert(config.survivalDeath and services.survivalDeath, "death config missing")
			local bundles = DeathBundle.fromSave(saved.death.bundles, catalog)
			assert(
				saved.death.worldRevision == services.survivalDeath.worldRevision or next(bundles.bundles) == nil,
				"WORLD_REVISION_MISMATCH"
			)
			assert(
				bundles.ownerId == id and inventoryConfig and bundles.carriedId == inventoryConfig.carriedContainer,
				"death ownership mismatch"
			)
			local locations: { [string]: Shared.SurvivalPosition } = {}
			for deathId in bundles.bundles do
				local position = saved.death.locations[deathId]
				assert(type(position) == "table", "bundle location missing")
				for _, axis in { "x", "y", "z" } do
					assert(
						Validation.finite(position[axis]) and math.abs(position[axis]) <= 1000000,
						"invalid death position"
					)
				end
				locations[deathId] = table.clone(position)
			end
			return { bundles = bundles, worldRevision = services.survivalDeath.worldRevision, locations = locations }
		end)
		if not validDeath then
			return { ok = false, reason = tostring(death) }
		end
		players[id] = {
			inventory = containers,
			vitals = vitals,
			workshop = workshop,
			death = death,
			combat = if saved then saved.combat else nil,
			progression = if saved and saved.progression
				then SkillTree.copy(saved.progression)
				else if content and (content :: any).progressionPolicy
					then SkillTree.new(content, (content :: any).progressionPolicy.tree)
					else nil,
			companions = if saved then saved.companions else nil,
			skills = skills,
			wallet = if suppliedWallet
				then nil
				else Wallet.new({ [config.currency] = if saved then saved.balance else config.startingBalance }),
		}
		local retained = {}
		for _, key in
			{
				"journal",
				"journalOutcomes",
				"journalGrants",
				"missionItems",
				"multistorey",
				"buildOutcomes",
				"audioSettings",
				"market",
				"brawl",
			}
		do
			if saved and saved[key] ~= nil then
				retained[key] = Data.clone(saved[key])
			end
		end
		players[id].personalExtensions = retained
		local loadedCompanions = players[id].companions
		if rebase and loadedCompanions then
			local companions = Data.clone(loadedCompanions)
			companions.lastMillis = Clock.millis(lastAt)
			players[id].companions = companions
		end
		return { ok = true }
	end
	return {
		pendingServerEvent = pendingServerEvent,
		join = function(id, saved)
			if players[id] ~= nil then
				return { ok = false, reason = "already joined" }
			end
			return loadPlayer(id, saved, true)
		end,
		hydrate = function(id, saved)
			if not players[id] then
				return { ok = false, reason = "not joined" }
			end
			return loadPlayer(id, saved, false)
		end,
		prepareLeave = function(id)
			local player = players[id]
			if player and player.vitals then
				if config.survivalDeath then
					local nowMillis = Clock.millis(services.now())
					assert(pendingServerEvent(id, nowMillis) == nil, "DURABLE_VITALS_TICK_REQUIRED")
					player.vitals = Vitals.disconnect(player.vitals, nowMillis)
				else
					player.vitals = Vitals.disconnect(player.vitals, Clock.millis(lastAt))
				end
			end
		end,
		leave = function(id)
			players[id] = nil
		end,
		stageCommand = tracked,
		dispatch = function(id, action, args)
			if players[id] == nil then
				return { ok = false, reason = "not joined" }
			end
			local staged = tracked(id, action, args)
			if staged then
				staged.apply()
				return staged.result
			end
			local feature = ACTION_FEATURE[action]
			if feature == nil then
				return { ok = false, reason = "unknown action" }
			end
			local supported, reason = Capability.assertSupported("crafting", feature)
			if not supported then
				return { ok = false, reason = reason }
			end
			-- Unreachable while `implemented` is empty. When a later task lands a
			-- mechanism it replaces this branch with the real dispatch; it must
			-- never return ok = true from here.
			return { ok = false, reason = "crafting: action has no implementation bound" }
		end,
		advance = function(now)
			assert(bounded(now, lastAt, math.huge, false) and now < math.huge, "invalid authoritative time")
			lastAt = now
			for _, player in players do
				if player.vitals then
					local projected = Vitals.advance(player.vitals, Clock.millis(now))
					if not config.survivalDeath or player.vitals.healthMilli == 0 or projected.healthMilli > 0 then
						player.vitals = projected
					end
				end
			end
		end,
		snapshot = function(id)
			if players[id] == nil then
				return {}
			end
			local snapshot: Shared.StateData = {
				mode = descriptor.mode,
				saveVersion = descriptor.saveVersion,
				actionVersion = descriptor.actionVersion,
				contentVersion = config.contentVersion,
				balance = wallet.balance(id),
				combat = players[id].combat,
				progression = players[id].progression,
				missingFeatures = Capability.missingFeatures("crafting"),
				vitals = if players[id].vitals then copyVitals(players[id].vitals) else nil,
				workshop = if players[id].workshop
					then Workshop.snapshot(players[id].workshop :: Workshop.State)
					else nil,
				skills = if players[id].skills and mastery
					then {
						displayLevel = Skills.displayLevel(mastery, players[id].skills :: Skills.State),
						state = Skills.snapshot(players[id].skills :: Skills.State),
					}
					else nil,
				deathBundles = if players[id].death
					then DeathBundle.snapshot((players[id].death :: DeathState).bundles)
					else nil,
			}
			if players[id].inventory then
				snapshot.inventory = {}
				for name, state in players[id].inventory :: { [string]: Inventory.State } do
					local view: any = Inventory.snapshot(state)
					view.weightMilli = Inventory.weight(state, catalog)
					view.speedMultiplierMilli = Inventory.speedMultiplierMilli(state, catalog)
					view.kind = if inventoryConfig and name == inventoryConfig.carriedContainer
						then "carried"
						else "personal-storage"
					snapshot.inventory[name] = view
					if view.kind == "carried" then
						snapshot.carriedWeightMilli = view.weightMilli
						snapshot.speedMultiplierMilli = view.speedMultiplierMilli
					end
				end
			end
			if players[id].vitals then
				snapshot.vitalsMovementMilli = Vitals.movementMilli(players[id].vitals :: Vitals.State)
			end
			return snapshot
		end,
		save = function(id)
			local player = players[id]
			assert(player ~= nil, "player not joined")
			local saved = savePlayer(id, player.inventory, player.vitals, player.workshop, player.skills)
			if player.death then
				saved.death = {
					bundles = DeathBundle.save(player.death.bundles),
					worldRevision = player.death.worldRevision,
					locations = player.death.locations,
				}
			end
			return saved
		end,
	}
end

return M
