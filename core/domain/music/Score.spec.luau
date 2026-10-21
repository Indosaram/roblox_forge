--!strict
local serde = require("@lune/serde")
local Score = require("./Score")
local Rules = require("./TestCatalog")
local function score(): any
	return {
		version = 1,
		tempo = 120,
		parts = {
			{ instrumentId = "piano", notes = { { startTick = 0, durationTicks = 480, pitch = 60, velocity = 100 } } },
		},
	}
end
local function decode(text: string): any
	return serde.decode("json", text)
end
return {
	["strict score schema refuses each malformed field without changing input"] = function()
		local mutations: { (any) -> () } = {
			function(s)
				s.url = "https://invalid"
			end,
			function(s)
				s.version = 2
			end,
			function(s)
				s.tempo = 39
			end,
			function(s)
				s.tempo = 201
			end,
			function(s)
				s.parts[1].instrumentId = "unknown"
			end,
			function(s)
				s.parts[1].notes[1].pitch = 20
			end,
			function(s)
				s.parts[1].notes[1].pitch = 109
			end,
			function(s)
				s.parts[1].notes[1].velocity = 0
			end,
			function(s)
				s.parts[1].notes[1].velocity = 128
			end,
			function(s)
				s.parts[1].notes[1].startTick = -1
			end,
			function(s)
				s.parts[1].notes[1].durationTicks = 0
			end,
			function(s)
				s.parts[1].notes[1].durationTicks = 172801
			end,
			function(s)
				s.parts[1].notes[1].extra = true
			end,
			function(s)
				s.parts[1].notes.bad = {}
			end,
			function(s)
				for _ = 1, 8 do
					table.insert(s.parts[1].notes, Score.copy(s.parts[1].notes[1]))
				end
			end,
			function(s)
				for _ = 1, 6 do
					table.insert(s.parts, Score.copy(s.parts[1]))
				end
			end,
		}
		for _, mutate in mutations do
			local value = score()
			mutate(value)
			local before = serde.encode("json", value)
			assert(Score.validate(value, Rules) == nil, "Score.spec.luau: invariant failed")
			assert(serde.encode("json", value) == before, "Score.spec.luau: invariant failed")
		end
	end,
	["import rejects size before decoder and malformed UTF8 JSON"] = function()
		local called = false
		assert(Score.import(string.rep(" ", Rules.maxBytes + 1), Rules, function()
			called = true
			return nil
		end) == nil, "Score.spec.luau: invariant failed")
		assert(not called, "Score.spec.luau: invariant failed")
		assert(Score.import(string.char(255), Rules, decode) == nil, "Score.spec.luau: invariant failed")
		assert(Score.import("{", Rules, decode) == nil, "Score.spec.luau: invariant failed")
		assert(Score.import(serde.encode("json", score()), Rules, decode), "Score.spec.luau: invariant failed")
	end,
	["half open polyphony and eight distinct instrument bindings"] = function()
		local value = score()
		for _ = 1, 7 do
			table.insert(value.parts[1].notes, Score.copy(value.parts[1].notes[1]))
		end
		table.insert(value.parts[1].notes, { startTick = 480, durationTicks = 480, pitch = 108, velocity = 127 })
		assert(Score.validate(value, Rules), "Score.spec.luau: invariant failed")
		local seen = {}
		local count = 0
		local instruments: any = Rules.instruments
		for id, instrument in instruments do
			assert(not seen[instrument.assetKey], "Score.spec.luau: invariant failed")
			seen[instrument.assetKey] = true
			count += 1
			value.parts[1].instrumentId = id
			assert(Score.validate(value, Rules), "Score.spec.luau: invariant failed")
		end
		assert(count == 8, "Score.spec.luau: invariant failed")
	end,
}
