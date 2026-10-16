--!strict
-- Publication supplies Assets; local WAV paths are not Roblox playback IDs.
return {
	assets = require("./Assets"),
	cues = {
		gather = { asset = "survival-coop-gather", volume = 0.4 },
		craft = { asset = "survival-coop-craft", volume = 0.4 },
		eat = { asset = "survival-coop-eat", volume = 0.3 },
		hit = { asset = "survival-coop-action", volume = 0.45 },
		rest = { asset = "survival-coop-rest", volume = 0.15 },
		ambient = { asset = "survival-coop-ambient", volume = 0.12 },
	},
}
