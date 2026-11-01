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

local function saturation(c: { number }): number
	local high, low = math.max(c[1], c[2], c[3]), math.min(c[1], c[2], c[3])
	return if high <= 0 then 0 else (high - low) / high
end

-- HSV hue in degrees (0..360).
local function hue(c: { number }): number
	local r, g, b = c[1], c[2], c[3]
	local high, low = math.max(r, g, b), math.min(r, g, b)
	if high == low then
		return 0
	end
	local d = high - low
	local h = if high == r then ((g - b) / d) % 6 elseif high == g then (b - r) / d + 2 else (r - g) / d + 4
	return h * 60
end

-- First-order estimate of a lit surface on screen from the pure lighting state: outdoor ambient
-- plus sky light (scaled by daylight), exposure, the grade tint and saturation. Studio captures
-- (p134/lane150) showed the night sea follows Terrain.WaterColor, not its reflectance, so water
-- is estimated as a lit surface of `state.water`. Thresholds were confirmed on those captures.
local GRASS = { 86, 110, 60 }
-- `fire` adds the cycle's fire PointLight colour (SkyCycle.applyFire) at `share` of its strength
-- (default half: the pool at half its range under a roughly linear falloff).
local function onScreen(state: any, albedo: { number }, fire: boolean?, share: number?): { number }
	local d = state.daylight
	local k = state.brightness * (d + (1 - d) * 0.25) * 0.6
	local e = 2 ^ state.exposure
	local out = {}
	for i = 1, 3 do
		local light = state.outdoorAmbient[i] / 255 + k * state.colorShiftTop[i] / 255
		if fire then
			light += state.fire.color[i] / 255 * state.fire.brightness * (share or 0.5)
		end
		out[i] = albedo[i] * light * e * state.grade.tint[i] / 255
	end
	local y = luminance(out)
	for i = 1, 3 do
		out[i] = math.clamp(y + (out[i] - y) * (1 + state.grade.saturation) + state.grade.brightness * 255, 0, 255)
	end
	return out
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
	["night is bright cool blue-grey moonlight with a warm fire pool and a slate sea"] = function()
		local day, night = DayNight.at(12, FOG), DayNight.at(0, FOG)
		local dayLand, nightLand = onScreen(day, GRASS), onScreen(night, GRASS)
		local nightSea = onScreen(night, night.water)
		local pool = onScreen(night, GRASS, true)
		assert(luminance(nightLand) >= 0.55 * luminance(dayLand), "night land luminance >= 55% of day")
		assert(nightLand[3] >= nightLand[1] + 15, "night grass is blue-grey: B exceeds R by >= 15")
		assert(saturation(nightSea) <= saturation(nightLand) + 0.15, "night sea saturation <= land + 0.15")
		assert(luminance(pool) >= 1.3 * luminance(nightLand), "fire pool >= 1.3x night land luminance")
		assert(saturation(night.water) <= 0.4, "night water colour is warm grey, not royal blue")
		assert(day.water[1] == 69 and day.water[2] == 139 and day.water[3] == 153, "day water keeps its colour")
		for hours = 0, 23.5, 0.5 do
			local state = DayNight.at(hours, FOG)
			local land = onScreen(state, GRASS)
			assert(luminance(land) >= 0.55 * luminance(dayLand), "readable at " .. hours)
		end
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
		-- R17 lane: a tighter pool at night (D2c: 24-stud night fires washed the camp white).
		assert(night.fire.range <= day.fire.range, "night fire pool no wider than by day")
		assert(DayNight.at(17.5, FOG).golden > 0.5, "golden hour at sunset")
	end,
	["night grade turns grass and sand moon blue-grey, not daytime green (D2b R17)"] = function()
		local night = DayNight.at(1, FOG)
		local grass, sand = onScreen(night, GRASS), onScreen(night, { 180, 170, 140 })
		-- D2b captured explore10 grass at 01:00 as green (G - B = 27 on screen): the grade must pull
		-- green to grey-blue on every role, since grass covers every island.
		assert(grass[3] > grass[1] and grass[3] > grass[2], "night grass reads moon blue, not green")
		assert(grass[2] - grass[3] <= 10, "night grass is not green: G - B = " .. grass[2] - grass[3])
		-- Night2 (v64 phone, Studio 01:00): a -0.6 grade bleached the camp fire pool pink-white; the
		-- grade only trims saturation now, so the fire pool keeps its warm hue on screen.
		assert(night.grade.saturation < 0 and night.grade.saturation >= -0.3, "night grade trims, not bleaches")
		local pool = onScreen(night, GRASS, true)
		assert(pool[1] - pool[3] > grass[1] - grass[3] + 20, "the fire pool reads warmer than the moonlit grass")
		assert(sand[3] >= sand[1], "night sand reads moon blue")
		assert(night.exposure >= 1.25, "town night lifted: exposure " .. night.exposure)
	end,
	["R17 night lane: deep moon-blue light, small saturated warm fire pools, near-zero bloom"] = function()
		-- Studio 01:00 (night lane, onboarding camp + town, 800x360 and 1280x720): the old grade
		-- (grey-white tint, ambient lum ~150, bloom 0.3, 24-stud fires) turned the camp white and the
		-- town grey-green. The tuned night carries its blue in the light itself.
		local night = DayNight.at(1, FOG)
		for _, c in { night.ambient, night.outdoorAmbient, night.colorShiftTop } do
			assert(c[3] >= 150 and c[3] >= c[1] + 85, "moon-blue light: " .. table.concat(c, ","))
		end
		assert(
			luminance(night.outdoorAmbient) >= 70,
			"not black: outdoor ambient lum " .. luminance(night.outdoorAmbient)
		)
		assert(luminance(night.outdoorAmbient) <= 130, "deep, not a grey wash: " .. luminance(night.outdoorAmbient))
		local tint = night.grade.tint
		assert(tint[3] - tint[1] <= 72, "a light grade tint (the light carries the blue, not a heavy filter)")
		assert(night.bloom <= 0.1, "bloom nearly off at night: " .. night.bloom)
		assert(night.fire.range <= 12, "fire pools stay local: range " .. night.fire.range)
		assert(night.fire.brightness >= 2, "fires still read at night")
		local fire = assert(night.fire.color, "night fire colour")
		assert(fire[1] == 255 and fire[3] <= 60 and saturation(fire) >= 0.75, "saturated orange fire at night")
		local dayFire = assert(DayNight.at(12, FOG).fire.color, "day fire colour")
		assert(saturation(dayFire) < saturation(fire), "day fire is the softer lamp colour")
	end,
	["night2: camp sand dims at night and the night exposure no longer clips the camp"] = function()
		-- Studio bisection (all lights off): the pale lilac-white camp disc was terrain Sand under +1.8
		-- exposure. Sand dims with the cycle; the exposure stays under the clipping level.
		local day, night = DayNight.at(12, FOG), DayNight.at(1, FOG)
		assert(night.exposure < 1.8, "night exposure under the camp clip: " .. night.exposure)
		for i = 1, 3 do
			assert(day.sand[i] == SkyCycle.SAND[i], "day sand keeps its colour")
		end
		assert(luminance(night.sand) <= 0.7 * luminance(day.sand), "night sand dims")
		local previous = DayNight.at(16, FOG).sand
		for step = 1, 40 do
			local sand = DayNight.at(16 + step * 0.1, FOG).sand
			for i = 1, 3 do
				assert(math.abs(sand[i] - previous[i]) <= 6, "sand colour jumps")
			end
			previous = sand
		end
	end,
	["dusk and dawn blend every lit value with no jump"] = function()
		local fields = { "exposure", "brightness", "bloom" }
		for _, span in { { 4, 8 }, { 16, 20 } } do
			local previous = DayNight.at(span[1], FOG)
			for step = 1, 40 do
				local state = DayNight.at(span[1] + step * 0.1, FOG)
				for _, key in fields do
					assert(math.abs(state[key] - previous[key]) <= 0.2, key .. " jumps at " .. state.clockTime)
				end
				for _, key in { "outdoorAmbient", "ambient" } do
					for i = 1, 3 do
						assert(math.abs(state[key][i] - previous[key][i]) <= 24, key .. " jumps at " .. state.clockTime)
					end
				end
				local a, b = assert(state.fire.color, "fire colour"), assert(previous.fire.color, "fire colour")
				for i = 1, 3 do
					assert(math.abs(a[i] - b[i]) <= 12, "fire colour jumps at " .. state.clockTime)
				end
				assert(math.abs(state.fire.range - previous.fire.range) <= 1, "fire range jumps")
				previous = state
			end
		end
	end,
	["night3: blue-teal moonlight and orange fire, never a purple or magenta cast"] = function()
		-- v66 phone (lead review ~3.5/5): night ambients at hue ~235 / saturation ~0.77 read purple
		-- and the camp fire pool mixed to magenta on sand. Durango's night (R17-1) is a desaturated
		-- blue-teal; the fire is orange. A hue drift toward violet or a pink fire fails here.
		local night = DayNight.at(1, FOG)
		local lights = {
			ambient = night.ambient,
			outdoorAmbient = night.outdoorAmbient,
			colorShiftTop = night.colorShiftTop,
			tint = night.grade.tint,
			fog = night.atmosphere.color,
		}
		for name, c in lights do
			local h = hue(c)
			assert(h >= 195 and h <= 230, string.format("night %s hue %.1f outside [195,230]", name, h))
			assert(saturation(c) <= 0.65, string.format("night %s saturation %.2f > 0.65", name, saturation(c)))
		end
		assert(saturation(night.grade.tint) <= 0.25, "night grade tint stays a light filter")
		for _, at in { 0, 1, 3, 22 } do
			local fire = DayNight.at(at, FOG).fire.color
			local h = hue(fire)
			assert(h >= 20 and h <= 40, string.format("fire hue %.1f outside [20,40] at %d", h, at))
		end
		-- The pool's falloff from rim to core on grass, dirt, camp sand and wood: no step may read
		-- violet/magenta (hue 250..345) with visible colour.
		local sand = { 180 * SkyCycle.SAND_NIGHT, 170 * SkyCycle.SAND_NIGHT, 140 * SkyCycle.SAND_NIGHT }
		for _, albedo in { GRASS, sand, { 112, 100, 66 }, { 96, 66, 40 } } do
			for step = 0, 20 do
				local c = onScreen(night, albedo, true, step / 20)
				local h, s = hue(c), saturation(c)
				assert(
					s <= 0.08 or h < 250 or h > 345,
					string.format("magenta pool at share %.2f: %.0f,%.0f,%.0f", step / 20, c[1], c[2], c[3])
				)
			end
		end
		-- Readability no worse than night2 (grass lum 116, camp sand lum 129 on screen).
		assert(luminance(onScreen(night, GRASS)) >= 116, "night grass stays readable")
		assert(luminance(onScreen(night, sand)) >= 129, "night camp sand stays readable")
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
