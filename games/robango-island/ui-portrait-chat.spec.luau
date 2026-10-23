--!strict
-- p47: the p46 Studio 360x640 portrait failures, driven through the real layout functions.
-- The menu grid overlapped the 메뉴 button and clipped its first category header, Roblox's
-- chat window (log 0,5 140x145, bar at 12,167) covered the 메뉴 button, the vitals labels
-- were 10px, and the grid's top rows sat under the chat (wheel-up never reached them).
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local Panels = require("../../genres/survival-coop/module/ExtensionPanels")
local Locale = require("../../genres/survival-coop/module/SurvivalHUDLocale")
local HudFit = require("../../core/ui-kit/genre/HudFit")
local Editor = require("../../genres/survival-coop/module/ScoreEditorPanel")
local Rules = require("../../core/domain/music/TestCatalog")

-- { width, height, touch }: portrait phones, short landscape phone, PC.
local VIEWPORTS = { { 360, 640, true }, { 390, 844, true }, { 640, 339, true }, { 1280, 720, false } }
-- The p46 chat measurements (log and bar) as one rect.
local CHAT = { x = 0, y = 0, width = 152, height = 207 }
local HEADER = 16

local function overlaps(a: any, b: any): boolean
	return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

local function inside(rect: any, width: number, height: number, label: string)
	assert(
		rect.x >= 0 and rect.y >= 0 and rect.x + rect.width <= width and rect.y + rect.height <= height,
		string.format("%s (%d,%d %dx%d) outside %dx%d", label, rect.x, rect.y, rect.width, rect.height, width, height)
	)
end

local function grid(width: number, height: number, touch: boolean): any
	local x, y, w, h, columns, tile = Panels.menuRect(width, height, touch)
	x, y, w, h = Model.chatSafe(width, height, x, y, w, h)
	return { x = x, y = y, width = w, height = h, columns = columns, tile = tile }
end

return {
	["menu grid starts below the menu button and shows the first category header"] = function()
		for _, viewport in VIEWPORTS do
			local width, height, touch = viewport[1], viewport[2], viewport[3]
			local at = width .. "x" .. height
			local frame = grid(width, height, touch)
			local button = Model.contextHudBounds(width, height).menu
			inside(frame, width, height, "menu grid at " .. at)
			inside(button, width, height, "menu button at " .. at)
			assert(frame.y >= button.y + button.height + Panels.MENU_GAP, "grid not below the menu button at " .. at)
			assert(not overlaps(frame, button), "grid covers the menu button at " .. at)
			-- The canvas carries a top gap, so the first row's header is fully in the frame.
			local canvas = Panels.menuCanvas(1, frame.columns, frame.tile)
			assert(canvas >= Panels.MENU_GAP + frame.tile + Panels.MENU_GAP, "no top padding in the canvas at " .. at)
			local header = { x = frame.x, y = frame.y + Panels.MENU_GAP, width = frame.width, height = HEADER }
			assert(header.y > frame.y and header.y + HEADER <= frame.y + frame.height, "first header clipped at " .. at)
			assert(frame.height >= frame.tile + 2 * Panels.MENU_GAP, "one full row visible at " .. at)
		end
		local source = fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")
		assert(string.find(source, "menuPad.PaddingTop, menuPad.Parent = UDim.new(0, M.MENU_GAP), menuList", 1, true))
	end,
	["portrait phone HUD and menu grid stay out of the Roblox chat window"] = function()
		for _, viewport in { { 360, 640 }, { 390, 844 } } do
			local width, height = viewport[1], viewport[2]
			local at = width .. "x" .. height
			local hud = Model.contextHudBounds(width, height)
			for key, rect in hud do
				if key ~= "photo" then
					inside(rect, width, height, key .. " at " .. at)
					assert(not overlaps(rect, CHAT), key .. " under the chat window at " .. at)
				end
			end
			for _, a in { "menu", "vitals", "objective", "coins", "status" } do
				for _, b in { "menu", "vitals", "objective", "coins", "status" } do
					assert(a == b or not overlaps(hud[a], hud[b]), a .. " overlaps " .. b .. " at " .. at)
				end
			end
			assert(not overlaps(grid(width, height, true), CHAT), "menu grid under the chat window at " .. at)
		end
		-- PC and short landscape keep their layout (the desktop chat rule is chatSafe's).
		local pc = Model.contextHudBounds(1280, 720)
		assert(pc.menu.x == 1280 - 216 - 84 and pc.menu.y == 64 and pc.status == nil, "1280x720 HUD unchanged")
		assert(grid(1280, 720, false).y == 116, "1280x720 grid top unchanged")
	end,
	["vitals labels are at least 11px and fit their row at every viewport"] = function()
		local v = Model.VITALS
		assert(v and v.textSize >= HudFit.MIN_TEXT_SIZE, "vitals label text under 11px")
		local source = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		assert(
			string.find(
				source,
				"symbol.TextSize = t(stat), Color3.fromRGB(240, 244, 240), Model.VITALS.textSize",
				1,
				true
			)
		)
		assert(string.find(source, "Model.VITALS.textSize, Model.VITALS.textSize, symbol", 1, true), "min size 11")
		for _, viewport in VIEWPORTS do
			local width, height = viewport[1], viewport[2]
			local vitals = Model.contextHudBounds(width, height).vitals
			local track = vitals.width - v.trackX - v.trackRight
			assert(v.labelX + v.labelWidth <= v.trackX and track >= 40, "vitals track squeezed at " .. width)
			assert(vitals.height >= 4 + 2 * v.rowStep + 20, "three vitals rows fit")
			for _, locale in { "en-us", "ko-kr" } do
				for _, stat in { "health", "hunger", "fatigue" } do
					local text = Locale.text(locale, stat)
					assert(HudFit.textWidth(text, v.textSize) <= v.labelWidth, text .. " overflows its label")
				end
			end
		end
	end,
	["menu scroll frame is vertical and not rewritten every frame"] = function()
		local source = fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")
		local first = assert(string.find(source, "if contextual then\n\t\t\tmenuToggle.Visible = true", 1, true))
		local last = assert(string.find(source, "if lastCompact ~= isCompact then", first, true))
		local contextual = string.sub(source, first, last)
		assert(string.find(source, "menuList.ScrollingDirection = Enum.ScrollingDirection.Y", 1, true), "Y scrolling")
		for _, key in { "Position", "Size", "CanvasSize" } do
			assert(string.find(contextual, 'set(menuList, "' .. key .. '",', 1, true), key .. " written only on change")
			assert(not string.find(contextual, "menuList." .. key .. " =", 1, true), key .. " rewritten each Heartbeat")
		end
		-- The wheel-up target rows must not sit under the chat log (its own ScrollingFrame).
		for _, viewport in { { 360, 640 }, { 390, 844 } } do
			assert(not overlaps(grid(viewport[1], viewport[2], true), CHAT), "grid under chat scroll")
		end
	end,
	["Korean score editor labels and its sheet fit 360x640"] = function()
		local objects: { [string]: any } = {}
		local function signal(): any
			return {
				Connect = function()
					return { Disconnect = function() end }
				end,
			}
		end
		local view = {
			new = function(class)
				local node: any =
					{ class = class, Activated = signal(), FocusLost = signal(), Destroy = function() end }
				return setmetatable({}, {
					__index = node,
					__newindex = function(_, key, value)
						node[key] = value
						if key == "Name" then
							objects[value] = node
						end
					end,
				})
			end,
			size = function(x, y, dx, dy)
				return { x = x, y = y, dx = dx, dy = dy }
			end,
			position = function(x, y, dx, dy)
				return { x = x, y = y, dx = dx, dy = dy }
			end,
		}
		Editor.factory({
			rules = Rules,
			locale = "ko-kr",
			playerGui = {},
			view = view,
			decode = function(text)
				return serde.decode("json", text)
			end,
			encode = function(value)
				return serde.encode("json", value)
			end,
			requestId = function()
				return "r"
			end,
			serverNow = function()
				return 0
			end,
			stop = function() end,
			playAt = function() end,
			send = function()
				return { ok = true }
			end,
		})
		assert(objects.Instrument.Text == "다음 악기", "instrument: " .. tostring(objects.Instrument.Text))
		assert(objects.Part2.Text == "파트 2", "part: " .. tostring(objects.Part2.Text))
		assert(objects.Close.Text == "닫기", "close: " .. tostring(objects.Close.Text))
		local x, y, w, h = Model.contextSheet(360, 640, true)
		inside({ x = x, y = y, width = w, height = h }, 360, 640, "editor sheet")
		inside({ x = x + w - 50, y = y, width = 44, height = 44 }, 360, 640, "editor close")
	end,
}
