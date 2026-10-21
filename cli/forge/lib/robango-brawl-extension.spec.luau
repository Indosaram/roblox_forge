--!strict
local Extension = require("../../../genres/survival-coop/module/BrawlExtension")
local Match = require("../../../core/domain/brawl/Match")
local Policy = require("../../../core/domain/brawl/Policy.fixture")
local Data = require("../../../core/domain/genre/SerializedData")
local Controller = require("../../../genres/survival-coop/module/BrawlController")
local Memory = require("../../../core/infra/data/MemoryBackend")
local World = require("../../../games/robango-island/src/server/BrawlWorld")
local Content = require("../../../games/robango-island/src/shared/SurvivalContent")
return {
	["transaction refusal action verification reward retry and role builder"] = function()
		local state = Match.new("extension", Policy)
		local wallets: any = { a = { balance = 0 }, b = { balance = 0 } }
		local now, fail, hits = 0, false, 0
		local facts = { level = 60, maxHealth = 100, equipment = { durability = 10 } }
		local extension = Extension.new({
			match = {
				snapshot = function()
					return state
				end,
				transaction = function(transform)
					local candidate = Data.clone(state)
					local result = transform(candidate)
					if fail then
						return { ok = false, reason = "COMMIT_FAILED" }
					end
					if result.ok then
						state = candidate
					end
					return result
				end,
			},
			personal = {
				transaction = function(actor, transform)
					local candidate = Data.clone(wallets[actor])
					local result = transform(candidate)
					if fail then
						return { ok = false, reason = "COMMIT_FAILED" }
					end
					if result.ok then
						wallets[actor] = candidate
					end
					return result
				end,
			},
			facts = function()
				return facts
			end,
			now = function()
				return now
			end,
			utc = function()
				return 86400
			end,
			action = function(_actor, token)
				return if token == "shot" then { kind = "ranged", range = 40 } else nil
			end,
			apply = function(candidate: any, actor)
				hits += 1
				candidate.actors[actor].equipment.durability -= 1
				return { ok = true }
			end,
			frame = function()
				return {}, { b = 100 }
			end,
		})
		fail = true
		assert(not extension.command("a", "brawl-queue", {}).ok and not state.actors.a, "BrawlExtension.spec.luau: 46")
		fail = false
		assert(extension.command("a", "brawl-queue", {}).ok, "BrawlExtension.spec.luau: 48")
		assert(extension.command("b", "brawl-queue", {}).ok, "BrawlExtension.spec.luau: 49")
		assert(extension.start().ok, "BrawlExtension.spec.luau: 50")
		now = 30
		assert(not extension.command("a", "brawl-action", { "forged" }).ok, "BrawlExtension.spec.luau: 52")
		assert(extension.command("a", "brawl-action", { "shot" }).ok, "BrawlExtension.spec.luau: 53")
		assert(
			hits == 1 and facts.equipment.durability == 10 and state.actors.a.equipment.durability == 9,
			"BrawlExtension.spec.luau: 54"
		)
		now = 270
		assert(not extension.command("a", "brawl-action", { "shot" }).ok and hits == 1, "BrawlExtension.spec.luau: 56")
		assert(extension.tick().ok and state.winner == "a", "BrawlExtension.spec.luau: 57")
		fail = true
		assert(
			not extension.command("a", "brawl-reward", {}).ok and wallets.a.balance == 0,
			"BrawlExtension.spec.luau: 59"
		)
		fail = false
		assert(extension.command("a", "brawl-reward", {}).amount == 150, "BrawlExtension.spec.luau: 61")
		assert(
			extension.command("a", "brawl-reward", {}).amount == 0 and wallets.a.balance == 150,
			"BrawlExtension.spec.luau: 62"
		)
		local copy = extension.snapshot()
		copy.actors.a.health = 0
		assert(state.actors.a.health == 100, "BrawlExtension.spec.luau: 65")
		local content: any = table.clone(Content)
		content.brawlPolicy = Policy
		local rendered: any = nil
		local plan = World.build({
			content = content,
			isServer = function()
				return true
			end,
			render = function(value)
				rendered = value
			end,
		})
		assert(
			plan == rendered and plan.capacity == 15 and #plan.spawns == 15 and #plan.layout.resourceNodes == 0,
			"BrawlExtension.spec.luau: 70"
		)
	end,
	["factory is opt in and admission gates commands"] = function()
		assert(Extension.factory({ content = {}, world = {} }) == nil, "other packs remain disabled")
		local calls = 0
		local backend = Memory.new()
		local controller = Controller.new({
			store = {
				UpdateAsync = function(_, key, transform)
					local ok, value = backend.update(key, transform)
					assert(ok, value)
					return value
				end,
			},
			owner = "admission-spec",
			leaseSeconds = 120,
			key = "arena",
			matchId = "admission",
			policy = Policy,
			now = function()
				return 0
			end,
			utc = function()
				return 0
			end,
			facts = function()
				calls += 1
				return { level = Policy.minimumLevel, maxHealth = 100, equipment = { durability = 10 } }
			end,
			publish = function() end,
		})
		assert(controller.acquire().ok, "production controller owns durable arena")
		local factory = Extension.factory({
			content = { brawlPolicy = Policy },
			world = {
				brawl = {
					controller = controller,
				},
			},
		})
		assert(
			factory.handles("survival-coop:brawl-queue") and not factory.handles("survival-coop:attack"),
			"scoped actions"
		)
		local result = factory.command("a", "survival-coop:brawl-queue", {}, {}, "client", function()
			return { ok = false, reason = "ADMISSION_REFUSED" }
		end)
		assert(result.reason == "ADMISSION_REFUSED" and calls == 0, "no mutation before admission")
		assert(factory.command("a", "survival-coop:brawl-queue", {}, {}, "client", function()
			return { ok = true }
		end).ok and calls == 1, "admitted command uses runtime")
		assert(controller.snapshot().actors.a, "admitted actor persisted in real match")
		assert(controller.release().ok, "release durable arena")
	end,
}
