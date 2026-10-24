--!strict
-- p68 real-input Studio defects: the invisible CameraTestRoof read as "no flat ground" for camp
-- cells, the 360x640 menu showed a sliver of the row holding the Music tile (taps fell through),
-- and the 360x640 placement bar covered the gather button by 8px.
local fs = require("@lune/fs")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local Panels = require("../../genres/survival-coop/module/ExtensionPanels")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")

local function overlaps(a: any, b: any): boolean
	return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

-- Menu ScreenGui uses CoreUISafeInsets: touch phones lose the 56px topbar.
local VIEWPORTS =
	{ { 360, 640, true }, { 390, 844, true }, { 640, 339, true }, { 740, 360, true }, { 1280, 720, false } }

return {
	["CameraTestRoof never collides but stays queryable for the camera fade"] = function()
		local engine = Engine.new()
		local workspace = engine.game:GetService("Workspace")
		engine.preview(Content, Source, nil, nil, "onboarding", true)
		local island = assert(workspace:FindFirstChild("DevelopmentIsland"), "island folder")
		local roof = assert(island:FindFirstChild("CameraTestRoof"), "camera-occlusion QA marker kept")
		assert(roof.Transparency == 1, "roof stays invisible")
		assert(roof.CanCollide == false, "roof must not be the support hit for camp cells")
		-- p74: GetPartsObscuringTarget only reports CanQuery parts, so the camera fade needs it.
		assert(roof.CanQuery == true, "camera occlusion query must see the roof")
		local world = fs.readFile("genres/survival-coop/module/SurvivalWorld.luau")
		local _, rays = string.gsub(world, "Vector3%.new%(0, %-64, 0%), solid%)", "")
		assert(rays == 2, "placement verify and structure support rays respect CanCollide: " .. rays)
	end,
	["menu frame shows whole tile rows so the last visible tile is tappable"] = function()
		local source = fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")
		assert(string.find(source, "mh = M.menuRows(mh, tileHeight)", 1, true), "dock trims the frame to rows")
		assert(string.find(source, "menuList.ScrollBarImageTransparency", 1, true), "visible scrollbar cue")
		for _, viewport in VIEWPORTS do
			local width, height, touch = viewport[1], viewport[2] - (if viewport[3] then 56 else 0), viewport[3]
			local at = width .. "x" .. height
			local x, y, w, h, columns, tile = Panels.menuRect(width, height, touch)
			x, y, w, h = Model.chatSafe(width, height, x, y, w, h)
			local shown = Panels.menuRows(h, tile)
			assert(shown <= h and shown >= tile + Panels.MENU_GAP, "one full row inside the frame at " .. at)
			assert(shown % (tile + Panels.MENU_GAP) == 0, "partial row visible at " .. at)
			for _, count in { 19, 24, 37 } do
				local canvas = Panels.menuCanvas(count, columns, tile)
				local scroll = math.max(0, canvas - shown)
				-- Every row is either fully in the frame or fully out of it, unscrolled and at max scroll.
				for _, offset in { 0, scroll } do
					for row = 0, math.ceil(count / columns) - 1 do
						local top = Panels.MENU_GAP + row * (tile + Panels.MENU_GAP) - offset
						local bottom = top + tile
						local partial = top < shown and bottom > shown
						assert(not partial, string.format("row %d cut at %s scroll %d", row, at, offset))
					end
				end
				local lastTop = Panels.MENU_GAP + (math.ceil(count / columns) - 1) * (tile + Panels.MENU_GAP) - scroll
				assert(lastTop >= 0 and lastTop + tile <= shown, "last row reachable at " .. at)
			end
		end
		-- The p68 case: 360x640 (584 below the inset) had a 238px frame = 3 rows + a 28px sliver.
		local _, _, _, h, _, tile = Panels.menuRect(360, 584, true)
		assert(h == 238 and Panels.menuRows(h, tile) == 210, "360x640 menu trims the sliver")
	end,
	["360x640 gather button is hidden while the placement bar covers it"] = function()
		local width, height = 360, 640 - 56
		local bar = { x = width / 2 - 164, y = height - Model.PLACEMENT_BOTTOM, width = 328, height = 48 }
		-- GatheringClient: 132x48 at (0.5,-66, 1,-112).
		local gather = { x = width / 2 - 66, y = height - 112, width = 132, height = 48 }
		local hud = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		local client = fs.readFile("genres/survival-coop/module/GatheringClient.luau")
		assert(string.find(client, "UDim2.fromOffset(132, 48), UDim2.new(0.5, -66, 1, -112)", 1, true), "gather rect")
		if overlaps(bar, gather) then
			assert(
				string.find(hud, "gatherGui.Enabled = not modal and not placementBar.Visible", 1, true),
				"placement bar overlaps the gather button, so the HUD must hide it while placing"
			)
		end
	end,
}
