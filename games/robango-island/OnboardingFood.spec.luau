--!strict
-- p134 v43 (staging, phone): three starvation deaths in about an hour. A fresh character starts
-- full (100), but every rift respawn set fullness to 50: empty after 15 min, dead about 8 min
-- later, so a player who had not found food yet (the gather button did nothing, issue 1) died every
-- ~23 min. These scripted first-30-minute runs drive the real onboarding RoleWorld, SurvivalFactory,
-- RescueExtension and Session (the RescueLiveWiring harness) on the shipped content and vitals.
local serde = require("@lune/serde")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content: any = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Session = require("../../core/infra/genre/Session")
local Memory = require("../../core/infra/data/MemoryBackend")
local Clock = require("../../core/infra/genre/Clock")
local Durable = require("./src/shared/GenreDurable")

local DOWNED = "11734795308"

local function boot(saved: any?, startAt: number?)
	local engine = Engine.new(true)
	local forge = engine.forge
	local module = forge.genres["survival-coop"].module
	for _, name in
		{
			"SurvivalBootstrap",
			"Gathering",
			"ToolTiers",
			"GuideEvents",
			"Wildlife",
			"HomeExtension",
			"ArchipelagoExtension",
			"ExpeditionExtension",
			"ProgressionExtension",
			"ProgressionPorts",
			"Extensions",
			"JournalPorts",
			"JournalObjectiveFeed",
			"JournalExtension",
			"RecipeMarks",
			"CarcassExtension",
			"MultistoreyCommands",
		}
	do
		module[name] = (require :: any)("../../genres/survival-coop/module/" .. name)
	end
	forge.core.domain.home = { HomeContent = require("../../core/domain/home/HomeContent") }
	forge.core.domain.settlement = {
		Settlement = require("../../core/domain/settlement/Settlement"),
		Clan = require("../../core/domain/settlement/Clan"),
	}
	forge.core.domain.inventory = {
		Inventory = require("../../core/domain/inventory/Inventory"),
		ItemCatalog = require("../../core/domain/inventory/ItemCatalog"),
	}
	forge.core.domain.crafting = { Job = require("../../core/domain/crafting/Job") }
	forge.core.domain.command = {
		Journal = require("../../core/domain/command/Journal"),
		Ledger = require("../../core/domain/command/Ledger"),
	}
	forge.core.domain.island.Archipelago = require("../../core/domain/island/Archipelago")
	forge.core.infra = {
		render = forge.core.infra.render,
		genre = { Clock = Clock, Session = Session },
		data = {
			ActorDocumentStore = require("../../core/infra/data/ActorDocumentStore"),
			ClanStoreWallet = require("../../core/infra/data/ClanStoreWallet"),
		},
	}
	local at = { value = startAt or 1000 }
	local clock = Clock.new(function()
		return at.value
	end)
	local function now(): number
		return math.floor(at.value)
	end
	local world: any = engine.role.build(Content, Source, Policy, function()
		return at.value * 1000
	end, "rw.onboarding", 1776)
	-- The port RobangoIslandServer.server.luau assigns (C6), on the world's own live reads.
	world.rescue = {
		position = function(actor: string)
			local p = world.rootPosition(actor)
			return if p then { x = p.X, y = p.Y, z = p.Z } else nil
		end,
		health = function(actor: string): number?
			local vitals = world.vitals(actor)
			return if vitals then vitals.healthMilli else nil
		end,
		safe = function(): boolean
			return false
		end,
		camp = function(actor: string)
			local p = world.nearestStation(actor, { "campfire", "fireplace" })
			return if p then { x = p.X, y = p.Y, z = p.Z } else nil
		end,
		name = function(actor: string): string
			return "P" .. actor
		end,
	}
	local factoryBuilder = engine.load("games/robango-island/src/server/SurvivalFactory.luau", {}, {
		Parent = {
			LateEquipmentPorts = require("./src/server/LateEquipmentPorts"),
			WorldDressing = engine.dressing,
		},
	})
	local provision = engine.load("games/robango-island/src/server/SurvivalProvision.luau", {}, nil)(
		{ provisionId = "camp", policy = "public", ownerId = "", acceptedInvitations = {}, actors = {} },
		Source.tribe.config.tribeId,
		{ studio = false, server = "rescue-live" }
	)
	local backend = saved or Memory.new()
	local encode = function(value)
		return serde.encode("json", value)
	end
	local options: any = { sessionId = "rescue-live", leaseSeconds = 120, now = now, budget = { encode = encode } }
	local factory: any = assert(factoryBuilder(Content, Source, world, backend, clock, options, provision, Policy))
	assert(world.downHold, "RescueExtension installed the SurvivalWorld down hold")
	local services = table.clone(factory.services)
	services.now = clock.now
	services.roll = function()
		return 0
	end
	services.emit = function() end
	services.encode = encode
	local session = Session.new({
		packConfig = require("./src/shared/GenreConfig"),
		contracts = { require("../../genres/survival-coop/module/Contract") },
		durable = Durable,
		controls = {},
		storeName = "rescue-live-personal",
	}, backend, { sessionId = "rescue-live", lockTimeout = 120, retries = 0, now = now }, services, Durable)
	factory.bind(session)
	local sequence = 0
	local function command(actor: string, action: string, args: { any }, server: boolean?): any
		sequence += 1
		at.value += 1
		session.advance(clock.now())
		local request = {
			requestId = "rescue-live-" .. sequence,
			sessionEpoch = session.commandEpoch(actor, action),
			action = action,
			args = args,
		}
		return if server then session.commandServer(actor, request) else session.command(actor, request)
	end
	local heartbeat = engine.game:GetService("RunService").Heartbeat
	return {
		engine = engine,
		session = session,
		factory = factory,
		backend = backend,
		command = command,
		at = at,
		heartbeat = function()
			at.value += 1
			heartbeat:Fire()
		end,
	}
end

local MINUTE = 60
local STEP = 5

local function arrive(live: any, actor: string, titleUp: boolean?)
	live.engine.move(actor, Content.homePolicy.dock)
	-- The fixture Humanoid lacks HealthChanged, which the down hold connects to.
	local character = live.engine.game:GetService("Players"):GetPlayerByUserId(tonumber(actor)).Character
	character:FindFirstChildOfClass("Humanoid").HealthChanged = character.AttributeChanged
	-- The player taps Start (TitleFlow.bindWake); `titleUp` keeps the title screen up instead.
	if not titleUp then
		assert(live.session.dispatch(actor, "survival-coop:vitals-wake", {}).ok, "Start")
	end
end

local function vitals(live: any): any
	return live.session.snapshot(DOWNED)["survival-coop"].vitals
end

local function berryId(live: any): string?
	for id, item in live.session.snapshot(DOWNED)["survival-coop"].inventory.bag.items do
		if item.catalogId == "berry" then
			return id
		end
	end
	return nil
end

-- Plays `seconds` of onboarding time in STEP-second heartbeats. With `eat`, the player eats a
-- berry whenever the HUD says hungry, gathering the onboarding berry bush when the bag has none.
-- Returns the lowest health seen.
local gathers = 0
local function play(live: any, seconds: number, eat: boolean): number
	local lowest = vitals(live).healthMilli
	for _ = 1, seconds // STEP do
		live.at.value += STEP - 1
		-- The server Heartbeat advances the session (vitals ticks) and then the world.
		live.session.advance(live.at.value + 1)
		live.heartbeat()
		local state = vitals(live)
		lowest = math.min(lowest, state.healthMilli)
		if eat and state.hungerMilli < 30000 then
			if not berryId(live) then
				local nodes = live.factory.services.survivalGathering.snapshot(DOWNED)
				live.engine.move(DOWNED, nodes.nodes["rw.onboarding.berry"].position)
				-- One frozen request, replayed through the durable transfer as GatheringClient.drive does.
				gathers += 1
				local request = {
					requestId = "food-gather-" .. gathers,
					sessionEpoch = live.session.commandEpoch(DOWNED, "survival-coop:gather"),
					action = "survival-coop:gather",
					args = { "rw.onboarding.berry", nodes.version, "berry" },
				}
				local got = live.session.command(DOWNED, request)
				for _ = 1, 4 do
					if got.ok or type(got.data) ~= "table" or got.data.status ~= "pending" then
						break
					end
					got = live.session.command(DOWNED, request)
				end
				assert(
					got.ok,
					"berry gather: " .. tostring(got.reason) .. " " .. tostring(got.data and got.data.status)
				)
				live.heartbeat()
			end
			local id = assert(berryId(live), "a berry to eat")
			local fed = live.command(DOWNED, "survival-coop:food", { id })
			assert(fed.ok, "eat: " .. tostring(fed.reason))
		end
	end
	return lowest
end

return {
	["a new character eating when prompted never loses health to hunger in its first 30 minutes"] = function()
		local live = boot()
		assert(live.session.join(DOWNED).ok, "join")
		arrive(live, DOWNED)
		local start = vitals(live)
		assert(start.hungerMilli == 100000 and start.healthMilli == 100000, "a new character starts full")
		local lowest = play(live, 30 * MINUTE, true)
		assert(lowest == 100000, "health fell to " .. lowest .. " in the first 30 minutes")
		live.factory.close()
	end,
	["after a rift respawn the character has 30 minutes before hunger hurts"] = function()
		local live = boot()
		assert(live.session.join(DOWNED).ok, "join")
		arrive(live, DOWNED)
		assert(live.command(DOWNED, "survival-coop:vitals-damage", { 100000 }, true).ok, "down")
		local rift = live.command(DOWNED, "survival-coop:rescue-choose", { "rift" })
		assert(rift.ok, "rift: " .. tostring(rift.reason))
		for _ = 1, 10 do
			live.heartbeat()
			if vitals(live).healthMilli > 0 then
				break
			end
		end
		local woke = vitals(live)
		print(string.format("respawn fullness %d health %d", woke.hungerMilli // 1000, woke.healthMilli // 1000))
		assert(woke.healthMilli > 0, "respawned through the rift")
		-- Worst case: the death left no food in the bag and the player has not found the bush yet.
		local lowest = play(live, 30 * MINUTE - 2 * STEP, false)
		assert(
			lowest == woke.healthMilli,
			string.format(
				"respawned at fullness %d; health fell to %d within 30 minutes",
				woke.hungerMilli // 1000,
				lowest
			)
		)
		live.factory.close()
	end,
	-- p134 v49: a returning (not fresh) account started at fullness 8 with no food and starved about
	-- 11 minutes after Start. The join floor (ADR-13) gives a living survivor at least
	-- CraftingAdapter.JOIN_FULLNESS_FLOOR_MILLI on join, through the real Session.join wiring.
	["a returning survivor who logged off nearly empty joins with the fullness floor"] = function()
		local Adapter = require("../../genres/survival-coop/module/CraftingAdapter")
		local first = boot()
		assert(first.session.join(DOWNED).ok, "first join")
		arrive(first, DOWNED)
		-- Spend the bag's berries elsewhere: the worst case is an empty bag.
		while berryId(first) do
			assert(first.command(DOWNED, "survival-coop:food", { berryId(first) }).ok, "eat the starter berries")
		end
		play(first, 59 * MINUTE, false)
		local left = vitals(first)
		assert(left.healthMilli > 0 and left.hungerMilli <= 10000, "logged off nearly empty: " .. left.hungerMilli)
		local leftAt = first.at.value
		assert(first.session.close(DOWNED).ok, "leave saves")
		first.factory.close()
		local back = boot(first.backend, leftAt + 600)
		assert(back.session.join(DOWNED).ok, "rejoin")
		arrive(back, DOWNED)
		local joined = vitals(back)
		assert(
			joined.hungerMilli == Adapter.JOIN_FULLNESS_FLOOR_MILLI,
			"joined at fullness " .. joined.hungerMilli // 1000
		)
		assert(berryId(back) == nil, "still no food in the bag")
		-- The floor is a real runway: 30 minutes of looking for food costs no health.
		local lowest = play(back, 30 * MINUTE, false)
		assert(lowest == joined.healthMilli, "health fell to " .. lowest .. " within 30 minutes of joining")
		back.factory.close()
	end,
	-- p134 v53 (phone): the title sat 65 s before Start and the join floor 50 showed 46 at the first
	-- HUD. Through the real Session.join and the client's wake: hunger holds until Start.
	["fullness holds under the title and drains only after Start reports vitals-wake"] = function()
		local Flow = require("./src/first/TitleFlow")
		local live = boot()
		assert(live.session.join(DOWNED).ok, "join")
		arrive(live, DOWNED, true)
		local joined = vitals(live).hungerMilli
		-- Five minutes on the title screen: the server advances, fullness does not move.
		play(live, 5 * MINUTE, false)
		assert(vitals(live).hungerMilli == joined, "drained under the title to " .. vitals(live).hungerMilli)
		local woke = live.session.dispatch(DOWNED, Flow.WAKE_ACTION, {})
		assert(woke.ok, "wake: " .. tostring(woke.reason))
		play(live, 5 * MINUTE, false)
		local after = vitals(live).hungerMilli
		assert(after < joined, "hunger runs after Start")
		local perMinute = (joined - after) / 5 / 1000
		-- Durango pace (ADR-13): full -> hungry (30) in roughly 45-60 min of active play.
		local toHungry = (100 - 30) / perMinute
		assert(toHungry >= 45 and toHungry <= 60, string.format("full -> hungry in %.1f min", toHungry))
		live.factory.close()
	end,
	["the join hold ends by itself when a client never reports Start"] = function()
		local Adapter = require("../../genres/survival-coop/module/CraftingAdapter")
		local live = boot()
		assert(live.session.join(DOWNED).ok, "join")
		arrive(live, DOWNED, true)
		local joined = vitals(live).hungerMilli
		play(live, Adapter.JOIN_HOLD_MAX_MILLIS // 1000 + 3 * MINUTE, false)
		local after = vitals(live).hungerMilli
		assert(after < joined, "the hold capped, hunger runs")
		assert(joined - after <= 4 * MINUTE * 1000 // 39, "only the time after the cap drained")
		live.factory.close()
	end,
	-- Saves written under the old 18 s/unit rate must keep loading (the old code asserted
	-- "vitals config mismatch" and refused the join), and adopt the new rate.
	["a survivor saved under the old hunger rate rejoins on the new rate"] = function()
		local first = boot()
		assert(first.session.join(DOWNED).ok, "first join")
		arrive(first, DOWNED)
		local leftAt = first.at.value
		assert(first.session.close(DOWNED).ok, "leave saves")
		first.factory.close()
		-- Rewrite the saved vitals config to the v53 shipped rates (no strike cost).
		local rewritten = 0
		local function rewrite(value: any)
			if type(value) ~= "table" then
				return
			end
			if type(value.config) == "table" and value.config.hungerMillisPerUnit ~= nil then
				value.config.hungerMillisPerUnit, value.config.strikeHungerMilli = 18000, nil
				value.hungerRemainder = math.min(value.hungerRemainder, 17999)
				rewritten += 1
			end
			for _, child in value do
				rewrite(child)
			end
		end
		local backend = first.backend
		local old = { update = backend.update }
		for _, key in { "personal:" .. DOWNED, DOWNED } do
			old.update(key, function(raw)
				rewrite(raw)
				return raw
			end)
		end
		assert(rewritten > 0, "found the saved vitals")
		local back = boot(backend, leftAt + 60)
		local joined = back.session.join(DOWNED)
		assert(joined.ok, "rejoin with an old-rate save: " .. tostring(joined.reason))
		arrive(back, DOWNED)
		local state = vitals(back)
		assert(state.config.hungerMillisPerUnit == Content.vitals.hungerMillisPerUnit, "adopted the new rate")
		assert(state.config.strikeHungerMilli == Content.vitals.strikeHungerMilli, "adopted the strike cost")
		back.factory.close()
	end,
	-- p134 v54: 18 berries took fullness 26 -> 56 (+3 each with the join floor masking it) and the
	-- only bush was ~100 studs from the start. Early food has to be worth the walk.
	["a berry is worth about a tenth of the gauge and a bush stands beside the entry"] = function()
		local effect: any = {}
		for _, item in Content.items do
			effect[item.id] = item.foodEffects
		end
		assert(effect.berry.hungerMilli >= 8000 and effect.berry.hungerMilli <= 10000, "berry +8..10")
		assert(effect["cooked-meat"].hungerMilli >= 3 * effect.berry.hungerMilli, "cooked meat is a real meal")
		local entry, nearest = nil :: any, math.huge
		local layout: any
		for _, candidate in Content.layouts do
			layout = if candidate.id == "rw.onboarding" then candidate else layout
		end
		for _, anchor in layout.anchors do
			entry = if anchor.id == "entry" then anchor.position else entry
		end
		for _, node in layout.resourceNodes do
			if node.item == "berry" then
				nearest =
					math.min(nearest, math.sqrt((node.position.x - entry.x) ^ 2 + (node.position.z - entry.z) ^ 2))
			end
		end
		assert(nearest <= 20, string.format("nearest berry bush %.0f studs from the entry", nearest))
		-- And it is a live gather node on the real world, eaten through the real food command.
		local live = boot()
		assert(live.session.join(DOWNED).ok, "join")
		arrive(live, DOWNED)
		local nodes = live.factory.services.survivalGathering.snapshot(DOWNED)
		assert(nodes.nodes["rw.onboarding.berry-2"], "the entry bush is a gather node")
		local id = assert(berryId(live), "starter berries")
		-- Room for a whole berry below full: eight minutes of play after Start.
		play(live, 8 * MINUTE, false)
		local before = vitals(live).hungerMilli
		assert(before <= 100000 - effect.berry.hungerMilli, "room for a berry: " .. before)
		local fed = live.command(DOWNED, "survival-coop:food", { id })
		assert(fed.ok, "eat: " .. tostring(fed.reason))
		local gained = vitals(live).hungerMilli - before
		assert(gained >= 8000, "one berry gave " .. gained)
		live.factory.close()
	end,
}
