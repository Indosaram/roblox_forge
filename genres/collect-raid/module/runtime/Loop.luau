--!strict
-- Loop: pure, engine-free game loop for collect-raid packs. Every id, price,
-- and rule comes from the pack's `Config` (see the `Config` type below); this
-- module holds no pack-specific identifiers.

local Wallet = require("../../../../core/domain/economy/Wallet")
local WeightedRoll = require("../../../../core/domain/economy/WeightedRoll")
local HatchTimer = require("../../../../core/domain/progression/HatchTimer")
local Production = require("../../../../core/domain/economy/Production")
local Vault = require("../../../../core/domain/economy/Vault")
local Merge = require("../../../../core/domain/progression/Merge")
local OfflineIncome = require("../../../../core/domain/economy/OfflineIncome")
local DailyQuest = require("../../../../core/domain/progression/DailyQuest")
local Tutorial = require("../../../../core/domain/progression/Tutorial")

-- Robux grants, mirroring the shapes validated by core/infra/monetization/Catalog.
-- Core's Catalog validator hardcodes the wire names "kaiju" and `kaijuId`, so
-- the grant kind and field keep those names even though genre state uses the
-- neutral "creature" vocabulary everywhere else.
export type GrantKind = "multiplier" | "slots" | "flag" | "kaiju" | "speedup" | "shield" | "serverBoost"

export type Grant = {
	kind: GrantKind,
	value: number?,
	flag: string?,
	kaijuId: string?,
	seconds: number?,
}

-- Keep Grant stable for existing mutable catalog lookup maps.
export type CoinsGrant = { kind: "coins", amount: number? }
export type ProductGrant = Grant | CoinsGrant

export type Incubator = {
	sourceId: string,
	timer: HatchTimer.Timer,
}

export type PlayerState = {
	wallet: Wallet.Wallet,
	incubators: { Incubator },
	creatures: { string },
	vaultedCreatures: { string },
	passes: { [string]: boolean },
	processedPurchases: { string },
	production: Production.Accumulator,
	quest: DailyQuest.State,
	tutorial: Tutorial.State,
	shieldUntil: number,
}

export type IncubatorSnapshot = {
	sourceId: string,
	remaining: number,
}

export type QuestSnapshot = {
	id: string,
	target: number,
	reward: number,
	progress: number,
	claimed: boolean,
}

export type Snapshot = {
	coins: number,
	incubators: { IncubatorSnapshot },
	creatures: { string },
	vaulted: number,
	odds: { [string]: { [string]: number } },
	sourcePrices: { [string]: number },
	quests: { QuestSnapshot },
}

-- Persisted incubator: source id plus the absolute server time the timer completes.
export type SavedIncubator = {
	sourceId: string,
	readyAt: number,
}

export type SaveData = {
	version: number,
	coins: number,
	creatures: { string },
	vaultedCreatures: { string },
	passes: { [string]: boolean },
	processedPurchases: { string },
	incubators: { SavedIncubator },
	tutorial: Tutorial.Save,
	shieldUntil: number,
	lastSeen: number,
	questDay: number,
	quest: {
		progress: { [string]: number },
		claimed: { [string]: boolean },
	},
}

export type SourcePoolEntry = { id: string, weight: number }

export type SourceConfig = {
	id: string,
	displayName: string,
	price: number,
	hatchSeconds: number,
	pool: { SourcePoolEntry },
}

export type CreatureConfig = {
	id: string,
	displayName: string,
	rarity: string,
	coinsPerSecond: number,
}

export type PricingConfig = { growthPerOwned: number }
export type IncomeConfig = { activeSlots: number }
export type SiegeConfig = { period: number, duration: number, maxTake: number }
export type OfflineConfig = { maxSeconds: number, efficiency: number }
export type QuestConfig = { id: string, target: number, reward: number }
export type TutorialStepConfig = { id: string, hint: string, event: string }
export type ProfileConfig = { version: number, defaults: () -> { [string]: any } }

-- Pure data every pack supplies. Field names are genre-neutral: `sources` are
-- the collectible-producing purchases ("eggs" in Kaiju Egg Raiders), and
-- `creatures` are what a source yields when it completes.
export type Config = {
	currency: string,
	startingCoins: number,
	maxIncubators: number,
	pricing: PricingConfig,
	income: IncomeConfig,
	sources: { [string]: SourceConfig },
	sourceOrder: { string },
	creatures: { [string]: CreatureConfig },
	mergeFamilies: { { id: string, displayName: string, rules: { Merge.Rule } } },
	siege: SiegeConfig,
	offline: OfflineConfig,
	dailyQuests: { QuestConfig },
	tutorialSteps: { TutorialStepConfig },
	profile: ProfileConfig,
}

local Loop = {}
Loop.SAVE_CAPACITY = 1024

-- This ledger has no acknowledgement metadata: every marker may still be
-- awaiting a durable commit or receipt redelivery, so none can be evicted safely.

local function rarityOf(config: Config, id: string): string?
	local creatureConfig = config.creatures[id]
	if creatureConfig == nil then
		return nil
	end
	return creatureConfig.rarity
end

-- Coins/sec of every owned creature, highest first, so the slot cap can pick the top N.
local function sortedRates(config: Config, state: PlayerState): { number }
	local rates: { number } = {}
	for _, creatureId in state.creatures do
		local creatureConfig = config.creatures[creatureId]
		if creatureConfig ~= nil then
			table.insert(rates, creatureConfig.coinsPerSecond)
		end
	end
	for _, creatureId in state.vaultedCreatures do
		local creatureConfig = config.creatures[creatureId]
		if creatureConfig ~= nil then
			table.insert(rates, creatureConfig.coinsPerSecond)
		end
	end
	table.sort(rates, function(a, b)
		return a > b
	end)
	return rates
end

-- Owned and vaulted creatures both produce coins; Robux creatures are account-bound
-- but live. Only the `income.activeSlots` highest rates earn; a cap < 1 means no limit.
local function baseRate(config: Config, state: PlayerState): number
	local rates = sortedRates(config, state)
	local slots = config.income.activeSlots
	local limit = if slots >= 1 then math.min(slots, #rates) else #rates
	local rate = 0
	for index = 1, limit do
		rate += rates[index]
	end
	return rate
end

local function dailyRate(config: Config, state: PlayerState): number
	local rate = baseRate(config, state)
	if state.passes.coins2x then
		rate *= 2
	end
	return rate
end

-- Coins/sec before any gamepass multiplier: the top `income.activeSlots` owned
-- creature rates. Exposed for QA/telemetry introspection alongside coinsPerSecond.
function Loop.baseCoinsPerSecond(config: Config, state: PlayerState): number
	return baseRate(config, state)
end

-- Coins/sec actually being earned right now, gamepass multiplier included.
function Loop.coinsPerSecond(config: Config, state: PlayerState): number
	return dailyRate(config, state)
end

function Loop.newPlayer(config: Config, now: number): PlayerState
	assert(type(now) == "number", "Loop.newPlayer requires an explicit time")
	local day = DailyQuest.dayIndex(now)
	return {
		wallet = Wallet.new({ [config.currency] = config.startingCoins }),
		incubators = {},
		creatures = {},
		vaultedCreatures = {},
		passes = {},
		processedPurchases = {},
		production = Production.new(),
		quest = DailyQuest.new(day, config.dailyQuests),
		tutorial = Tutorial.new(config.tutorialSteps),
		shieldUntil = 0,
	}
end

-- Effective incubator cap: the base cap plus any slot game pass.
function Loop.maxIncubators(config: Config, state: PlayerState): number
	if state.passes.vipSlots then
		return config.maxIncubators + 4
	end
	return config.maxIncubators
end

-- Effective source price for a player: base price scaled by owned creature count.
function Loop.sourcePrice(config: Config, state: PlayerState, sourceId: string): number
	local sourceConfig = config.sources[sourceId]
	if sourceConfig == nil then
		return 0
	end
	local ownedCount = #state.creatures + #state.vaultedCreatures
	return math.floor(sourceConfig.price * (1 + config.pricing.growthPerOwned * ownedCount))
end

function Loop.buySource(config: Config, state: PlayerState, sourceId: string, now: number): (boolean, string?)
	if type(sourceId) ~= "string" then
		return false, "invalid source id type"
	end
	local sourceConfig = config.sources[sourceId]
	if not sourceConfig then
		return false, "unknown source id"
	end
	if #state.incubators >= math.min(Loop.maxIncubators(config, state), Loop.SAVE_CAPACITY) then
		return false, "incubators full"
	end
	local price = Loop.sourcePrice(config, state, sourceId)
	if not state.wallet:canAfford(config.currency, price) then
		return false, "insufficient coins"
	end

	local debited = state.wallet:debit(config.currency, price)
	if not debited then
		return false, "debit failed"
	end

	local timer = HatchTimer.start(now, sourceConfig.hatchSeconds)
	table.insert(state.incubators, {
		sourceId = sourceId,
		timer = timer,
	})
	Loop.recordQuest(state, "buy", 1)

	return true, nil
end

function Loop.hatch(
	config: Config,
	state: PlayerState,
	index: number,
	now: number,
	roll: number,
	luckMultiplier: number?
): (boolean, string)
	if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #state.incubators then
		return false, "invalid incubator index"
	end

	local incubator = state.incubators[index]
	if not HatchTimer.isReady(incubator.timer, now) then
		return false, "egg not ready"
	end

	local sourceConfig = config.sources[incubator.sourceId]
	if not sourceConfig then
		return false, "unknown source in incubator"
	end
	if #state.creatures >= Loop.SAVE_CAPACITY then
		return false, "creatures full"
	end

	local pool = if luckMultiplier ~= nil and luckMultiplier > 1
		then WeightedRoll.boost(sourceConfig.pool, luckMultiplier)
		else sourceConfig.pool
	local rolledCreature = WeightedRoll.pick(pool, roll)
	table.remove(state.incubators, index)
	table.insert(state.creatures, rolledCreature)
	Loop.recordQuest(state, "hatch", 1)

	return true, rolledCreature
end

-- True when `creatureId` belongs to `family`: it appears in the family's own
-- source pool (the eggs that hatch it) or is the result of one of the
-- family's own merge rules (so a creature born from an earlier merge in this
-- family can be merged again). A source id is expected to match its family's
-- id (see games/*/src/shared/Config.luau); packs with no matching source
-- treat every creature as belonging to no family, so the merge simply fails
-- with "not enough" rather than silently accepting creatures from elsewhere.
local function inFamily(config: Config, family: { id: string, rules: { Merge.Rule } }, creatureId: string): boolean
	local sourceConfig = config.sources[family.id]
	if sourceConfig ~= nil then
		for _, poolEntry in sourceConfig.pool do
			if poolEntry.id == creatureId then
				return true
			end
		end
	end
	for _, rule in family.rules do
		if rule.resultId == creatureId then
			return true
		end
	end
	return false
end

-- Fuses owned creatures matching `rule` into one resultId, choosing the lowest
-- indices first. Only creatures belonging to `family` are eligible: a family's
-- rule must never consume another family's creatures just because it shares a
-- rarity, or every merge could be routed to the highest-paying family. The 4th
-- return value is the id of the first creature actually consumed (analytics
-- callers use it to log which input drove the merge); it is nil on failure.
function Loop.merge(
	config: Config,
	state: PlayerState,
	family: { id: string, displayName: string, rules: { Merge.Rule } },
	rule: Merge.Rule
): (boolean, string?, string?, string?)
	local eligible: { string } = {}
	local eligibleIndices: { number } = {}
	for index, creatureId in state.creatures do
		if inFamily(config, family, creatureId) then
			table.insert(eligible, creatureId)
			table.insert(eligibleIndices, index)
		end
	end

	local ok, indices, err = Merge.plan(eligible, function(id: string): string?
		return rarityOf(config, id)
	end, rule)
	if not ok then
		return false, nil, err, nil
	end
	if indices == nil then
		return false, nil, err or "merge failed", nil
	end
	local fromId = eligible[indices[1]]

	-- Map the eligible-array indices Merge.plan chose back to indices into the
	-- full state.creatures array before applying the fuse.
	local originalIndices: { number } = {}
	for _, eligibleIndex in indices do
		table.insert(originalIndices, eligibleIndices[eligibleIndex])
	end

	state.creatures = Merge.apply(state.creatures, originalIndices, rule.resultId)
	return true, rule.resultId, nil, fromId
end

-- Adds one token to a team vault; vaulted creatures are stored non-raidable.
function Loop.depositToVault(vault: Vault.Vault, tokenId: string, raidable: boolean?): ()
	Vault.deposit(vault, tokenId, if raidable == nil then true else raidable)
end

-- Sets or clears a game-pass capability on the player.
function Loop.setPass(state: PlayerState, passKey: string, owned: boolean): ()
	if type(passKey) ~= "string" or passKey == "" then
		return
	end
	if owned then
		state.passes[passKey] = true
	else
		state.passes[passKey] = nil
	end
end

function Loop.readyAllIncubators(state: PlayerState, now: number): ()
	for _, incubator in state.incubators do
		incubator.timer = HatchTimer.start(now, 0)
	end
end

-- Applies a developer-product grant. Passes are set separately via Loop.setPass.
function Loop.grantProduct(config: Config, state: PlayerState, grant: ProductGrant, now: number): boolean
	-- The receipt caller grants before marking; reserve representability before
	-- any grant changes state, not after a paid item has already been delivered.
	if #state.processedPurchases >= Loop.SAVE_CAPACITY then
		return false
	end
	if grant.kind == "coins" then
		local amount = grant.amount
		if type(amount) ~= "number" then
			return false
		end
		state.wallet:credit(config.currency, amount)
		return true
	elseif grant.kind == "kaiju" then
		local creatureId = grant.kaijuId
		if type(creatureId) ~= "string" or creatureId == "" or config.creatures[creatureId] == nil then
			return false
		end
		if #state.vaultedCreatures >= Loop.SAVE_CAPACITY then
			return false
		end
		table.insert(state.vaultedCreatures, creatureId)
		return true
	elseif grant.kind == "speedup" then
		Loop.readyAllIncubators(state, now)
		return true
	elseif grant.kind == "shield" then
		local seconds = grant.seconds
		if type(seconds) ~= "number" or seconds <= 0 then
			return false
		end
		state.shieldUntil = now + seconds
		return true
	end
	return false
end

function Loop.isShielded(state: PlayerState, now: number): boolean
	return state.shieldUntil > now
end

function Loop.hasProcessed(state: PlayerState, purchaseId: string): boolean
	for _, id in state.processedPurchases do
		if id == purchaseId then
			return true
		end
	end
	return false
end

function Loop.markProcessed(state: PlayerState, purchaseId: string): boolean
	if type(purchaseId) ~= "string" or purchaseId == "" then
		return false
	end
	if Loop.hasProcessed(state, purchaseId) then
		return true
	end
	if #state.processedPurchases >= Loop.SAVE_CAPACITY then
		return false
	end
	table.insert(state.processedPurchases, purchaseId)
	return true
end

function Loop.observeTutorial(state: PlayerState, eventName: string): boolean
	return Tutorial.observe(state.tutorial, eventName)
end

function Loop.tutorialHint(state: PlayerState): string?
	local step = Tutorial.current(state.tutorial)
	if step == nil then
		return nil
	end
	return step.hint
end

function Loop.tutorialStepId(state: PlayerState): string
	local step = Tutorial.current(state.tutorial)
	if step == nil then
		return "complete"
	end
	return step.id
end

function Loop.tutorialComplete(state: PlayerState): boolean
	return Tutorial.isComplete(state.tutorial)
end

function Loop.resetTutorial(config: Config, state: PlayerState): ()
	state.tutorial = Tutorial.new(config.tutorialSteps)
end

-- Records progress toward `questId` only when the pack's dailyQuests config
-- actually defines that id. Loop calls this after buy/hatch/raid mutate state
-- (wallet debit, incubator insert, vault move), so a pack whose dailyQuests
-- omits one of those ids must not crash and roll that mutation back into an
-- error for the caller; it simply has no quest to advance for that action.
function Loop.recordQuest(state: PlayerState, questId: string, amount: number): ()
	if state.quest.quests[questId] == nil then
		return
	end
	DailyQuest.record(state.quest, questId, amount)
end

function Loop.claimQuest(config: Config, state: PlayerState, questId: string): (boolean, number)
	local quest = state.quest.quests[questId]
	if quest and quest.reward > 2 ^ 53 - 1 - state.wallet:balance(config.currency) then
		return false, 0
	end
	local ok, reward = DailyQuest.claim(state.quest, questId)
	if ok then
		state.wallet:credit(config.currency, reward)
	end
	return ok, reward
end

function Loop.tick(config: Config, state: PlayerState, dt: number, multiplier: number?, now: number?): number
	if now ~= nil then
		local day = DailyQuest.dayIndex(now)
		if day ~= state.quest.day then
			state.quest = DailyQuest.rollover(state.quest, day, config.dailyQuests)
		end
	end

	-- Passive income saturates at the exact-integer wallet boundary. Overflow
	-- is discarded, never retained as a claim against future spending capacity.
	local room = 2 ^ 53 - 1 - state.wallet:balance(config.currency)
	local nextProduction = { carry = state.production.carry }
	local accrued = Production.accrue(nextProduction, dailyRate(config, state) * (multiplier or 1), dt)
	local produced = math.min(accrued, room)
	state.production.carry = if accrued >= room then 0 else nextProduction.carry
	if produced > 0 then
		state.wallet:credit(config.currency, produced)
	end

	return produced
end

function Loop.snapshot(config: Config, state: PlayerState, now: number, luckMultiplier: number?): Snapshot
	local incubatorsSnapshot: { IncubatorSnapshot } = {}
	for _, inc in state.incubators do
		table.insert(incubatorsSnapshot, {
			sourceId = inc.sourceId,
			remaining = HatchTimer.remaining(inc.timer, now),
		})
	end

	local odds: { [string]: { [string]: number } } = {}
	for sourceId, sourceConfig in config.sources do
		local pool = if luckMultiplier ~= nil and luckMultiplier > 1
			then WeightedRoll.boost(sourceConfig.pool, luckMultiplier)
			else sourceConfig.pool
		odds[sourceId] = WeightedRoll.odds(pool)
	end

	local creaturesCopy: { string } = {}
	for _, id in state.creatures do
		table.insert(creaturesCopy, id)
	end

	local quests: { QuestSnapshot } = {}
	for _, questDef in config.dailyQuests do
		table.insert(quests, {
			id = questDef.id,
			target = questDef.target,
			reward = questDef.reward,
			progress = state.quest.progress[questDef.id] or 0,
			claimed = state.quest.claimed[questDef.id] or false,
		})
	end

	local sourcePrices: { [string]: number } = {}
	for sourceId in config.sources do
		sourcePrices[sourceId] = Loop.sourcePrice(config, state, sourceId)
	end

	return {
		coins = state.wallet:balance(config.currency),
		incubators = incubatorsSnapshot,
		creatures = creaturesCopy,
		vaulted = #state.vaultedCreatures,
		odds = odds,
		sourcePrices = sourcePrices,
		quests = quests,
	}
end

-- Serializes the persistent slice of player state as a plain, DataStore-safe table.
function Loop.toSave(config: Config, state: PlayerState, now: number): SaveData
	local creaturesCopy: { string } = {}
	for _, creatureId in state.creatures do
		table.insert(creaturesCopy, creatureId)
	end

	local vaultedCopy: { string } = {}
	for _, creatureId in state.vaultedCreatures do
		table.insert(vaultedCopy, creatureId)
	end

	local passesCopy: { [string]: boolean } = {}
	for passKey, owned in state.passes do
		if owned then
			passesCopy[passKey] = true
		end
	end

	local processedCopy: { string } = {}
	for _, purchaseId in state.processedPurchases do
		table.insert(processedCopy, purchaseId)
	end

	local incubatorCopy: { SavedIncubator } = {}
	for _, incubator in state.incubators do
		table.insert(incubatorCopy, { sourceId = incubator.sourceId, readyAt = incubator.timer.readyAt })
	end

	local progress = table.clone(state.quest.progress)
	local claimed = table.clone(state.quest.claimed)

	return {
		version = config.profile.version,
		coins = state.wallet:balance(config.currency),
		creatures = creaturesCopy,
		vaultedCreatures = vaultedCopy,
		passes = passesCopy,
		processedPurchases = processedCopy,
		incubators = incubatorCopy,
		tutorial = Tutorial.toSave(state.tutorial),
		shieldUntil = state.shieldUntil,
		lastSeen = now,
		questDay = state.quest.day,
		quest = { progress = progress, claimed = claimed },
	}
end

-- Rebuilds player state from a saved table, rolling quests over and crediting
-- offline income for the time between `lastSeen` and `now`.
function Loop.fromSave(config: Config, data: { [string]: any }, now: number): PlayerState
	local coins = if type(data.coins) == "number" then data.coins else config.startingCoins

	local creatures: { string } = {}
	if type(data.creatures) == "table" then
		for _, creatureId in data.creatures do
			if type(creatureId) == "string" then
				table.insert(creatures, creatureId)
			end
		end
	end

	local vaultedCreatures: { string } = {}
	if type(data.vaultedCreatures) == "table" then
		for _, creatureId in data.vaultedCreatures do
			if type(creatureId) == "string" then
				table.insert(vaultedCreatures, creatureId)
			end
		end
	end

	local passes: { [string]: boolean } = {}
	if type(data.passes) == "table" then
		for passKey, owned in data.passes do
			if type(passKey) == "string" and owned == true then
				passes[passKey] = true
			end
		end
	end

	local processedPurchases: { string } = {}
	if type(data.processedPurchases) == "table" then
		for _, purchaseId in data.processedPurchases do
			if type(purchaseId) == "string" then
				table.insert(processedPurchases, purchaseId)
			end
		end
	end

	local savedTutorial: Tutorial.Save? = nil
	if type(data.tutorial) == "table" then
		local index = data.tutorial.index
		savedTutorial = {
			index = if type(index) == "number" and index % 1 == 0 then index else 1,
			completed = data.tutorial.completed == true,
		}
	end

	local shieldUntil = if type(data.shieldUntil) == "number" then data.shieldUntil else 0

	local incubators: { Incubator } = {}
	if type(data.incubators) == "table" then
		for _, saved in data.incubators do
			if type(saved) == "table" and type(saved.sourceId) == "string" and type(saved.readyAt) == "number" then
				table.insert(incubators, {
					sourceId = saved.sourceId,
					timer = HatchTimer.start(saved.readyAt, 0),
				})
			end
		end
	end

	local questDay = if type(data.questDay) == "number" then data.questDay else DailyQuest.dayIndex(now)
	local state: PlayerState = {
		wallet = Wallet.new({ [config.currency] = math.max(0, math.floor(coins)) }),
		incubators = incubators,
		creatures = creatures,
		vaultedCreatures = vaultedCreatures,
		passes = passes,
		processedPurchases = processedPurchases,
		production = Production.new(),
		quest = DailyQuest.new(questDay, config.dailyQuests),
		tutorial = Tutorial.fromSave(config.tutorialSteps, savedTutorial),
		shieldUntil = shieldUntil,
	}

	local savedQuest = data.quest
	if type(savedQuest) == "table" then
		for _, questDef in config.dailyQuests do
			local progress = savedQuest.progress
			if type(progress) == "table" and type(progress[questDef.id]) == "number" then
				state.quest.progress[questDef.id] = math.clamp(math.floor(progress[questDef.id]), 0, questDef.target)
			end
			local claimed = savedQuest.claimed
			if type(claimed) == "table" and type(claimed[questDef.id]) == "boolean" then
				state.quest.claimed[questDef.id] = claimed[questDef.id]
			end
		end
	end

	state.quest = DailyQuest.rollover(state.quest, DailyQuest.dayIndex(now), config.dailyQuests)

	local lastSeen = if type(data.lastSeen) == "number" then data.lastSeen else now
	local earned = OfflineIncome.compute(
		lastSeen,
		now,
		dailyRate(config, state),
		config.offline.maxSeconds,
		config.offline.efficiency
	)
	local credited = math.min(earned, 2 ^ 53 - 1 - state.wallet:balance(config.currency))
	if credited > 0 then
		state.wallet:credit(config.currency, credited)
	end

	return state
end

return Loop
