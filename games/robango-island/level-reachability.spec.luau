--!strict
-- Spec progression gate (owner decision 2026-10-23): every route character gate is reachable
-- from level 1 within contentgraph.RUN_BUDGET runs of the kills, missions, guides and chapters
-- open before it. The p33 curve (route 1 at L2, route 2 at L35, xpStep 80) needs far more.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local graph = require("../../cli/forge/lib/contentgraph")

local function load(): any
	return serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
end

local function failures(document: any): { string }
	local result = {}
	for _, gate in graph.levelReachability(document) do
		if not gate.ok then
			table.insert(
				result,
				string.format(
					"L%d: L%d->L%d after %d runs (budget %d)",
					gate.gate,
					gate.from,
					gate.reached,
					gate.runs,
					gate.budget
				)
			)
		end
	end
	return result
end

return {
	["every route level gate is reachable within the run budget"] = function()
		local gates = graph.levelReachability(load())
		assert(#gates == 5, "five route gates, got " .. tostring(#gates))
		local bad = failures(load())
		assert(#bad == 0, "unreachable route gates: " .. table.concat(bad, "; "))
	end,
	["route gates and mission xp follow the world-spec index table"] = function()
		local document = load()
		local spec = { { 30, 700, 170 }, { 35, 800, 195 }, { 40, 900, 220 }, { 50, 1100, 270 }, { 60, 1300, 320 } }
		for _, stage in document.stages do
			local index = tonumber(string.match(stage.id, "^rw%.a(%d)%."))
			if index then
				assert(stage.gates.characterLevel == spec[index][1], stage.id .. " gate")
			end
		end
		for _, mission in document.missions do
			local row = spec[assert(tonumber(string.match(mission.id, "^rw%.m(%d)%.")), mission.id)]
			assert(mission.gates.characterLevel == row[1], mission.id .. " gate")
			assert(mission.rewards.xp == row[2] and mission.rewards.coins == row[3], mission.id .. " reward")
		end
		local tree = document.progressionPolicy.tree
		-- Spec R01: the next level from L needs 100 + 25 * (L - 1).
		assert(tree.xpBase + tree.xpStep * 1 == 100 and tree.xpStep == 25, "spec xp curve")
	end,
	["the check rejects the p33 redesign curve"] = function()
		local document = load()
		document.progressionPolicy.tree.xpBase, document.progressionPolicy.tree.xpStep = 20, 80
		local p33 = { 450, 500, 600, 700 }
		for _, stage in document.stages do
			if string.match(stage.id, "^rw%.a1%.") then
				stage.gates.characterLevel = 2
			end
		end
		for _, mission in document.missions do
			local index = assert(tonumber(string.match(mission.id, "^rw%.m(%d)%.")), mission.id)
			mission.rewards.xp = if index == 1 then 30 else p33[index - 1]
		end
		local bad = failures(document)
		assert(#bad > 0, "the p33 curve must fail levelReachability")
	end,
}
