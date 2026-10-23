--!strict
-- Content operations (kind practice / instrument) run through OperationExtension on the personal
-- slice: a fresh player can practice, learn farming_1 and plant corn; instruments are craftable
-- only at a reachable workbench with the authored level and skill gates.
local Operation = require("../../genres/survival-coop/module/OperationExtension")
local HomeExtension = require("../../genres/survival-coop/module/HomeExtension")
local Extensions = require("../../genres/survival-coop/module/Extensions")
local Contract = require("../../genres/survival-coop/module/Contract")
local HomeContent = require("../../core/domain/home/HomeContent")
local Inventory = require("../../core/domain/inventory/Inventory")
local Catalog = require("../../core/domain/inventory/ItemCatalog")
local Fenced = require("../../core/infra/data/FencedStore")
local Memory = require("../../core/infra/data/MemoryBackend")
local Tree = require("../../core/domain/progression/SkillTree")
local Content: any = require("./src/shared/SurvivalContent")
local Durable: any = require("./src/shared/GenreDurable")

local function stack(id: string, catalogId: string, quantity: number): any
	return {
		itemId = id,
		catalogId = catalogId,
		quantity = quantity,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = {},
	}
end

local function harness(items: { any }): any
	local policy = Content.progressionPolicy.tree
	local catalog = Catalog.new(Content.items)
	local state =
		Inventory.new("bag", { contentVersion = 2, slots = 30, softWeightMilli = 60000, hardWeightMilli = 90000 })
	for _, entry in items do
		state = assert(Inventory.add(state, catalog, entry, state.version))
	end
	local slice: any =
		{ balance = 100, inventory = { bag = Inventory.save(state) }, progression = Tree.new(Content, policy) }
	local token: any = { data = { envelope = { genres = { ["survival-coop"] = { data = slice } } } } }
	local h: any = { commits = 0 }
	local port = {
		personal = {
			inventoryPath = function()
				return { "genres", "survival-coop", "data", "inventory", "bag" }
			end,
			update = function(_self: any, profile: any, transform: any)
				local nextView = transform(profile.data)
				if nextView ~= profile.data then
					h.commits += 1
				end
				token = { data = nextView }
				return token, nil
			end,
		},
		profile = function()
			return token
		end,
		install = function() end,
	}
	local world: any = {
		services = {
			survivalSpatial = {
				station = function(_actor: string, key: string)
					return if key == h.station
						then { kind = string.match(key, "^station%.(.+)%.t%d$"), reachable = true }
						else nil
				end,
			},
		},
	}
	h.extension = assert(Operation.factory({
		content = Content,
		world = world,
		personalTransfer = function()
			return port
		end,
	}))
	h.slice = function()
		return token.data.envelope.genres["survival-coop"].data
	end
	h.held = function(catalogId: string): number
		local total = 0
		for _, item in h.slice().inventory.bag.items do
			total += if item.catalogId == catalogId then item.quantity else 0
		end
		return total
	end
	h.run = function(id: string, station: string?, request: string?): any
		return h.extension.command(
			"1",
			Operation.RUN,
			{ id, station or "hand" },
			{ actorId = "1", sessionEpoch = 1, requestId = request or id },
			"client",
			function()
				return { ok = true }
			end
		)
	end
	return h
end

return {
	["fresh player practices the seedbed, learns farming_1 and plants corn"] = function()
		local h = harness({ stack("f", "fiber", 2), stack("w", "water", 1) })
		local _, locked = Tree.learn(Content, h.slice().progression, "farming_1")
		assert(locked == "PROFICIENCY_GATE", "farming_1 is locked before practice: " .. tostring(locked))
		local practiced = h.run("practice-seedbed")
		assert(practiced.ok, "practice-seedbed: " .. tostring(practiced.reason))
		assert(h.held("fiber") == 0 and h.held("water") == 0 and h.held("practice-seedbed") == 1, "inputs -> output")
		assert(h.slice().progression.mastery.farming.level == 1, "practice awards farming proficiency")
		local again = h.run("practice-seedbed", nil, "second")
		assert(again.reason == "INSUFFICIENT_ITEMS" and h.held("practice-seedbed") == 1, "no inputs, no output")
		local learned = assert(Tree.learn(Content, h.slice().progression, "farming_1"))
		assert(learned.paid.farming_1, "skill-learn farming_1 succeeds after practice")
		local catalog = Catalog.new(Content.items)
		local home = HomeExtension.new({
			content = Content,
			rules = HomeContent.rules(Content),
			structures = {},
			seed = function()
				return 7
			end,
			now = function()
				return 0
			end,
			store = function()
				return Fenced.new(Memory.new(), {
					sessionId = "s",
					now = function()
						return 0
					end,
					leaseSeconds = 30,
				})
			end,
			ownerOf = function(actor, token)
				return if token == "home:" .. actor then actor else nil
			end,
			-- SurvivalFactory passes the personal progression's paid nodes as home facts.
			facts = function()
				return { reachable = true, nodes = learned.paid }
			end,
			initialStorage = function(_owner, storage)
				local bag = Inventory.fromSave(storage, catalog)
				for _, row in { { "seed", "corn-seed" }, { "water", "water" } } do
					local item = stack(row[1], row[2], 1)
					item.attributes = { level = 1 }
					bag = assert(Inventory.add(bag, catalog, item, bag.version))
				end
				return Inventory.save(bag)
			end,
		})
		local planted = home.command(
			"1",
			"survival-coop:home-plant",
			{ "home:1", { plot = "starter-farm", crop = "corn", seedItem = "seed" } },
			{ actorId = "1", requestId = "plant", sessionEpoch = 1 },
			"client",
			function()
				return { ok = true }
			end
		)
		assert(planted.ok, "home-plant corn: " .. tostring(planted.reason))
	end,
	["instrument-flute is crafted at a reachable workbench behind level and skill gates"] = function()
		local h = harness({ stack("d", "dried-wood", 6) })
		assert(h.run("instrument-flute", "station.workbench.t1").reason == "CHARACTER_LEVEL_GATE", "level 1")
		local slice = h.slice()
		slice.progression = Tree.level(slice.progression, Content.progressionPolicy.tree, 20)
		assert(h.run("instrument-flute", "station.workbench.t1").reason == "SKILL_GATE", "weapon_tool_1 required")
		slice.progression.paid.weapon_tool_1 = 1
		local before = h.commits
		assert(h.run("instrument-flute", "station.workbench.t1").reason == "STATION_GATE", "away from the bench")
		assert(h.run("instrument-flute", "hand").reason == "STATION_GATE", "hand is not a workbench")
		assert(h.commits == before and h.held("dried-wood") == 6, "refusals change nothing")
		h.station = "station.workbench.t1"
		local crafted = h.run("instrument-flute", "station.workbench.t1")
		assert(crafted.ok, "instrument-flute: " .. tostring(crafted.reason))
		assert(h.held("instrument-flute") == 1 and h.held("dried-wood") == 3, "three dried wood -> one flute")
		for _, item in h.slice().inventory.bag.items do
			if item.catalogId == "instrument-flute" then
				assert(item.durabilityMilli == 100000, "a new instrument starts at full durability")
			end
		end
		assert(h.run("practice-fiber-stitch").reason == "INSUFFICIENT_ITEMS", "unrelated op still checks inputs")
		assert(h.run("plant-corn").reason == "UNKNOWN_OPERATION", "only practice and instrument kinds run here")
	end,
	["snapshot lists every runnable operation with its gate reason"] = function()
		local h = harness({ stack("f", "fiber", 2) })
		local view = assert(h.extension.snapshot("1"))
		local byId = {}
		for _, row in view.operations do
			byId[row.id] = row
		end
		assert(byId["practice-seedbed"] and byId["practice-seedbed"].reason == nil, "practice is open at level 1")
		assert(byId["instrument-flute"].reason == "CHARACTER_LEVEL_GATE", "flute shows its level gate")
		assert(byId["plant-corn"] == nil, "other kinds are not listed")
	end,
	["operation-run is declared, durable and served by a registered factory"] = function()
		assert(table.find(Contract.extensionActions :: { string }, "operation-run"), "extension action")
		assert(table.find(Durable.actions, Operation.RUN), "durable action")
		assert(table.find(Extensions.factories, Operation.factory), "factory registered")
	end,
}
