--!strict
local Adapter = require("./Adapter")
local Fixture = require("./Adapter.fixture")
local Shared = require("../../../core/domain/genre/Contract")
local function setup(port: Adapter.WalletPort?, initial: number?)
	local events: { Shared.Event } = {}
	local config = table.clone(Fixture.config)
	if initial ~= nil then
		config.startingBalance = initial
	end
	local instance = Adapter.new(config, {
		now = function()
			return 0
		end,
		roll = function()
			return 0
		end,
		emit = function(event)
			table.insert(events, event)
		end,
	}, port)
	return instance, events
end
return {
	["empty server and abandoned waves cannot strand new joins"] = function()
		local instance, events = setup()
		instance.advance(0)
		instance.advance(100)
		assert(instance.join("a", nil).ok, "first join")
		assert(instance.snapshot("a").waveIndex == 0, "no empty-server wave")
		instance.advance(100)
		instance.advance(102)
		assert(instance.join("late", nil).ok, "late join")
		instance.leave("a")
		assert(instance.snapshot("late").activeWave == nil, "abandoned wave canceled")
		assert(#events == 1 and instance.snapshot("late").balance == 10, "cancel never rewards")
		instance.advance(104)
		assert(instance.dispatch("late", "defend-active", {}).ok, "new roster can resolve next wave")
		instance.leave("late")
		instance.advance(1000)
		assert(instance.join("new", nil).ok, "new server member")
		instance.advance(1000)
		assert(instance.snapshot("new").activeWave ~= nil, "overdue scheduler spawns once for real roster")
	end,
	["reward capacity preflight is atomic for standalone and injected wallets"] = function()
		for _, injected in { false, true } do
			local balances = { a = 0, b = 1e9 }
			local credits = 0
			local port: Adapter.WalletPort = {
				balance = function(id)
					return balances[id]
				end,
				debit = function(id, amount)
					if balances[id] < amount then
						return false
					end
					balances[id] -= amount
					return true
				end,
				credit = function(id, amount)
					balances[id] += amount
					credits += 1
				end,
			}
			local instance, events = setup(if injected then port else nil, if injected then 0 else nil)
			assert(instance.join("a", { upgradeLevel = 1, balance = if injected then nil else 0 }).ok, "join a")
			assert(instance.join("b", { upgradeLevel = 0, balance = if injected then nil else 1e9 }).ok, "join b")
			instance.advance(0)
			instance.advance(2)
			assert(not instance.dispatch("a", "defend-active", {}).ok, "overflow refuses settlement")
			assert(
				instance.snapshot("a").activeWave ~= nil and instance.snapshot("a").lastResolvedWave == 0,
				"unsettled wave retained"
			)
			assert(
				instance.snapshot("a").balance == 0
					and instance.snapshot("b").balance == 1e9
					and #events == 1
					and credits == 0,
				"no partial reward or hooks"
			)
			assert(instance.dispatch("b", "buy-defense", {}).ok, "make reward capacity")
			assert(instance.dispatch("a", "defend-active", {}).ok, "retry settles once")
			assert(
				instance.snapshot("a").balance == 5 and instance.snapshot("b").balance == 1e9 - 5,
				"bounded exact rewards"
			)
			assert(#Adapter.validateSave(instance.save("b")) == 0, "save remains valid")
		end
	end,
	["constructor isolates config and rejects nonfinite clock"] = function()
		local config = table.clone(Fixture.config)
		local services: Shared.Services = {
			now = function()
				return 0
			end,
			roll = function()
				return 0
			end,
			emit = function(_) end,
		}
		local instance = Adapter.new(config, services)
		config.upgradeCost = 0
		config.upgradePower = 0
		config.winReward = 999
		config.waveInterval = 999
		assert(instance.join("a", nil).ok, "join")
		assert(instance.dispatch("a", "buy-defense", {}).ok, "upgrade")
		instance.advance(0)
		instance.advance(2)
		assert(
			instance.dispatch("a", "defend-active", {}).ok and instance.snapshot("a").balance == 5,
			"original config retained"
		)
		for _, invalid in { math.huge, -math.huge, 0 / 0 } do
			services.now = function()
				return invalid
			end
			assert(not pcall(Adapter.new, Fixture.config, services), "nonfinite initial clock rejected")
		end
	end,
	["upgrade changes native defense and pays once; save is player only"] = function()
		local instance, events = setup()
		assert(instance.join("a", nil).ok, 'check: instance.join("a", nil).ok')
		assert(
			not instance.dispatch("a", "defend-active", {}).ok,
			'check: not instance.dispatch("a", "defend-active", {}).ok'
		)
		assert(instance.dispatch("a", "buy-defense", {}).ok, 'check: instance.dispatch("a", "buy-defense", {}).ok')
		assert(
			not instance.dispatch("a", "buy-defense", {}).ok,
			'check: not instance.dispatch("a", "buy-defense", {}).ok'
		)
		instance.advance(0)
		instance.advance(2)
		assert(instance.dispatch("a", "defend-active", {}).ok, 'check: instance.dispatch("a", "defend-active", {}).ok')
		assert(
			instance.snapshot("a").lastWaveWon == true and instance.snapshot("a").balance == 5,
			'check: instance.snapshot("a").lastWaveWon == true and instance.snapshot("a").balance == 5'
		)
		assert(
			not instance.dispatch("a", "defend-active", {}).ok,
			'check: not instance.dispatch("a", "defend-active", {}).ok'
		)
		assert(
			#events == 3 and events[3].data.defensePower == 4,
			"check: #events == 3 and events[3].data.defensePower == 4"
		)
		local saved = instance.save("a")
		assert(
			saved.balance == 5 and saved.upgradeLevel == 1 and saved.waveIndex == nil,
			"check: saved.balance == 5 and saved.upgradeLevel == 1 and saved.waveIndex == nil"
		)
		local fresh = setup()
		assert(fresh.join("a", saved).ok, 'check: fresh.join("a", saved).ok')
		assert(
			fresh.snapshot("a").waveIndex == 0 and fresh.snapshot("a").balance == 5,
			'check: fresh.snapshot("a").waveIndex == 0 and fresh.snapshot("a").balance == 5'
		)
	end,
	["baseline loses; clients cannot choose wave time or power"] = function()
		local instance, events = setup()
		assert(instance.join("a", nil).ok, 'check: instance.join("a", nil).ok')
		instance.advance(0)
		instance.advance(2)
		for _, args in { { 1 }, { 999, 999 }, { time = 2 }, { [2] = 4 } } do
			assert(
				not instance.dispatch("a", "defend-active", args).ok,
				'check: not instance.dispatch("a", "defend-active", args).ok'
			)
		end
		assert(
			#events == 1 and instance.snapshot("a").balance == 10,
			'check: #events == 1 and instance.snapshot("a").balance == 10'
		)
		assert(instance.dispatch("a", "defend-active", {}).ok, 'check: instance.dispatch("a", "defend-active", {}).ok')
		assert(
			instance.snapshot("a").lastWaveWon == false and instance.snapshot("a").balance == 10,
			'check: instance.snapshot("a").lastWaveWon == false and instance.snapshot("a").balance == 10'
		)
	end,
	["unresolved wave blocks backlog and roster excludes late or rejoined players"] = function()
		local instance = setup()
		assert(instance.join("a", nil).ok, 'check: instance.join("a", nil).ok')
		assert(instance.join("b", nil).ok, 'check: instance.join("b", nil).ok')
		instance.advance(0)
		instance.advance(2)
		instance.advance(1000)
		assert(instance.snapshot("a").waveIndex == 1, 'check: instance.snapshot("a").waveIndex == 1')
		local saved = instance.save("b")
		instance.leave("b")
		assert(instance.join("b", saved).ok, 'check: instance.join("b", saved).ok')
		assert(instance.join("c", nil).ok, 'check: instance.join("c", nil).ok')
		assert(
			not instance.dispatch("b", "defend-active", {}).ok,
			'check: not instance.dispatch("b", "defend-active", {}).ok'
		)
		assert(
			not instance.dispatch("c", "defend-active", {}).ok,
			'check: not instance.dispatch("c", "defend-active", {}).ok'
		)
		assert(instance.dispatch("a", "defend-active", {}).ok, 'check: instance.dispatch("a", "defend-active", {}).ok')
		assert(instance.snapshot("a").lastWaveWon == false, 'check: instance.snapshot("a").lastWaveWon == false')
		instance.advance(1000)
		assert(instance.snapshot("a").waveIndex == 2, 'check: instance.snapshot("a").waveIndex == 2')
		instance.advance(1000)
		assert(instance.snapshot("a").waveIndex == 2, 'check: instance.snapshot("a").waveIndex == 2')
	end,
	["joined participants contribute and each receive one reward"] = function()
		local instance = setup()
		for _, id in { "a", "b", "c" } do
			assert(instance.join(id, nil).ok, "check: instance.join(id, nil).ok")
		end
		instance.advance(0)
		instance.advance(2)
		assert(instance.dispatch("b", "defend-active", {}).ok, 'check: instance.dispatch("b", "defend-active", {}).ok')
		for _, id in { "a", "b", "c" } do
			assert(instance.snapshot(id).balance == 15, "check: instance.snapshot(id).balance == 15")
		end
		assert(
			not instance.dispatch("a", "defend-active", {}).ok,
			'check: not instance.dispatch("a", "defend-active", {}).ok'
		)
	end,
	["wallet injection has single owner and no reward replay"] = function()
		local balance, credits = 10, 0
		local port: Adapter.WalletPort = {
			balance = function(_)
				return balance
			end,
			debit = function(_, amount)
				if balance < amount then
					return false
				end
				balance -= amount
				return true
			end,
			credit = function(_, amount)
				balance += amount
				credits += 1
			end,
		}
		local instance = setup(port, 0)
		assert(instance.join("a", nil).ok, 'check: instance.join("a", nil).ok')
		assert(
			instance.dispatch("a", "buy-defense", {}).ok and balance == 0,
			'check: instance.dispatch("a", "buy-defense", {}).ok and balance == 0'
		)
		instance.advance(0)
		instance.advance(2)
		assert(instance.dispatch("a", "defend-active", {}).ok, 'check: instance.dispatch("a", "defend-active", {}).ok')
		assert(
			balance == 5 and credits == 1 and instance.save("a").balance == nil,
			'check: balance == 5 and credits == 1 and instance.save("a").balance == nil'
		)
		assert(
			not instance.dispatch("a", "defend-active", {}).ok and credits == 1,
			'check: not instance.dispatch("a", "defend-active", {}).ok and credits == 1'
		)
		local saved = instance.save("a")
		instance.leave("a")
		assert(instance.join("a", saved).ok, 'check: instance.join("a", saved).ok')
		assert(balance == 5 and credits == 1, "check: balance == 5 and credits == 1")
		assert(
			not instance.join("b", { upgradeLevel = 0, balance = 10 }).ok,
			'check: not instance.join("b", { upgradeLevel = 0, balance = 10 }).ok'
		)
	end,
	["invalid config and saves reject without mutation"] = function()
		for _, value in { -1, math.huge, 0 / 0, 0.5 } do
			local config = table.clone(Fixture.config)
			config.upgradeCost = value
			assert(#Adapter.validateConfig(config :: any) > 0, "check: #Adapter.validateConfig(config :: any) > 0")
		end
		local instance = setup()
		assert(
			not instance.join("a", { upgradeLevel = 0, balance = 10, waveIndex = 8 }).ok,
			'check: not instance.join("a", { upgradeLevel = 0, balance = 10, waveIndex = 8 }).ok'
		)
		assert(
			not instance.join("a", { upgradeLevel = 0 }).ok,
			'check: not instance.join("a", { upgradeLevel = 0 }).ok'
		)
		assert(instance.join("a", nil).ok, 'check: instance.join("a", nil).ok')
		assert(not instance.join("a", nil).ok, 'check: not instance.join("a", nil).ok')
		assert(
			not instance.dispatch("outsider", "buy-defense", {}).ok,
			'check: not instance.dispatch("outsider", "buy-defense", {}).ok'
		)
		assert(instance.snapshot("a").balance == 10, 'check: instance.snapshot("a").balance == 10')
	end,
}
