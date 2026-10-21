--!strict
local Timbre = require("./Timbre")
return {
	["eight first party profiles produce distinct audible deterministic samples"] = function()
		local signatures = {}
		for index, id in { "piano", "guitar", "bass", "violin", "flute", "clarinet", "trumpet", "drums" } do
			local profile: any = {
				id = id,
				attack = 0.002 * index,
				release = 0.1,
				decay = index,
				harmonics = { 1, index / 10, index / 20 },
				noise = if id == "drums" then 0.5 else 0,
				gain = 0.2,
			}
			if id == "drums" then
				profile.pitchMin = 21
				profile.drums = {
					{
						frequency = 80,
						attack = 0.001,
						release = 0.1,
						decay = 20,
						harmonics = { 1 },
						noise = 0.5,
						gain = 0.2,
					},
				}
			end
			local a = Timbre.render(profile, 60, 100, 0.2, 8000, 1605)
			local b = Timbre.render(profile, 60, 100, 0.2, 8000, 1605)
			local sum = 0
			for i, sample in a.samples do
				assert(sample == b.samples[i], "same seed renders same samples")
				sum += math.abs(sample)
			end
			assert(sum > 1, "render is audible not a silent placeholder")
			local signature = tostring(sum)
			assert(not signatures[signature], "timbres differ")
			signatures[signature] = true
		end
	end,
}
