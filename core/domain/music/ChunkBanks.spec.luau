--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Rules = require("./TestCatalog")
return {
	["rendered production banks have real PCM distinct hashes and valid segment boundaries"] = function()
		local seen = {}
		local banks = 0
		local instruments: { [string]: any } = Rules.instruments
		for id in instruments do
			banks += 1
			local bytes = fs.readFile("games/robango-island/assets/audio/instruments/" .. id .. ".wav")
			local digest = serde.hash("sha256", bytes)
			assert(not seen[digest], "actual unique bank digest")
			seen[digest] = true
			local wav = buffer.fromstring(bytes)
			assert(buffer.readstring(wav, 0, 4) == "RIFF" and buffer.readstring(wav, 8, 4) == "WAVE", "real WAV header")
			assert(
				buffer.readu32(wav, 24) == 22050 and buffer.readu16(wav, 34) == 16 and buffer.readu16(wav, 22) == 1,
				"mono PCM format"
			)
			local count = buffer.readu32(wav, 40) / 2
			local energy = 0
			for i = 0, count - 1 do
				energy += math.abs(buffer.readi16(wav, 44 + i * 2))
			end
			assert(energy > count, "audible bank")
			assert(#bytes == 44 + count * 2, "sample regions cover exact bank")
		end
		assert(banks == 8, "eight banks")
	end,
}
