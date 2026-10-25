--!strict
-- EN / KO strings and refusal copy for the farming and crafting screens
-- (farm plot, sprayer, crop book, specialization, processing, recipe preview, inbox).
local HudLocale = require("./SurvivalHUDLocale")
local PackLocale = require("./PackLocale")
local M = {}
M.strings = PackLocale.rows({}, { "fct." })

local function pick(locale: string, key: string): string?
	local row = M.strings[key]
	return if row then row[if string.sub(locale, 1, 2) == "ko" then 2 else 1] else nil
end

function M.text(locale: string, key: string, ...: any): string
	local value = pick(locale, key) or HudLocale.text(locale, key)
	return if select("#", ...) > 0 then string.format(value, ...) else value
end

function M.refusal(locale: string, reason: string?): string
	local key = tostring(reason)
	return pick(locale, key) or HudLocale.refusal(locale, key)
end

-- Seconds as m:ss for growth timers.
function M.clock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

return M
