--!strict
-- p35 portrait: the contextual menu tile grid must stay inside the viewport and inside the
-- visible part of its ScrollingFrame (left of the 6px scrollbar) at portrait 360x620, short
-- landscape 640x339 and desktop 1280x720. Studio p34 showed the right tile column cut off at
-- 360 wide: 4 x 79px tiles + gaps filled the full 336px frame, under the scrollbar.
local fs = require("@lune/fs")
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local Panels = require("../../genres/survival-coop/module/ExtensionPanels")

-- { width, height, touch }: the Studio portrait viewport, the short-landscape device
-- simulator and PC.
local VIEWPORTS = { { 360, 620, true }, { 640, 339, true }, { 1280, 720, false } }
-- More launchers than robango registers (19 at p34), so every column is filled.
local TILES = 24

-- Tile rects in viewport space, laid out the way UIGridLayout fills the menu canvas.
local function menuTiles(width: number, height: number, touch: boolean): (any, { any })
	local x, y, w, h, columns, tile = Panels.menuRect(width, height, touch)
	x, y, w, h = Model.chatSafe(width, height, x, y, w, h)
	local cell = Panels.menuCell(w, columns)
	local tiles = {}
	for index = 0, TILES - 1 do
		local column, row = index % columns, index // columns
		table.insert(tiles, {
			x = x + column * (cell + Panels.MENU_GAP),
			y = y + row * (tile + Panels.MENU_GAP),
			width = cell,
			height = tile,
		})
	end
	return { x = x, y = y, width = w, height = h, columns = columns, cell = cell }, tiles
end

return {
	["menu tiles stay inside the viewport and left of the scrollbar at every target viewport"] = function()
		local source = fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")
		assert(
			string.find(
				source,
				"menuLayout.CellSize = UDim2.fromOffset(M.menuCell(menuWidth, columns), tileHeight)",
				1,
				true
			),
			"dock sizes menu cells with menuCell"
		)
		assert(
			string.find(source, "menuList.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar", 1, true),
			"menu canvas stops left of the scrollbar"
		)
		assert(
			string.find(source, "menuList.ScrollBarThickness = " .. Panels.MENU_SCROLLBAR, 1, true),
			"scrollbar width"
		)
		for _, viewport in VIEWPORTS do
			local width, height, touch = viewport[1], viewport[2], viewport[3]
			local at = width .. "x" .. height
			local frame, tiles = menuTiles(width, height, touch)
			assert(frame.x >= 0 and frame.x + frame.width <= width, "menu frame inside viewport at " .. at)
			assert(frame.cell >= Panels.MENU_MIN_TILE, "menu tile under 44px at " .. at)
			local visibleRight = frame.x + frame.width - Panels.MENU_SCROLLBAR
			for index, rect in tiles do
				local label = string.format("tile %d (%d..%d) at %s", index, rect.x, rect.x + rect.width, at)
				assert(rect.x >= 0 and rect.x + rect.width <= width, label .. " exceeds the viewport")
				assert(rect.x >= frame.x and rect.x + rect.width <= visibleRight, label .. " under the scrollbar")
				-- Rows inside the scroll viewport (unscrolled) are fully on screen too.
				if rect.y + rect.height <= frame.y + frame.height then
					assert(rect.y >= 0 and rect.y + rect.height <= height, label .. " below the viewport")
				end
			end
			assert(tiles[1].y + tiles[1].height <= frame.y + frame.height, "first row fully visible at " .. at)
		end
	end,
	["menu keeps its design column count where it fits"] = function()
		-- Portrait 4, short landscape capped by the thumb gutters, desktop 6.
		local expected = { ["360x620"] = 4, ["640x339"] = 8, ["1280x720"] = 6 }
		for _, viewport in VIEWPORTS do
			local frame = menuTiles(viewport[1], viewport[2], viewport[3])
			local at = viewport[1] .. "x" .. viewport[2]
			assert(frame.columns == expected[at], at .. " columns " .. frame.columns)
		end
		-- A narrower phone drops columns instead of shrinking tiles under 44px.
		local frame = menuTiles(200, 560, true)
		assert(frame.cell >= Panels.MENU_MIN_TILE and frame.columns < 4, "200 wide drops a column")
	end,
}
