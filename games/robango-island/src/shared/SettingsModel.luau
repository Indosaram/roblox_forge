--!strict
-- ui.settings model (engine-free): the persisted audio-settings snapshot, the per-channel gain a
-- SoundBank group plays at, and the rows the settings sheet shows with their selected values.
local M = {}

M.STEPS = { 0, 0.25, 0.5, 0.75, 1 }
-- SoundBank group -> settings channel. UI and ambient follow the effects channel.
M.CHANNEL = { Music = "music", SFX = "sfx", UI = "sfx", Ambient = "sfx", Ensemble = "ensemble" }
M.CHANNELS = { "volume", "music", "sfx", "ensemble" }

local LABELS: { [string]: { string } } = {
	volume = { "Master volume", "전체 음량" },
	music = { "Music", "음악" },
	sfx = { "Sound effects", "효과음" },
	ensemble = { "Ensemble", "합주" },
	mute = { "Sound: on", "소리: 켜짐" },
	unmute = { "Sound: muted", "소리: 꺼짐" },
	reduced_on = { "Reduced effects: on", "효과 줄이기: 켜짐" },
	reduced_off = { "Reduced effects: off", "효과 줄이기: 꺼짐" },
}

function M.text(locale: string, key: string): string
	local row = LABELS[key]
	return if row then row[if string.sub(locale, 1, 2) == "ko" then 2 else 1] else key
end

--- Normalized settings from the server snapshot (older saves have only muted/volume).
function M.normalize(value: any): any
	local v = if type(value) == "table" then value else {}
	local function gain(x: any): number
		return if type(x) == "number" then math.clamp(x, 0, 1) else 1
	end
	return {
		muted = v.muted == true,
		volume = gain(v.volume),
		music = gain(v.music),
		sfx = gain(v.sfx),
		ensemble = gain(v.ensemble),
		reducedEffects = v.reducedEffects == true,
	}
end

--- Gain a SoundBank group plays at: authored group gain x master x its channel.
function M.groupGain(base: number, settings: any, group: string): number
	local s = M.normalize(settings)
	local channel = M.CHANNEL[group]
	return base * s.volume * (if channel then s[channel] else 1)
end

--- The next step after `value` (wraps 100% -> 0%).
function M.nextStep(value: number): number
	for _, step in M.STEPS do
		if step > value + 1e-6 then
			return step
		end
	end
	return M.STEPS[1]
end

--- The audio-settings command args for `settings` with `key` changed to `value`.
function M.args(settings: any, key: string, value: any): { any }
	local s = table.clone(M.normalize(settings))
	s[key] = value
	return {
		s.muted,
		s.volume,
		{ music = s.music, sfx = s.sfx, ensemble = s.ensemble, reducedEffects = s.reducedEffects },
	}
end

--- Sheet rows: { key, text } with the current value in every label (the selected state).
function M.rows(locale: string, settings: any): { { string } }
	local s = M.normalize(settings)
	local rows = { { "muted", M.text(locale, if s.muted then "unmute" else "mute") } }
	for _, key in M.CHANNELS do
		table.insert(rows, { key, M.text(locale, key) .. ": " .. tostring(math.floor(s[key] * 100 + 0.5)) .. "%" })
	end
	table.insert(rows, { "reducedEffects", M.text(locale, if s.reducedEffects then "reduced_on" else "reduced_off") })
	return rows
end

return M
