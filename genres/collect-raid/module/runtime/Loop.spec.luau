--!strict
-- Specs for Loop: core gameplay loop, hatch timing, pool weighting, and
-- production. Runs against Loop.fixture's Config so the genre module stays
-- pack-agnostic while exercising the same numbers Kaiju Egg Raiders ships.

local Loop = require("./Loop")
local Config = require("./Loop.fixture")
local Vault = require("../../../../core/domain/economy/Vault")
local Catalog = require("../../../../core/infra/monetization/Catalog")
local Receipts = require("../../../../core/infra/monetization/Receipts")
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local function expectFalse(ok: boolean, message: string)
	assert(not ok, "expected false: " .. message)
end

return {
	["server boost receipts reject full ledgers before external effects"] = function()
		local source = fs.readFile("genres/collect-raid/module/runtime/Server.luau")
		local start = assert(string.find(source, "\tlocal function applyProductGrant", 1, true))
		local finish = assert(string.find(source, "\n\tlocal receipts =", start, true))
		local notifications, tracks = 0, 0
		local grant, expires = luau.load(
			"local serverBoostUntil = 0\n"
				.. string.sub(source, start, finish - 1)
				.. "\nreturn applyProductGrant, function() return serverBoostUntil end",
			{
				environment = {
					Catalog = {
						productByKey = { boost = { grant = { kind = "serverBoost", seconds = 60 }, price = 1 } },
					},
					Loop = Loop,
					Config = Config,
					Messages = { serverBoostActive = "boost" },
					Notify = {
						FireAllClients = function()
							notifications += 1
						end,
					},
					track = function()
						tracks += 1
					end,
				},
			}
		)()
		local state = Loop.newPlayer(Config, 0)
		for i = 1, Loop.SAVE_CAPACITY do
			assert(Loop.markProcessed(state, tostring(i)))
		end
		assert(not grant({}, state, "boost", 100), "full receipt ledger refuses boost")
		assert(expires() == 0 and notifications == 0 and tracks == 0, "no external effect before refusal")
		table.remove(state.processedPurchases)
		assert(grant({}, state, "boost", 100), "last representable boost accepted")
		assert(expires() == 160 and notifications == 1 and tracks == 1, "accepted boost applied once")
	end,
	["vault and receipt ledger capacity reject before grants and preserve retries"] = function()
		local state = Loop.newPlayer(Config, 0)
		for i = 1, 1023 do
			Loop.markProcessed(state, "capacity-" .. tostring(i))
			table.insert(state.vaultedCreatures, "solar-titan")
		end
		local purchase = "last"
		local processor = Receipts.new({
			productKeyFor = function()
				return "creature"
			end,
			hasProcessed = function(id)
				return Loop.hasProcessed(state, id)
			end,
			markProcessed = function(id)
				Loop.markProcessed(state, id)
			end,
			grant = function()
				return Loop.grantProduct(Config, state, { kind = "kaiju", kaijuId = "solar-titan" }, 0)
			end,
			commit = function()
				return true
			end,
		})
		assert(
			processor:process({ PlayerId = 1, ProductId = 1, PurchaseId = purchase }) == "PurchaseGranted",
			"capacity and income regression invariant"
		)
		assert(
			processor:process({ PlayerId = 1, ProductId = 1, PurchaseId = "overflow" }) == "NotProcessedYet",
			"first unrepresentable receipt refused"
		)
		assert(#state.vaultedCreatures == 1024 and #state.processedPurchases == 1024, "no grant or marker consumed")
		state = Loop.fromSave(Config, Loop.toSave(Config, state, 0), 0)
		assert(
			processor:process({ PlayerId = 1, ProductId = 1, PurchaseId = purchase }) == "PurchaseGranted",
			"duplicate remains idempotent at capacity"
		)
		assert(
			not Loop.grantProduct(Config, state, { kind = "coins", amount = 1 }, 0),
			"ledger capacity preflights all grants"
		)
		state.processedPurchases = {}
		assert(
			not Loop.grantProduct(Config, state, { kind = "kaiju", kaijuId = "solar-titan" }, 0),
			"vault capacity independent of receipt capacity"
		)
	end,
	["catalog coins receipts credit once through commit failure and retry"] = function()
		local entry: Catalog.Entry = {
			key = "coinPack",
			name = "Coins",
			price = 49,
			grant = { kind = "coins", amount = 100 },
		}
		assert(Catalog.validate({ products = { entry } }), "coin product must pass the catalog boundary")
		-- Use a non-default currency and an owned multiplier pass: a fixed grant
		-- credits the configured wallet by exactly its amount, not production rates.
		local config = table.clone(Config)
		config.currency = "Tokens"
		local state = Loop.newPlayer(config, 0)
		Loop.setPass(state, "coins2x", true)
		local before = state.wallet:balance(config.currency)
		local grants, commits = 0, 0
		local saved: Loop.SaveData? = nil
		local processor = Receipts.new({
			productKeyFor = function(productId)
				return if productId == 123 then entry.key else nil
			end,
			grant = function(userId, productKey)
				assert(userId == 1 and productKey == entry.key, "receipt resolves the catalog entry")
				grants += 1
				assert(entry.grant.kind == "coins", "catalog entry is a fixed coin grant")
				local grant: Loop.CoinsGrant = { kind = "coins", amount = entry.grant.amount }
				return Loop.grantProduct(config, state, grant, 0)
			end,
			hasProcessed = function(purchaseId)
				return Loop.hasProcessed(state, purchaseId)
			end,
			markProcessed = function(purchaseId)
				Loop.markProcessed(state, purchaseId)
			end,
			commit = function(userId)
				assert(userId == 1, "commit targets the receipt player")
				commits += 1
				if commits == 1 then
					return false
				elseif commits == 2 then
					error("persistence unavailable")
				end
				saved = Loop.toSave(config, state, 0)
				return true
			end,
		})
		local receipt = { PlayerId = 1, ProductId = 123, PurchaseId = "coins-1" }
		assert(processor:process(receipt) == "NotProcessedYet", "failed commit must not acknowledge")
		assert(state.wallet:balance(config.currency) == before + 100, "fixed amount is credited")
		assert(state.wallet:balance(Config.currency) == 0, "grant uses the configured currency")
		assert(Loop.hasProcessed(state, receipt.PurchaseId), "ledger marks the grant before commit")
		assert(#state.processedPurchases == 1, "purchase is recorded once")
		assert(grants == 1 and commits == 1 and saved == nil, "first commit failed after one grant")

		assert(processor:process(receipt) == "NotProcessedYet", "throwing commit remains retryable")
		assert(state.wallet:balance(config.currency) == before + 100, "failed retry does not re-credit")
		assert(grants == 1 and commits == 2, "retry only calls commit")
		assert(processor:process(receipt) == "PurchaseGranted", "successful commit acknowledges")
		assert(saved ~= nil, "successful commit persists the profile")
		local persisted = saved :: Loop.SaveData
		assert(persisted.coins == before + 100, "saved balance includes exactly one credit")
		assert(#persisted.processedPurchases == 1, "saved ledger contains one purchase")
		assert(persisted.processedPurchases[1] == receipt.PurchaseId, "saved ledger records this receipt")

		-- Reload the real saved state, then redeliver to the same processor.
		state = Loop.fromSave(config, persisted, 0)
		assert(processor:process(receipt) == "PurchaseGranted", "persisted redelivery acknowledges")
		assert(state.wallet:balance(config.currency) == before + 100, "redelivery never credits twice")
		assert(#state.processedPurchases == 1, "redelivery never duplicates the ledger")
		assert(grants == 1 and commits == 4, "all redeliveries commit without re-granting")
	end,

	["coins grants leave wallet unchanged when the safe balance would overflow"] = function()
		local state = Loop.newPlayer(Config, 0)
		local maximum = 2 ^ 53 - 1
		state.wallet:credit(Config.currency, maximum - Config.startingCoins)
		local grant: Loop.CoinsGrant = { kind = "coins", amount = 1 }
		local ok = pcall(Loop.grantProduct, Config, state, grant, 0)
		assert(not ok, "wallet rejects overflow before mutating")
		assert(state.wallet:balance(Config.currency) == maximum, "safe balance remains intact")
		assert(#state.processedPurchases == 0, "failed grant does not mark a purchase")
	end,

	["coins grant without an amount is rejected"] = function()
		local state = Loop.newPlayer(Config, 0)
		assert(not Loop.grantProduct(Config, state, { kind = "coins" }, 0), "missing amount returns false")
		assert(state.wallet:balance(Config.currency) == Config.startingCoins, "balance is unchanged")
	end,
	["new player has 100 Coins"] = function()
		local state = Loop.newPlayer(Config)
		local snap = Loop.snapshot(Config, state, 0)
		assert(snap.coins == 100, "expected 100 coins, got " .. tostring(snap.coins))
	end,

	["buying ember debits 50 and adds one incubator"] = function()
		local state = Loop.newPlayer(Config)
		local ok, err = Loop.buySource(Config, state, "ember", 1000)
		assert(ok, "buySource ember failed: " .. tostring(err))
		local snap = Loop.snapshot(Config, state, 1000)
		assert(snap.coins == 50, "expected 50 coins remaining, got " .. tostring(snap.coins))
		assert(#snap.incubators == 1, "expected 1 incubator, got " .. tostring(#snap.incubators))
		assert(snap.incubators[1].sourceId == "ember", "expected ember incubator")
		assert(snap.incubators[1].remaining == 5, "expected 5 seconds remaining")
	end,

	["insufficient Coins rejected, balance unchanged"] = function()
		local state = Loop.newPlayer(Config)
		-- tidal costs 250 Coins, player starts with 100
		local ok, err = Loop.buySource(Config, state, "tidal", 1000)
		expectFalse(ok, "expected tidal purchase to fail")
		assert(err == "insufficient coins", "unexpected error reason: " .. tostring(err))
		local snap = Loop.snapshot(Config, state, 1000)
		assert(snap.coins == 100, "coins should remain 100")
		assert(#snap.incubators == 0, "no incubator should be added")
	end,

	["unknown source id rejected"] = function()
		local state = Loop.newPlayer(Config)
		local ok, err = Loop.buySource(Config, state, "nonexistent-egg", 1000)
		expectFalse(ok, "expected nonexistent source to fail")
		assert(err == "unknown source id", "unexpected error reason: " .. tostring(err))
	end,

	["numeric source id rejected"] = function()
		local state = Loop.newPlayer(Config)
		local ok, err = Loop.buySource(Config, state, 123 :: any, 1000)
		expectFalse(ok, "expected numeric source id to fail")
		assert(err == "invalid source id type", "unexpected error reason: " .. tostring(err))
	end,

	["4th egg rejected when incubators full"] = function()
		local state = Loop.newPlayer(Config)
		-- Give enough coins to test 4 buys (ember costs 50, 4 would cost 200)
		state.wallet:credit(Config.currency, 200)

		local ok1 = Loop.buySource(Config, state, "ember", 0)
		local ok2 = Loop.buySource(Config, state, "ember", 0)
		local ok3 = Loop.buySource(Config, state, "ember", 0)
		assert(ok1 and ok2 and ok3, "first 3 buys should succeed")

		local ok4, err4 = Loop.buySource(Config, state, "ember", 0)
		expectFalse(ok4, "4th egg should be rejected")
		assert(err4 == "incubators full", "unexpected error: " .. tostring(err4))
		assert(#state.incubators == 3, "should have exactly 3 incubators")
	end,

	["hatch before hatchSeconds rejected"] = function()
		local state = Loop.newPlayer(Config)
		local okBuy = Loop.buySource(Config, state, "ember", 100)
		assert(okBuy, "buy should succeed")

		-- ember duration is 5s, so now = 104 is before readyAt = 105
		local okHatch, errHatch = Loop.hatch(Config, state, 1, 104, 0.5)
		expectFalse(okHatch, "hatch before readyAt should fail")
		assert(errHatch == "egg not ready", "unexpected error: " .. tostring(errHatch))
		assert(#state.incubators == 1, "incubator should not be removed")
	end,

	["hatch at hatchSeconds succeeds"] = function()
		local state = Loop.newPlayer(Config)
		Loop.buySource(Config, state, "ember", 100)

		-- ember duration is 5s, ready at 105
		local okHatch, creatureId = Loop.hatch(Config, state, 1, 105, 0.5)
		assert(okHatch, "hatch at readyAt should succeed: " .. tostring(creatureId))
		assert(#state.incubators == 0, "incubator should be removed")
		assert(#state.creatures == 1, "creature should be added")
		assert(state.creatures[1] == creatureId, "creature list should match returned id")
	end,

	["roll 0 yields first pool entry"] = function()
		local state = Loop.newPlayer(Config)
		Loop.buySource(Config, state, "ember", 0)
		local okHatch, creatureId = Loop.hatch(Config, state, 1, 10, 0)
		assert(okHatch, "hatch should succeed")
		assert(creatureId == "pyro-pup", "roll 0 should yield pyro-pup, got " .. tostring(creatureId))
	end,

	["roll 0.99 yields last pool entry"] = function()
		local state = Loop.newPlayer(Config)
		Loop.buySource(Config, state, "ember", 0)
		local okHatch, creatureId = Loop.hatch(Config, state, 1, 10, 0.99)
		assert(okHatch, "hatch should succeed")
		assert(creatureId == "solar-titan", "roll 0.99 should yield solar-titan, got " .. tostring(creatureId))
	end,

	["hatch index 0, 99, 1.5 rejected"] = function()
		local state = Loop.newPlayer(Config)
		Loop.buySource(Config, state, "ember", 0)

		local ok0, _ = Loop.hatch(Config, state, 0, 10, 0)
		expectFalse(ok0, "index 0 should be rejected")

		local ok99, _ = Loop.hatch(Config, state, 99, 10, 0)
		expectFalse(ok99, "index 99 should be rejected")

		local okFloat, _ = Loop.hatch(Config, state, 1.5, 10, 0)
		expectFalse(okFloat, "index 1.5 should be rejected")
	end,

	["tick with one pyro-pup over 10 x 0.1 s yields exactly its rate"] = function()
		local state = Loop.newPlayer(Config)
		-- Initial balance is 100
		local initialCoins = state.wallet:balance(Config.currency)
		table.insert(state.creatures, "pyro-pup") -- 1 coin/sec

		local totalProduced = 0
		for _ = 1, 10 do
			local p = Loop.tick(Config, state, 0.1)
			totalProduced += p
		end

		assert(totalProduced == 1, "expected 1 coin produced over 1s, got " .. tostring(totalProduced))
		local endingCoins = state.wallet:balance(Config.currency)
		assert(
			endingCoins == initialCoins + 1,
			"expected balance " .. (initialCoins + 1) .. ", got " .. tostring(endingCoins)
		)
	end,

	["snapshot odds per source sum to 1"] = function()
		local state = Loop.newPlayer(Config)
		local snap = Loop.snapshot(Config, state, 0)
		local EPSILON = 1e-6

		for sourceId, sourceOdds in snap.odds do
			local sum = 0
			for _, prob in sourceOdds do
				sum += prob
			end
			assert(
				math.abs(sum - 1) < EPSILON,
				"odds for source " .. sourceId .. " must sum to 1, got " .. tostring(sum)
			)
		end
	end,

	["every pool id exists in creatures table and every source price is a positive integer in Coins"] = function()
		for sourceId, sourceConfig in Config.sources do
			assert(type(sourceConfig.price) == "number", "price must be number for " .. sourceId)
			assert(sourceConfig.price > 0, "price must be positive for " .. sourceId)
			assert(sourceConfig.price % 1 == 0, "price must be integer for " .. sourceId)

			local totalWeight = 0
			for _, entry in sourceConfig.pool do
				assert(Config.creatures[entry.id] ~= nil, "pool id " .. entry.id .. " missing from Config.creatures")
				assert(entry.weight > 0, "weight must be positive for " .. entry.id)
				totalWeight += entry.weight
			end
			assert(totalWeight > 0, "pool weight must be positive")
		end

		for creatureId, creatureConfig in Config.creatures do
			assert(type(creatureConfig.coinsPerSecond) == "number", "coinsPerSecond must be number for " .. creatureId)
			assert(creatureConfig.coinsPerSecond > 0, "coinsPerSecond must be positive for " .. creatureId)
		end
	end,

	["merge fuses three common ember creatures into magma-mauler"] = function()
		local state = Loop.newPlayer(Config, 0)
		state.creatures = { "pyro-pup", "pyro-pup", "pyro-pup" }
		local ember = Config.mergeFamilies[1]
		local ok, resultId, err = Loop.merge(Config, state, ember, ember.rules[1])
		assert(ok == true, "merge should succeed: " .. tostring(err))
		assert(resultId == "magma-mauler", "expected magma-mauler, got " .. tostring(resultId))
		assert(#state.creatures == 1, "three common fuse into one")
		assert(state.creatures[1] == "magma-mauler", "result replaces the consumed creatures")
	end,

	["merge with too few matching creatures fails and leaves state unchanged"] = function()
		local state = Loop.newPlayer(Config, 0)
		state.creatures = { "pyro-pup", "pyro-pup", "magma-mauler" }
		local ember = Config.mergeFamilies[1]
		local ok, resultId, err = Loop.merge(Config, state, ember, ember.rules[1])
		assert(ok == false, "merge should fail")
		assert(resultId == nil, "no result id on failure")
		assert(err == "not enough", "expected 'not enough', got " .. tostring(err))
		assert(#state.creatures == 3, "failed merge leaves creatures untouched")
	end,

	["merge only consumes creatures from the rule's own family, even when another family has enough"] = function()
		local state = Loop.newPlayer(Config, 0)
		-- 3 ember-family commons (pyro-pup) plus 2 tidal-family commons (reef-runner):
		-- invoking the tidal common->rare rule must not be satisfiable by ember creatures.
		state.creatures = { "pyro-pup", "pyro-pup", "pyro-pup", "reef-runner", "reef-runner" }
		local tidal = Config.mergeFamilies[2]
		assert(tidal.id == "tidal", "expected the tidal family fixture")
		local ok, resultId, err = Loop.merge(Config, state, tidal, tidal.rules[1])
		assert(ok == false, "tidal merge must not be satisfied by ember creatures")
		assert(resultId == nil, "no result id on failure")
		assert(err == "not enough", "expected 'not enough', got " .. tostring(err))
		assert(#state.creatures == 5, "cross-family merge attempt leaves creatures untouched")
	end,

	["merge consumes only the chosen family's creatures when multiple families qualify"] = function()
		local state = Loop.newPlayer(Config, 0)
		-- 3 ember commons and 3 tidal commons both qualify by rarity; invoking the ember
		-- rule must consume only the ember-family creatures and yield the ember result.
		state.creatures = { "pyro-pup", "pyro-pup", "pyro-pup", "reef-runner", "reef-runner", "reef-runner" }
		local ember = Config.mergeFamilies[1]
		local ok, resultId, err = Loop.merge(Config, state, ember, ember.rules[1])
		assert(ok == true, "ember merge should succeed: " .. tostring(err))
		assert(resultId == "magma-mauler", "expected the ember family result, got " .. tostring(resultId))

		local remainingReef = 0
		for _, id in state.creatures do
			if id == "reef-runner" then
				remainingReef += 1
			end
		end
		assert(remainingReef == 3, "the tidal family's creatures must be untouched by an ember merge")
	end,

	["merge reports the consumed family's own creature as fromId, never another family's"] = function()
		local state = Loop.newPlayer(Config, 0)
		-- Exact repro fixture from the round-2 report: one ember-family creature
		-- (pyro-pup) plus three tidal-family creatures (reef-runner). Invoking the
		-- tidal common->rare rule must report a consumed reef-runner as fromId,
		-- never the pyro-pup that the merge never touches (analytics callers use
		-- fromId to log which input actually drove the merge).
		state.creatures = { "pyro-pup", "reef-runner", "reef-runner", "reef-runner" }
		local tidal = Config.mergeFamilies[2]
		assert(tidal.id == "tidal", "expected the tidal family fixture")
		local ok, resultId, err, fromId = Loop.merge(Config, state, tidal, tidal.rules[1])
		assert(ok == true, "tidal merge should succeed: " .. tostring(err))
		assert(resultId == "storm-serpent", "expected the tidal family result, got " .. tostring(resultId))
		assert(
			fromId == "reef-runner",
			"fromId must be a creature the merge actually consumed, got " .. tostring(fromId)
		)
	end,

	["save and load round trip keeps creatures and pays offline income"] = function()
		local state = Loop.newPlayer(Config, 1000)
		state.creatures = { "pyro-pup" } -- 1 coin/second
		local saved = Loop.toSave(Config, state, 1000)

		-- 600s away at efficiency 0.5 => 300 coins on top of the starting 100.
		local loaded = Loop.fromSave(Config, saved, 1600)
		local coins = loaded.wallet:balance(Config.currency)
		assert(coins == 400, "expected 400 coins, got " .. tostring(coins))
		assert(#loaded.creatures == 1 and loaded.creatures[1] == "pyro-pup", "creatures survive the round trip")
	end,

	["incubators survive save and load with their readyAt"] = function()
		local state = Loop.newPlayer(Config, 100)
		local bought, buyErr = Loop.buySource(Config, state, "ember", 100)
		assert(bought, "buy should succeed: " .. tostring(buyErr))
		local readyAt = state.incubators[1].timer.readyAt

		local loaded = Loop.fromSave(Config, Loop.toSave(Config, state, 100), 100)
		assert(#loaded.incubators == 1, "incubator survives the round trip")
		assert(loaded.incubators[1].sourceId == "ember", "source id survives the round trip")
		assert(loaded.incubators[1].timer.readyAt == readyAt, "readyAt survives the round trip")

		local okHatch, creatureId = Loop.hatch(Config, loaded, 1, readyAt, 0)
		assert(okHatch, "restored incubator hatches at readyAt: " .. tostring(creatureId))
		assert(#loaded.incubators == 0, "hatched incubator is removed")
	end,

	["claim pays once and never again"] = function()
		local state = Loop.newPlayer(Config, 0)
		Loop.recordQuest(state, "hatch", 3)
		local ok, reward = Loop.claimQuest(Config, state, "hatch")
		assert(ok == true, "first claim succeeds")
		assert(reward == 100, "first claim pays 100")
		assert(state.wallet:balance(Config.currency) == 200, "reward credited once")

		local againOk, againReward = Loop.claimQuest(Config, state, "hatch")
		assert(againOk == false, "second claim fails")
		assert(againReward == 0, "second claim pays nothing")
		assert(state.wallet:balance(Config.currency) == 200, "balance unchanged after second claim")
	end,

	["hatch and buy record their daily quest progress"] = function()
		local state = Loop.newPlayer(Config, 0)
		Loop.buySource(Config, state, "ember", 0)
		assert(state.quest.progress["buy"] == 1, "buy records one")
		Loop.hatch(Config, state, 1, 10, 0)
		assert(state.quest.progress["hatch"] == 1, "hatch records one")
	end,

	["buySource succeeds and leaves state consistent when the pack's dailyQuests has no 'buy' id"] = function()
		-- Regression for the crash-after-mutate bug: a pack config whose
		-- dailyQuests never defines "buy" must still let buySource debit the
		-- wallet and insert the incubator, instead of erroring out of
		-- DailyQuest.record after the mutation already happened. On the old
		-- code (unconditional DailyQuest.record(state.quest, "buy", 1)) this
		-- throws "unknown quest: buy" even though the debit already landed.
		local noBuyQuestConfig = table.clone(Config)
		noBuyQuestConfig.dailyQuests = {
			{ id = "hatch", target = 3, reward = 100 },
			{ id = "raid", target = 1, reward = 300 },
		}
		local state = Loop.newPlayer(noBuyQuestConfig, 0)
		local before = state.wallet:balance(noBuyQuestConfig.currency)

		local ok, err = Loop.buySource(noBuyQuestConfig, state, "ember", 0)
		assert(ok, "buySource should succeed even without a 'buy' quest: " .. tostring(err))
		assert(
			before - state.wallet:balance(noBuyQuestConfig.currency) == 50,
			"wallet is still debited the ember price"
		)
		assert(#state.incubators == 1, "the incubator is still inserted")
		assert(state.quest.progress["buy"] == nil, "no 'buy' quest exists to record progress against")
	end,

	["depositToVault adds one raidable token"] = function()
		local vault = Vault.new()
		Loop.depositToVault(vault, "pyro-pup")
		assert(Vault.count(vault, true) == 1, "one raidable token deposited")
		assert(Vault.count(vault) == 1, "total count matches")
	end,

	["depositToVault can lock a token as non-raidable"] = function()
		local vault = Vault.new()
		Loop.depositToVault(vault, "pyro-pup", false)
		assert(Vault.count(vault, true) == 0, "no raidable tokens")
		assert(Vault.count(vault) == 1, "locked token still counted in total")
	end,

	["vaulted creatures produce coins"] = function()
		local state = Loop.newPlayer(Config, 0)
		table.insert(state.vaultedCreatures, "pyro-pup") -- 1 coin/sec
		local initialCoins = state.wallet:balance(Config.currency)

		local produced = 0
		for _ = 1, 10 do
			produced += Loop.tick(Config, state, 0.1)
		end

		assert(produced == 1, "expected 1 coin from a vaulted creature, got " .. tostring(produced))
		assert(state.wallet:balance(Config.currency) == initialCoins + 1, "vaulted production credits the wallet")
		assert(Loop.snapshot(Config, state, 0).vaulted == 1, "snapshot counts vaulted creatures")
	end,

	["coins2x game pass doubles production"] = function()
		local state = Loop.newPlayer(Config, 0)
		table.insert(state.creatures, "pyro-pup") -- 1 coin/sec base
		Loop.setPass(state, "coins2x", true)

		local produced = 0
		for _ = 1, 10 do
			produced += Loop.tick(Config, state, 0.1)
		end

		assert(produced == 2, "expected 2 coins with the 2x pass, got " .. tostring(produced))
	end,

	["vipSlots game pass allows 7 incubators"] = function()
		local state = Loop.newPlayer(Config, 0)
		state.wallet:credit(Config.currency, 400) -- enough for 7 ember eggs (350)
		Loop.setPass(state, "vipSlots", true)
		assert(Loop.maxIncubators(Config, state) == 7, "vip slots raise the cap by 4")

		for i = 1, 7 do
			local ok, err = Loop.buySource(Config, state, "ember", 0)
			assert(ok, "buy " .. i .. " should succeed: " .. tostring(err))
		end
		assert(#state.incubators == 7, "7 incubators allowed")

		local ok8, err8 = Loop.buySource(Config, state, "ember", 0)
		expectFalse(ok8, "8th incubator should be rejected")
		assert(err8 == "incubators full", "unexpected error: " .. tostring(err8))
	end,

	["hatch speed-up makes every incubator ready"] = function()
		local state = Loop.newPlayer(Config, 0)
		Loop.buySource(Config, state, "ember", 0) -- ember is ready at t = 5
		local granted = Loop.grantProduct(Config, state, { kind = "speedup", seconds = 3600 }, 1)
		assert(granted, "speedup grant applies")

		local ok, creatureId = Loop.hatch(Config, state, 1, 1, 0)
		assert(ok, "egg is ready after speed-up: " .. tostring(creatureId))
		assert(#state.incubators == 0, "hatched incubator removed")
	end,

	["siege shield sets shieldUntil from now"] = function()
		local state = Loop.newPlayer(Config, 0)
		local granted = Loop.grantProduct(Config, state, { kind = "shield", seconds = 600 }, 100)
		assert(granted, "shield grant applies")
		assert(state.shieldUntil == 700, "shield expires at now + seconds")
		assert(Loop.isShielded(state, 699), "shielded before expiry")
		assert(not Loop.isShielded(state, 700), "not shielded at expiry")
	end,

	["processed purchases persist across save and load"] = function()
		local state = Loop.newPlayer(Config, 1000)
		Loop.markProcessed(state, "purchase-a")
		Loop.markProcessed(state, "purchase-b")

		local saved = Loop.toSave(Config, state, 1000)
		local loaded = Loop.fromSave(Config, saved, 1000)
		assert(Loop.hasProcessed(loaded, "purchase-a"), "first purchase survives save/load")
		assert(Loop.hasProcessed(loaded, "purchase-b"), "second purchase survives save/load")
		assert(not Loop.hasProcessed(loaded, "purchase-c"), "unknown purchase is not remembered")
	end,

	["processed purchases retain all markers and ignore duplicate or invalid marks"] = function()
		local state = Loop.newPlayer(Config, 0)
		for i = 1, 205 do
			Loop.markProcessed(state, "purchase-" .. tostring(i))
		end
		Loop.markProcessed(state, "purchase-1")
		Loop.markProcessed(state, "")
		Loop.markProcessed(state, 123 :: any)
		assert(#state.processedPurchases == 205, "all unique markers remain")
		for i = 1, 205 do
			assert(state.processedPurchases[i] == "purchase-" .. tostring(i), "marker order remains intact")
		end
	end,

	["save and restore retain oversized existing-schema ledgers without aliasing"] = function()
		local saved = Loop.toSave(Config, Loop.newPlayer(Config, 0), 0)
		for i = 1, 205 do
			table.insert(saved.processedPurchases, "legacy-" .. tostring(i))
		end
		local loaded = Loop.fromSave(Config, saved, 0)
		local roundTrip = Loop.toSave(Config, loaded, 0)
		assert(roundTrip.version == saved.version, "profile version is unchanged")
		assert(#loaded.processedPurchases == 205 and #roundTrip.processedPurchases == 205, "no truncation")
		for i = 1, 205 do
			assert(loaded.processedPurchases[i] == saved.processedPurchases[i], "restore retains every marker")
			assert(roundTrip.processedPurchases[i] == saved.processedPurchases[i], "save retains every marker")
		end
		saved.processedPurchases[1] = "changed-input"
		roundTrip.processedPurchases[2] = "changed-output"
		assert(Loop.hasProcessed(loaded, "legacy-1"), "restore owns its ledger")
		assert(Loop.hasProcessed(loaded, "legacy-2"), "save copies its ledger")
		assert(#Loop.fromSave(Config, {}, 0).processedPurchases == 0, "missing legacy ledger defaults empty")
		assert(
			#Loop.fromSave(Config, { processedPurchases = false }, 0).processedPurchases == 0,
			"invalid legacy ledger defaults empty"
		)
		local malformed: { any } = { "valid", 123, false }
		local filtered = Loop.fromSave(Config, { processedPurchases = malformed }, 0)
		assert(#filtered.processedPurchases == 1 and Loop.hasProcessed(filtered, "valid"), "non-string IDs filtered")
	end,

	["201 pending receipts retry once per grant before and after save restore"] = function()
		for _, restore in { false, true } do
			local state = Loop.newPlayer(Config, 0)
			local grants, commits = 0, 0
			local commitSucceeds = false
			local processor = Receipts.new({
				productKeyFor = function()
					return "coins"
				end,
				grant = function()
					grants += 1
					return Loop.grantProduct(Config, state, { kind = "coins", amount = 10 }, 0)
				end,
				hasProcessed = function(id)
					return Loop.hasProcessed(state, id)
				end,
				markProcessed = function(id)
					Loop.markProcessed(state, id)
				end,
				commit = function()
					commits += 1
					return commitSucceeds
				end,
			})
			for i = 1, 201 do
				local receipt = { PlayerId = 1, ProductId = 1, PurchaseId = "pending-" .. tostring(i) }
				assert(processor:process(receipt) == "NotProcessedYet", "outage never acknowledges")
			end
			assert(grants == 201 and commits == 201, "each unique receipt grants and attempts commit")
			if restore then
				state = Loop.fromSave(Config, Loop.toSave(Config, state, 0), 0)
			end
			-- Retry every pending receipt during the outage, then after recovery.
			for _, recovered in { false, true } do
				commitSucceeds = recovered
				for i = 1, 201 do
					local receipt = { PlayerId = 1, ProductId = 1, PurchaseId = "pending-" .. tostring(i) }
					local expected = if recovered then "PurchaseGranted" else "NotProcessedYet"
					assert(processor:process(receipt) == expected, "acknowledgement follows commit")
				end
			end
			assert(grants == 201 and commits == 603, "redelivery only retries persistence")
			assert(#state.processedPurchases == 201, "all markers retained without duplicates")
			assert(state.wallet:balance(Config.currency) == Config.startingCoins + 2010, "each grant paid once")
		end
	end,

	["tutorial progress survives save and load"] = function()
		local state = Loop.newPlayer(Config, 0)
		assert(Loop.tutorialStepId(state) == "buy", "fresh tutorial starts at buy")
		Loop.observeTutorial(state, "buy")
		Loop.observeTutorial(state, "hatch")

		local loaded = Loop.fromSave(Config, Loop.toSave(Config, state, 0), 0)
		assert(Loop.tutorialStepId(loaded) == "claim", "resumes at the saved step")
		Loop.observeTutorial(loaded, "claim")
		Loop.observeTutorial(loaded, "store")
		assert(Loop.tutorialComplete(loaded), "walked to completion")

		local doneLoaded = Loop.fromSave(Config, Loop.toSave(Config, loaded, 0), 0)
		assert(Loop.tutorialComplete(doneLoaded), "completed tutorial reloads complete")
		assert(Loop.tutorialHint(doneLoaded) == nil, "completed tutorial shows no hint")
	end,

	["daily quest rolls over mid-session when tick crosses a day boundary"] = function()
		local DAY = 86400
		local state = Loop.newPlayer(Config, 0) -- day 0
		Loop.recordQuest(state, "hatch", 3)
		assert(state.quest.progress["hatch"] == 3, "progress recorded before rollover")

		-- Advance well past midnight without a save/load round trip in between.
		Loop.tick(Config, state, 1, 1, DAY + 10)

		assert(state.quest.day == 1, "quest day rolls over during a live tick, not only on load")
		assert(state.quest.progress["hatch"] == 0, "progress resets for the new day")
		assert(state.quest.claimed["hatch"] == false, "claim flag resets for the new day")
	end,

	["tick with no explicit now does not roll the quest over"] = function()
		local state = Loop.newPlayer(Config, 0)
		Loop.recordQuest(state, "hatch", 3)
		Loop.tick(Config, state, 1)
		assert(state.quest.progress["hatch"] == 3, "progress is untouched when tick has no now argument")
	end,

	["tick applies an optional multiplier"] = function()
		local state = Loop.newPlayer(Config)
		table.insert(state.creatures, "pyro-pup") -- 1 coin/sec
		local state2 = Loop.newPlayer(Config)
		table.insert(state2.creatures, "pyro-pup")

		local first = Loop.tick(Config, state, 1)
		local second = Loop.tick(Config, state2, 1, 2)
		assert(
			second == first * 2,
			"multiplier should double production, got " .. tostring(second) .. " vs " .. tostring(first)
		)
	end,

	["source price scales with owned creatures and buySource debits the scaled price"] = function()
		local state = Loop.newPlayer(Config, 0)
		assert(Loop.sourcePrice(Config, state, "ember") == 50, "no creatures keeps the base price")

		state.creatures = { "pyro-pup", "magma-mauler" }
		local expected = math.floor(50 * (1 + Config.pricing.growthPerOwned * 2))
		assert(Loop.sourcePrice(Config, state, "ember") == expected, "price grows with the owned count")

		table.insert(state.vaultedCreatures, "solar-titan")
		local expectedVaulted = math.floor(50 * (1 + Config.pricing.growthPerOwned * 3))
		assert(Loop.sourcePrice(Config, state, "ember") == expectedVaulted, "vaulted creatures count as owned")

		local snap = Loop.snapshot(Config, state, 0)
		assert(snap.sourcePrices.ember == expectedVaulted, "snapshot exposes the effective price")

		state.wallet:credit(Config.currency, 1000000)
		local before = state.wallet:balance(Config.currency)
		local ok, err = Loop.buySource(Config, state, "ember", 0)
		assert(ok, "buySource should succeed: " .. tostring(err))
		assert(before - state.wallet:balance(Config.currency) == expectedVaulted, "buySource debits the scaled price")
	end,

	["luck boost shifts hatch odds away from the common pool entry"] = function()
		local state = Loop.newPlayer(Config)
		state.wallet:credit(Config.currency, 100)
		Loop.buySource(Config, state, "ember", 0)

		-- ember pool weights are 70/25/5 (common/rare/legendary). Unboosted, a roll of
		-- 0.65 sits well inside the 70% common share.
		local okBase, baseId = Loop.hatch(Config, state, 1, 10, 0.65)
		assert(okBase, "unboosted hatch should succeed")
		assert(baseId == "pyro-pup", "unboosted roll 0.65 should yield the common entry")

		Loop.buySource(Config, state, "ember", 0)
		-- Same roll (0.65), but with a 4x luck multiplier: WeightedRoll.boost divides the
		-- common weight by 4 (70 -> 17.5) and multiplies the rest by 4 (25->100, 5->20),
		-- so the common share shrinks to 17.5/137.5 (~13%) and 0.65 now lands past it.
		-- Index 1 again: the first hatch already removed incubator 1 from the array.
		local okBoosted, boostedId = Loop.hatch(Config, state, 1, 10, 0.65, 4)
		assert(okBoosted, "boosted hatch should succeed")
		assert(boostedId ~= "pyro-pup", "luck boost should shift the roll away from the common entry")
	end,

	["luck boost is reflected in the snapshot odds"] = function()
		local state = Loop.newPlayer(Config)
		local baseSnap = Loop.snapshot(Config, state, 0)
		local boostedSnap = Loop.snapshot(Config, state, 0, 4)

		local baseCommon = baseSnap.odds.ember["pyro-pup"]
		local boostedCommon = boostedSnap.odds.ember["pyro-pup"]
		assert(boostedCommon < baseCommon, "boosted snapshot odds should lower the common share")
	end,

	["income counts only the top activeSlots creatures"] = function()
		local state = Loop.newPlayer(Config, 0)
		for _ = 1, 10 do
			table.insert(state.creatures, "pyro-pup") -- 1 coin/s each
		end
		table.insert(state.creatures, "solar-titan") -- 8 coins/s
		table.insert(state.creatures, "abyss-leviathan") -- 15 coins/s

		-- Fixture's income.activeSlots is 6; the top 6 rates are 15+8+1+1+1+1 = 27.
		-- Hardcoded, not derived from the cap formula under test.
		local expected = 27

		local produced = 0
		for _ = 1, 10 do
			produced += Loop.tick(Config, state, 0.1)
		end
		assert(produced == expected, "expected " .. expected .. " coins from the top slots, got " .. tostring(produced))
	end,

	["activeSlots below 1 means no cap: every creature's rate counts"] = function()
		local uncapped = table.clone(Config)
		uncapped.income = { activeSlots = 0 }

		local state = Loop.newPlayer(uncapped, 0)
		for _ = 1, 10 do
			table.insert(state.creatures, "pyro-pup") -- 1 coin/s each
		end
		table.insert(state.creatures, "solar-titan") -- 8 coins/s
		table.insert(state.creatures, "abyss-leviathan") -- 15 coins/s

		-- Uncapped: all 12 creatures' rates sum, 10*1 + 8 + 15 = 33.
		local expected = 33

		local produced = 0
		for _ = 1, 10 do
			produced += Loop.tick(uncapped, state, 0.1)
		end
		assert(produced == expected, "expected " .. expected .. " uncapped coins, got " .. tostring(produced))
	end,

	["baseCoinsPerSecond and coinsPerSecond expose the capped production rate"] = function()
		local state = Loop.newPlayer(Config, 0)
		table.insert(state.creatures, "solar-titan") -- 8 coins/s
		table.insert(state.creatures, "abyss-leviathan") -- 15 coins/s

		assert(Loop.baseCoinsPerSecond(Config, state) == 23, "base rate is the uncapped sum under activeSlots")
		assert(Loop.coinsPerSecond(Config, state) == 23, "no coins2x pass: effective rate equals base rate")

		Loop.setPass(state, "coins2x", true)
		assert(Loop.coinsPerSecond(Config, state) == 46, "coins2x doubles the effective rate")
		assert(Loop.baseCoinsPerSecond(Config, state) == 23, "base rate stays unmultiplied")
	end,

	["gamepass effects come from config.passEffects, not literals"] = function()
		local tuned = table.clone(Config)
		tuned.passEffects = { coins2xMultiplier = 3, vipSlotBonus = 5 }

		local state = Loop.newPlayer(tuned, 0)
		table.insert(state.creatures, "solar-titan") -- 8 coins/s
		Loop.setPass(state, "coins2x", true)
		assert(Loop.coinsPerSecond(tuned, state) == 24, "multiplier 3 triples the effective rate")

		local produced = 0
		for _ = 1, 10 do
			produced += Loop.tick(tuned, state, 0.1)
		end
		assert(produced == 24, "expected 24 coins over 1s with a 3x pass, got " .. tostring(produced))

		assert(Loop.maxIncubators(tuned, state) == tuned.maxIncubators, "no vipSlots pass: base cap")
		Loop.setPass(state, "vipSlots", true)
		assert(Loop.maxIncubators(tuned, state) == tuned.maxIncubators + 5, "vipSlots bonus comes from config")
	end,
}
