--!strict
local Render = require("./render-audio")
local Wav = require("../../../cli/forge/lib/wav")
local Catalog = require("../src/shared/RobangoAudioCatalog")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
return {
	["every catalog slot has a non silent deterministic first party recipe"] = function()
		local doc = serde.decode("yaml", fs.readFile("games/robango-island/assets/robango-audio.yml"))
		local seen = {}
		for _, cue in doc.cues do
			assert(Catalog.slots[cue.key] and not seen[cue.key], "unique configured recipe")
			seen[cue.key] = true
			local short = table.clone(cue)
			short.duration = if cue.kind == "music" then 4 else cue.duration
			local a = Wav.encode(Render.render(short, 8000))
			local b = Wav.encode(Render.render(short, 8000))
			assert(buffer.tostring(a) == buffer.tostring(b), cue.key .. " must be deterministic")
			local nonzero = false
			for offset = 44, buffer.len(a) - 2, 2 do
				if buffer.readi16(a, offset) ~= 0 then
					nonzero = true
					break
				end
			end
			assert(nonzero, cue.key .. " must not be silent")
		end
		for slot in Catalog.slots do
			assert(seen[slot], tostring(slot) .. " recipe missing")
		end
	end,
}
