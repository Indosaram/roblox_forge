--!strict
-- G18 day-night and weather: the cycle is a pure function of injected server seconds, night is
-- a strong but readable blue, fires strengthen at night, and weather is bound to content climates
-- and the recorded seed.
local Content = require("./src/shared/SurvivalContent")
local SkyCycle = require("./src/shared/SkyCycle")
local DayNight, Weather = SkyCycle, SkyCycle
local Volcano = require("../../core/domain/survival/Volcano")

local FOG = { 192, 215, 205 }

local function layoutWith(predicate: (any) -> boolean): any
	for _, layout in Content.layouts do
		if predicate(layout) then
			return layout
		end
	end
	error("no matching layout")
end

local function luminance(c: { number }): number
	return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3]
end

return {
	["a full cycle is 24 real minutes and depends only on the injected clock"] = function()
		assert(DayNight.DAY_SECONDS == 1440, "24-minute day")
		assert(DayNight.clockTime(1000, 1000) == 0, "origin is midnight")
		assert(DayNight.clockTime(1000 + 720, 1000) == 12, "half a cycle is noon")
		assert(DayNight.clockTime(1000 + 60, 1000) == 1, "one real minute is one game hour")
		assert(DayNight.clockTime(1000 + 1440 * 7 + 360, 1000) == 6, "cycle wraps")
		local a = DayNight.state(5000, 100, FOG)
		local b = DayNight.state(5000, 100, FOG)
		assert(a.clockTime == b.clockTime and a.brightness == b.brightness, "same input, same state")
	end,
	["day grade is warm and slightly desaturated"] = function()
		local noon = DayNight.at(12, FOG)
		assert(noon.daylight == 1, "full daylight at noon")
		local tint = noon.grade.tint
		assert(tint[1] > tint[3] and tint[2] > tint[3], "warm tint at noon")
		assert(noon.grade.saturation < 0 and noon.grade.saturation >= -0.2, "slightly desaturated")
		assert(noon.starCount == 0 and noon.sunRays > 0, "no stars by day")
	end,
	["night grade is strong cool blue but readable"] = function()
		local night = DayNight.at(0, FOG)
		assert(night.daylight == 0, "full night at midnight")
		for _, c in { night.grade.tint, night.ambient, night.outdoorAmbient, night.atmosphere.color } do
			assert(c[3] > c[1] + 30 and c[3] > c[2], "blue dominates the night")
		end
		assert(luminance(night.outdoorAmbient) >= 80, "outdoor ambient keeps the night readable")
		assert(night.brightness >= 1 and night.exposure > 0, "night stays lit")
		assert(night.starCount > 0, "stars at night")
	end,
	["dawn and dusk blend smoothly and fires burn brighter at night"] = function()
		local previous = DayNight.at(4, FOG).daylight
		for step = 1, 30 do
			local hours = 4 + step * 0.1
			local d = DayNight.at(hours, FOG).daylight
			assert(d >= previous and d - previous < 0.2, "monotonic smooth dawn at " .. hours)
			previous = d
		end
		local day, night = DayNight.at(12, FOG), DayNight.at(0, FOG)
		assert(night.fire.brightness > day.fire.brightness * 2, "fire stronger at night")
		assert(night.fire.range > day.fire.range, "fire reaches further at night")
		assert(DayNight.at(17.5, FOG).golden > 0.5, "golden hour at sunset")
	end,
	["volcano layouts follow the content storm timeline with ash"] = function()
		local layout = layoutWith(function(l)
			return table.find(l.biomes, "volcano") ~= nil
		end)
		local policy = Content.progressionPolicy.volcano
		assert(Weather.climate(Content, layout) == "volcano", "volcano climate")
		for _, t in { 0, 299, 300, 419, 420, 1000 } do
			local visual = Weather.weatherAt(Content, layout, 7, t, 0, nil)
			local stormy = Volcano.storm(t, 0, policy)
			assert((visual.id == "ash") == stormy, "ash exactly during storm at " .. t)
			assert(visual.ash > 0 and visual.rain == 0, "volcanic ash, never rain")
		end
	end,
	["brawl weather follows the match timeline"] = function()
		local layout = layoutWith(function(l)
			return l.id == Content.brawlPolicy.layout
		end)
		local brawl = { startsAt = 100, policy = Content.brawlPolicy }
		assert(Weather.weatherAt(Content, layout, 7, 50, 0, nil).id == "clear", "no match: clear")
		for _, entry in Content.brawlPolicy.weather do
			assert(Weather.weatherAt(Content, layout, 7, 100 + entry.at, 0, brawl).id == entry.id, entry.id)
		end
		assert(Weather.weatherAt(Content, layout, 7, 100 + 130, 0, brawl).rain > 0, "rain falls")
		assert(Weather.weatherAt(Content, layout, 7, 100 + 250, 0, brawl).fogDensity > 0.2, "fog thickens")
	end,
	["seeded weather is deterministic per recorded seed and window and uses the biome climate"] = function()
		local layout = layoutWith(function(l)
			return Weather.climate(Content, l) == "seeded" and l.biomes[1] == "grassland"
		end)
		local seen, differs = {}, false
		for window = 0, 63 do
			local a = Weather.seeded(layout, 1776, window)
			assert(a == Weather.seeded(layout, 1776, window), "same seed, same weather")
			differs = differs or a ~= Weather.seeded(layout, 1777, window)
			seen[a] = true
		end
		assert(differs, "a different seed changes the sequence")
		assert(seen.clear and seen.rain, "grassland climate shows clear and rain")
		assert(not seen.ash and not seen.storm, "grassland never shows ash or storm")
		local t = Weather.WINDOW_SECONDS * 3 + 5
		assert(
			Weather.weatherAt(Content, layout, 1776, t, 0, nil).id == Weather.seeded(layout, 1776, 3),
			"window index"
		)
		assert(Weather.origin(layout.id, 1776, 10000) == Weather.origin(layout.id, 1776, 10000), "origin seeded")
	end,
	["phones emit fewer weather particles"] = function()
		assert(Weather.particleScale("low") < 0.5 and Weather.particleScale("high") == 1, "low profile scale")
	end,
}
