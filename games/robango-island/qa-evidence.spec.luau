--!strict
-- robango-island QA evidence specs (plan §12): QA-ERR-01, QA-ECON-01, QA-ASSET-01,
-- QA-SAVE-01 and QA-PERF-01 (static build budget). Every spec name carries its QA ID
-- so `git grep QA-XXX` finds it. Each gate has a negative case that must fail.

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Allocation = require("../../core/domain/island/Allocation")
local Content = require("../../core/domain/survival/Content")
local Strings = require("../../core/infra/localization/Strings")
local assetsLib = require("../../cli/forge/lib/assets")
local qa = require("../../cli/forge/commands/qa")
local qaharness = require("../../cli/forge/lib/qaharness")
local registryLib = require("../../cli/forge/lib/genreregistry")
local run = require("../../cli/forge/lib/run")

-- Specs run from the repository root.
local PACK = "games/robango-island"

local function decodeYaml(path: string): any
	return serde.decode("yaml", fs.readFile(path))
end

-- QA-ERR-01 ---------------------------------------------------------------------

-- Internal text that must never reach a player: SQL, Lua stack traces, internal ids
-- (uuid / long hex / island keys / job ids) and file or instance paths.
local ERR_PATTERNS: { { pattern: string, reason: string } } = {
	{ pattern = "SELECT%s", reason = "sql" },
	{ pattern = "INSERT%s+INTO", reason = "sql" },
	{ pattern = "UPDATE%s+[%w_]+%s+SET", reason = "sql" },
	{ pattern = "DELETE%s+FROM", reason = "sql" },
	{ pattern = "DROP%s+TABLE", reason = "sql" },
	{ pattern = "%f[%w]SQL%f[%W]", reason = "sql" },
	{ pattern = "[Ss]tack [Tt]raceback", reason = "stack" },
	{ pattern = "%.luau?:%d+", reason = "stack" },
	{ pattern = "attempt to ", reason = "stack" },
	{ pattern = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x", reason = "uuid" },
	{ pattern = "%f[%x]%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x+%f[%X]", reason = "hex-id" },
	{ pattern = "island:", reason = "island-key" },
	{ pattern = "w%d+:%d+:%d+:%d+:", reason = "job-id" },
	{ pattern = "[%w_%-]+/[%w_%-]+%.[%a]+", reason = "file-path" },
	{ pattern = "ServerStorage", reason = "instance-path" },
	{ pattern = "ReplicatedStorage", reason = "instance-path" },
	{ pattern = "/Users/", reason = "file-path" },
}

local function leakReasons(text: string): { string }
	local reasons: { string } = {}
	for _, rule in ERR_PATTERNS do
		if string.find(text, rule.pattern) and not table.find(reasons, rule.reason) then
			table.insert(reasons, rule.reason)
		end
	end
	return reasons
end

-- Player-facing strings: the Source/en-us/ko-kr columns of strings.csv (the Context
-- column is a developer note and never rendered), plus every player message the
-- island allocator can build (key + params).
local function playerStrings(): { string }
	local parsed = Strings.parseCsv(fs.readFile(PACK .. "/locale/strings.csv"))
	local found: { string } = {}
	for _, row in parsed.rows do
		for _, column in { 2, 4, 5 } do
			if row[column] ~= nil and row[column] ~= "" then
				table.insert(found, row[column])
			end
		end
	end
	for _, code in { "queued", "assigned", "moved", "full", "invalid_transition", "route_expired", "internal" } do
		local message = Allocation.playerMessage(code, 12, 4)
		local parts = { message.key }
		for name, value in message.params do
			table.insert(parts, name .. "=" .. tostring(value))
		end
		table.insert(found, table.concat(parts, " "))
	end
	return found
end

-- QA-ECON-01 --------------------------------------------------------------------

-- 신규 산정: per-material source/sink band, in units of (gather yield per hour) /
-- (raw material needed to build every structure once). Below 1.0 the structures
-- cannot all be built from node income; above 100 the material is free.
local ECON_BAND_MIN = 1.0
local ECON_BAND_MAX = 100.0

type Economy = { source: { [string]: number }, sink: { [string]: number } }

-- Raw gather yield per hour per item, and the raw items (recursively expanded
-- through recipes) needed to build each structure once.
local function economy(document: Content.Document, sourceScale: number): Economy
	local source: { [string]: number } = {}
	for _, node in document.nodes do
		for _, entry in node.harvest do
			source[entry.item] = (source[entry.item] or 0) + sourceScale * entry.quantity * 3600000 / node.respawnMillis
		end
	end
	local producer: { [string]: any } = {}
	for _, recipe in document.recipes do
		for _, output in recipe.outputs do
			producer[output.item] = recipe
		end
	end
	local sink: { [string]: number } = {}
	local function expand(item: string, quantity: number)
		local recipe = producer[item]
		if recipe == nil then
			sink[item] = (sink[item] or 0) + quantity
			return
		end
		local produced = 1
		for _, output in recipe.outputs do
			if output.item == item then
				produced = output.quantity
			end
		end
		local runs = math.ceil(quantity / produced)
		for _, input in recipe.inputs do
			expand(input.item, input.quantity * runs)
		end
	end
	for _, structure in document.structures do
		for _, cost in structure.cost do
			expand(cost.item, cost.quantity)
		end
	end
	return { source = source, sink = sink }
end

-- Materials with a gather-node source must sit inside the band. Items that only
-- drop from wildlife (hide) have no node source and are covered by WildlifePolicy.
local function econBandErrors(model: Economy): { string }
	local errors: { string } = {}
	for item, needed in model.sink do
		local income = model.source[item]
		if income ~= nil then
			local ratio = income / needed
			if ratio < ECON_BAND_MIN or ratio > ECON_BAND_MAX then
				table.insert(
					errors,
					string.format(
						"%s source/sink ratio %.2f outside [%g, %g]",
						item,
						ratio,
						ECON_BAND_MIN,
						ECON_BAND_MAX
					)
				)
			end
		end
	end
	table.sort(errors)
	return errors
end

local function canonicalContent(): Content.Document
	local document, errors = Content.canonicalize(decodeYaml(PACK .. "/content.yml"))
	assert(document, table.concat(errors, "; "))
	return document :: Content.Document
end

-- QA-ASSET-01 -------------------------------------------------------------------

local function loadManifest(): assetsLib.Manifest
	local manifest, err = assetsLib.parseManifest(decodeYaml(PACK .. "/assets/manifest.yml"))
	assert(manifest, tostring(err))
	return manifest :: assetsLib.Manifest
end

local function provenanceErrors(manifest: assetsLib.Manifest): { string }
	return assetsLib.checkProvenance(manifest, { requireProvenance = true }).errors
end

local function mentions(errors: { string }, needle: string): boolean
	for _, message in errors do
		if string.find(message, needle, 1, true) then
			return true
		end
	end
	return false
end

-- QA-SAVE-01 --------------------------------------------------------------------

local SAVE_SCENARIO = "survival-coop.qa-save-01-rejoin-transfer-crash"

local function runSave(mutate: ((any) -> ())?): qaharness.Outcome
	local scenario = decodeYaml(PACK .. "/qa-scenarios/" .. SAVE_SCENARIO .. ".yml")
	if mutate then
		mutate(scenario)
	end
	local registry = assert(registryLib.discover(nil))
	local target, errors = qa.loadTarget("robango-island", registry, nil, nil)
	assert(target, table.concat(errors, "; "))
	return qaharness.runNative(scenario, target :: qaharness.Target)
end

-- QA-PERF-01 --------------------------------------------------------------------

-- 신규 산정 static build budget for the low-end mobile profile. Measured at
-- 217 instances / 168 scripts / 1.26 MB script source / 0.54 MB place file; the
-- budget leaves roughly 2x headroom. First-interaction time and device memory
-- cannot be measured locally (see docs/games/robango-island/qa-evidence.md).
local PERF_BUDGET = { instances = 400, scripts = 300, sourceBytes = 2500000, fileBytes = 1500000 }

type Measure = { instances: number, scripts: number, sourceBytes: number, fileBytes: number }

local function measurePlace(path: string): Measure
	local content = fs.readFile(path)
	local place: any = roblox.deserializePlace(content)
	local measure = { instances = 0, scripts = 0, sourceBytes = 0, fileBytes = #content }
	local function walk(instance: any)
		measure.instances += 1
		if instance:IsA("LuaSourceContainer") then
			measure.scripts += 1
			measure.sourceBytes += #instance.Source
		end
		for _, child in instance:GetChildren() do
			walk(child)
		end
	end
	for _, child in place:GetChildren() do
		walk(child)
	end
	return measure
end

local function budgetErrors(measure: Measure): { string }
	local errors: { string } = {}
	for name, limit in PERF_BUDGET do
		local value = (measure :: any)[name]
		if value > limit then
			table.insert(errors, string.format("%s %d exceeds budget %d", name, value, limit))
		end
	end
	table.sort(errors)
	return errors
end

return {
	["QA-ERR-01 no player-facing string carries SQL, stack traces, internal ids or paths"] = function()
		local strings = playerStrings()
		assert(#strings > 100, "the real catalog must be scanned, got " .. #strings .. " strings")
		for _, text in strings do
			local reasons = leakReasons(text)
			assert(#reasons == 0, string.format("player string leaks (%s): %s", table.concat(reasons, ","), text))
		end
	end,

	["QA-ERR-01 NEGATIVE: planted SQL, stack, uuid, island key and path strings are flagged"] = function()
		local planted = {
			sql = "Could not load: SELECT * FROM profiles WHERE id = 1",
			stack = "Error at core/infra/island/Lease.luau:42 in function acquire",
			uuid = "Join failed for 123e4567-e89b-12d3-a456-426614174000",
			islandKey = "Teleporting to island:home:7",
			path = "Missing file games/robango-island/src/server/Boot.luau",
			hex = "Session a1b2c3d4e5f60718293a4b5c6d7e8f90 expired",
		}
		local expected = {
			sql = "sql",
			stack = "stack",
			uuid = "uuid",
			islandKey = "island-key",
			path = "file-path",
			hex = "hex-id",
		}
		for name, text in planted do
			local reasons = leakReasons(text)
			assert(
				table.find(reasons, (expected :: any)[name]) ~= nil,
				"planted " .. name .. " string was not flagged: " .. text
			)
		end
	end,

	["QA-ECON-01 material source/sink balance sits inside the 신규 산정 band"] = function()
		local model = economy(canonicalContent(), 1)
		local checked = 0
		for item in model.sink do
			if model.source[item] ~= nil then
				checked += 1
			end
		end
		assert(checked >= 5, "expected at least 5 node-sourced materials in the sink, got " .. checked)
		local errors = econBandErrors(model)
		assert(#errors == 0, table.concat(errors, "; "))
	end,

	["QA-ECON-01 NEGATIVE: a doubled source breaks the band"] = function()
		local errors = econBandErrors(economy(canonicalContent(), 2))
		assert(#errors > 0, "doubling every gather yield must leave the band")
		assert(mentions(errors, "flint"), "flint (highest ratio) must be the first to leave the band")
	end,

	["QA-ECON-01 NEGATIVE: a starved source breaks the band from below"] = function()
		local errors = econBandErrors(economy(canonicalContent(), 0.1))
		assert(#errors > 0, "a tenth of the gather yield must fall below the band")
	end,

	["QA-ASSET-01 the real robango-island manifest passes tool, rights and provenance"] = function()
		local manifest = loadManifest()
		assert(#manifest.assets >= 1, "manifest has assets")
		local errors = provenanceErrors(manifest)
		assert(#errors == 0, table.concat(errors, "; "))
		local staging = assetsLib.check(manifest, "staging")
		assert(staging.ok, table.concat(staging.errors, "; "))
	end,

	["QA-ASSET-01 NEGATIVE: banned generators are rejected whatever rights the manifest claims"] = function()
		for _, banned in { "audiocraft", "roblox-cube", "hunyuan3d-2" } do
			local manifest = loadManifest()
			local asset = manifest.assets[1]
			asset.tool = banned
			if asset.provenance ~= nil then
				asset.provenance.provider.name = banned
			end
			local errors = provenanceErrors(manifest)
			assert(
				mentions(errors, "denied"),
				banned .. " must be denied by the provenance gate: " .. table.concat(errors, "; ")
			)
			local framework = assetsLib.check(manifest, "staging")
			assert(not framework.ok, banned .. " must fail assetsLib.check")
		end
	end,

	["QA-ASSET-01 NEGATIVE: missing provenance and missing rights fields are rejected"] = function()
		local manifest = loadManifest()
		manifest.assets[1].provenance = nil
		assert(mentions(provenanceErrors(manifest), "missing provenance"), "an asset without provenance must fail")

		for _, field in { "rights", "digest", "recipe", "provider" } do
			local raw = decodeYaml(PACK .. "/assets/manifest.yml")
			raw.version = 2
			raw.assets[1].provenance[field] = nil
			local parsed, err = assetsLib.parseManifest(raw)
			assert(parsed == nil, "a manifest missing provenance." .. field .. " must not parse")
			assert(
				string.find(tostring(err), field, 1, true) ~= nil,
				"error must name " .. field .. ": " .. tostring(err)
			)
		end

		local raw = decodeYaml(PACK .. "/assets/manifest.yml")
		raw.assets[1].provenance.rights.source = nil
		local parsed, err = assetsLib.parseManifest(raw)
		assert(parsed == nil and string.find(tostring(err), "rights.source", 1, true) ~= nil, tostring(err))
	end,

	["QA-SAVE-01 rejoin and transfer-crash scenario conserves items on robango-island"] = function()
		local outcome = runSave(nil)
		assert(outcome.ok, "scenario failed: " .. table.concat(outcome.failures, "; "))
		assert(outcome.assertions >= 14, "scenario must keep its conservation assertions, got " .. outcome.assertions)
	end,

	["QA-SAVE-01 NEGATIVE: a lost item (bag sum off by one) fails the scenario"] = function()
		local outcome = runSave(function(scenario: any)
			local changed = 0
			for _, step in scenario.steps do
				if step.op == "expect_snapshot" and step.field == "inventory.bag.items.starter-fiber.quantity" then
					step.equals = 8
					changed += 1
				end
			end
			assert(changed >= 3, "scenario must assert the bag quantity at least 3 times")
		end)
		assert(not outcome.ok, "an off-by-one bag quantity must fail the scenario")
	end,

	["QA-PERF-01 built robango-island place stays inside the 신규 산정 static budget"] = function()
		local out = "build/qa-perf-01.rbxl"
		local built = run.exec("rojo", { "build", PACK .. "/default.project.json", "-o", out })
		assert(built.ok, "rojo build failed: " .. built.stdout .. built.stderr)
		local measure = measurePlace(out)
		assert(measure.instances > 0 and measure.scripts > 0, "the built place must contain instances and scripts")
		local errors = budgetErrors(measure)
		assert(#errors == 0, table.concat(errors, "; "))
		local manifest = loadManifest()
		local icons, audio = 0, 0
		for _, asset in manifest.assets do
			if asset.kind == "image" then
				icons += 1
			elseif asset.kind == "sfx" or asset.kind == "bgm" then
				audio += 1
			end
			asset.assetId = 999999999999999
			asset.moderation = "Approved"
		end
		assert(icons == 518 and audio == 56, "future budget must include every icon and audio cue")
		local futureBytes = measure.sourceBytes
			- #fs.readFile(PACK .. "/src/shared/Assets.luau")
			+ #assetsLib.renderLuau(manifest, "robango-island")
		assert(
			futureBytes <= PERF_BUDGET.sourceBytes - 15000,
			"fully published assets leave less than 15 KB margin: " .. futureBytes
		)
	end,

	["QA-PERF-01 NEGATIVE: an inflated place measurement exceeds the budget"] = function()
		local errors = budgetErrors({ instances = 5000, scripts = 900, sourceBytes = 9000000, fileBytes = 4000000 })
		assert(#errors == 4, "all four budget lines must trip, got " .. #errors)
	end,
}
