--!strict
-- Specs for the headless 8-actor load proof. The script/actor helpers are pure;
-- the last case runs the real Session/Executor for eight actors against the
-- grow-harvest contract and requires every invariant to hold.

local loadproof = require("./loadproof")
local registryLib = require("./genreregistry")
local qagen = require("./qagen")
local Runtime = require("../../../genres/grow-harvest/module/Contract")
local Fixture = require("../../../genres/grow-harvest/module/Adapter.fixture")

local function target(): any
	return {
		packConfig = { api = 1, order = { Runtime.id }, configs = { [Runtime.id] = Fixture.config() } },
		contracts = { Runtime },
		controls = {},
		storeName = "LoadProofSpec",
	}
end

local function growScenario(): any
	local registry = assert(registryLib.discover())
	local spec = registry.packages["grow-harvest"].spec
	return qagen.derive(spec, { name = "golden-path", genre = "grow-harvest", pack = "load-proof" })
end

return {
	["the script replays the primary's actions and normalizes the clock"] = function()
		local steps: { any } = {
			{ op = "begin_clock" },
			{ op = "join", player = "1" },
			{ op = "join", player = "2" },
			{ op = "dispatch", player = "1", action = "grow-harvest:buy-seed", args = { "carrot" } },
			{ op = "advance_elapsed", seconds = 2 },
			{ op = "dispatch", player = "1", action = "grow-harvest:plant", args = { 1, "carrot" } :: { any } },
			-- A peer's own step is not part of the primary's loop.
			{ op = "dispatch", player = "2", action = "grow-harvest:plant", args = { 1, "carrot" } :: { any } },
			{ op = "expect_snapshot", player = "1", genre = "grow-harvest", field = "balance", equals = 9 },
			{ op = "advance_to", seconds = 5 },
			{ op = "save", player = "1", label = "saved" },
		}
		local script = loadproof.script({
			kind = "native",
			players = { "1", "2" },
			steps = steps,
		})
		assert(script.primary == "1", "the primary is the first declared player")
		assert(#script.roster == 2, "the roster keeps both declared players")
		local kinds: { string } = {}
		for _, step in script.steps do
			table.insert(kinds, step.kind .. ":" .. tostring(step.action or step.seconds))
		end
		assert(
			table.concat(kinds, "|") == "action:grow-harvest:buy-seed|advance:2|action:grow-harvest:plant|advance:5",
			table.concat(kinds, "|")
		)
	end,

	["the actor list keeps the primary, adds distinct peers, and joins the declared roster"] = function()
		local declared = { "1", "2" }
		local runners = loadproof.runners(declared, 8)
		assert(#runners == 8, "eight loop actors")
		assert(runners[1] == "1", "the primary acts first")
		local roster = loadproof.roster(declared, 8)
		assert(#roster == 9, "the declared peers stay in the roster beside the eight loop actors")
		assert(roster[1] == "1" and roster[2] == "2", "the declared roster comes first")
		local seen: { [string]: boolean } = {}
		for _, actor in roster do
			assert(not seen[actor], "no duplicate actor id: " .. actor)
			seen[actor] = true
		end
		for _, actor in runners do
			assert(seen[actor], "every loop actor is joined: " .. actor)
		end
	end,

	["eight actors run the golden path concurrently and every invariant holds"] = function()
		local result = loadproof.run({
			target = target(),
			scenario = growScenario(),
			actors = 8,
			storeName = "LoadProofSpec",
		})
		assert(result.actors == 8, "eight actors ran")
		assert(result.actions > 0, "the script carried actions")
		for name, invariant in result.invariants do
			assert(invariant.ok, name .. ": " .. tostring(invariant.detail))
		end
		assert(result.ok, "the run is green: " .. table.concat(result.failures, "; "))
		assert(#result.failures == 0, "no failures recorded")
	end,
}
