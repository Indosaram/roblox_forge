--!strict
local HomeExtension = require("./HomeExtension")
local HomeContent = require("../../../core/domain/home/HomeContent")
local Home = require("../../../core/domain/home/HomeState")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Fenced = require("../../../core/infra/data/FencedStore")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Session = require("../../../core/infra/genre/Session")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
-- These pack-only modules are intentionally absent from other packs' sourcemaps.
local Content: any = luau.load(fs.readFile("games/robango-island/src/shared/SurvivalContent.luau"))()
local Rng = require("../../../core/domain/random/Rng")
local Dressing: any = luau.load(fs.readFile("games/robango-island/src/server/WorldDressing.luau"), {
	environment = {
		require = function(key)
			assert(key == "../../../../core/domain/random/Rng", "unexpected dressing dependency")
			return Rng
		end,
	},
})()
local World: any = luau.load(fs.readFile("games/robango-island/src/server/HomeWorld.luau"), {
	environment = {
		require = function(key)
			assert(key == "./WorldDressing", "unexpected home dependency")
			return Dressing
		end,
	},
})()

return {
	["home content uses all eight generated planting operations including flaxseed output"] = function()
		local crops = HomeContent.crops(Content)
		local count = 0
		for _ in crops do
			count += 1
		end
		assert(count == 8 and crops.flax.output == "flaxseed" and crops.corn.seconds == 600, "home invariant: 20")
	end,
	["home extension fenced new server persistence handoff idempotency and stolen lease"] = function()
		local backend = Memory.new()
		local now = 10
		local server = "server-a"
		local definitions: { Catalog.Definition } = {}
		for _, item in Content.items do
			table.insert(definitions, {
				id = item.id,
				stackMax = item.stackMax,
				weightMilli = item.weightMilli,
				maxDurabilityMilli = item.maxDurabilityMilli,
			})
		end
		local catalog = Catalog.new(definitions)
		local rules = {
			baseSlots = 20,
			storageGrants = {},
			landSizes = { 64 },
			floors = { 2, 14, 26 },
			dock = { x = 0, y = 2, z = 144 },
			plots = { p1 = true },
		}
		local function new(): any
			return HomeExtension.new({
				content = Content,
				rules = rules,
				structures = {},
				seed = function()
					return 74
				end,
				now = function()
					return now
				end,
				store = function()
					return Fenced.new(backend, {
						sessionId = server,
						now = function()
							return now
						end,
						leaseSeconds = 30,
					})
				end,
				ownerOf = function(_actor, token)
					return if token == "home:owner" then "owner" else nil
				end,
				facts = function()
					return { reachable = true, ownerOnline = false, nodes = { farming_1 = true } }
				end,
				initialStorage = function(_owner, storage)
					local bag = Inventory.fromSave(storage, catalog)
					for _, item in { { "seed", "corn-seed" }, { "water", "water" } } do
						bag = assert(Inventory.add(bag, catalog, {
							itemId = item[1],
							catalogId = item[2],
							quantity = 1,
							qualityMilli = 1000,
							durabilityMilli = 0,
							attributes = { level = 30 },
						}, bag.version))
					end
					return Inventory.save(bag)
				end,
			})
		end
		local extension = new()
		local function command(ext: any, actor: string, action: string, args: any, id: string): any
			return ext.command(
				actor,
				action,
				{ "home:owner", args },
				{ actorId = actor, requestId = id, sessionEpoch = 1 },
				"server",
				function()
					return { ok = true }
				end
			)
		end
		assert(
			command(
				extension,
				"owner",
				"survival-coop:home-plant",
				{ plot = "p1", crop = "corn", seedItem = "seed" },
				"plant"
			).ok,
			"home invariant: 50"
		)
		assert(
			command(extension, "owner", "home-plant", { plot = "p1", crop = "corn", seedItem = "seed" }, "plant").ok,
			"home invariant: 50"
		)
		local life = Session.lifecycle(extension)
		assert(assert(life.drain)("owner").ok and assert(life.releaseActor)("owner").ok, "home invariant: 53")
		assert(not command(extension, "owner", "home-harvest", { plot = "p1" }, "left").ok, "home invariant: 54")
		assert(assert(life.resumeActor)("owner").ok, "home invariant: 55")
		assert(extension.close().ok, "home invariant: 56")
		server = "server-b"
		now = 610
		extension = new()
		local snapshot = assert(extension.snapshot("owner"))
		assert(snapshot.homeId == "home:owner" and snapshot.plots.p1.readyAt == 610, "home invariant: 61")
		assert(
			command(extension, "intruder", "home-harvest", { plot = "p1" }, "intruder").reason == "FORBIDDEN",
			"home invariant: 62"
		)
		assert(command(extension, "owner", "home-harvest", { plot = "p1" }, "harvest").ok, "home invariant: 63")
		assert(
			command(extension, "owner", "home-harvest", { plot = "p1" }, "double").reason == "EMPTY_PLOT",
			"home invariant: 64"
		)
		assert(
			extension.snapshot("owner").storage.items["home:owner:crop:1"].quantity == 3,
			"harvest credits exactly three"
		)
		now = 641
		local thief = Fenced.new(backend, {
			sessionId = "new-writer",
			now = function()
				return now
			end,
			leaseSeconds = 30,
		})
		assert(thief:acquire("home:owner", function(data)
			return data
		end))
		assert(command(extension, "owner", "home-capacity", {}, "stale").reason == "lease lost", "home invariant: 69")
	end,
	["home world role is deterministic server only and starter pads fit initial land"] = function()
		local rules = {
			baseSlots = 20,
			landSizes = { 64 },
			dock = { x = 0, y = 2, z = 144 },
			padSize = { x = 8, y = 1, z = 8 },
			dockSize = { x = 16, y = 2, z = 16 },
			structureSize = { x = 8, y = 8, z = 8 },
			labRank = 3,
		}
		local home = Home.new("owner", rules, 74)
		local parts = World.plan(Content, home, rules)
		local gameplayParts = 0
		for _, part in parts do
			if not part.decorative then
				gameplayParts += 1
			end
		end
		assert(gameplayParts == 6 and parts[1].size.x == 64, "home invariant: 77")
		local rendered: { any } = {}
		assert(not pcall(World.build, {
			isServer = function()
				return false
			end,
		}), "home invariant: 79")
		World.build({
			isServer = function()
				return true
			end,
			content = Content,
			home = home,
			rules = rules,
			render = function(part)
				table.insert(rendered, part)
			end,
		})
		assert(#rendered == #parts, "home invariant: 82")
		for index, part in parts do
			assert(rendered[index].id == part.id, "home invariant: 84")
			if part.kind == "starter-pad" then
				assert(
					math.abs(part.position.x) + part.size.x / 2 <= 32
						and math.abs(part.position.z) + part.size.z / 2 <= 32,
					"home invariant: 86"
				)
			end
		end
		home.developmentRank = 3
		local developed = 0
		for _, part in World.plan(Content, home, rules) do
			if not part.decorative then
				developed += 1
			end
		end
		assert(developed == 7, "home invariant: 90")
	end,
}
