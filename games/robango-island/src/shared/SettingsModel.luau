--!strict
-- ui.settings model (engine-free): the persisted settings snapshot (audio, reduced effects,
-- language, text size), the per-channel gain a SoundBank group plays at, the rows the settings
-- sheet shows with their selected values, and the client-side text scale and effect reduction.
-- Labels are the set.* rows of locale/strings.csv (read through PackLocale).
local PackLocale = require("../../../../genres/survival-coop/module/PackLocale")
local M = {}

M.STEPS = { 0, 0.25, 0.5, 0.75, 1 }
-- SoundBank group -> settings channel. UI and ambient follow the effects channel.
M.CHANNEL = { Music = "music", SFX = "sfx", UI = "sfx", Ambient = "sfx", Ensemble = "ensemble" }
M.CHANNELS = { "volume", "music", "sfx", "ensemble" }
M.LANGUAGES = { "auto", "ko", "en" }
M.LOCALE = { ko = "ko-kr", en = "en-us" }
M.TEXT_SIZES = { "normal", "large" }
M.TEXT_SCALE = { normal = 1, large = 1.2 }
-- Decorative effect classes reduced effects turns off; Highlight telegraphs are never touched.
M.DECOR = { "Fire", "Smoke", "ParticleEmitter", "Sparkles" }
M.REDUCED_DENSITY = 0.1

function M.text(locale: string, key: string): string
	return PackLocale.get(locale, "set." .. key) or key
end

local function oneOf(list: { string }, value: any): string
	return if table.find(list, value) then value else list[1]
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
		language = oneOf(M.LANGUAGES, v.language),
		textSize = oneOf(M.TEXT_SIZES, v.textSize),
	}
end

--- The locale pack text uses: the saved language, else (auto) the player's LocaleId.
function M.locale(playerLocale: string, settings: any): string
	return M.LOCALE[M.normalize(settings).language] or playerLocale
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

--- The value a tap on row `key` selects next.
function M.next(settings: any, key: string): any
	local s = M.normalize(settings)
	if key == "muted" or key == "reducedEffects" then
		return not s[key]
	end
	local list = if key == "language" then M.LANGUAGES elseif key == "textSize" then M.TEXT_SIZES else nil
	if list then
		return list[(table.find(list, s[key]) :: number) % #list + 1]
	end
	return M.nextStep(s[key])
end

--- The audio-settings command args for `settings` with `key` changed to `value`.
function M.args(settings: any, key: string, value: any): { any }
	local s = table.clone(M.normalize(settings))
	s[key] = value
	return {
		s.muted,
		s.volume,
		{
			music = s.music,
			sfx = s.sfx,
			ensemble = s.ensemble,
			reducedEffects = s.reducedEffects,
			language = s.language,
			textSize = s.textSize,
		},
	}
end

--- Settings back from audio-settings command args.
function M.fromArgs(args: { any }): any
	local value = table.clone(args[3] or {})
	value.muted, value.volume = args[1], args[2]
	return M.normalize(value)
end

--- Sheet rows: { key, text } with the current value in every label (the selected state).
function M.rows(locale: string, settings: any): { { string } }
	local s = M.normalize(settings)
	local rows = { { "muted", M.text(locale, if s.muted then "unmute" else "mute") } }
	for _, key in M.CHANNELS do
		table.insert(rows, { key, M.text(locale, key) .. ": " .. tostring(math.floor(s[key] * 100 + 0.5)) .. "%" })
	end
	table.insert(rows, { "reducedEffects", M.text(locale, if s.reducedEffects then "reduced_on" else "reduced_off") })
	table.insert(rows, { "language", M.text(locale, "language") .. ": " .. M.text(locale, "lang_" .. s.language) })
	table.insert(rows, { "textSize", M.text(locale, "textSize") .. ": " .. M.text(locale, "text_" .. s.textSize) })
	return rows
end

--- Scales a text object (or its UITextSizeConstraint cap) from its first-seen authored size.
function M.scaleText(object: any, scale: number)
	local property = if object:IsA("UITextSizeConstraint")
		then "MaxTextSize"
		elseif object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then "TextSize"
		else nil
	if property then
		local base = object:GetAttribute("ForgeBaseTextSize")
		if base == nil then
			base = object[property]
			object:SetAttribute("ForgeBaseTextSize", base)
		end
		object[property] = math.floor(base * scale + 0.5)
	end
end

--- Turns decorative particles off and thins Atmosphere haze while `reduced`; restores the
--- authored values when it is cleared. Attack and hazard telegraphs (Highlight) are untouched.
function M.reduceEffect(object: any, reduced: boolean)
	local saved = object:GetAttribute("ForgeEffectSaved")
	if object:IsA("Atmosphere") then
		if reduced and saved == nil then
			object:SetAttribute("ForgeEffectSaved", object.Density)
			object:SetAttribute("ForgeEffectHaze", object.Haze)
			object.Density, object.Haze = math.min(object.Density, M.REDUCED_DENSITY), 0
		elseif not reduced and saved ~= nil then
			object.Density, object.Haze = saved, object:GetAttribute("ForgeEffectHaze")
			object:SetAttribute("ForgeEffectSaved", nil)
		end
		return
	end
	for _, class in M.DECOR do
		if object:IsA(class) then
			if reduced and saved == nil then
				object:SetAttribute("ForgeEffectSaved", object.Enabled)
				object.Enabled = false
			elseif not reduced and saved ~= nil then
				object.Enabled = saved
				object:SetAttribute("ForgeEffectSaved", nil)
			end
			return
		end
	end
end

return M
