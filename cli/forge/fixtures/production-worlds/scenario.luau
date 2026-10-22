--!strict
local Engine = require("./engine")
local Content: any = require("../../../../games/robango-island/src/shared/SurvivalContent")
local Source = require("../../../../games/robango-island/src/shared/SurvivalWorldConfig")
local Policy = require("../../../../games/robango-island/src/shared/WildlifePolicy")
local HomeContent = require("../../../../core/domain/home/HomeContent")
local Session = require("../../../../core/infra/genre/Session")
local Data = require("../../../../core/domain/genre/SerializedData")
local M = {}
local function actorOf(_ctx: any, _step: any): string
	return "11734795308"
end
M.operations = {
	world_join = function(ctx, step): string?
		local ok, result = pcall(ctx.fixture.session.join, actorOf(ctx, step))
		if not ok then
			print(result)
			return "world_join_exception"
		end
		return if result.ok then nil else result.reason
	end,
	world_home = function(ctx, step): string?
		return ctx.fixture.enter("home", actorOf(ctx, step))
	end,
	world_expedition = function(ctx, step): string?
		return ctx.fixture.expedition(actorOf(ctx, step))
	end,
	world_onboarding = function(ctx, step): string?
		return ctx.fixture.onboarding(actorOf(ctx, step))
	end,
	world_warehouse_campfire = function(ctx, step): string?
		return ctx.fixture.warehouseCampfire(actorOf(ctx, step))
	end,
	world_prompt_campfire = function(ctx, step): string?
		local ok, result = xpcall(function()
			return ctx.fixture.warehouseCampfire(actorOf(ctx, step), true)
		end, debug.traceback)
		if not ok then
			print(result)
			return "prompt_campfire_exception"
		end
		return result
	end,
	world_gather = function(ctx, step): string?
		return ctx.fixture.gather(actorOf(ctx, step))
	end,
	world_survey = function(ctx, step): string?
		return ctx.fixture.survey(actorOf(ctx, step))
	end,
	world_return_reload = function(ctx, step): string?
		return ctx.fixture.returnReload(actorOf(ctx, step))
	end,
	world_first_stage = function(ctx, step): string?
		local ok, result = xpcall(function()
			return ctx.fixture.firstStage(actorOf(ctx, step))
		end, debug.traceback)
		if not ok then
			print(result)
			return "first_stage_exception"
		end
		return result
	end,
	world_storage_transfer = function(ctx, step): string?
		return ctx.fixture.storageTransfer(actorOf(ctx, step))
	end,
	world_rescue_cargo = function(ctx, step): string?
		return ctx.fixture.rescueCargo(actorOf(ctx, step), false)
	end,
	world_four_rewards = function(ctx, step): string?
		local ok, result = xpcall(function()
			return ctx.fixture.rescueCargo(actorOf(ctx, step), true)
		end, debug.traceback)
		if not ok then
			print(result)
			return "four_island_exception"
		end
		return result
	end,
	world_score = function(ctx, step): string?
		local ok, result = xpcall(function()
			return ctx.fixture.score(actorOf(ctx, step))
		end, debug.traceback)
		if not ok then
			print(result)
			return "production_score_exception"
		end
		return result
	end,
	world_audio = function(ctx, step): string?
		return ctx.fixture.audio(actorOf(ctx, step))
	end,
	world_clan = function(ctx, step): string?
		local ok, result = xpcall(function()
			return ctx.fixture.clan(actorOf(ctx, step))
		end, debug.traceback)
		if not ok then
			print(result)
			return "production_clan_exception"
		end
		return result
	end,
	world_building = function(ctx, step): string?
		return ctx.fixture.building(actorOf(ctx, step))
	end,
}
function M.new(ctx: any): any
	local engine = Engine.new(true)
	local forge = engine.forge
	local module = forge.genres["survival-coop"].module
	module.HarborFacilities = require("../../../../genres/survival-coop/module/HarborFacilities")
	module.SurvivalBootstrap = require("../../../../genres/survival-coop/module/SurvivalBootstrap")
	module.Gathering = require("../../../../genres/survival-coop/module/Gathering")
	module.Wildlife = require("../../../../genres/survival-coop/module/Wildlife")
	module.HomeExtension = require("../../../../genres/survival-coop/module/HomeExtension")
	module.ArchipelagoExtension = require("../../../../genres/survival-coop/module/ArchipelagoExtension")
	module.ExpeditionExtension = require("../../../../genres/survival-coop/module/ExpeditionExtension")
	module.ProgressionExtension = require("../../../../genres/survival-coop/module/ProgressionExtension")
	module.ProgressionPorts = require("../../../../genres/survival-coop/module/ProgressionPorts")
	module.Extensions = {
		factories = {
			require("../../../../genres/survival-coop/module/ContractsExtension").factory,
			require("../../../../genres/survival-coop/module/ScoreTransport").factory,
			require("../../../../genres/survival-coop/module/EnsembleExtension").factory,
			require("../../../../genres/survival-coop/module/ClanExtension").factory,
			require("../../../../genres/survival-coop/module/OutpostExtension").factory,
		},
	}
	module.JournalPorts = require("../../../../genres/survival-coop/module/JournalPorts")
	module.JournalObjectiveFeed = require("../../../../genres/survival-coop/module/JournalObjectiveFeed")
	module.JournalExtension = require("../../../../genres/survival-coop/module/JournalExtension")
	forge.core.domain.home = { HomeContent = HomeContent }
	forge.core.domain.settlement = { Settlement = require("../../../../core/domain/settlement/Settlement") }
	forge.core.domain.settlement.Clan = require("../../../../core/domain/settlement/Clan")
	forge.core.domain.inventory = {
		Inventory = require("../../../../core/domain/inventory/Inventory"),
		ItemCatalog = require("../../../../core/domain/inventory/ItemCatalog"),
	}
	forge.core.domain.crafting = { Job = require("../../../../core/domain/crafting/Job") }
	forge.core.domain.command = {
		Journal = require("../../../../core/domain/command/Journal"),
		Ledger = require("../../../../core/domain/command/Ledger"),
	}
	forge.core.domain.island.Archipelago = require("../../../../core/domain/island/Archipelago")
	forge.core.infra = {
		render = forge.core.infra.render,
		genre = { Clock = require("../../../../core/infra/genre/Clock"), Session = Session },
		data = { ActorDocumentStore = require("../../../../core/infra/data/ActorDocumentStore") },
	}
	forge.core.infra.data.ClanStoreWallet = require("../../../../core/infra/data/ClanStoreWallet")
	forge.genres["survival-coop"].module.MultistoreyCommands =
		require("../../../../genres/survival-coop/module/MultistoreyCommands")
	local factoryBuilder = engine.load("games/robango-island/src/server/SurvivalFactory.luau", {}, {
		Parent = {
			LateEquipmentPorts = require("../../../../games/robango-island/src/server/LateEquipmentPorts"),
			WorldDressing = engine.dressing,
		},
	})
	local source: any = table.clone(Source)
	source.seed, source.renderRole = ctx.scenario.seed, engine.role.build
	local factory: any, session: any, world: any
	local sequence = 0
	local clanDirectory: any = nil
	local actorId: string? = nil
	local function create(role: string, actor: string)
		sequence += 1
		if role == "preview" then
			world = engine.preview(Content, source, nil, nil, "onboarding", true)
		elseif role == "home" then
			world = engine.home.live(Content, source, Policy, function()
				return ctx.now() * 1000
			end)
		elseif string.sub(role, 1, 3) == "rw." then
			world = engine.role.build(Content, source, Policy, function()
				return ctx.now() * 1000
			end, role, ctx.scenario.seed)
		else
			world = engine.archipelago.live(Content, source, Policy, function()
				return ctx.now() * 1000
			end)
		end
		local options: any = {
			sessionId = "worlds:" .. tostring(sequence),
			leaseSeconds = 120,
			now = ctx.now,
			budget = {
				encode = function(value)
					return require("@lune/serde").encode("json", value)
				end,
			},
		}
		local provisionBuilder = engine.load("games/robango-island/src/server/SurvivalProvision.luau", {}, nil)
		local provision = provisionBuilder(
			{ provisionId = "camp", policy = "public", ownerId = "", acceptedInvitations = {}, actors = {} },
			source.tribe.config.tribeId,
			{ studio = false, server = "worlds:" .. tostring(sequence) }
		)
		world.clanDirectory = clanDirectory
		factory = assert(
			factoryBuilder(
				Content,
				source,
				world,
				ctx.backend,
				ctx.clock,
				options,
				provision,
				if role == "preview" then nil else Policy
			)
		)
		local services = table.clone(factory.services)
		services.now = ctx.clock.now
		services.roll = function()
			return 0
		end
		services.emit = function() end
		services.encode = function(value)
			return require("@lune/serde").encode("json", value)
		end
		session = Session.new(
			{
				packConfig = require("../../../../games/robango-island/src/shared/GenreConfig"),
				contracts = { require("../../../../genres/survival-coop/module/Contract") },
				durable = require("../../../../games/robango-island/src/shared/GenreDurable"),
				controls = {},
				storeName = "worlds-personal",
			},
			ctx.backend,
			{ sessionId = options.sessionId, lockTimeout = 120, retries = 0, now = ctx.now },
			services,
			require("../../../../games/robango-island/src/shared/GenreDurable")
		)
		factory.bind(session)
		actorId = actor
	end
	local api: any = {}
	local function close()
		if not factory then
			return { ok = true }
		end
		for _, actor in session.members() do
			local left = session.close(actor)
			if not left.ok then
				return left
			end
		end
		return factory.close()
	end
	function api.enter(role, actor)
		if factory then
			local closed = close()
			if not closed.ok then
				return closed.reason
			end
		end
		local created, failure = xpcall(function()
			create(role, actor)
		end, debug.traceback)
		if not created then
			print(failure)
			return "world_create_failed"
		end
		local joined = session.join(actor)
		if not joined.ok then
			return joined.reason
		end
		api.session = session
		engine.move(actor, Content.homePolicy.dock)
		local home, reason = factory.homeOwner().snapshot(actor)
		return if home and home.owner == actor then nil else reason or "home_missing"
	end
	function api.expedition(actor)
		local opened = factory.archipelago.open(actor, {
			id = "production-expedition",
			index = 1,
			seed = ctx.scenario.seed,
			revision = "production-v2",
			ttl = 1800,
			entryBuffer = 30,
		})
		if not opened.ok then
			return opened.reason
		end
		source.expedition = factory.expeditionStore.snapshot(actor).archipelago
		return api.enter("archipelago", actor)
	end
	local commandSequence = 0
	local function request(actor: string, action: string, args: { any }): any
		commandSequence += 1
		local qualified = "survival-coop:" .. action
		return {
			requestId = "world-command-" .. tostring(commandSequence),
			sessionEpoch = session.commandEpoch(actor, qualified),
			action = qualified,
			args = args,
		}
	end
	local function refused(actor: string, action: string, args: { any }, reason: string)
		ctx.clock.advanceTo(ctx.clock.now() + 3)
		local result = session.command(actor, request(actor, action, args))
		assert(
			not result.ok and result.reason == reason,
			action .. ": expected " .. reason .. " got " .. tostring(result.reason)
		)
	end
	local function command(actor: string, action: string, args: { any }): any
		ctx.clock.advanceTo(ctx.clock.now() + 3)
		session.advance(ctx.clock.now())
		commandSequence += 1
		local qualified = "survival-coop:" .. action
		local result = session.command(actor, {
			requestId = "onboarding-" .. tostring(commandSequence),
			sessionEpoch = session.commandEpoch(actor, qualified),
			action = qualified,
			args = args,
		})
		assert(result.ok or (result.data and result.data.status == "pending"), action .. ":" .. tostring(result.reason))
		return result
	end
	function api.score(actor)
		local serde = require("@lune/serde")
		local repository = require("../../../../genres/survival-coop/module/ScoreLibraryStore").new({
			dataStoreService = {
				GetDataStore = function(_, name: string)
					return {
						UpdateAsync = function(_, key, transform)
							local ok, value = ctx.backend.update(name .. ":" .. key, transform)
							assert(ok, value)
							return value
						end,
						GetAsync = function(_, key)
							local ok, value = ctx.backend.update(name .. ":" .. key, function(old)
								return old
							end)
							assert(ok, value)
							return value
						end,
					}
				end,
			},
			storeName = "production-scores",
			rules = Content.music,
			maxStoreBytes = 3900000,
			encode = function(value)
				return serde.encode("json", value)
			end,
		})
		local decode = function(text)
			return serde.decode("json", text)
		end
		require("../../../../genres/survival-coop/module/ScoreTransport").configure({
			repository = repository,
			decode = decode,
			uploadTtl = 120,
		})
		require("../../../../genres/survival-coop/module/EnsembleExtension").configure({
			rules = Content.music,
			repository = repository,
			decode = decode,
			inRange = function(id)
				return world.services.survivalDeath.position(id) ~= nil
			end,
		})
		assert(api.enter("home", actor) == nil, "rebuild configured production session")
		local transport = require("../../../../genres/survival-coop/module/ScoreTransport")
		local saved = transport.send(
			{
				rules = Content.music,
				send = function(action, args)
					return command(actor, string.gsub(action, "^survival%-coop:", ""), args)
				end,
			},
			serde.encode("json", {
				version = 1,
				tempo = Content.music.tempoMin,
				parts = {
					{
						instrumentId = "piano",
						notes = {
							{
								startTick = 0,
								durationTicks = Content.music.ticksPerQuarter,
								pitch = 60,
								velocity = 100,
							},
						},
					},
				},
			}),
			nil,
			"production-score-upload"
		)
		assert(saved.ok, saved.reason)
		command(actor, "score-share", { saved.data.scoreId, saved.data.revision, "11734795309" })
		command(actor, "ensemble-join", { saved.data.scoreId, saved.data.revision, 1 })
		command(actor, "ensemble-ready", { true })
		command(actor, "ensemble-start", {})
		local snapshot = session.snapshot(actor).survivalExtensions.ensemble
		assert(snapshot.room and snapshot.room.startAt, "ensemble has authoritative start timestamp")
		return nil
	end
	function api.audio(actor)
		command(actor, "audio-settings", { true, 0.5 })
		local before = session.snapshot(actor).survivalExtensions["audio-settings"]
		assert(before.muted and before.volume == 0.5, "settings committed through Session")
		assert(api.enter("home", actor) == nil, "rejoin home")
		local after = session.snapshot(actor).survivalExtensions["audio-settings"]
		assert(after.muted and after.volume == 0.5, "settings survive fresh profile owner")
		return nil
	end
	function api.building(actor)
		local port = session.personalTransfer(actor)
		local token = assert(port.personal:update(port.profile(), function(data)
			local bag = data.envelope.genres["survival-coop"].data.inventory.bag
			local kits: { [string]: number } = { floor = 3, pillar = 2, stairs = 2, wall = 1, door = 1, roof = 1 }
			for kind, quantity in kits do
				for index = 1, quantity do
					local id = "fixture-" .. kind .. index
					bag.items[id] = {
						itemId = id,
						catalogId = Content.buildingPolicy.kits[kind],
						quantity = 1,
						qualityMilli = 1000,
						durabilityMilli = 0,
						attributes = {},
					}
				end
			end
			return data
		end))
		port.install(token)
		engine.move(actor, Content.homePolicy.dock)
		engine.move(actor, { x = 0, y = Content.homePolicy.dock.y, z = 0 })
		command(
			actor,
			"building-place",
			{ { version = 0, part = { id = "floor1", kind = "floor", x = 0, z = 0, floor = 1 } } }
		)
		assert(session.snapshot(actor).survivalExtensions.building.parts.floor1, "committed floor snapshot")
		local version = 1
		for floor = 1, 3 do
			engine.move(actor, { x = 0, y = Content.homePolicy.dock.y + Content.homePolicy.floors[floor], z = 0 })
			local kinds: { string } = if floor == 3
				then { "floor" }
				elseif floor == 1 then { "pillar", "stairs" }
				else { "floor", "pillar", "stairs" }
			for _, kind in kinds do
				command(
					actor,
					"building-place",
					{ { version = version, part = { id = kind .. floor, kind = kind, x = 0, z = 0, floor = floor } } }
				)
				version += 1
			end
		end
		assert(api.enter("home", actor) == nil, "upper floors survive a fresh owner")
		local topology = session.snapshot(actor).survivalExtensions.building
		assert(topology.parts.floor3 and topology.version == version, "three-floor topology restored")
		local collidable = 0
		for _, part in engine.parts do
			if not part.destroyed and string.sub(part.Name, 1, 9) == "Building:" and part.CanCollide then
				collidable += 1
			end
		end
		assert(
			collidable >= 2 * Content.buildingPolicy.stairSteps + 5,
			"fresh home publishes collidable stairs supports and upper landings"
		)
		engine.move(actor, { x = 0, y = Content.homePolicy.dock.y, z = 0 })
		refused(actor, "building-remove", { { version = version, id = "pillar1" } }, "SUPPORT_REQUIRED")
		for _, id in { "floor3", "stairs2", "pillar2", "floor2", "stairs1", "pillar1", "floor1" } do
			local part = session.snapshot(actor).survivalExtensions.building.parts[id]
			engine.move(actor, { x = 0, y = Content.homePolicy.dock.y + Content.homePolicy.floors[part.floor], z = 0 })
			command(actor, "building-remove", { { version = version, id = id } })
			version += 1
		end
		command(
			actor,
			"building-place",
			{ { version = version, part = { id = "base", kind = "floor", x = 0, z = 0, floor = 1 } } }
		)
		version += 1
		for _, kind in { "wall", "door", "roof" } do
			command(
				actor,
				"building-place",
				{ { version = version, part = { id = kind, kind = kind, x = 0, z = 0, floor = 1 } } }
			)
			version += 1
			command(actor, "building-remove", { { version = version, id = kind } })
			version += 1
		end
		command(actor, "building-remove", { { version = version, id = "base" } })
		local bag = session.personalTransfer(actor).profile().data.envelope.genres["survival-coop"].data.inventory.bag
		local count = 0
		for _, item in bag.items do
			if item.catalogId == "floor-kit" then
				count += item.quantity
			end
		end
		assert(count == 3, "exact kit refunds after three-floor place/reload/remove")
		port = session.personalTransfer(actor)
		local progressed = assert(
			port.personal:update(port.profile(), function(raw)
				raw.envelope.genres["survival-coop"].data.progression.level = 20
				return raw
			end),
			"journal level fixture"
		)
		port.install(progressed)
		command(actor, "journal-open", { "rw.c01.signal-trace" })
		assert(api.enter("rw.explore20", actor) == nil, "exploration role")
		local marker = world.journalTargets["rw.c01.signal-trace.1:1"]
		assert(marker, "authored journal marker")
		engine.move(actor, marker.position)
		command(actor, "journal-interact", { "rw.c01.signal-trace.1:1" })
		assert(api.enter("home", actor) == nil, "journal fresh owner")
		assert(
			session.snapshot(actor).survivalExtensions.journal.counts["rw.c01.signal-trace.1"] == 1,
			"durable survey credit"
		)
		port = session.personalTransfer(actor)
		local materials = assert(
			port.personal:update(port.profile(), function(raw)
				local saved = raw.envelope.genres["survival-coop"].data.inventory.bag
				for _, item in { "stone", "fiber" } do
					saved.items["journal-" .. item] = {
						itemId = "journal-" .. item,
						catalogId = item,
						quantity = 2,
						qualityMilli = 1000,
						durabilityMilli = 0,
						attributes = {},
					}
				end
				return raw
			end),
			"journal materials fixture"
		)
		port.install(materials)
		assert(api.enter("rw.harbor", actor) == nil, "harbor journal workbench")
		engine.move(actor, world.journalTargets["rw.c01.signal-trace.2:1"].position)
		command(actor, "journal-interact", { "rw.c01.signal-trace.2:1" })
		assert(api.enter("rw.harbor", actor) == nil, "assembly crash recovery")
		engine.move(actor, world.journalTargets["rw.c01.signal-trace.2:1"].position)
		ctx.clock.advanceTo(ctx.clock.now() + 6)
		command(actor, "journal-interact", { "rw.c01.signal-trace.2:1" })
		for _, index in { 3, 4 } do
			local id = "rw.c01.signal-trace." .. tostring(index) .. ":1"
			engine.move(actor, world.journalTargets[id].position)
			ctx.clock.advanceTo(ctx.clock.now() + 3)
			engine.interact(actor, id)
			assert(
				session.snapshot(actor).survivalExtensions.journal.counts["rw.c01.signal-trace." .. tostring(index)]
					== 1,
				"physical harbor prompt committed Session checkpoint"
			)
		end
		command(actor, "journal-claim", {})
		assert(
			session.snapshot(actor).survivalExtensions.journal.completed["rw.c01.signal-trace"],
			"production chapter complete"
		)
		local function checkpoint(chapterId, checkpointCount)
			local owner = session.personalTransfer(actor)
			local updated = assert(
				owner.personal:update(owner.profile(), function(raw)
					local data = raw.envelope.genres["survival-coop"].data
					data.progression.level = 60
					data.journal =
						{ version = 1, completed = {}, counts = {}, markers = {}, receipts = {}, active = chapterId }
					for _, chapter in Content.chapters do
						if chapter.id == chapterId then
							for index = 1, checkpointCount do
								local objective = chapter.objectives[index]
								data.journal.counts[objective.id] = objective.quantity
							end
							break
						end
						data.journal.completed[chapter.id] = true
					end
					data.journalOpenedAt = ctx.clock.now()
					data.inventory.bag.items["remedy"] = {
						itemId = "remedy",
						catalogId = "onion-soup",
						quantity = 1,
						qualityMilli = 1000,
						durabilityMilli = 0,
						attributes = {},
					}
					return raw
				end),
				"checkpoint fixture"
			)
			owner.install(updated)
		end
		checkpoint("rw.c04.marsh-remedy", 4)
		assert(api.enter("rw.harbor", actor) == nil, "remedy role")
		local remedy = "rw.c04.marsh-remedy.5:1"
		engine.move(actor, world.journalTargets[remedy].position)
		ctx.clock.advanceTo(ctx.clock.now() + 3)
		engine.interact(actor, remedy)
		assert(
			session
				.personalTransfer(actor)
				.profile().data.envelope.genres["survival-coop"].data.inventory.bag.items.remedy == nil,
			"remedy consumed atomically"
		)
		for _, chapter in Content.chapters do
			local objective = chapter.objectives[#chapter.objectives]
			checkpoint(chapter.id, #chapter.objectives - 1)
			assert(api.enter("rw.harbor", actor) == nil, "harbor chapter dialogue role")
			local markerId = objective.id .. ":1"
			engine.move(actor, world.journalTargets[markerId].position)
			ctx.clock.advanceTo(ctx.clock.now() + 3)
			engine.interact(actor, markerId)
			assert(
				session.snapshot(actor).survivalExtensions.journal.counts[objective.id] == objective.quantity,
				"every chapter dialogue producer commits through its physical NPC prompt"
			)
		end
		checkpoint("rw.c08.collapse-return", 3)
		assert(api.enter("rw.a5.s4", actor) == nil, "journal escort role")
		local rescue = "rw.c08.collapse-return.4:1"
		local position = world.journalTargets[rescue].position
		engine.move(actor, position)
		command(actor, "journal-interact", { rescue })
		assert(api.enter("rw.a5.s4", actor) == nil, "escort restart")
		local exit = world.journalTargets["rw.c08.collapse-return.5:1"].position
		local length = math.sqrt((exit.x - position.x) ^ 2 + (exit.z - position.z) ^ 2)
		for index = 1, math.ceil(length / 4) do
			local t = math.min(1, index * 4 / length)
			engine.move(
				actor,
				{ x = position.x + (exit.x - position.x) * t, y = exit.y, z = position.z + (exit.z - position.z) * t }
			)
			ctx.clock.advanceTo(ctx.clock.now() + 1)
			assert(session.recoverTransfers(actor, 8).ok, "escort movement recovery")
		end
		command(actor, "journal-interact", { "rw.c08.collapse-return.5:1" })
		assert(
			session.snapshot(actor).survivalExtensions.journal.counts["rw.c08.collapse-return.4"] == 1,
			"escort arrival credited"
		)
		checkpoint("rw.c07.tyrant-material", 1)
		port = session.personalTransfer(actor)
		local armed = assert(
			port.personal:update(port.profile(), function(raw)
				raw.envelope.genres["survival-coop"].data.inventory.bag.items["biology-weapon"] = {
					itemId = "biology-weapon",
					catalogId = Content.missionPolicy.starterWeapon,
					quantity = 1,
					qualityMilli = 1000,
					durabilityMilli = 100000,
					attributes = {},
				}
				return raw
			end),
			"biology weapon fixture"
		)
		port.install(armed)
		assert(api.enter("rw.a5.s3", actor) == nil, "tyrannosaurus role")
		local target: any = nil
		for _, spawn in world.roleWildlife.spawns do
			if spawn.catalogId == "tyrannosaurus" then
				target = spawn
				break
			end
		end
		assert(target, "authored tyrannosaurus")
		engine.move(actor, { x = target.position.x, y = target.position.y, z = target.position.z + 2 })
		engine.equip(world, actor, "biology-weapon")
		for hit = 1, 400 do
			if factory.services.survivalWildlife.snapshot(actor)[target.id].healthMilli == 0 then
				break
			end
			if hit % 90 == 0 then
				local owner = session.personalTransfer(actor)
				local repaired = assert(
					owner.personal:update(owner.profile(), function(raw)
						raw.envelope.genres["survival-coop"].data.inventory.bag.items["biology-weapon"].durabilityMilli =
							100000
						return raw
					end),
					"between-hit fixture repair"
				)
				owner.install(repaired)
			end
			command(actor, "attack", { target.id })
			ctx.clock.advanceTo(ctx.clock.now() + 3)
			assert(session.recoverTransfers(actor, 64).ok, "biology kill recovery")
		end
		assert(session.recoverTransfers(actor, 64).ok, "biology committed receipt delivery")
		assert(factory.services.survivalWildlife.snapshot(actor)[target.id].healthMilli == 0, "real tyrannosaurus kill")
		assert(
			session.snapshot(actor).survivalExtensions.journal.counts["rw.c07.tyrant-material.2"] == 1,
			"fresh biological kill credit"
		)
		return nil
	end
	function api.clan(actor)
		local serde = require("@lune/serde")
		local loseCreditAck = false
		clanDirectory = require("../../../../core/infra/data/ClanStore").new({
			dataStore = {
				UpdateAsync = function(_, key, transform)
					local ok, result = ctx.backend.update("clan-directory:" .. key, transform)
					assert(ok, result)
					local record = result.records["clan:native-clan"]
					if loseCreditAck and record then
						local credits = 0
						for _, receipt in (record.data.itemTransfers or {}).receipts or {} do
							if receipt.phase == "CREDITED" then
								credits += 1
							end
						end
						if credits == 2 then
							loseCreditAck = false
							error("native lost clan credit acknowledgement")
						end
					end
					return result
				end,
			},
			rules = Content.clanPolicy,
			maxBytes = 3900000,
			encode = function(value)
				return serde.encode("json", value)
			end,
			fence = { sessionId = "native-clan", leaseSeconds = 120, now = ctx.now },
		})
		assert(api.enter("home", actor) == nil, "rebuild production clan bindings")
		command(actor, "clan-create", { "native-clan" })
		local other = "11734795309"
		assert(session.join(other).ok, "second live Session actor")
		command(actor, "clan-invite", { "native-clan", { target = other } })
		command(other, "clan-join", { "native-clan", {} })
		local funds = session.personalTransfer(actor)
		local token = assert(
			funds.personal:update(funds.profile(), function(data)
				data.envelope.genres["survival-coop"].data.balance = 100
				return data
			end),
			"fixture starting wallet"
		)
		funds.install(token)
		command(actor, "clan-deposit", { "native-clan", { amount = 25 } })
		local state = session.snapshot(actor).survivalExtensions.clan
		assert(state.funds == 25 and state.members[other], "durable clan funds and membership")
		assert(
			session.personalTransfer(actor).profile().data.envelope.genres["survival-coop"].data.balance == 75,
			"same personal wallet debited"
		)
		loseCreditAck = true
		ctx.clock.advanceTo(ctx.clock.now() + 3)
		local interrupted = session.command(actor, request(actor, "clan-deposit", { "native-clan", { amount = 10 } }))
		assert(not interrupted.ok and not loseCreditAck, "credit committed but acknowledgement lost")
		assert(api.enter("home", actor) == nil, "fresh Session recovers retained treasury request")
		assert(session.recoverTransfers(actor, 8).ok, "treasury recovery confirmed")
		state = session.snapshot(actor).survivalExtensions.clan
		assert(state.funds == 35, "credit not repeated after lost acknowledgement")
		assert(
			session.personalTransfer(actor).profile().data.envelope.genres["survival-coop"].data.balance == 65,
			"recovered treasury conserves personal plus clan currency"
		)
		for _, row in state.walletOperations do
			assert(row.result and row.result.ok, "fresh owner finalizes every retained treasury request")
		end
		command(actor, "clan-relocate", { "native-clan", { territory = "rw.home" } })
		assert(close().ok, "release clan before fixture progression")
		local clanStore = clanDirectory.store
		local clanToken = assert(
			clanStore:acquire("clan:native-clan", function(data)
				return data
			end),
			"fixture clan fence"
		)
		clanToken = assert(
			clanStore:update(clanToken, function(data)
				data.level, data.funds = 16, 5000
				return data
			end),
			"fixture research progression"
		)
		assert(clanStore:release(clanToken), "release fixture clan fence")
		-- Existing extension tokens are deliberately invalidated by the fixture
		-- setup, as they would be after a crashed owner. Reopen the real world.
		assert(api.enter("home", actor) == nil, "reload progressed clan")
		local port = session.personalTransfer(actor)
		local itemId = "fixture-clan-hall"
		local bagCatalog = require("../../../../core/domain/inventory/ItemCatalog").new(Content.items)
		local inventory = require("../../../../core/domain/inventory/Inventory")
		local saved = assert(
			port.personal:update(port.profile(), function(raw)
				local slice = raw.envelope.genres["survival-coop"].data
				local bag = inventory.fromSave(slice.inventory.bag, bagCatalog)
				bag = assert(
					inventory.add(bag, bagCatalog, {
						itemId = itemId,
						catalogId = "clan-hall-kit",
						quantity = 1,
						qualityMilli = 1000,
						durabilityMilli = 0,
						attributes = {},
					}, bag.version),
					"fixture hall kit"
				)
				slice.inventory.bag = inventory.save(bag)
				return raw
			end),
			"save hall kit"
		)
		port.install(saved)
		engine.move(actor, source.tribe.warehousePosition)
		command(actor, "transfer-deposit", { itemId, 1 })
		assert(session.recoverTransfers(actor, 8).ok, "hall deposit recovery")
		local shared = session.snapshot(actor).survivalSettlement
		engine.move(actor, { x = 2, y = 2, z = -14 })
		local reserved = command(actor, "settlement-reserve", {
			"clan-hall",
			8,
			1,
			0,
			shared.settlement.version,
			shared.warehouse.version,
			shared.settlement.membershipRevision,
		})
		shared = session.snapshot(actor).survivalSettlement
		command(
			actor,
			"settlement-place",
			{ reserved.data.reservationId, shared.settlement.version, shared.warehouse.version }
		)
		command(actor, "clan-research-start", { "native-clan", { id = "clan-research-advanced-capture" } })
		local research = session.snapshot(actor).survivalExtensions.clan
		local jobId, finishAt
		for id, job in research.jobs do
			jobId, finishAt = id, job.finishAt
		end
		assert(jobId ~= nil and research.funds == 0, "durable research input escrow")
		assert(api.enter("home", actor) == nil, "restart pending research owner")
		ctx.clock.advanceTo(finishAt)
		for _ = 1, 4 do
			assert(session.recoverTransfers(actor, 8).ok, "research recovery pass")
		end
		research = session.snapshot(actor).survivalExtensions.clan
		assert(
			research.jobs[jobId].status == "completed" and research.research["advanced-capture"] == 1,
			"fresh Session finishes durable research"
		)
		assert(api.enter("rw.team-outpost", actor) == nil, "production outpost role")
		local teams = { { actor, other, "11734795310" }, { "11734795311", "11734795312", "11734795313" } }
		for index, team in teams do
			local leader = team[1]
			if leader ~= actor then
				assert(session.join(leader).ok, "join second clan leader")
				command(leader, "clan-create", { "native-rivals" })
			end
			local clanId = if index == 1 then "native-clan" else "native-rivals"
			for slot, player in team do
				if slot > 1 then
					assert(session.join(player).ok, "join queued Session actor")
					if player ~= other then
						command(leader, "clan-invite", { clanId, { target = player } })
						command(player, "clan-join", { clanId, {} })
					end
				end
				engine.move(player, Content.homePolicy.dock)
				command(player, "outpost-queue", { "rw.team-outpost", { enabled = true } })
			end
		end
		assert(session.recoverTransfers(actor, 8).ok, "server forms two queued teams")
		local outpost = session.snapshot(actor).survivalExtensions.outpost
		local matchId: string? = nil
		for id, match in outpost.matches do
			assert(#match.teams == 2 and #match.teams[1].actors == 3, "authoritative three versus three")
			matchId = id
		end
		assert(matchId, "automatic match created")
		local center: any = nil
		for _, anchor in world.layout.anchors do
			if anchor.id == "objective" then
				center = anchor.position
			end
		end
		engine.move(actor, center)
		assert(session.recoverTransfers(actor, 8).ok, "sample live Humanoid occupancy")
		ctx.clock.advanceTo(ctx.clock.now() + Content.outpostPolicy.captureSeconds)
		assert(session.recoverTransfers(actor, 8).ok, "server settles capture interval")
		outpost = session.snapshot(actor).survivalExtensions.outpost
		assert(outpost.owner == "native-clan", "live occupancy wins durable ownership")
		local expiresAt = outpost.expiresAt
		assert(api.enter("rw.team-outpost", actor) == nil, "restart settled outpost owner")
		assert(
			session.snapshot(actor).survivalExtensions.outpost.expiresAt == expiresAt,
			"reconnect cannot extend ownership"
		)
		return nil
	end
	local function gather(actor, item, count)
		local node
		for _, candidate in world.roleSource.nodes do
			if candidate.id == "rw.home." .. item then
				node = candidate
			end
		end
		assert(node, "onboarding node missing: " .. item)
		engine.move(actor, node.position)
		for _ = 1, count do
			local snapshot = factory.services.survivalGathering.snapshot(actor)
			command(actor, "gather", { node.id, snapshot.version })
			local settled = factory.services.survivalGathering.recover(actor, 8)
			assert(settled.status == "confirmed", settled.error)
		end
	end
	local function personal(actor)
		return session.personalTransfer(actor).profile().data.envelope.genres["survival-coop"].data
	end
	function api.warehouseCampfire(actor, clientPrompts)
		assert(api.enter("preview", actor) == nil, "fresh preview admission")
		local gatherClient
		if clientPrompts then
			gatherClient = engine.gatherClient(actor, function(verb, payload)
				if verb == nil then
					return {
						ok = true,
						durable = {
							actions = { "survival-coop:gather" },
							epochs = { ["survival-coop:gather"] = session.commandEpoch(actor, "survival-coop:gather") },
						},
					}
				end
				assert(verb == "command", "same client command ingress")
				return session.command(actor, payload)
			end)
		end
		local function gatherNode(node: any)
			ctx.clock.advanceTo(ctx.clock.now() + 3)
			session.advance(ctx.clock.now())
			engine.move(actor, { x = node.position.x + 3, y = node.position.y + 3, z = node.position.z })
			if clientPrompts then
				engine.interact(actor, node.id)
			else
				command(actor, "gather", { node.id, factory.services.survivalGathering.snapshot(actor).version })
			end
			assert(factory.services.survivalGathering.recover(actor, 8).status == "confirmed", "gather recovery")
			if gatherClient and gatherClient.result().data.status == "pending" then
				engine.interact(actor, node.id)
				assert(gatherClient.result().ok, "same prompt confirms recovered gather")
			end
		end
		local camp = session.snapshot(actor).survivalSettlement
		assert(camp.settlement.roles[actor] == "owner", "fresh owner")
		local node = source.nodes[1]
		for _, candidate in source.nodes do
			if candidate.id == "fallen-tree-01" then
				node = candidate
			end
		end
		if clientPrompts then
			for _, kind in { "fiber", "flint" } do
				local target
				for _, candidate in source.nodes do
					for _, definition in Content.nodes do
						if definition.id == candidate.catalogId and definition.harvest[1].item == kind then
							target = candidate
						end
					end
				end
				assert(target, kind .. " starter node")
				gatherNode(target)
			end
		end
		for _ = 1, 2 do
			gatherNode(node)
		end
		if clientPrompts then
			local reserved = command(actor, "craft-reserve", { "stone-axe", "hand" })
			assert(reserved.ok, "gathered materials reserve stone axe")
			local job = reserved.data.jobId
			assert(command(actor, "craft-start", { job }).ok, "axe starts")
			ctx.clock.advanceTo(ctx.clock.now() + 3)
			assert(command(actor, "craft-complete", { job }).ok, "axe completes")
			assert(
				session.snapshot(actor).survivalExtensions.contracts.tutorial.step == "declare-settlement",
				"real craft feed advances axe objective"
			)
		end
		-- Stand beyond the visual depot: its old collidable box blocked the reach ray.
		engine.move(actor, { x = 6, y = 2, z = -22 })
		local remaining = 4
		for id, item in personal(actor).inventory.bag.items do
			if item.catalogId == "wood" and remaining > 0 then
				local quantity = math.min(remaining, item.quantity)
				local deposited = command(actor, "transfer-deposit", { id, quantity })
				assert(deposited.ok and deposited.data.phase == "FINALIZED", "deposit confirms immediately")
				remaining -= quantity
			end
		end
		assert(remaining == 0, "four gathered wood deposited")
		if clientPrompts then
			assert(
				session.snapshot(actor).survivalExtensions.contracts.tutorial.step == "declare-settlement",
				"deposit preserves next unmet tutorial objective"
			)
		end
		engine.move(actor, { x = -6, y = 3, z = -10 })
		camp = session.snapshot(actor).survivalSettlement
		local reserved = command(actor, "settlement-reserve", {
			"campfire",
			6,
			1,
			0,
			camp.settlement.version,
			camp.warehouse.version,
			camp.settlement.membershipRevision,
		})
		camp = session.snapshot(actor).survivalSettlement
		command(
			actor,
			"settlement-place",
			{ reserved.data.reservationId, camp.settlement.version, camp.warehouse.version }
		)
		assert(next(session.snapshot(actor).survivalSettlement.warehouse.items) == nil, "warehouse paid campfire cost")
		local station
		for _, value in engine.parts do
			if value:GetAttribute("ForgeStructureId") then
				local visual = assert(value:FindFirstChild("campfire"), "built campfire uses authored kit")
				local flame, light, pieces = false, false, 0
				for _, piece in visual:GetDescendants() do
					flame = flame or piece:IsA("Fire")
					light = light or piece:IsA("PointLight")
					if piece:IsA("BasePart") then
						pieces += 1
					end
				end
				assert(pieces > 8 and flame and light, "built fire has stone ring logs flame and light")
				station = value:GetAttribute("ForgeStationId")
				engine.move(actor, { x = value.Position.X, y = value.Position.Y + 3, z = value.Position.Z })
			end
		end
		assert(station, "new campfire published")
		if clientPrompts then
			assert(
				session.snapshot(actor).survivalExtensions.contracts.tutorial.step ~= "declare-settlement",
				"real placement feed advances settlement objective"
			)
		end
		assert(command(actor, "rest", { station }).ok, "rest at new campfire")
		if clientPrompts then
			assert(
				session.snapshot(actor).survivalExtensions.contracts.tutorial.step == "accept-contract",
				"rest preserves the contract objective after building"
			)
		end
		if gatherClient then
			gatherClient.destroy()
		end
		return nil
	end
	local function craft(actor: string, recipeId: string, station: string?)
		local recipe
		for _, row in Content.recipes do
			if row.id == recipeId then
				recipe = row
			end
		end
		assert(recipe, "onboarding recipe missing")
		if station then
			for _, anchor in world.layout.anchors do
				if anchor.id == station then
					engine.move(actor, anchor.position)
				end
			end
		end
		local result = command(actor, "craft-reserve", { recipeId, station or "hand" })
		local job = result.data.jobId
		command(actor, "craft-start", { job })
		ctx.clock.advanceTo(ctx.clock.now() + recipe.craftMillis / 1000)
		command(actor, "craft-complete", { job })
	end
	function api.storageTransfer(actor)
		gather(actor, "branch", 2)
		local id, quantity
		for key, item in personal(actor).inventory.bag.items do
			if item.catalogId == "branch" then
				id, quantity = key, item.quantity
			end
		end
		assert(id and quantity, "gathered owned branch")
		engine.move(actor, Content.homePolicy.dock)
		refused(actor, "home-deposit", { "home:other", { itemId = id, quantity = 1 } }, "WRONG_HOME_TOKEN")
		refused(
			actor,
			"home-deposit",
			{ "home:" .. actor, { itemId = id, quantity = quantity + 1 } },
			"INSUFFICIENT_ITEMS"
		)
		local deposit = request(actor, "home-deposit", { "home:" .. actor, { itemId = id, quantity = quantity } })
		assert(session.command(actor, deposit).ok, "deposit commits")
		assert(session.command(actor, deposit).ok, "deposit replay")
		assert(personal(actor).inventory.bag.items[id] == nil, "bag debited once")
		local home = factory.homeOwner().snapshot(actor)
		assert(home.storage.items[id].quantity == quantity, "home credited once")
		assert(api.enter("home", actor) == nil, "reconnect")
		command(actor, "home-withdraw", { "home:" .. actor, { itemId = id, quantity = quantity } })
		assert(personal(actor).inventory.bag.items[id].quantity == quantity, "same identity and quantity returned")
		refused(actor, "home-withdraw", { "home:" .. actor, { itemId = id, quantity = 1 } }, "INSUFFICIENT_ITEMS")
		return nil
	end
	local function anchor(id)
		for _, row in world.layout.anchors do
			if row.id == id then
				return row.position
			end
		end
		error("missing anchor " .. id)
	end
	local function reloadStage(actor)
		source.expedition = factory.expeditionStore.snapshot(actor).archipelago
		assert(api.enter("archipelago", actor) == nil, "enter stage")
	end
	local function mission(actor, action)
		return command(actor, "mission-action", { action, world.layout.id })
	end
	local function recover(actor)
		assert(session.recoverTransfers(actor, 64).ok, "production recovery")
	end
	local function hunt(actor)
		local objective
		for _, row in Content.stages do
			if row.layout == world.layout.id then
				for _, candidate in row.objectives do
					if candidate.action == "hunt" then
						objective = candidate
					end
				end
			end
		end
		for _, spawn in world.roleWildlife.spawns do
			if spawn.catalogId == objective.target then
				local target = { x = spawn.position.x, y = spawn.position.y, z = spawn.position.z + 2 }
				engine.move(actor, target)
				engine.equip(world, actor, api.spear)
				for _ = 1, 100 do
					local npcs = factory.services.survivalWildlife.snapshot(actor)
					if npcs[spawn.id].healthMilli == 0 then
						break
					end
					command(actor, "attack", { spawn.id })
					ctx.clock.advanceTo(ctx.clock.now() + Content.progressionPolicy.combat.windupMillis / 1000)
					recover(actor)
				end
				recover(actor)
				local state = factory.expeditionStore.snapshot(actor).archipelago
				if state.completed[objective.id] then
					return
				end
			end
		end
		error("hunt objective not completed")
	end
	function api.rescueCargo(actor, finish)
		assert(api.onboarding(actor) == nil, "legitimate onboarding")
		local initialBalance = personal(actor).balance
		gather(actor, "branch", 3)
		gather(actor, "stone", 2)
		craft(actor, "starter-club", "station.workbench.t1")
		for id, item in personal(actor).inventory.bag.items do
			if item.catalogId == "starter-club" then
				api.spear = id
			end
		end
		assert(api.spear, "owned crafted club")
		assert(api.expedition(actor) == nil, "eligible expedition")
		refused(actor, "mission-action", { "next-island", "none" }, "mission_gate")
		assert(api.gather(actor) == nil, "stage one gather")
		assert(api.survey(actor) == nil, "stage one survey")
		mission(actor, "next-island")
		reloadStage(actor)
		engine.move(actor, anchor("objective"))
		refused(actor, "mission-action", { "rescue-treat", world.layout.id }, "BANDAGE_REQUIRED")
		local origin, offset = anchor("objective"), Content.missionPolicy.bandageOffset
		engine.move(actor, { x = origin.x + offset.x, y = origin.y + offset.y, z = origin.z + offset.z })
		mission(actor, "bandage-claim")
		refused(actor, "mission-action", { "bandage-claim", world.layout.id }, "already_claimed")
		engine.move(actor, origin)
		mission(actor, "rescue-treat")
		local state = factory.expeditionStore.snapshot(actor).archipelago
		assert(
			state.treated and state.bandage == 0 and not state.completed["rw.a1.s2.rescue"],
			"treatment consumes reserve, not completion"
		)
		engine.move(actor, anchor("entry"))
		ctx.clock.advanceTo(ctx.clock.now() + 10)
		recover(actor)
		state = factory.expeditionStore.snapshot(actor).archipelago
		assert(state.escort.position.x == origin.x, "escort stops beyond 24")
		reloadStage(actor)
		state = factory.expeditionStore.snapshot(actor).archipelago
		assert(
			state.treated and (not state.escort or state.escort.position.x == origin.x),
			"disconnect retains treatment and resets NPC"
		)
		local destination = anchor("entry")
		local dx, dy, dz = destination.x - origin.x, destination.y - origin.y, destination.z - origin.z
		local length = math.sqrt(dx ^ 2 + dy ^ 2 + dz ^ 2)
		engine.move(actor, origin)
		recover(actor)
		local steps = math.ceil(length / Content.missionPolicy.followStuds)
		for index = 1, steps do
			local alpha = index / steps
			engine.move(actor, { x = origin.x + dx * alpha, y = origin.y + dy * alpha, z = origin.z + dz * alpha })
			ctx.clock.advanceTo(ctx.clock.now() + 1)
			recover(actor)
		end
		assert(factory.expeditionStore.snapshot(actor).archipelago.completed["rw.a1.s2.rescue"], "escort arrival")
		-- The real hand recipe consumes bag branch and runs at the rendered campfire.
		craft(actor, "dry-twig", "station.campfire.t1")
		mission(actor, "next-island")
		reloadStage(actor)
		engine.move(actor, anchor("objective"))
		refused(actor, "mission-action", { "cargo-deliver", world.layout.id }, "COMPLETE_CARGO_REQUIRED")
		engine.move(actor, anchor("resources"))
		mission(actor, "cargo-claim")
		refused(actor, "mission-action", { "cargo-claim", world.layout.id }, "MISSION_SLOT_FULL")
		state = factory.expeditionStore.snapshot(actor).archipelago
		assert(state.questCargo.slots == 1 and state.questCargo.quantity == 5, "separate complete bundle")
		engine.move(actor, anchor("objective"))
		mission(actor, "cargo-deliver")
		assert(factory.expeditionStore.snapshot(actor).archipelago.questCargo == nil, "cargo consumed")
		refused(actor, "mission-action", { "cargo-deliver", world.layout.id }, "objective_mismatch")
		if not finish then
			return nil
		end
		hunt(actor)
		mission(actor, "next-island")
		reloadStage(actor)
		assert(api.survey(actor) == nil, "last survey")
		hunt(actor)
		mission(actor, "next-island")
		recover(actor)
		local document = factory.expeditionStore.snapshot(actor)
		assert(
			document.archipelago.status == "complete" and document.development.instabilityAccess == 2,
			"four island clear"
		)
		-- One settlement per completed mission (six a1 missions, eight objectives),
		-- each a first clear at the full catalog reward. Guide rewards share the outbox
		-- (keyed "guide:") and were settled during onboarding, before initialBalance.
		local expected, actual = 0, 0
		for id, entry in document.missionRewards do
			if string.sub(id, 1, 6) == "guide:" then
				assert(entry.settled, "guide rewards acknowledged")
				continue
			end
			expected += entry.rewards.coins
			assert(entry.settled, "all outbox rewards acknowledged")
			assert(not entry.repeatClear, "first route clear pays full reward")
			actual += 1
		end
		assert(
			actual == 6 and personal(actor).balance == initialBalance + expected,
			"six catalog mission settlements: "
				.. tostring(actual)
				.. ":"
				.. tostring(personal(actor).balance)
				.. ":"
				.. tostring(initialBalance + expected)
		)
		local beforeBalance = personal(actor).balance
		local beforeProgression = require("../../../../core/domain/command/Journal").hash(personal(actor).progression)
		recover(actor)
		assert(api.enter("home", actor) == nil, "reward reconnect")
		recover(actor)
		assert(personal(actor).balance == beforeBalance, "no reconnect coin award")
		assert(
			require("../../../../core/domain/command/Journal").hash(personal(actor).progression) == beforeProgression,
			"no reconnect XP award"
		)
		return nil
	end
	function api.onboarding(actor)
		-- Paid guide XP can lift a fresh player past the level gate; the development gate still holds.
		local refusal = api.expedition(actor)
		if refusal ~= "level_gate" and refusal ~= "development_gate" then
			return "fresh_entry_gate_missing"
		end
		gather(actor, "branch", 4)
		gather(actor, "stone", 2)
		gather(actor, "fiber", 1)
		craft(actor, "campfire-kit", nil)
		craft(actor, "dry-twig", "station.campfire.t1")
		craft(actor, "starter-axe", "station.workbench.t1")
		for id, item in personal(actor).inventory.bag.items do
			if item.catalogId == "starter-axe" then
				api.axe = id
			end
		end
		assert(api.axe, "starter axe was not crafted")
		engine.equip(world, actor, api.axe)
		local wood
		for _, node in world.roleSource.nodes do
			if node.id == "rw.home.extra-0" then
				wood = node
			end
		end
		engine.move(actor, wood.position)
		for _ = 1, 2 do
			command(actor, "gather", { wood.id, factory.services.survivalGathering.snapshot(actor).version })
			assert(factory.services.survivalGathering.recover(actor, 8).status == "confirmed", "wood recovery")
		end
		engine.move(actor, source.tribe.warehousePosition)
		for id, item in personal(actor).inventory.bag.items do
			if item.catalogId == "wood" then
				command(actor, "transfer-deposit", { id, item.quantity })
			end
		end
		assert(session.recoverTransfers(actor, 8).ok, "deposit recovery")
		engine.move(actor, { x = 2, y = 2, z = -14 })
		local shared = session.snapshot(actor).survivalSettlement
		local reservation = command(actor, "settlement-reserve", {
			"campfire",
			8,
			1,
			0,
			shared.settlement.version,
			shared.warehouse.version,
			shared.settlement.membershipRevision,
		})
		shared = session.snapshot(actor).survivalSettlement
		command(
			actor,
			"settlement-place",
			{ reservation.data.reservationId, shared.settlement.version, shared.warehouse.version }
		)
		engine.move(actor, { x = -12, y = 2, z = -16 })
		command(actor, "rest", { "station.campfire.t1" })
		local development = factory.expeditionStore.snapshot(actor).development
		if development.points < 200 or personal(actor).progression.level < 2 then
			return "onboarding_progress_missing"
		end
		if personal(actor).progression.mastery.construction.level ~= 1 then
			return "placement_proficiency_missing"
		end
		return nil
	end
	function api.gather(actor)
		engine.equip(world, actor, api.axe)
		local node = world.roleSource.nodes[1]
		for _, candidate in world.roleSource.nodes do
			if candidate.id == "rw.a1.s1.material.wood" then
				node = candidate
			end
		end
		engine.move(actor, node.position)
		for index = 1, 5 do
			local action = "survival-coop:gather"
			local epoch = session.commandEpoch(actor, action)
			local snapshot = factory.services.survivalGathering.snapshot(actor)
			local result = session.command(actor, {
				requestId = "world-gather-" .. tostring(index),
				sessionEpoch = epoch,
				action = action,
				args = { node.id, snapshot.version },
			})
			if not result.ok and (not result.data or result.data.status ~= "pending") then
				return result.reason or "gather_failed"
			end
			local settled = factory.services.survivalGathering.recover(actor, 8)
			if settled.status ~= "confirmed" then
				return settled.error or "gather_not_finalized"
			end
		end
		return nil
	end
	function api.survey(actor)
		local ids = {}
		for id in world.surveyMarkers do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			local marker = world.surveyMarkers[id]
			engine.move(actor, marker.position)
			local result = command(actor, "mission-action", { "survey-start", id })
			if not result.ok then
				return result.reason
			end
			ctx.clock.advanceTo(ctx.clock.now() + Content.missionPolicy.surveySeconds)
			assert(session.recoverTransfers(actor, 64).ok, "survey recovery")
		end
		return nil
	end
	-- Fresh-ish player (a1 entry level, own crafted starter axe) clears a1.s1 and departs.
	function api.firstStage(actor)
		assert(api.onboarding(actor) == nil, "legitimate onboarding")
		local level = personal(actor).progression.level
		if level >= 30 then
			return "not_fresh:" .. tostring(level)
		end
		local initialBalance = personal(actor).balance
		local opened = api.expedition(actor)
		if opened then
			return "expedition:" .. opened
		end
		refused(actor, "mission-action", { "next-island", "none" }, "mission_gate")
		local gathered = api.gather(actor)
		if gathered then
			return "gather:" .. gathered
		end
		local state = factory.expeditionStore.snapshot(actor).archipelago
		if not state.completed["rw.a1.s1.gather"] then
			return "wood_objective_incomplete:" .. tostring(state.progress["rw.a1.s1.gather"])
		end
		-- Node level is the minted material level: first-route wood must match the route.
		for _, item in personal(actor).inventory.bag.items do
			if item.catalogId == "wood" and item.material and item.material.level > state.index * 10 then
				return "first_route_wood_level:" .. tostring(item.material.level)
			end
		end
		local surveyed = api.survey(actor)
		if surveyed then
			return "survey:" .. surveyed
		end
		local departed = command(actor, "mission-action", { "next-island", world.layout.id })
		if not departed.ok then
			return "depart:" .. tostring(departed.reason)
		end
		assert(session.recoverTransfers(actor, 64).ok, "reward recovery")
		assert(session.recoverTransfers(actor, 64).ok, "reward replay")
		local document = factory.expeditionStore.snapshot(actor)
		if document.archipelago.stage ~= 2 then
			return "stage_not_advanced"
		end
		local paid = 0
		for _, entry in document.missionRewards or {} do
			if entry.mission == "rw.m1.gather" then
				paid += 1
				if not entry.settled then
					return "reward_unsettled"
				end
			end
		end
		local reward = 0
		for _, row in Content.missions do
			if row.id == "rw.m1.gather" then
				reward = row.rewards.coins
			end
		end
		if paid ~= 1 or personal(actor).balance ~= initialBalance + reward then
			return "reward_not_once:" .. tostring(paid) .. ":" .. tostring(personal(actor).balance - initialBalance)
		end
		return nil
	end
	function api.returnReload(actor)
		local expedition = factory.expeditionStore.snapshot(actor).archipelago
		if not expedition.completed["rw.a1.s1.gather"] or not expedition.completed["rw.a1.s1.survey"] then
			return "objectives_not_persisted"
		end
		local before =
			Data.clone(session.personalTransfer(actor).profile().data.envelope.genres["survival-coop"].data.inventory)
		local home = factory.homeOwner().snapshot(actor)
		local result = session.prepareHandoff(actor)
		if not result.ok then
			return result.reason
		end
		local resumed = session.resumeHandoff(actor)
		if not resumed.ok then
			return resumed.reason
		end
		local reason = api.enter("home", actor)
		if reason then
			return reason
		end
		local after = session.personalTransfer(actor).profile().data.envelope.genres["survival-coop"].data.inventory
		local Journal = require("../../../../core/domain/command/Journal")
		if Journal.hash(before) ~= Journal.hash(after) then
			return "inventory_changed"
		end
		local loaded = factory.homeOwner().snapshot(actor)
		if loaded.homeId ~= home.homeId or loaded.landRank ~= home.landRank then
			return "home_changed"
		end
		return nil
	end
	api.close = close
	api.snapshot = function()
		return { actor = actorId, layout = if world and world.layout then world.layout.id else nil, sequence = sequence }
	end
	-- A production session is constructed by the first world operation, not a fixture profile.
	api.session = {
		join = function(actor)
			return { ok = api.enter("home", actor) == nil }
		end,
	}
	return api
end
return M
