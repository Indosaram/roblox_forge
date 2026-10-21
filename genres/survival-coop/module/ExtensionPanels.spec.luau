--!strict
local Panels = require("./ExtensionPanels")
local Model = require("./SurvivalHUDModel")

local function overlaps(a: any, b: any): boolean
	return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

return {
	["context menu tiles and HUD clear topbar and mobile control zones at target viewports"] = function()
		for _, size in { { 360, 640 }, { 640, 360 }, { 1280, 720 }, { 1920, 1080 } } do
			-- ScreenGui consumes the topbar inset; model coordinates are in the remaining safe area.
			local width, height = size[1], size[2] - 56
			local menuWidth, columns, tileHeight, top = Panels.menuBounds(width, height)
			local menu = {
				x = (width - menuWidth) / 2,
				y = top,
				width = menuWidth,
				height = math.ceil(19 / columns) * (tileHeight + 6) - 6,
			}
			local stick = { x = 0, y = height - 128, width = 128, height = 128 }
			local jump = { x = width - 128, y = height - 128, width = 128, height = 128 }
			assert(menuWidth <= 720 and menu.x >= 0 and menu.y >= 0, "centered menu respects safe area")
			assert(menu.y + menu.height <= height - 128, "all tiles fit above movement controls without scrolling")
			assert(not overlaps(menu, stick) and not overlaps(menu, jump), "menu clears movement zones")
			local hud = Model.contextHudBounds(width, height)
			assert(
				not overlaps(hud.vitals, hud.objective) and not overlaps(hud.vitals, hud.menu),
				"HUD cards remain separate"
			)
			for _, rect in hud do
				assert(rect.y >= 0 and rect.x >= 0 and rect.x + rect.width <= width, "HUD within topbar safe area")
				assert(not overlaps(rect, stick) and not overlaps(rect, jump), "HUD clears joystick and jump")
			end
			-- Opening any sheet/photo mode hides vitals/objective; they are mutually exclusive surfaces.
			assert(hud.photo.y + hud.photo.height <= height - 128, "photo controls fit above movement zones")
		end
	end,
}
