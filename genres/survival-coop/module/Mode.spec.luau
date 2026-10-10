--!strict
local Mode = require("./Mode")
local Adapter = require("./Adapter")
local Capabilities = require("./Capabilities")
local Capability = require("../../../core/domain/survival/Capability")
local Fixture = require("./Adapter.fixture")
local Shared = require("../../../core/domain/genre/Contract")

local function services(): Shared.Services
	return {
		now = function()
			return 0
		end,
		roll = function()
			return 0
		end,
		emit = function(_) end,
	}
end

local function craftingConfig(): any
	return { mode = "crafting", currency = "Coins", startingBalance = 10, contentVersion = 1 }
end

local function hasError(errors: { string }, fragment: string): boolean
	for _, err in errors do
		if string.find(err, fragment, 1, true) ~= nil then
			return true
		end
	end
	return false
end

return {
	["an absent mode is the legacy wave loop, byte for byte"] = function()
		local legacy = table.clone(Fixture.config)
		assert(#Mode.validateConfig(legacy :: any) == 0, "legacy config validates unchanged")
		assert(
			#Mode.validateConfig(legacy :: any) == #Adapter.validateConfig(legacy :: any),
			"routing adds no legacy errors"
		)
		local descriptor = Mode.describe(legacy :: any)
		assert(descriptor ~= nil and (descriptor :: any).mode == "wave", "absent mode resolves to wave")
		local instance = Mode.create(legacy :: any, services())
		assert(instance.join("a", nil).ok, "wave join")
		assert(instance.dispatch("a", "buy-defense", {}).ok, "wave actions keep working")
		instance.advance(0)
		instance.advance(2)
		assert(instance.dispatch("a", "defend-active", {}).ok, "wave resolution keeps working")
		local snapshot = instance.snapshot("a")
		assert(snapshot.lastWaveWon == true and snapshot.balance == 5, "legacy reward ledger unchanged")
		local saved = instance.save("a")
		assert(
			saved.upgradeLevel == 1 and saved.balance == 5 and saved.saveVersion == nil,
			"legacy save carries no new marker"
		)
		assert(#Adapter.validateSave(saved) == 0, "legacy save still validates against the original adapter")
	end,

	["an explicit wave mode behaves exactly like the absent default"] = function()
		local explicit = table.clone(Fixture.config) :: any
		explicit.mode = "wave"
		assert(#Mode.validateConfig(explicit) == 0, table.concat(Mode.validateConfig(explicit), "; "))
		local instance = Mode.create(explicit, services())
		assert(instance.join("a", nil).ok and instance.dispatch("a", "buy-defense", {}).ok, "explicit wave works")
		assert(instance.save("a").saveVersion == nil, "explicit wave save stays legacy shaped")
	end,

	["an unknown mode is refused, never silently defaulted"] = function()
		local bad = table.clone(Fixture.config) :: any
		bad.mode = "sandbox"
		assert(hasError(Mode.validateConfig(bad), "mode: expected wave|crafting"), "unknown mode refused")
	end,

	["crafting declares distinct action save and content versions"] = function()
		local wave = Capability.describe("wave")
		local crafting = Capability.describe("crafting")
		assert(wave.saveVersion ~= crafting.saveVersion, "save versions are distinct")
		assert(wave.actionVersion ~= crafting.actionVersion, "action versions are distinct")
		assert(wave.contentVersion == nil and crafting.contentVersion == 1, "only crafting pins a content version")
		assert(#Capability.validateDescriptor(wave) == 0, "wave descriptor is well formed")
		assert(#Capability.validateDescriptor(crafting) == 0, "crafting descriptor is well formed")
		for _, action in
			{
				"gather",
				"settlement-workshop-reserve",
				"settlement-workshop-start",
				"settlement-workshop-complete",
				"settlement-workshop-cancel",
			}
		do
			assert(table.find(crafting.actions, action), "declared shared command: " .. action)
		end
	end,

	["crafting declares its missing features and never fakes them"] = function()
		local missing = Capability.missingFeatures("crafting")
		assert(#missing > 0, "crafting still has unimplemented features")
		assert(Capability.isImplemented("crafting", "inventory"), "inventory is backed by domain transitions")
		assert(Capability.isImplemented("crafting", "crafting-jobs"), "crafting jobs are bound through Workshop")
		for _, feature in { "gathering", "vitals", "placement", "tribe", "wildlife" } do
			assert(table.find(missing, feature) ~= nil, "declared but unimplemented: " .. feature)
			assert(not Capability.isImplemented("crafting", feature), feature .. " must not claim implementation")
			local ok, reason = Capability.assertSupported("crafting", feature)
			assert(not ok and reason ~= nil and string.find(reason :: string, feature, 1, true), "named refusal")
		end
		local ok, reason = Capability.assertSupported("crafting", "teleportation")
		assert(not ok and reason ~= nil and string.find(reason :: string, "not declared", 1, true), "undeclared fails")
		assert(#Capabilities.missing("crafting") == #missing, "the genre descriptor reports the same gap")
	end,

	["a crafting instance refuses unimplemented actions by feature name"] = function()
		local instance = Mode.create(craftingConfig(), services())
		assert(instance.join("a", nil).ok, "crafting join")
		for _, action in { "buy-defense", "defend-active" } do
			local result = instance.dispatch("a", action, {})
			assert(not result.ok, action .. " must not succeed without a mechanism")
			assert(
				result.reason ~= nil and string.find(result.reason :: string, "not implemented", 1, true),
				"refusal names the missing implementation: " .. tostring(result.reason)
			)
		end
		assert(not instance.dispatch("a", "craft", {}).ok, "undeclared action refused")
		local snapshot = instance.snapshot("a")
		assert(snapshot.mode == "crafting" and snapshot.saveVersion == 2, "snapshot reports the crafting capability")
		assert(#snapshot.missingFeatures > 0, "snapshot is honest about the gap")
	end,

	["crafting and wave saves can never be read as each other"] = function()
		local crafting = Mode.create(craftingConfig(), services())
		assert(crafting.join("a", nil).ok, "crafting join")
		local craftSave = crafting.save("a")
		assert(craftSave.saveVersion == 2 and craftSave.balance == 10, "crafting save carries its marker")
		assert(#Mode.validateSave(craftSave) == 0, "crafting save validates in crafting mode")
		assert(#Adapter.validateSave(craftSave) > 0, "the wave reader refuses a crafting save")

		local wave = Mode.create(table.clone(Fixture.config) :: any, services())
		assert(wave.join("a", nil).ok, "wave join")
		local waveSave = wave.save("a")
		assert(#Mode.validateSave(waveSave) == 0, "wave save still validates")
		assert(not crafting.join("b", waveSave).ok, "crafting refuses a legacy wave save")
		assert(not wave.join("b", craftSave).ok, "wave refuses a crafting save")
	end,

	["a newer crafting save is refused rather than downgraded"] = function()
		local future = { saveVersion = 3, balance = 10 }
		local errors = Mode.validateSave(future)
		assert(hasError(errors, "unsupported crafting save 3"), table.concat(errors, "; "))
		local instance = Mode.create(craftingConfig(), services())
		assert(not instance.join("a", future).ok, "a newer save cannot join")
	end,

	["a crafting config rejects wave tuning keys and unsupported content"] = function()
		local mixed = craftingConfig()
		mixed.waveInterval = 2
		assert(hasError(Mode.validateConfig(mixed), "unknown config key"), "wave keys are not silently ignored")
		local stale = craftingConfig()
		stale.contentVersion = 2
		assert(hasError(Mode.validateConfig(stale), "unsupported content version"), "content version is pinned")
	end,
}
