--!strict
-- Audio: the grow-harvest genre's declared cue set and the actions each cue is
-- bound to, in the runtime form a pack can require.
--
-- The declaration lives in `genres/grow-harvest/genre-spec.yml` under `audio:`
-- (cues + bindings). `forge check`'s genre-contract stage asserts this module
-- equals that section, so the two can never drift.
--
-- A generated pack reads the declaration from the serialized spec
-- (`src/shared/GenreSpec.luau`). A pack whose client owns its own transport — a
-- hand-written game pack, which ships no spec module — reads it from here
-- through the genre package the pack already mounts, and hands it to
-- `core/ui-kit/genre/AudioKit`, which resolves the cue for a committed action.
-- Either way the pack declares no cue mapping of its own.

export type Cue = {
	key: string,
	kind: string,
	type: string?,
	mood: string?,
	duration: number,
	sampleRate: number?,
	seed: number,
}

export type Binding = {
	on: string,
	cue: string,
	dedupe: number?,
	field: string?,
	["local"]: boolean?,
}

export type Audio = { cues: { Cue }, bindings: { Binding } }

local audio: Audio = {
	cues = {
		{ key = "grow-harvest-buy", kind = "sfx", type = "coin", duration = 0.2, seed = 0 },
		{ key = "grow-harvest-plant", kind = "sfx", type = "click", duration = 0.15, seed = 1 },
		{ key = "grow-harvest-harvest", kind = "sfx", type = "coin", duration = 0.25, seed = 2 },
		{ key = "grow-harvest-sell", kind = "sfx", type = "coin", duration = 0.3, seed = 3 },
	},
	bindings = {
		{ on = "action:grow-harvest:buy-seed", cue = "grow-harvest-buy" },
		{ on = "action:grow-harvest:plant", cue = "grow-harvest-plant" },
		{ on = "action:grow-harvest:harvest", cue = "grow-harvest-harvest" },
		{ on = "action:grow-harvest:sell-held", cue = "grow-harvest-sell" },
		-- The state-diff bindings a generated pack's snapshots drive. A pack that
		-- reports only its committed actions never feeds a revision packet, so these
		-- fire nothing for it — the same declaration serves both shapes.
		{ on = "event:OnPlant", cue = "grow-harvest-plant", field = "plots" },
		{ on = "event:OnHarvest", cue = "grow-harvest-harvest", field = "inventory" },
		{ on = "event:CropSold", cue = "grow-harvest-sell", field = "balance" },
	},
}

return audio
