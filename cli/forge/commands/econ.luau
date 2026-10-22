--!strict
-- `forge econ sim [--pack <slug>] [--players N] [--days D] [--seed S] [--out <path>] [--json <path>]`:
-- simulate a pack's free-currency economy with the pure econsim engine and write
-- a markdown report (default reports/econ-sim-<pack>.md), and with --json a
-- schemaVersion 1 JSON result. No network calls.
-- `--crafting [--hours H]` instead runs the single-player survival-coop crafting-loop pacing
-- driver (lib/craftsim) on the pack's content.yml.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local econsim = require("../lib/econsim")
local craftsim = require("../lib/craftsim")
local cliutil = require("../lib/cliutil")
local registryLib = require("../lib/genreregistry")
local genrecontract = require("../lib/genrecontract")
local genresim = require("../lib/genresim")
local scaffold = require("../lib/scaffold")

local M = {}

local DEFAULT_PACK = "kaiju-egg-raiders"
local DEFAULT_PLAYERS = 20
local DEFAULT_DAYS = 7
local DEFAULT_SEED = 1
local MAX_PLAYERS = 1000000
local MAX_DAYS = 3650
local DEFAULT_HOURS = 10
local MAX_HOURS = 1000

local function printUsage()
	stdio.ewrite(
		[[Usage: lune run cli/forge econ sim [--pack <slug>] [--players N] [--days D] [--seed S] [--out <path>] [--json <path>]
       lune run cli/forge econ sim --crafting [--pack <slug>] [--hours H] [--seed S] [--out <path>] [--json <path>]

  sim    Simulate a game pack's free-currency economy and write a markdown report.
         Flags:
           --pack <slug>  game pack under games/ (default: kaiju-egg-raiders)
           --players N    simulated players (default: 20)
           --days D       simulated days (default: 7)
           --seed S       deterministic PRNG seed (default: 1)
           --out <path>   report path (default: reports/econ-sim-<pack>.md)
           --json <path>  also write a versioned machine-readable result (schemaVersion 1)
           --crafting     survival-coop crafting packs (content.yml): one scripted free player
                          gathers, crafts, clears guides/contracts/missions, sells at the harbor
                          buyback and pays repairs on an explicit clock. Reports per-hour Coins,
                          XP/level, first-time milestones and faucets vs sinks. No Robux.
           --hours H      simulated hours for --crafting (default: 10)
]]
	)
end

local function ensureDir(path: string)
	if path ~= "" and not fs.isDir(path) then
		fs.writeDir(path)
	end
end

local function ensureParentDir(path: string)
	local parent = string.match(path, "^(.*)/[^/]+$")
	if parent ~= nil then
		ensureDir(parent)
	end
end

local function writeJson(path: string, document: { [string]: any })
	ensureParentDir(path)
	fs.writeFile(path, serde.encode("json", document, true) .. "\n")
end

--- Inserts a "Seed: <n>" line under the genre report title.
local function withSeedLine(report: string, seed: number): string
	local title, rest = string.match(report, "^([^\n]*)\n\n(.*)$")
	assert(title ~= nil and rest ~= nil, "unexpected genre report layout")
	return title .. "\n\nSeed: " .. string.format("%d", seed) .. "\n\n" .. rest
end

--- Machine-readable Sources/Sinks/Accepted/Rejected rows, sorted by genre id.
local function genreRows(results: { [string]: genrecontract.SimMetrics }): { { [string]: any } }
	local ids = {}
	for id in results do
		table.insert(ids, id)
	end
	table.sort(ids)
	local rows = {}
	for _, id in ids do
		local metrics = results[id]
		table.insert(rows, {
			genre = id,
			sources = metrics.sourceTotal,
			sinks = metrics.sinkTotal,
			accepted = metrics.acceptedActions,
			rejected = metrics.rejectedActions,
		})
	end
	return rows
end

local function loadMonetization(path: string): { econsim.MonetizationEntry }
	local entries: { econsim.MonetizationEntry } = {}
	if not fs.isFile(path) then
		return entries
	end
	local decodeOk, game = pcall(function()
		return serde.decode("yaml", fs.readFile(path))
	end)
	if not decodeOk or typeof(game) ~= "table" then
		return entries
	end
	local monetization = game.monetization
	if typeof(monetization) ~= "table" then
		return entries
	end
	for _, kind in { "gamepasses", "products", "subscriptions" } do
		local list = monetization[kind]
		if typeof(list) == "table" then
			for _, item in pairs(list) do
				if typeof(item) == "table" then
					local name = item.name
					if name == nil then
						name = item.key
					end
					table.insert(entries, {
						kind = kind,
						name = tostring(name or ""),
						price = tonumber(item.price) or 0,
					})
				end
			end
		end
	end
	return entries
end

--- `--crafting`: run the survival-coop crafting-loop driver on content.yml and write the
--- markdown table plus the optional schemaVersion 1 JSON.
local function runCrafting(
	pack: string,
	packDir: string,
	seed: number,
	hours: number,
	out: string?,
	jsonPath: string?,
	context: cliutil.CommandContext?
): boolean
	local contentPath = packDir .. "/content.yml"
	local econPath = packDir .. "/econ.yml"
	if not fs.isFile(contentPath) or not fs.isFile(econPath) then
		stdio.ewrite("Error: --crafting needs " .. contentPath .. " and " .. econPath .. "\n")
		return false
	end
	local ok, result = pcall(function()
		local content = serde.decode("yaml", fs.readFile(contentPath))
		local econ = serde.decode("yaml", fs.readFile(econPath))
		local survival = econ.genre_contract.configs["survival-coop"]
		assert(survival and survival.mode == "crafting", "pack is not a survival-coop crafting pack")
		local inventory = survival.inventory
		return craftsim.simulate(content, {
			seed = seed,
			hours = hours,
			startingBalance = survival.startingBalance,
			starter = inventory.containers[inventory.carriedContainer],
		})
	end)
	if not ok then
		stdio.ewrite("Error: crafting simulation: " .. tostring(result) .. "\n")
		return false
	end
	result.pack = pack
	local outPath = if out ~= nil and out ~= ""
		then out
		else (if context and context.reportsDir then context.reportsDir else "reports")
			.. "/econ-sim-"
			.. pack
			.. "-crafting.md"
	local lines = {
		"# Crafting-loop sim: " .. pack,
		"",
		string.format("Seed: %d, hours: %d, Robux spent: 0", seed, hours),
		"",
		"| hour | coins | xp | level |",
		"|---|---|---|---|",
	}
	for _, row in result.hourly do
		table.insert(lines, string.format("| %d | %d | %d | %d |", row.hour, row.coins, row.xp, row.level))
	end
	table.insert(lines, "")
	table.insert(lines, string.format("Faucets %d, sinks %d", result.faucetTotal, result.sinkTotal))
	ensureParentDir(outPath)
	fs.writeFile(outPath, table.concat(lines, "\n") .. "\n")
	if jsonPath ~= nil then
		writeJson(jsonPath, result)
	end
	stdio.write(
		string.format(
			"econ sim: crafting %s %dh coins=%d level=%d; wrote %s\n",
			pack,
			hours,
			result.final.coins,
			result.final.level,
			outPath
		)
	)
	return true
end

--- Parses flags, runs the simulation, and writes the report. Returns false with a
--- stderr message on usage errors; never touches the network.
function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	if args[2] ~= "sim" then
		printUsage()
		return false
	end

	local pack = DEFAULT_PACK
	local players = DEFAULT_PLAYERS
	local days = DEFAULT_DAYS
	local seed = DEFAULT_SEED
	local out: string? = nil
	local jsonPath: string? = nil
	local crafting = false
	local hours = DEFAULT_HOURS
	local index = 3
	while index <= #args do
		local flag = args[index]
		if flag == "--crafting" then
			crafting = true
			index += 1
		elseif
			flag == "--pack"
			or flag == "--players"
			or flag == "--days"
			or flag == "--hours"
			or flag == "--seed"
			or flag == "--out"
			or flag == "--json"
		then
			local value = args[index + 1]
			if value == nil or value == "" then
				stdio.ewrite("Error: " .. flag .. " requires a value\n")
				return false
			end
			if flag == "--pack" then
				pack = value
			elseif flag == "--out" then
				out = value
			elseif flag == "--json" then
				jsonPath = value
			else
				local number, reason = cliutil.parseFiniteInt(value)
				if number == nil then
					stdio.ewrite("Error: " .. flag .. " requires a number: " .. tostring(reason) .. "\n")
					return false
				end
				if flag == "--players" then
					players = number
				elseif flag == "--days" then
					days = number
				elseif flag == "--hours" then
					hours = number
				else
					seed = number
				end
			end
			index += 2
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge econ sim\n")
			return false
		end
	end

	if players < 1 or days < 1 then
		stdio.ewrite("Error: --players and --days must be >= 1\n")
		return false
	end
	if players > MAX_PLAYERS or days > MAX_DAYS then
		stdio.ewrite(string.format("Error: --players must be <= %d and --days <= %d\n", MAX_PLAYERS, MAX_DAYS))
		return false
	end
	if seed < 0 then
		stdio.ewrite("Error: --seed must be >= 0\n")
		return false
	end
	if hours < 1 or hours > MAX_HOURS then
		stdio.ewrite(string.format("Error: --hours must be between 1 and %d\n", MAX_HOURS))
		return false
	end

	local packDir = (if context and context.packsDir then context.packsDir else "games") .. "/" .. pack
	if crafting then
		return runCrafting(pack, packDir, seed, hours, out, jsonPath, context)
	end
	local econPath = packDir .. "/econ.yml"
	if not fs.isDir(packDir) or not fs.isFile(econPath) then
		stdio.ewrite("Error: missing " .. econPath .. "\n")
		return false
	end

	local decodeOk, econ = pcall(function()
		return serde.decode("yaml", fs.readFile(econPath))
	end)
	if not decodeOk or typeof(econ) ~= "table" then
		stdio.ewrite("Error: failed to decode " .. econPath .. "\n")
		return false
	end

	local outPath = if out ~= nil and out ~= ""
		then out
		else (if context and context.reportsDir then context.reportsDir else "reports") .. "/econ-sim-" .. pack .. ".md"
	if econ.genre_contract ~= nil then
		local ok, simulated = pcall(function()
			local registry, errors = registryLib.discover(if context then context.genresDir else nil)
			assert(registry ~= nil, table.concat(errors, "; "))
			local pascal = scaffold.pascalCase(pack)
			local results = genresim.simulate(econ.genre_contract, registry, {
				mode = "plan",
				slug = pack,
				pascal = pascal,
				title = pack,
				concept = "",
				seed = seed,
				teams = { "Red", "Blue" },
				debugName = pascal .. "Debug",
				guiName = pascal .. "Gui",
			}, players, days)
			return { report = withSeedLine(genresim.render(pack, results), seed), rows = genreRows(results) }
		end)
		if not ok then
			stdio.ewrite("Error: genre simulation: " .. tostring(simulated) .. "\n")
			return false
		end
		ensureParentDir(outPath)
		fs.writeFile(outPath, simulated.report)
		if jsonPath ~= nil then
			writeJson(jsonPath, {
				schemaVersion = 1,
				pack = pack,
				seed = seed,
				players = players,
				days = days,
				mode = "genre",
				rows = simulated.rows,
			})
		end
		stdio.write("econ sim: wrote " .. outPath .. "\n")
		return true
	end
	local config = econsim.parseConfig(econ)
	local monetization = loadMonetization(packDir .. "/game.yml")
	local options: econsim.SimOptions = { players = players, days = days, seed = seed }
	local result = econsim.simulate(config, options)
	local report = econsim.renderReport(pack, config, options, monetization, result)

	ensureParentDir(outPath)
	fs.writeFile(outPath, report)
	if jsonPath ~= nil then
		local series = {}
		for day = 1, result.days do
			table.insert(series, {
				day = day,
				supply = result.dailySupply[day],
				inflationPercent = result.dailyInflation[day],
			})
		end
		local rows = {}
		for _, item in monetization do
			table.insert(rows, { kind = item.kind, name = item.name, price = item.price })
		end
		writeJson(jsonPath, {
			schemaVersion = 1,
			pack = pack,
			seed = seed,
			players = result.players,
			days = result.days,
			mode = "legacy",
			startingSupply = result.startingSupply,
			series = series,
			totalProduced = result.totalProduced,
			totalSpent = result.totalSpent,
			monetization = rows,
		})
	end

	stdio.write(econsim.summarize(pack, outPath, result) .. "\n")
	return true
end

return M
