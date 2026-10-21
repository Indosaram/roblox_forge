--!strict
-- Specification fixture only. Production injects generated SurvivalContent.music.
return {
	maxBytes = 262144,
	tempoMin = 40,
	tempoMax = 200,
	maxParts = 6,
	maxPerformers = 6,
	maxNotesPerPart = 16384,
	ticksPerQuarter = 480,
	maxDurationSeconds = 180,
	maxPolyphony = 8,
	pitchMin = 21,
	pitchMax = 108,
	velocityMin = 1,
	velocityMax = 127,
	radiusStuds = 16,
	countdownSeconds = 2,
	instruments = {
		piano = { assetKey = "audio.instrument.piano" },
		guitar = { assetKey = "audio.instrument.guitar" },
		bass = { assetKey = "audio.instrument.bass" },
		violin = { assetKey = "audio.instrument.violin" },
		flute = { assetKey = "audio.instrument.flute" },
		clarinet = { assetKey = "audio.instrument.clarinet" },
		trumpet = { assetKey = "audio.instrument.trumpet" },
		drums = { assetKey = "audio.instrument.drums" },
	},
}
