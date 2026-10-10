--!strict
-- Specs for Icons: output size, non-empty alpha for every painter, determinism,
-- and size validation.

local Icons = require("./Icons")

local SPEC: Icons.Spec = {
	body = { 235, 110, 40 },
	accent = { 255, 200, 60 },
	eye = { 255, 255, 180 },
	seed = 101,
}

local function assertNonEmpty(canvas: any, label: string): ()
	local painted = false
	for i = 4, #canvas.data, 4 do
		if canvas.data[i] > 0 then
			painted = true
			break
		end
	end
	assert(painted, label .. " must paint at least one pixel")
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
	["egg icon matches the requested size and draws pixels"] = function()
		local canvas = Icons.egg(SPEC, 64)
		assert(canvas.width == 64 and canvas.height == 64, "egg icon is square")
		assertNonEmpty(canvas, "egg icon")
	end,

	["creature icon matches the requested size and draws pixels"] = function()
		local canvas = Icons.creature(SPEC, 64)
		assert(canvas.width == 64 and canvas.height == 64, "creature icon is square")
		assertNonEmpty(canvas, "creature icon")
	end,

	["coin icon matches the requested size and draws pixels"] = function()
		local canvas = Icons.coin(48)
		assert(canvas.width == 48 and canvas.height == 48, "coin icon is square")
		assertNonEmpty(canvas, "coin icon")
	end,

	["rarityBadge draws pixels for known and unknown rarities"] = function()
		for _, rarity in { "Common", "Legendary", "mystery" } do
			local canvas = Icons.rarityBadge(rarity, 40)
			assert(canvas.width == 40 and canvas.height == 40, rarity .. " badge is square")
			assertNonEmpty(canvas, rarity .. " badge")
		end
	end,

	["icons are deterministic for the same spec"] = function()
		assert(sameData(Icons.egg(SPEC, 48), Icons.egg(SPEC, 48)), "egg icons repeat")
		assert(sameData(Icons.creature(SPEC, 48), Icons.creature(SPEC, 48)), "creature icons repeat")
	end,

	["0..1 color tables are accepted like 0..255 arrays"] = function()
		local tableSpec: Icons.Spec = {
			body = { r = 235 / 255, g = 110 / 255, b = 40 / 255 },
			accent = { r = 1, g = 200 / 255, b = 60 / 255 },
			eye = { r = 1, g = 1, b = 180 / 255 },
			seed = 101,
		}
		assert(sameData(Icons.egg(SPEC, 48), Icons.egg(tableSpec, 48)), "both color forms agree")
	end,

	["invalid size is rejected"] = function()
		assert(not pcall(Icons.egg, SPEC, 0), "zero size rejected")
		assert(not pcall(Icons.coin, -4), "negative size rejected")
	end,

	["every glyph kind paints a deterministic square icon"] = function()
		local kinds = Icons.kinds()
		assert(#kinds >= 15, "the HUD glyph set is populated")
		for _, kind in kinds do
			local canvas = Icons.glyph(kind, 64)
			assert(canvas ~= nil, kind .. " glyph exists")
			local drawn = canvas :: any
			assert(drawn.width == 64 and drawn.height == 64, kind .. " glyph is square")
			assertNonEmpty(drawn, kind .. " glyph")
			assert(sameData(Icons.glyph(kind, 64), Icons.glyph(kind, 64)), kind .. " glyph repeats")
		end
	end,

	["glyphs render at 64 and 128px"] = function()
		for _, kind in Icons.kinds() do
			for _, px in { 64, 128 } do
				local canvas = Icons.glyph(kind, px)
				assert(canvas ~= nil and (canvas :: any).width == px, kind .. " renders at " .. px)
			end
		end
	end,

	["unknown glyph returns nil"] = function()
		assert(Icons.glyph("no_such_kind", 64) == nil, "unknown glyph is nil")
	end,
}
