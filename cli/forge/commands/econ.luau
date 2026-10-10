--!strict
-- `forge econ sim [--pack <slug>] [--players N] [--days D] [--seed S] [--out <path>]`:
-- simulate a pack's free-currency economy with the pure econsim engine and write
-- a markdown report (default reports/econ-sim-<pack>.md). No network calls.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local econsim = require("../lib/econsim")
local cliutil = require("../lib/cliutil")
local registryLib = require("../lib/genreregistry")
local genresim = require("../lib/genresim")
local scaffold = require("../lib/scaffold")

local M = {}

local DEFAULT_PACK = "kaiju-egg-raiders"
local DEFAULT_PLAYERS = 20
local DEFAULT_DAYS = 7
local DEFAULT_SEED = 1
local MAX_PLAYERS = 1000000
local MAX_DAYS = 3650

local function printUsage()
	stdio.ewrite([[Usage: lune run cli/forge econ sim [--pack <slug>] [--players N] [--days D] [--seed S] [--out <path>]

  sim    Simulate a game pack's free-currency economy and write a markdown report.
         Flags:
           --pack <slug>  game pack under games/ (default: kaiju-egg-raiders)
           --players N    simulated players (default: 20)
           --days D       simulated days (default: 7)
           --seed S       deterministic PRNG seed (default: 1)
           --out <path>   report path (default: reports/econ-sim-<pack>.md)
]])
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
	local index = 3
	while index <= #args do
		local flag = args[index]
		if flag == "--pack" or flag == "--players" or flag == "--days" or flag == "--seed" or flag == "--out" then
			local value = args[index + 1]
			if value == nil or value == "" then
				stdio.ewrite("Error: " .. flag .. " requires a value\n")
				return false
			end
			if flag == "--pack" then
				pack = value
			elseif flag == "--out" then
				out = value
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

	local packDir = (if context and context.packsDir then context.packsDir else "games") .. "/" .. pack
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
		local ok, report = pcall(function()
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
			return genresim.render(pack, results)
		end)
		if not ok then
			stdio.ewrite("Error: genre simulation: " .. tostring(report) .. "\n")
			return false
		end
		ensureParentDir(outPath)
		fs.writeFile(outPath, report)
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

	stdio.write(econsim.summarize(pack, outPath, result) .. "\n")
	return true
end

return M
