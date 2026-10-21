--!strict
-- Prove negative assertions detect removed guards, without editing production files.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Score = require("./Score")
local Rules = require("./TestCatalog")
local function mutant(path: string, old: string, replacement: string): any
	local source = fs.readFile(path)
	local startAt, endAt = string.find(source, old, 1, true)
	assert(startAt and endAt, "mutation anchor exists")
	source = string.sub(source, 1, startAt - 1) .. replacement .. string.sub(source, endAt + 1)
	return luau.load(source, { environment = {
		require = function()
			return Score
		end,
	} })()
end
return {
	["negative cases kill byte polyphony and performer capacity mutations"] = function()
		local noSize = mutant("core/domain/music/Score.luau", "#text > rules.maxBytes", "false")
		local decoded = false
		noSize.import(string.rep("x", Rules.maxBytes + 1), Rules, function()
			decoded = true
			return nil
		end)
		assert(decoded, "size mutation is killed by decoder side-effect assertion")
		local score: any = { version = 1, tempo = 120, parts = { { instrumentId = "piano", notes = {} } } }
		for _ = 1, 9 do
			table.insert(score.parts[1].notes, { startTick = 0, durationTicks = 480, pitch = 60, velocity = 100 })
		end
		local noPolyphony = mutant("core/domain/music/Score.luau", "voices > rules.maxPolyphony", "false")
		assert(
			Score.validate(score, Rules) == nil and noPolyphony.validate(score, Rules) ~= nil,
			"polyphony mutation killed"
		)
		local noCapacity = mutant("core/domain/music/Ensemble.luau", "count >= rules.maxPerformers", "false")
		local room = noCapacity.new(Rules, {
			inRange = function()
				return true
			end,
			load = function()
				return { parts = { {}, {}, {}, {}, {}, {}, {} } }
			end,
		})
		for i = 1, 7 do
			assert(room.join(tostring(i), "s", 1, i), "removed capacity admits seventh performer")
		end
		assert(room.snapshot().members["7"] ~= nil, "capacity mutation killed by seventh-member assertion")
	end,
}
