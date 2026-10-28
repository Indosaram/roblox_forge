--!strict
-- Specs for TownPlots: the Saltmeadow plot grid and its claim/build rules (C5a, G17).
local TownPlots = require("./TownPlots")
local Content: any = require("./SurvivalContent")

local SEED = 4310
local TOWN = "town-01"

local function reasonOf(_: any, why: string?): string
	return tostring(why)
end

local function definitions(): { [string]: TownPlots.Definition }
	local result = {}
	for _, definition in Content.structures do
		result[definition.id] = {
			id = definition.id,
			footprintX = definition.footprintX,
			footprintZ = definition.footprintZ,
			cost = definition.cost,
			station = definition.station,
		}
	end
	return result
end

local function claimed(layout: TownPlots.Layout, plotId: string, actor: string): TownPlots.Doc
	return assert(TownPlots.claim(layout, TOWN, nil, plotId, actor, { developmentRank = 1 }, 100))
end

return {
	["28 plots in three districts, deterministic for a recorded seed"] = function()
		local layout = TownPlots.layout(SEED)
		assert(#layout.plots == 28 and #layout.plots >= 20, "28 claimable plots")
		local districts = { W = 0, E = 0, N = 0 }
		for _, plot in layout.plots do
			districts[plot.district] += 1
			assert(plot.max.x - plot.min.x == 64 and plot.max.z - plot.min.z == 64, plot.id .. " is 64x64")
		end
		assert(districts.W == 12 and districts.E == 12 and districts.N == 4, "W12 E12 N4")
		-- Spec table rows are z-major: W01..W04 share the first row.
		local w01, w04, w05 = layout.byId.W01, layout.byId.W04, layout.byId.W05
		assert(w01.min.x == -608 and w01.min.z == -224 and w01.centre.x == -576, "W01 corner")
		assert(w04.min.x == -368 and w04.min.z == -224, "W04 ends the first row")
		assert(w05.min.x == -608 and w05.min.z == -144, "W05 starts the second row")
		assert(layout.byId.E12.min.x == 544 and layout.byId.E12.min.z == -64, "E12 corner")
		assert(layout.byId.N03.min.x == 96 and layout.byId.N03.min.z == -416, "N03 corner")
		local again, other = TownPlots.layout(SEED), TownPlots.layout(SEED + 1)
		local differs = false
		for index, plot in layout.plots do
			assert(again.plots[index].id == plot.id and again.plots[index].stake == plot.stake, "same seed, same town")
			differs = differs or other.plots[index].stake ~= plot.stake
		end
		assert(differs, "the seed drives the stake corners")
		assert(TownPlots.flagColour(SEED, "42") == TownPlots.flagColour(SEED, "42"), "flag colour is seeded")
		assert(not pcall(TownPlots.layout, -1), "invalid seed refused")
	end,
	["every plot sits inland and no two plots overlap"] = function()
		local layout = TownPlots.layout(SEED)
		for _, plot in layout.plots do
			for index = 1, 4 do
				local c = TownPlots.corner(plot, index)
				local r = math.sqrt((c.x / TownPlots.ISLAND.x) ^ 2 + (c.z / TownPlots.ISLAND.z) ^ 2)
				assert(r <= TownPlots.ISLAND.inner + 0.005, plot.id .. " corner " .. index .. " leaves the meadow")
			end
			for _, other in layout.plots do
				if other ~= plot then
					local apart = plot.max.x <= other.min.x
						or other.max.x <= plot.min.x
						or plot.max.z <= other.min.z
						or other.max.z <= plot.min.z
					assert(apart, plot.id .. " overlaps " .. other.id)
				end
			end
			assert(#TownPlots.key(TOWN, plot.id) <= 50, "fenced key fits")
		end
	end,
	["claim: free plot claimed once; owned plot, second claim and rank 0 refused"] = function()
		local layout = TownPlots.layout(SEED)
		local doc = claimed(layout, "W01", "1")
		assert(doc.ownerId == "1" and doc.settlement.config.tribeId == "town:town-01:W01", "owner and tribe")
		assert(doc.settlement.config.width == 16 and doc.settlement.config.cellStuds == 4, "16x16 grid of 4")
		assert(doc.settlement.config.maxMembers == 4 and doc.claimedAt == 100, "camp size and clock")
		local r1 = reasonOf(TownPlots.claim(layout, TOWN, doc, "W01", "2", { developmentRank = 3 }, 101))
		assert(r1 == "PLOT_OWNED", "claiming an owned plot is refused: " .. r1)
		local r2 = reasonOf(TownPlots.claim(layout, TOWN, doc, "W01", "1", { developmentRank = 3 }, 101))
		assert(r2 == "ALREADY_CLAIMED", "re-claiming your own plot is refused")
		local r3 = reasonOf(
			TownPlots.claim(layout, TOWN, nil, "W02", "1", { developmentRank = 3, claimed = "town-01:W01" }, 101)
		)
		assert(r3 == "ALREADY_CLAIMED", "one plot per account")
		local r4 = reasonOf(TownPlots.claim(layout, TOWN, nil, "W02", "3", { developmentRank = 0 }, 101))
		assert(r4 == "RANK_REQUIRED", "tutorial rank required")
		local r5 = reasonOf(TownPlots.claim(layout, TOWN, nil, "Z99", "3", { developmentRank = 1 }, 101))
		assert(r5 == "UNKNOWN_PLOT", "unknown plot")
		local r6 = reasonOf(TownPlots.claim(layout, TOWN, nil, "W02", "3", { developmentRank = 1 }, -1))
		assert(r6 == "INVALID_CLOCK", "explicit clock required")
	end,
	["D2b 5: the first plot's rank is met by the first two opening guides; refusals map to KO/EN toasts"] = function()
		-- Grade = floor(points / 100) (SurvivalFactory developmentFacts); the first-plot guides are open
		-- to a level-1, grade-0 player and together pay at least MIN_DEVELOPMENT_RANK grades.
		local fs = require("@lune/fs")
		local factory = fs.readFile("games/robango-island/src/server/SurvivalFactory.luau")
		assert(string.find(factory, "grade = math.min(10, math.floor(points / 100))", 1, true), "grade formula")
		assert(string.find(factory, "developmentFacts(expeditionStore.snapshot(actor)).grade", 1, true), "claim rank")
		local points = 0
		for _, id in TownPlots.FIRST_PLOT_GUIDES do
			local found = nil
			for _, guide in Content.guides do
				found = if guide.id == id then guide else found
			end
			assert(found, "guide " .. id)
			assert((found.gates.developmentRank or 0) == 0 and (found.gates.characterLevel or 1) <= 1, id .. " gate")
			points += found.rewards.development
		end
		assert(math.floor(points / 100) >= TownPlots.MIN_DEVELOPMENT_RANK, "first-plot guides pay grade 1")
		-- Both are beats of the C1 opening every new player plays (fiber gather, then the hatchet).
		local Scene = require("./OpeningScene")
		local steps = {}
		for _, step in Scene.STEPS do
			steps[step.id] = true
		end
		assert(steps.fiber and steps.hatchet, "opening teaches fiber and the axe")
		-- Every claim outcome the stake publishes is a toast with its own KO and EN line.
		local _text = require("../../PackText.fixture")
		local Panels = require("../../../../genres/survival-coop/module/ExtensionPanels")
		for outcome in TownPlots.CLAIM_OUTCOMES do
			assert(TownPlots.toastReason(outcome .. "|7") == outcome, outcome .. " toasts")
			local en, ko = Panels.travelText("en-us", outcome), Panels.travelText("ko-kr", outcome)
			assert(en ~= Panels.travelText("en-us", "?") and ko ~= Panels.travelText("ko-kr", "?"), outcome)
			assert(en ~= ko, outcome .. " KO differs from EN")
		end
		assert(string.find(Panels.travelText("en-us", "RANK_REQUIRED"), "axe", 1, true), "names the guides")
		assert(TownPlots.toastReason("travelling|3") == nil and TownPlots.toastReason(nil) == nil, "dock results")
		-- The client toasts each new claim result (the objective card is held by contract notices).
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(
			string.find(client, 'GetAttributeChangedSignal("ForgeTravelResult")', 1, true)
				and string.find(client, "TownPlots.toastReason(", 1, true),
			"client toasts claim results"
		)
	end,
	["build: inside your plot only; outsiders, other plots and town-hall pieces refused"] = function()
		local layout, defs = TownPlots.layout(SEED), definitions()
		local doc = claimed(layout, "E05", "1")
		local plot = layout.byId.E05
		local built = assert(
			TownPlots.build(
				layout,
				doc,
				"1",
				{ structure = "floor", x = plot.min.x + 8, z = plot.min.z + 8, rotation = 0 },
				defs
			)
		)
		local count = 0
		for _ in built.settlement.structures do
			count += 1
		end
		assert(count == 1, "one structure committed")
		local r7 = reasonOf(
			TownPlots.build(
				layout,
				doc,
				"2",
				{ structure = "floor", x = plot.min.x + 8, z = plot.min.z + 8, rotation = 0 },
				defs
			)
		)
		assert(r7 == "NOT_PLOT_MEMBER", "a visitor cannot build on someone's plot")
		local w01 = layout.byId.W01
		local r8 = reasonOf(
			TownPlots.build(
				layout,
				doc,
				"1",
				{ structure = "floor", x = w01.min.x + 8, z = w01.min.z + 8, rotation = 0 },
				defs
			)
		)
		assert(r8 == "OUT_OF_PLOT", "building on another plot is refused")
		local r9 = reasonOf(
			TownPlots.build(
				layout,
				doc,
				"1",
				{ structure = "floor", x = plot.max.x, z = plot.min.z + 8, rotation = 0 },
				defs
			)
		)
		assert(r9 == "OUT_OF_PLOT", "the far edge is outside the plot")
		-- Inside the plot but the footprint spills over the edge (2x2 floor at the last cell).
		local r10 = reasonOf(
			TownPlots.build(
				layout,
				doc,
				"1",
				{ structure = "floor", x = plot.max.x - 2, z = plot.min.z + 8, rotation = 0 },
				defs
			)
		)
		assert(r10 == "OUT_OF_BOUNDS", "a footprint crossing the plot edge is refused: " .. r10)
		-- Entry cell sits one cell before the origin: an origin on row 0 puts it outside.
		local r11 = reasonOf(
			TownPlots.build(
				layout,
				doc,
				"1",
				{ structure = "floor", x = plot.min.x + 8, z = plot.min.z, rotation = 0 },
				defs
			)
		)
		assert(r11 == "OUT_OF_BOUNDS", "an entry outside the plot is refused")
		for _, banned in { "clan-hall", "volcanic-wall" } do
			local r12 = reasonOf(
				TownPlots.build(
					layout,
					doc,
					"1",
					{ structure = banned, x = plot.min.x + 16, z = plot.min.z + 16, rotation = 0 },
					defs
				)
			)
			assert(r12 == "STRUCTURE_NOT_ALLOWED", banned .. " is town-hall or siege only")
		end
		local r13 = reasonOf(
			TownPlots.build(
				layout,
				built,
				"1",
				{ structure = "floor", x = plot.min.x + 8, z = plot.min.z + 8, rotation = 0 },
				defs
			)
		)
		assert(r13 == "COLLISION", "overlapping placement refused")
	end,
	["station caps: workbench 1, kiln 1, campfire 2 per plot"] = function()
		local layout, defs = TownPlots.layout(SEED), definitions()
		local plot = layout.byId.N02
		local doc = claimed(layout, "N02", "7")
		local function at(structure: string, cx: number, cz: number)
			return { structure = structure, x = plot.min.x + cx * 4, z = plot.min.z + cz * 4, rotation = 0 }
		end
		doc = assert(TownPlots.build(layout, doc, "7", at("workbench", 1, 2), defs))
		local r14 = reasonOf(TownPlots.build(layout, doc, "7", at("workbench-t2", 5, 2), defs))
		assert(r14 == "STATION_CAP", "a second workbench of any tier is refused")
		doc = assert(TownPlots.build(layout, doc, "7", at("kiln", 5, 2), defs))
		local r15 = reasonOf(TownPlots.build(layout, doc, "7", at("kiln", 9, 2), defs))
		assert(r15 == "STATION_CAP", "a second kiln is refused")
		doc = assert(TownPlots.build(layout, doc, "7", at("campfire", 9, 2), defs))
		doc = assert(TownPlots.build(layout, doc, "7", at("campfire", 13, 2), defs))
		local r16 = reasonOf(TownPlots.build(layout, doc, "7", at("campfire", 1, 8), defs))
		assert(r16 == "STATION_CAP", "a third campfire is refused")
	end,
	["plot save restores against pinned definitions and refuses forged costs"] = function()
		local layout, defs = TownPlots.layout(SEED), definitions()
		local plot = layout.byId.W12
		local doc = claimed(layout, "W12", "9")
		doc = assert(
			TownPlots.build(
				layout,
				doc,
				"9",
				{ structure = "floor", x = plot.min.x + 8, z = plot.min.z + 8, rotation = 0 },
				defs
			)
		)
		local restored = TownPlots.fromSave(TownPlots.save(doc), layout, TOWN, defs)
		assert(restored.ownerId == "9" and restored.settlement.version == doc.settlement.version, "round trip")
		local forged = TownPlots.save(doc)
		for _, placed in forged.settlement.structures do
			placed.definition.cost[1].quantity = 999
		end
		assert(not pcall(TownPlots.fromSave, forged, layout, TOWN, defs), "forged cost refused")
		assert(
			not pcall(TownPlots.fromSave, TownPlots.save(doc), layout, "town-02", defs),
			"another town's config refused"
		)
	end,
}
