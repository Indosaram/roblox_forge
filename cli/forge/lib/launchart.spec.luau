--!strict
-- Specs for launchart: creature/egg splitting, rarest-kaiju selection, canvas
-- sizes, and byte-stable rendering from the deterministic procgen meshes.

local launchart = require("./launchart")
local procgen = require("./procgen")

local DOC: any = {
	assets = {
		{
			key = "z-kaiju",
			kind = "creature",
			archetype = "quad",
			scale = 1,
			body = { 200, 100, 50 },
			accent = { 255, 220, 120 },
			eye = { 255, 255, 255 },
			seed = 11,
		},
		{
			key = "a-kaiju",
			kind = "creature",
			archetype = "quad",
			scale = 1.4,
			body = { 100, 50, 200 },
			accent = { 180, 140, 255 },
			eye = { 255, 255, 255 },
			seed = 12,
		},
		{
			key = "b-egg",
			kind = "prop",
			archetype = "egg",
			scale = 1,
			body = { 40, 120, 220 },
			accent = { 140, 230, 255 },
			eye = { 0, 0, 0 },
			seed = 13,
		},
		{
			key = "c-rock",
			kind = "prop",
			archetype = "rock",
			scale = 1,
			body = { 120, 120, 115 },
			accent = { 104, 150, 72 },
			eye = { 0, 0, 0 },
			seed = 14,
		},
	},
}

local function resolved(): { procgen.Resolved }
	local planned, errors = procgen.plan(DOC, {})
	assert(planned ~= nil and #errors == 0, "fixture must plan: " .. table.concat(errors, "; "))
	return planned :: { procgen.Resolved }
end

local function sameData(a: any, b: any): boolean
	if #a.data ~= #b.data then
		return false
	end
	for i = 1, #a.data do
		if a.data[i] ~= b.data[i] then
			return false
		end
	end
	return true
end

return {
	["split keeps creatures and eggs, sorted by key"] = function()
		local creatures, eggs = launchart.split(resolved())
		assert(#creatures == 2, "two creatures")
		assert(creatures[1].key == "a-kaiju" and creatures[2].key == "z-kaiju", "creatures sort by key")
		assert(#eggs == 1 and eggs[1].key == "b-egg", "only egg props become icons")
	end,

	["rarestKey picks the lowest hatch weight"] = function()
		local creatures = launchart.split(resolved())
		local econ: any = {
			eggs = {
				{ pool = { { id = "z-kaiju", weight = 90 }, { id = "a-kaiju", weight = 10 } } },
			},
			kaiju = {
				{ id = "z-kaiju", coinsPerSecond = 20 },
				{ id = "a-kaiju", coinsPerSecond = 1 },
			},
		}
		assert(launchart.rarestKey(econ, creatures) == "a-kaiju", "the lowest weight is the rarest")
	end,

	["rarestKey falls back to the first creature without pools"] = function()
		local creatures = launchart.split(resolved())
		assert(launchart.rarestKey(nil, creatures) == "a-kaiju", "sorted first creature is the fallback")
	end,

	["iconA is a deterministic 512 square"] = function()
		local creatures, eggs = launchart.split(resolved())
		local first = launchart.iconA(creatures, eggs, "a-kaiju")
		assert(first.width == 512 and first.height == 512, "icons are 512x512")
		local second = launchart.iconA(creatures, eggs, "a-kaiju")
		assert(sameData(first, second), "iconA repeats byte for byte")
	end,

	["thumbnail is a 1920x1080 lineup"] = function()
		local creatures = launchart.split(resolved())
		local canvas = launchart.thumbnail(creatures, "a")
		assert(canvas.width == 1920 and canvas.height == 1080, "thumbnails are 1920x1080")
		local painted = false
		for i = 4, #canvas.data, 4 do
			if canvas.data[i] > 0 then
				painted = true
				break
			end
		end
		assert(painted, "the thumbnail paints at least one pixel")
	end,

	["thumbnails read bright: mean luminance is at least 0.30"] = function()
		local function meanLuminance(canvas: any): number
			local data = canvas.data
			local total = 0
			local count = 0
			for i = 1, #data, 4 do
				if data[i + 3] > 0 then
					local r, g, b = data[i], data[i + 1], data[i + 2]
					total += 0.2126 * r + 0.7152 * g + 0.0722 * b
					count += 1
				end
			end
			if count == 0 then
				return 0
			end
			return total / count
		end

		local creatures = launchart.split(resolved())
		for _, variant in { "a", "b" } do
			local canvas = launchart.thumbnail(creatures, variant)
			local luminance = meanLuminance(canvas)
			assert(
				luminance >= 0.3,
				string.format("thumbnail %s mean luminance %.4f is below the 0.30 floor", variant, luminance)
			)
		end
	end,

	["iconB's background creature reads lit: mean luminance is at least 0.20"] = function()
		local function meanLuminance(canvas: any): number
			local data = canvas.data
			local total = 0
			local count = 0
			for i = 1, #data, 4 do
				if data[i + 3] > 0 then
					local r, g, b = data[i], data[i + 1], data[i + 2]
					total += 0.2126 * r + 0.7152 * g + 0.0722 * b
					count += 1
				end
			end
			if count == 0 then
				return 0
			end
			return total / count
		end

		local creatures = launchart.split(resolved())
		local rarest = launchart.rarestKey(nil, creatures)
		local art = launchart.iconBCreature(creatures, rarest)
		assert(art ~= nil, "icon B has a background creature to measure")
		local luminance = meanLuminance(art :: any)
		assert(
			luminance >= 0.2,
			string.format("icon-b creature mean luminance %.4f is below the 0.20 floor", luminance)
		)
	end,
}
