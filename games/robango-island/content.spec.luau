--!strict
-- Specs for the robango-island P0 content catalog (content.yml): schema validity,
-- biome/roster coverage, a reachable recipe tree, locale coverage for every id,
-- generated-file drift, and the original-naming gate.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local luau = require("@lune/luau")

local Content = require("../../core/domain/survival/Content")
local Strings = require("../../core/infra/localization/Strings")
local contentrender = require("../../cli/forge/lib/contentrender")
local Gathering = require("../../genres/survival-coop/module/Gathering")
local Shipped = require("./src/shared/SurvivalContent")
require("./PackText.fixture") -- installs the strings.csv lookup the genre text tables read (client: Strings table)

-- Specs run from the repository root.
local PACK = "games/robango-island"

local function load(): any
	return serde.decode("yaml", fs.readFile(PACK .. "/content.yml"))
end

local function canonical(): Content.Document
	local document, errors = Content.canonicalize(load())
	assert(document, table.concat(errors, "; "))
	return document :: Content.Document
end

-- Names this pack must never ship. Split so the spec itself stays clean under grep.
local FORBIDDEN = {
	"dur" .. "ango",
	"듀" .. "랑고",
	"wild " .. "lands",
	"야생의 " .. "땅",
	"개" .. "척",
	"pio" .. "neer",
	"워" .. "프",
}

local function forbiddenHits(text: string): { string }
	local hits: { string } = {}
	local lower = string.lower(text)
	for _, term in FORBIDDEN do
		if string.find(lower, term, 1, true) then
			table.insert(hits, term)
		end
	end
	return hits
end

-- Items obtainable from gathering or wildlife drops, closed under every recipe
-- whose station and inputs are themselves obtainable.
local function reachable(document: Content.Document, drops: { [string]: any }): { [string]: boolean }
	local have: { [string]: boolean } = {}
	for _, node in document.nodes do
		for _, entry in node.harvest do
			have[entry.item] = true
		end
	end
	for _, rule in drops do
		for _, entry in rule.drops do
			have[entry.item] = true
		end
	end
	-- Carcass picker outputs (C3): content species reservoirs are taken from the body after a kill.
	for _, species in document.wildlifeDetails or {} do
		for _, entry in species.dropReservoirs or {} do
			have[entry.item] = true
		end
	end
	local built: { [string]: boolean } = {}
	-- V2 acquisition also includes authored layout resources and public stations.
	-- Retired aliases remain covered by the legacy node checks above, including
	-- the negative marsh-clay dependency regression.
	local authored = load()
	for _, layout in authored.layouts do
		for _, node in layout.resourceNodes do
			if not string.find(node.id, ".legacy-", 1, true) then
				have[node.item] = true
			end
		end
		for _, anchor in layout.anchors do
			local station = string.match(anchor.id, "^station%.(.+)%.t%d+$")
			if station then
				built[station] = true
			end
		end
	end
	local changed = true
	while changed do
		changed = false
		for _, operation in authored.operations do
			local ok = operation.station == nil or built[operation.station] == true
			for _, entry in operation.inputs do
				ok = ok and have[entry.item] == true
			end
			if ok then
				for _, entry in operation.outputs do
					if not have[entry.item] then
						have[entry.item], changed = true, true
					end
				end
			end
		end
		for _, structure in document.structures do
			if not built[structure.id] then
				local ok = true
				for _, entry in structure.cost do
					ok = ok and have[entry.item] == true
				end
				if ok then
					built[structure.id], changed = true, true
				end
			end
		end
		for _, recipe in document.recipes do
			local ok = recipe.station == nil or built[recipe.station] == true
			for _, entry in recipe.inputs do
				ok = ok and have[entry.item] == true
			end
			if ok then
				for _, entry in recipe.outputs do
					if not have[entry.item] then
						have[entry.item], changed = true, true
					end
				end
			end
		end
	end
	return have
end

local function species(): { [string]: any }
	return luau.load(fs.readFile(PACK .. "/src/shared/WildlifePolicy.luau"), {
		environment = {
			require = function(dependency)
				assert(dependency == "./SurvivalContent", "unexpected wildlife policy dependency")
				return luau.load(fs.readFile(PACK .. "/src/shared/SurvivalContent.luau"))()
			end,
		},
	})().catalog.species
end

local function prefixed(list: { any }, prefix: string): number
	local count = 0
	for _, entry in list do
		if string.sub(entry.id, 1, #prefix) == prefix then
			count += 1
		end
	end
	return count
end

-- audit6h P9: the authored steps for hours 1.5-6 (Robango gap report section 5). Gate level, XP,
-- objectives; every one opens at island grade 2 and pays no development.
local P9: { [string]: { level: number, xp: number, objectives: { string } } } = {
	["rw.g32.tanning-frame"] = {
		level = 11,
		xp = 150,
		objectives = { "craft tanning-frame-kit", "place tanning-frame" },
	},
	["rw.g33.first-leather"] = { level = 12, xp = 150, objectives = { "purchase processing_2", "craft tan-hide" } },
	["rw.g34.hunting-bow"] = { level = 13, xp = 200, objectives = { "craft bow-t1", "equip bow-t1" } },
	["rw.g35.first-polish"] = { level = 15, xp = 200, objectives = { "purchase processing_3", "craft polish-flint" } },
	["rw.g36.flint-pick"] = { level = 16, xp = 200, objectives = { "craft pickaxe-t1" } },
	["rw.g37.first-crop"] = {
		level = 17,
		xp = 200,
		objectives = { "purchase farming_1", "plant corn", "harvest corn" },
	},
	["rw.g38.kiln"] = { level = 21, xp = 200, objectives = { "craft kiln-kit", "place kiln" } },
	["rw.g39.copper"] = { level = 23, xp = 250, objectives = { "gather copper-ore", "craft smelt-copper" } },
	["rw.g40.temperate-set"] = {
		level = 26,
		xp = 250,
		objectives = { "craft temperate-top", "craft temperate-shoes" },
	},
	["rw.g41.second-pet"] = {
		level = 12,
		xp = 250,
		objectives = { "capture creature", "place-training creature", "feed herbivore-feed", "tame creature" },
	},
	["rw.g42.storage"] = { level = 33, xp = 250, objectives = { "craft storage-kit", "place storage" } },
	["rw.g43.t1-weapon"] = { level = 36, xp = 300, objectives = { "craft club-t1", "equip club-t1" } },
	["rw.g44.second-route"] = { level = 37, xp = 300, objectives = { "deliver contract" } },
	["rw.g45.bone-work"] = {
		level = 42,
		xp = 350,
		objectives = { "purchase weapon_tool_3", "craft polish-bone", "craft tan-thick-hide" },
	},
	["rw.g46.t2-tool"] = { level = 45, xp = 400, objectives = { "craft pickaxe-t2" } },
	["rw.g47.first-ride"] = {
		level = 43,
		xp = 500,
		objectives = {
			"purchase melee_2",
			"purchase survival_3",
			"craft capture-rope",
			"capture protoceratops",
			"place-training protoceratops",
			"tame protoceratops",
			"craft saddle",
			"saddle protoceratops",
			"ride protoceratops",
		},
	},
}

-- Every id a guide objective names must resolve in the document: craft -> recipe (or a tool family
-- the craft event carries as `also`), place -> structure, purchase -> skill node, gather/plant/
-- harvest/equip/feed -> item, capture -> a species or "creature", deliver -> a contract or
-- "contract". Returns "<objective id>: <action> <target>" for each that does not.
local function unresolved(document: any): { string }
	local function ids(rows: { any }?): { [string]: boolean }
		local out = {}
		for _, row in rows or {} do
			out[row.id] = true
		end
		return out
	end
	local recipes, structures, nodes = ids(document.recipes), ids(document.structures), ids(document.skillNodes)
	local items, wildlife = ids(document.items), ids(document.wildlifeDetails)
	local contracts = ids((document.contracts or {}).entries)
	for _, family in (document.toolPolicy or {}).families or {} do
		recipes[family.id] = true
	end
	local resolve = {
		craft = recipes,
		place = structures,
		purchase = nodes,
		gather = items,
		plant = items,
		harvest = items,
		equip = items,
		feed = items,
	}
	local out = {}
	for _, guide in document.guides or {} do
		for _, objective in guide.objectives do
			local known = resolve[objective.action]
			local ok = if objective.action == "capture"
				then objective.target == "creature" or wildlife[objective.target] == true
				elseif objective.action == "deliver" then objective.target == "contract"
					or contracts[objective.target] == true
				elseif known then known[objective.target] == true
				else true
			if not ok then
				table.insert(out, objective.id .. ": " .. objective.action .. " " .. objective.target)
			end
		end
	end
	return out
end

-- Largest jump between consecutive gate levels of the guides a solo player sees, over [from, to].
local function soloGap(document: any, from: number, to: number): (number, number?)
	local GuideEvents = require("../../genres/survival-coop/module/GuideEvents")
	local levels: { number } = {}
	for _, guide in GuideEvents.visible(document, true) do
		local level = (guide.gates or {}).characterLevel or 1
		if not table.find(levels, level) then
			table.insert(levels, level)
		end
	end
	table.sort(levels)
	local worst, at = 0, nil
	for i = 2, #levels do
		if levels[i - 1] >= from and levels[i - 1] < to and levels[i] - levels[i - 1] > worst then
			worst, at = levels[i] - levels[i - 1], levels[i - 1]
		end
	end
	return worst, at
end

local function withoutP9(document: any): any
	local kept = {}
	for _, guide in document.guides do
		if not P9[guide.id] then
			table.insert(kept, guide)
		end
	end
	document.guides = kept
	return document
end

return {
	["content.yml validates against the current survival schema"] = function()
		local errors = Content.validate(load())
		assert(#errors == 0, table.concat(errors, "; "))
	end,

	["an unsupported wildlife behaviour is rejected by the same schema"] = function()
		local raw = load()
		table.insert(raw.wildlife, { id = "bad-flag", behavior = "aggressive" })
		local errors = Content.validate(raw)
		assert(#errors > 0, "a behaviour outside grazer|hunter must not validate")
	end,

	["both P0 biomes carry gather nodes and the roster has 12 species variants"] = function()
		local document = canonical()
		assert(prefixed(document.nodes, "forest-") >= 6, "temperate forest needs at least 6 node kinds")
		assert(prefixed(document.nodes, "marsh-") >= 6, "coastal marsh needs at least 6 node kinds")
		local variants = 0
		for _, archetype in { "leaper-", "charger-", "tailswing-", "roarer-", "scavenger-", "herd-" } do
			local count = prefixed(document.wildlife, archetype)
			assert(count == 2, archetype .. " expected 2 variants, got " .. count)
			variants += count
		end
		assert(variants == 12, "expected 12 species variants")
	end,

	["every wildlife id has a species rule and every recipe output is reachable"] = function()
		local document = canonical()
		local rules = species()
		for _, entry in document.wildlife do
			assert(rules[entry.id], "missing WildlifePolicy species for " .. entry.id)
		end
		local have = reachable(document, rules)
		for _, recipe in document.recipes do
			for _, entry in recipe.outputs do
				assert(have[entry.item], "unreachable recipe output " .. entry.item)
			end
		end
		for _, material in { "timber", "stone", "brick" } do
			assert(have[material .. "-wall-kit"], material .. " wall kit unreachable")
		end
	end,

	["removing the clay source makes brick parts unreachable"] = function()
		local document = canonical()
		local kept = {}
		for _, node in document.nodes do
			if node.id ~= "marsh-clay-bank" then
				table.insert(kept, node)
			end
		end
		document.nodes = kept
		local have = reachable(document, species())
		assert(not have["brick-wall-kit"], "brick wall kit must depend on marsh clay")
		assert(have["stone-wall-kit"], "stone parts do not depend on clay")
	end,

	["20 guides in 5 bands of 4 each award 50 development, then 10 waypoint guides toward route 1"] = function()
		-- The starter capture guide (tame lane redesign) sits in the start band; it pays no development.
		-- The audit6h P9 guides (g32..g46) are checked by their own cases below.
		local guides = {}
		for _, guide in load().guides do
			if P9[guide.id] then
				continue
			elseif guide.id == "rw.g31.first-capture" then
				assert(
					guide.gates.characterLevel == 1 and guide.gates.developmentRank == 0,
					"starter capture opens at L1"
				)
				assert(guide.rewards.development == 0, "starter capture pays no development")
			else
				table.insert(guides, guide)
			end
		end
		assert(#guides == 30, "30 guides")
		for i, guide in guides do
			if i > 20 then
				-- p59 waypoints: XP only, open at grade 2 between the start band and route 1 (L30).
				assert(guide.rewards.development == 0 and guide.rewards.xp > 0, "waypoint reward " .. guide.id)
				assert(guide.gates.developmentRank == 2, "waypoint rank " .. guide.id)
				assert(
					guide.gates.characterLevel > 1 and guide.gates.characterLevel < 30,
					"waypoint level " .. guide.id
				)
				continue
			end
			local first = guides[i - (i - 1) % 4]
			assert(guide.rewards.development == 50, "50 development " .. guide.id)
			assert(guide.gates.developmentRank == ((i - 1) // 4) * 2, "band rank " .. guide.id)
			assert(guide.gates.characterLevel == first.gates.characterLevel, "band level " .. guide.id)
		end
	end,

	["audit6h P9: the hours 1.5-6 guides open at grade 2 at their level, pay XP only, as authored"] = function()
		local seen = {}
		for _, guide in load().guides do
			local spec = P9[guide.id]
			if spec then
				seen[guide.id] = true
				assert(guide.gates.characterLevel == spec.level, guide.id .. " level " .. guide.gates.characterLevel)
				assert(guide.gates.developmentRank == 2, guide.id .. " grade")
				assert(guide.rewards.development == 0, guide.id .. " pays no development")
				assert(guide.rewards.xp == spec.xp, guide.id .. " xp " .. tostring(guide.rewards.xp))
				assert(#guide.objectives == #spec.objectives, guide.id .. " objective count")
				for i, objective in guide.objectives do
					local text = objective.action .. " " .. objective.target
					assert(text == spec.objectives[i], guide.id .. " objective " .. i .. ": " .. text)
					assert(objective.id == guide.id .. "." .. i, objective.id)
				end
				assert(
					guide.dialogueKeys[1] == guide.id .. ".offer" and guide.dialogueKeys[2] == guide.id .. ".complete",
					guide.id .. " dialogue keys"
				)
			end
		end
		for id in P9 do
			assert(seen[id], id .. " missing from content.yml")
		end
	end,

	["every guide objective names an id that exists in the content"] = function()
		local missing = unresolved(load())
		assert(#missing == 0, "unresolved guide targets:\n" .. table.concat(missing, "\n"))
		-- The check bites: a renamed recipe and a misspelled structure are both reported.
		local broken = load()
		for _, guide in broken.guides do
			if guide.id == "rw.g36.flint-pick" then
				guide.objectives[1].target = "pickaxe-t9"
			elseif guide.id == "rw.g38.kiln" then
				guide.objectives[2].target = "kiln-x"
			end
		end
		local found = unresolved(broken)
		assert(#found == 2, table.concat(found, "\n"))
	end,

	["the solo guide list has no gap above 6 levels between level 10 and 46 (fails on the old data)"] = function()
		local gap, at = soloGap(load(), 10, 46)
		assert(gap <= 6, "solo guide gap of " .. gap .. " levels after L" .. tostring(at))
		-- Without the P9 guides the solo list jumps from the rank-6 band (L38, g13-g16) to L50
		-- (g08/g12/g15/g17/g19 are hidden).
		local old, oldAt = soloGap(withoutP9(load()), 10, 46)
		assert(old > 6 and oldAt == 38, "old data gap " .. old .. " after L" .. tostring(oldAt))
	end,

	["every P9 guide has en and ko offer, complete and title rows with provenance"] = function()
		local parsed = Strings.parseCsv(fs.readFile(PACK .. "/locale/strings.csv"))
		local rows: { [string]: { string } } = {}
		for _, row in parsed.rows do
			rows[row[1]] = row
		end
		local provenance: { [string]: boolean } = {}
		for line in string.gmatch(fs.readFile(PACK .. "/locale/provenance.csv"), "[^\n]+") do
			provenance[string.match(line, "^([^,]+)") or ""] = true
		end
		for id in P9 do
			local short = assert(string.match(id, "^rw%.(g%d+)%."), id)
			for _, key in { id .. ".offer", id .. ".complete", "chr.guide_" .. short } do
				local row = rows[key]
				assert(row and row[4] ~= "" and row[5] ~= "", key .. " needs en and ko text")
				assert(provenance[key], key .. " needs a provenance row")
			end
		end
	end,

	["every catalog id has an English and Korean locale string"] = function()
		local document = canonical()
		local parsed = Strings.parseCsv(fs.readFile(PACK .. "/locale/strings.csv"))
		local rows: { [string]: { string } } = {}
		for _, row in parsed.rows do
			rows[row[1]] = row
		end
		local function key(prefix: string, id: string): string
			return prefix .. (string.gsub(id, "%-", "_"))
		end
		local wanted: { string } = {}
		for _, entry in document.items do
			table.insert(wanted, key("item_", entry.id))
		end
		for _, entry in document.recipes do
			table.insert(wanted, key("recipe_", entry.id))
		end
		for _, entry in document.nodes do
			table.insert(wanted, key("node_", entry.id))
		end
		for _, entry in document.structures do
			table.insert(wanted, key("structure_", entry.id))
		end
		for _, entry in document.wildlife do
			table.insert(wanted, key("wildlife_", entry.id))
		end
		for _, name in wanted do
			local row = rows[name]
			assert(row ~= nil, "missing locale row " .. name)
			assert(row[4] ~= "" and row[5] ~= "", "empty en-us/ko-kr for " .. name)
		end
		assert(rows.currency_name[4] == "Shellmoney" and rows.currency_name[5] == "조개돈", "currency name")
	end,

	["every skill node has a localized Skills sheet label with its cost"] = function()
		local HudLocale = require("../../genres/survival-coop/module/SurvivalHUDLocale")
		local nodes = load().skillNodes
		assert(#nodes == 72, "expected 72 skill nodes")
		for _, locale in { "en-us", "ko-kr" } do
			for _, node in nodes do
				local text = HudLocale.skill(locale, node)
				assert(
					text ~= "" and text ~= node.id and not string.find(text, node.id, 1, true),
					locale .. " raw " .. node.id
				)
				assert(string.find(text, tostring(node.cost) .. " SP", 1, true), locale .. " cost " .. node.id)
			end
		end
		local sample = { category = "construction", rank = 5, cost = 10 }
		assert(HudLocale.skill("ko-kr", sample) == "건축 5 · 10 SP", "ko label")
		assert(HudLocale.skill("en-us", sample) == "Construction 5 · 10 SP", "en label")
		local unknown = HudLocale.skill("ko-kr", { category = "deep_sea", rank = 1, cost = 2 })
		assert(unknown == "deep sea 1 · 2 SP", "unknown category falls back without underscores")
	end,

	["generated SurvivalContent.luau matches content.yml"] = function()
		local rendered, errors = contentrender.build(load(), "crafting")
		assert(rendered, table.concat(errors, "; "))
		local shipped = fs.readFile(PACK .. "/src/shared/SurvivalContent.luau")
		assert((rendered :: any).content == shipped, "SurvivalContent.luau is stale; run forge content codegen")
	end,

	["repair-equipment charges a recurring Coin cost scaled to item tier"] = function()
		local Job = require("../../core/domain/crafting/Job")
		local repair: any = nil
		for _, row in (canonical() :: any).operations do
			if row.id == "repair-equipment" then
				repair = row
			end
		end
		assert(repair and repair.kind == "repair" and repair.cost == 10, "repair base cost is 10 Coins")
		assert(Job.repairCost(repair, "starter-club") == 10, "untiered gear is tier 1")
		assert(Job.repairCost(repair, "axe-t1") == 10, "tier 1 costs 10")
		assert(Job.repairCost(repair, "sword-t2") == 20, "tier 2 costs 20")
		assert(Job.repairCost(repair, "hammer-t3") == 30, "tier 3 costs 30")
	end,

	["shipped pack text uses original names only"] = function()
		for _, path in { "content.yml", "econ.yml", "locale/strings.csv", "design/content-p0.md" } do
			local hits = forbiddenHits(fs.readFile(PACK .. "/" .. path))
			assert(#hits == 0, path .. " contains " .. table.concat(hits, ", "))
		end
		local injected = forbiddenHits("Welcome to " .. "Dur" .. "ango")
		assert(#injected == 1, "the naming gate must flag an injected forbidden name")
	end,
	["every daily contract is deliverable at level 1-3 from home and onboarding resources"] = function()
		local document = load()
		local available: { [string]: string? } = {} -- item -> required tool (or "" for none)
		for _, layout in document.layouts do
			if layout.id == "rw.home" or layout.id == "rw.onboarding" then
				for _, node in layout.resourceNodes or {} do
					available[node.item] = node.tool or ""
				end
			end
		end
		local details = {}
		for _, detail in document.recipeDetails do
			details[detail.id] = detail
		end
		local function obtainable(item: string, depth: number): boolean
			if depth > 10 then
				return false
			elseif available[item] ~= nil then
				return available[item] == "" or obtainable(available[item] :: string, depth + 1)
			end
			for _, recipe in document.recipes do
				local detail = details[recipe.id]
				local makes = false
				for _, output in recipe.outputs do
					makes = makes or output.item == item
				end
				if
					makes
					and string.sub(recipe.id, 1, 7) ~= "legacy-"
					and (detail == nil or (detail.minCharacterLevel <= 3 and #detail.skillNodes == 0))
					and (recipe.station == nil or obtainable(recipe.station .. "-kit", depth + 1))
				then
					local ok = true
					for _, input in recipe.inputs do
						ok = ok and obtainable(input.item, depth + 1)
					end
					if ok then
						return true
					end
				end
			end
			return false
		end
		local count = 0
		for _, entry in document.contracts.entries do
			if entry.pool == "daily" then
				count += 1
				for _, need in entry.deliver do
					assert(obtainable(need.item, 0), entry.id .. " needs unreachable " .. need.item)
				end
			end
		end
		assert(count >= document.contracts.dailyCount, "daily pool covers a full board")
		-- Witness: an item only found off the home island is rejected by the same check.
		assert(not obtainable("reed", 0), "reed is not a home resource")
	end,
	["C2: every gather node offers 2-6 distinct outputs, the shipped content agrees and extras are raw"] = function()
		local document: any = canonical()
		-- Picker extras are plain raw materials: never quest, retired or tool items.
		local special: { [string]: boolean } = {}
		for _, item in document.items do
			for _, tag in item.tags or {} do
				if tag == "quest-bound" or tag == "retired" or tag == "tool" then
					special[item.id] = true
				end
			end
		end
		local function check(where: string, offered: { any }, plain: number)
			assert(#offered >= 2 and #offered <= 6, where .. " offers " .. #offered .. " outputs")
			local seen = {}
			for _, output in offered do
				assert(not seen[output.item], where .. " repeats " .. output.item)
				seen[output.item] = true
				assert(output.quantity >= 1, where .. " quantity")
			end
			for index = plain + 1, #offered do
				assert(
					not special[offered[index].item],
					where .. " picker extra " .. offered[index].item .. " is not raw"
				)
			end
		end
		local nodes = 0
		for _, node in document.nodes do
			check(node.id, Gathering.outputs(document, node.harvest), #node.harvest)
			nodes += 1
		end
		for _, layout in document.layouts do
			for _, resource in layout.resourceNodes do
				if
					not string.find(resource.id, ".cargo.", 1, true)
					and not string.find(resource.id, ".chapter.", 1, true)
				then
					local kind = string.gsub(resource.id, "[._]", "-")
					local offered, level, plain = Gathering.offered(document, kind, resource.id)
					check(resource.id, offered, plain)
					assert(level == resource.level and plain == 1, resource.id .. " picker view")
					assert(
						offered[1].item == resource.item and offered[1].quantity == resource.yield,
						resource.id .. " harvest first"
					)
					nodes += 1
				end
			end
		end
		assert(nodes >= 280, "every catalog and layout node checked, got " .. nodes)
		local shipped: any = Shipped
		assert(shipped.gatherPolicy ~= nil, "codegen ships the gather policy")
		for _, node in shipped.nodes do
			assert(#Gathering.outputs(shipped, node.harvest) >= 2, "shipped " .. node.id)
		end
	end,
	-- C2h (owner-approved weights, 2026-10-29): Durango's wheel shows 3-6 outputs per node (R05-3).
	-- Before, 186 of 284 nodes offered only 2 and many alternatives were a single leaf for 3 stone.
	-- Every node now offers at least 3, and each alternative is worth half to all of the plain
	-- harvest at harbor buyback Coins (unlisted raw = 1), so a pick never mints more free currency.
	["C2h: every gather node offers 3+ outputs and each pick is Coin-bounded by the plain harvest"] = function()
		local document: any = canonical()
		local price: { [string]: number } = {}
		for _, row in document.harborPolicy.buyback do
			price[row.item] = row.price
		end
		local function coins(entry: any): number
			return (price[entry.item] or 1) * entry.quantity
		end
		local function check(where: string, harvest: { any })
			local offered = Gathering.outputs(document, harvest)
			assert(#offered >= 3, where .. " offers " .. #offered .. " outputs")
			local plain = 0
			for _, entry in harvest do
				plain = math.max(plain, coins(entry))
			end
			for index = #harvest + 1, #offered do
				local value = coins(offered[index])
				assert(
					value <= plain and value * 2 >= plain,
					where .. " pick " .. offered[index].item .. " worth " .. value .. " vs harvest " .. plain
				)
			end
		end
		local nodes = 0
		for _, node in document.nodes do
			check(node.id, node.harvest)
			nodes += 1
		end
		for _, layout in document.layouts do
			for _, resource in layout.resourceNodes do
				if
					not string.find(resource.id, ".cargo.", 1, true)
					and not string.find(resource.id, ".chapter.", 1, true)
				then
					check(resource.id, { { item = resource.item, quantity = resource.yield } })
					nodes += 1
				end
			end
		end
		assert(nodes >= 280, "every catalog and layout node checked, got " .. nodes)
	end,
}
