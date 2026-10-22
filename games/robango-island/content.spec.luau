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

	["20 guides in 5 bands of 4 each award 50 development"] = function()
		local guides = load().guides
		assert(#guides == 20, "20 guides")
		for i, guide in guides do
			local first = guides[i - (i - 1) % 4]
			assert(guide.rewards.development == 50, "50 development " .. guide.id)
			assert(guide.gates.developmentRank == ((i - 1) // 4) * 2, "band rank " .. guide.id)
			assert(guide.gates.characterLevel == first.gates.characterLevel, "band level " .. guide.id)
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
}
