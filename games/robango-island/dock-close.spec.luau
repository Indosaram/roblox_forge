--!strict
-- p48 Studio 360x640: after the score editor's X, the 소리 (audio) tile hid the menu column with
-- no sheet on screen, so the menu could not be reopened. This runs the shipped robango panel
-- wiring (RobangoIslandClient's ExtensionPanels.start section, every real panel module and the
-- real ui-kit Components) on a small fake engine, opens each dock entry from its menu tile and
-- closes it by its header X: a hidden dock always has a visible sheet, and X brings it back.
local roblox: any = require("@lune/roblox")
local harness = require("./PanelHarness.fixture").harness

-- Bag/craft/build/skills open SurvivalHUD's own sheet and island view the aerial camera.
local LAUNCHERS = { explore = true, bag = true, craft = true, build = true, skills = true }

-- Opens `id` from the menu and closes it by X; returns whether a sheet opened.
local function cycle(h: any, id: string): boolean
	h.step()
	assert(#h.sheets() == 0 and h.column.Visible and h.toggle.Visible, "dock visible before " .. id)
	h.click(h.toggle)
	assert(h.menu.Visible, "menu opens before " .. id)
	h.click(h.tile(id))
	local open = h.sheets()
	if h.column.Visible then
		-- A locked entry (camp outside its site) may decline to open; the dock stays usable.
		assert(#open == 0, id .. " shows a sheet over a visible dock")
		return false
	end
	assert(#open == 1, string.format("%s hides the menu with %d sheets on screen (wedge)", id, #open))
	local function small(item: any)
		for _, child in item:GetChildren() do
			if (child.ClassName == "TextLabel" or child.ClassName == "TextButton") and child.Text ~= "" then
				assert(
					not child.Visible or child.TextScaled or child.TextSize >= 11,
					id .. " text under 11 px: " .. child.Text
				)
			end
			small(child)
		end
	end
	small(open[1].frame)
	h.click(open[1].close)
	assert(#h.sheets() == 0, id .. " sheet still on screen after its X")
	assert(h.column.Visible and h.toggle.Visible, id .. " X left the menu column hidden")
	return true
end

-- D2 F4: the trading post (C8 full-screen panel) at the three plan C8 screens.
local VIEWS = { { 800, 360, 0 }, { 850, 411, 58 }, { 1920, 1080, 0 } }
local MARKET: any = {
	balance = 120,
	items = { a = { catalogId = "antler", quantity = 5 } },
	catalogIds = { "antler", "apple" },
	listed = { { id = "L1", catalogId = "antler", quantity = 2, price = 20 } },
	listings = { { id = "S1", catalogId = "antler", quantity = 2, price = 21 } },
	filter = "antler",
	claims = { { id = "C1", value = { coins = 30 } } },
	page = 1,
	pages = 2,
	eligible = true,
}
-- Screen rect of a GuiObject inside its ScreenGui (offset layout, plus scale against the parent).
local function rect(item: any): { x: number, y: number, width: number, height: number }
	local parent = item.Parent
	local base = if parent and parent.ClassName ~= "ScreenGui"
		then rect(parent)
		else { x = 0, y = 0, width = parent.AbsoluteSize.X, height = parent.AbsoluteSize.Y }
	local size, position = item.Size, item.Position or roblox.UDim2.new()
	local width = size.X.Scale * base.width + size.X.Offset
	local height = size.Y.Scale * base.height + size.Y.Offset
	local anchor = item.AnchorPoint or roblox.Vector2.zero
	return {
		x = base.x + position.X.Scale * base.width + position.X.Offset - anchor.X * width,
		y = base.y + position.Y.Scale * base.height + position.Y.Offset - anchor.Y * height,
		width = width,
		height = height,
	}
end
local function inside(r: any, bounds: any): boolean
	return r.x >= bounds.x - 0.5
		and r.y >= bounds.y - 0.5
		and r.x + r.width <= bounds.x + bounds.width + 0.5
		and r.y + r.height <= bounds.y + bounds.height + 0.5
end
-- Checks the open market at screen `view` (safe area = the viewport below the top-bar inset).
local function checkMarket(h: any, view: { number }, locale: string)
	local where = string.format("%dx%d inset %d %s", view[1], view[2], view[3], locale)
	local open = h.sheets()
	assert(#open == 1 and open[1].frame.Name == "TradeSheet", "trading post open at " .. where)
	local frame, close = open[1].frame, open[1].close
	local safe = { x = 0, y = 0, width = view[1], height = view[2] - view[3] }
	local panel = rect(frame)
	assert(
		panel.width == safe.width and panel.height == safe.height and inside(panel, safe),
		string.format("panel %dx%d fills the %s safe area", panel.width, panel.height, where)
	)
	local x = rect(close)
	assert(inside(x, panel), "close inside the panel at " .. where)
	assert(x.width >= 44 and x.height >= 44, "close >= 44 px at " .. where)
	local Social = require("../../genres/survival-coop/module/SocialSheet")
	local buttons = 0
	local function walk(item: any)
		for _, child in item:GetChildren() do
			if child.Visible ~= false and child.Size then
				local r = rect(child)
				local isButton = child.ClassName == "TextButton"
				if isButton or child.ClassName == "TextLabel" or child.ClassName == "ScrollingFrame" then
					-- Scrolling lists may run past their pane; everything else stays on screen.
					if not item:IsA("ScrollingFrame") then
						assert(inside(r, panel), child.Name .. " overflows the panel at " .. where)
					end
				end
				if isButton then
					buttons += 1
					assert(r.height >= 44 and r.width >= 44, child.Name .. " under 44 px at " .. where)
				end
				if (isButton or child.ClassName == "TextLabel") and child.Text ~= "" and not child.TextScaled then
					assert(child.TextSize >= 13, child.Name .. " text under 13 px at " .. where)
					-- Unwrapped text is one line; wrapped text fits its rows.
					local width = Social.textWidth(child.Text, child.TextSize)
					local lines = if child.TextWrapped
						then math.max(1, math.floor(r.height / (child.TextSize * 1.2)))
						else 1
					assert(
						width <= (r.width - 4) * lines,
						string.format(
							"'%s' (%d px) does not fit %d px x %d at %s",
							child.Text,
							width,
							r.width,
							lines,
							where
						)
					)
				end
				walk(child)
			end
		end
	end
	walk(frame)
	assert(buttons >= 8, "tabs, grid and primary rendered at " .. where)
end

-- Scrolls the open menu grid as a player would until `tile` is a whole row inside it, then returns
-- whether the tile (and the grid) sit fully on screen. Mirrors UIGridLayout: cells in LayoutOrder,
-- a gap after each cell, the canvas starting MENU_GAP below the frame top (UIPadding).
local Panels = require("../../genres/survival-coop/module/ExtensionPanels")
local function menuReach(h: any, tile: any, view: { any }): boolean
	local grid = assert(h.menu:FindFirstChildOfClass("UIGridLayout"), "menu grid layout")
	local cell, gap = grid.CellSize, Panels.MENU_GAP
	local frame = rect(h.menu)
	local columns = math.max(1, (frame.width - Panels.MENU_SCROLLBAR) // (cell.X.Offset + gap))
	local index = 0
	for _, other in h.tiles() do
		if other.Visible then
			if other == tile then
				break
			end
			index += 1
		end
	end
	local top = gap + (index // columns) * (cell.Y.Offset + gap)
	local bottom = top + cell.Y.Offset
	local canvas = h.menu.CanvasSize.Y.Offset
	local scroll = math.clamp(bottom - frame.height, 0, math.max(0, canvas - frame.height))
	h.menu.CanvasPosition = roblox.Vector2.new(0, scroll)
	local x = (index % columns) * (cell.X.Offset + gap)
	local screen = { x = 0, y = 0, width = view[1], height = view[2] }
	return bottom <= canvas
		and top - scroll >= 0
		and bottom - scroll <= frame.height
		and x + cell.X.Offset <= frame.width - Panels.MENU_SCROLLBAR
		and inside(frame, screen)
end

-- D2b fix 4: the SurvivalSheet (bag, craft, skills, build) on the shipped SurvivalHUD.
local function sheetParts(h: any): (any, any, any)
	local gui = assert(h.playerGui:FindFirstChild("ForgeSurvivalHUD"), "survival hud gui")
	local frame = assert(gui:FindFirstChild("SafeArea"):FindFirstChild("SurvivalSheet"), "survival sheet")
	return gui, frame, frame:FindFirstChild("Header"):FindFirstChild("Close")
end
local function overlap(a: any, b: any): boolean
	return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end
-- The notice lane (status line + MaterialToast) must sit on screen and off every content rect.
local function laneClear(h: any, content: { any }, where: string)
	local gui = h.playerGui:FindFirstChild("ForgeSurvivalHUD")
	for _, name in { "Status", "MaterialToast" } do
		local item = assert(gui:FindFirstChild(name), name)
		local r = h.rect(item)
		assert(r.width > 0 and r.height >= 28, string.format("%s lane %dx%d at %s", name, r.width, r.height, where))
		assert(r.y >= 0 and r.y + r.height <= gui.AbsoluteSize.Y, name .. " lane on screen at " .. where)
		for _, c in content do
			assert(
				not overlap(r, c.rect),
				string.format("%s (%d,%d %dx%d) covers %s at %s", name, r.x, r.y, r.width, r.height, c.name, where)
			)
		end
	end
end

return {
	["D2b 4: SurvivalSheet Close sits below the top-bar band, closes by click, and notices never cover its rows"] = function()
		-- PC 1280x720 (58 px top bar, the D2b capture) and the SM-N981N landscape phone.
		for _, view in { { 1280, 720, 58, false }, { 850, 411, 58, true } } do
			local where = string.format("%dx%d", view[1], view[2])
			local h = harness({ width = view[1], height = view[2], inset = view[3], touch = view[4], realHud = true })
			local _, frame, close = sheetParts(h)
			for _, section in { "bag", "craft", "skills", "build", "skills" } do
				h.hud.open(section)
				h.step()
				assert(frame.Visible, section .. " opens at " .. where)
				local x = h.rect(close)
				-- GuiService.TopbarInset.Max.Y in the gui's space: presses above it never reach the button.
				-- U6 Studio MCP probes: that dead strip is the PC player list (top right); on a touch screen a
				-- CoreUISafeInsets gui starts below the top bar and takes presses from its first row, so the
				-- phone keeps no band (the bag/craft bar no longer spends 58 of 281 px on it).
				local band = if view[4] then 0 else view[3]
				assert(
					x.y >= band and x.width >= 44 and x.height >= 44,
					string.format("%s Close at y %d inside the %d px top bar band at %s", section, x.y, band, where)
				)
				local content: { any } = {}
				if section == "bag" or section == "craft" then
					for _, name in { "Categories", "CraftActions" } do
						table.insert(content, { name = name, rect = h.rect(frame:FindFirstChild(name)) })
					end
					local panes = frame:FindFirstChild("PanelPanes")
					for _, name in { "ItemList", "ItemDetails" } do
						table.insert(content, { name = name, rect = h.rect(panes:FindFirstChild(name)) })
					end
				else
					table.insert(content, { name = section .. " sheet", rect = h.rect(frame) })
				end
				laneClear(h, content, section .. " " .. where)
				h.click(close)
				assert(not frame.Visible, section .. " X closes the sheet at " .. where)
			end
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	["D2 F4: the trading post fills 800x360, 850x411 (58 px inset) and 1920x1080 after any device change; X closes it"] = function()
		for _, locale in { "ko-kr", "en-us" } do
			-- Studio order: the panels start on a PC window, the device simulator then switches screens.
			local h = harness({ width = 1279, height = 662, touch = false, locale = locale, multiplayer = true })
			h.publish({
				market = MARKET,
				["harbor-buyback"] = { prices = { antler = 1 }, dailyUnits = 200, remaining = 7 },
			})
			for _, view in VIEWS do
				h.setViewport(view[1], view[2], view[3])
				h.step()
				assert(#h.sheets() == 0 and h.column.Visible, "dock idle before the market")
				h.click(h.toggle)
				h.click(h.tile("market"))
				checkMarket(h, view, locale)
				local close = h.sheets()[1].close
				h.click(close)
				assert(#h.sheets() == 0, "X closes the trading post at " .. view[1] .. "x" .. view[2])
				assert(h.column.Visible and h.attributes.ForgeExtensionSheetOpen == false, "X returns the menu")
			end
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	["D2 F4: an open trading post follows a device change and its X still closes it"] = function()
		local h = harness({ width = 1279, height = 662, touch = false, multiplayer = true })
		h.publish({ market = MARKET })
		h.step()
		h.click(h.toggle)
		h.click(h.tile("market"))
		for _, view in VIEWS do
			h.setViewport(view[1], view[2], view[3])
			h.step()
			checkMarket(h, view, "ko-kr")
		end
		h.click(h.sheets()[1].close)
		assert(#h.sheets() == 0 and h.column.Visible, "X closes after resizes")
		assert(#h.errors == 0, table.concat(h.errors, "\n"))
	end,
	["p48: after the score editor's X the menu toggle returns and the audio tile opens its sheet"] = function()
		local h = harness()
		assert(cycle(h, "music"), "score editor opens")
		assert(h.attributes.ForgeExtensionSheetOpen == false, "no extension sheet flagged open")
		assert(cycle(h, "audio"), "audio settings sheet opens")
		assert(#h.errors == 0, table.concat(h.errors, "\n"))
	end,
	["p56: the menu reopens scrolled to the top with the guide tile first"] = function()
		local h = harness()
		h.step()
		assert(string.sub(h.tiles()[1].Name, 6) == "guides", "first tile: " .. h.tiles()[1].Name)
		h.click(h.toggle)
		assert(h.menu.Visible, "menu opens")
		h.menu.CanvasPosition = roblox.Vector2.new(0, 400)
		h.click(h.toggle)
		assert(not h.menu.Visible, "menu closes")
		h.click(h.toggle)
		assert(h.menu.Visible and h.menu.CanvasPosition.Y == 0, "menu reopens at canvas " .. h.menu.CanvasPosition.Y)
		assert(#h.errors == 0, table.concat(h.errors, "\n"))
	end,
	["every dock entry opened from its tile closes by X and returns the menu column"] = function()
		-- Multiplayer mode: party, clan, trade... tiles exist and open (solo blocks them; see below).
		local h = harness({ multiplayer = true })
		local opened, ids = 0, {}
		for _, tile in h.tiles() do
			local id = string.sub(tile.Name, 6)
			if not LAUNCHERS[id] then
				table.insert(ids, id)
				if cycle(h, id) then
					opened += 1
				end
			end
		end
		assert(#ids >= 40 and opened >= #ids - 2, string.format("%d of %d dock entries opened", opened, #ids))
		assert(#h.errors == 0, table.concat(h.errors, "\n"))
	end,
	-- D2b (08bc5d0, Studio PC 1280x720): market, shop, audio, music, brawl, home-move,
	-- home-permissions, direct-trade and organizations "opened nothing". 36 tiles with 7 rows on
	-- screen put 8 of them below the fold. Multiplayer is on hold, so the tiles that only act on
	-- other players are held off the grid. Every tile left is reachable in the scrolling grid (a whole
	-- row on screen after scrolling, never clipped) and opens its panel (a sheet, or the HUD sheet for
	-- the bag/craft/build/skills launchers), on the PC and on the 800x360 phone.
	["D2b: every visible menu tile is reachable by scrolling and opens a panel; multiplayer-only tiles are held"] = function()
		local HELD = {
			brawl = true,
			["direct-trade"] = true,
			outpost = true,
			party = true,
			clan = true,
			["clan-membership"] = true,
			["home-permissions"] = true,
			["death-zone"] = true,
		}
		local REQUIRED = { "market", "shop", "audio", "music", "home-move", "organizations" }
		for _, view in { { 1280, 720 - 58, false }, { 1280, 720, false }, { 800, 360, true }, { 799, 339, true } } do
			local h = harness({ width = view[1], height = view[2], touch = view[3] })
			-- The slices a Studio onboarding join publishes (D2b census: 36 tiles before this fix), so the
			-- context tiles (camp, death-zone, practice, routes, party) count against the fold too.
			h.publish({
				market = MARKET,
				camp = { role = "guest", hosts = { ["2"] = true } },
				["death-zone"] = { zone = "safe", alive = true },
				operations = {},
				expedition = {
					routes = {},
					party = { members = { "1" }, capacity = 4, invites = {} },
					now = 0,
					facts = {},
				},
			})
			for _, id in { "camp", "operations", "routes" } do
				assert(h.tile(id).Visible, id .. " context tile shown for the fold count")
			end
			local visible = {}
			for _, tile in h.tiles() do
				local id = string.sub(tile.Name, 6)
				assert(not (HELD[id] and tile.Visible), id .. " (multiplayer only) is on the menu")
				if tile.Visible then
					table.insert(visible, tile)
				end
			end
			local at = view[1] .. "x" .. view[2]
			h.click(h.toggle)
			-- D2b fix 10: the phone grid showed 2 rows (108 px). The grid now runs the safe height:
			-- at least 5 whole rows on the 800x360 phone, and the PC shows every tile without scrolling.
			local cell = assert(h.menu:FindFirstChildOfClass("UIGridLayout"), "grid").CellSize.Y.Offset
			local rows = rect(h.menu).height // (cell + Panels.MENU_GAP)
			local columns = (rect(h.menu).width - Panels.MENU_SCROLLBAR)
				// (h.menu:FindFirstChildOfClass("UIGridLayout").CellSize.X.Offset + Panels.MENU_GAP)
			local need = if view[1] >= 1280 then math.ceil(#visible / columns) else 5
			assert(rows >= need, string.format("%d rows on screen, need %d at %s", rows, need, at))
			for _, tile in visible do
				assert(menuReach(h, tile, view), string.sub(tile.Name, 6) .. " not reachable at " .. at)
			end
			h.click(h.toggle)
			for _, id in REQUIRED do
				local tile = h.tile(id)
				assert(tile.Visible, id .. " tile on the menu at " .. at)
			end
			for _, tile in visible do
				local id = string.sub(tile.Name, 6)
				h.step()
				if not h.menu.Visible then
					h.click(h.toggle)
				end
				assert(h.menu.Visible, "menu opens before " .. id)
				assert(menuReach(h, tile, view), id .. " scrolled into view at " .. at)
				h.click(tile)
				if id == "explore" then
					-- Island view is the aerial camera (bound after this section): the menu just gives way.
					assert(not h.menu.Visible, "explore closes the menu")
				elseif LAUNCHERS[id] then
					assert(h.hud.shown, id .. " opens the HUD sheet at " .. at)
					h.hud.close()
				else
					local open = h.sheets()
					assert(#open == 1 and not h.column.Visible, id .. " opens no panel at " .. at)
					h.click(open[1].close)
					assert(#h.sheets() == 0 and h.column.Visible, id .. " X returns the menu at " .. at)
				end
			end
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	-- D2b fix 3 (08bc5d0: ~15 panels were one black sheet of ~9 px centred text, score 2) and fix 10
	-- (phone menu: 6 of 36 tiles in a 108 px scroller, tiles unlabeled on PC). Every docked sheet
	-- opened from its tile is the shell sheet: parchment body, header with icon badge, left-aligned
	-- title and a 44 px close inside the screen, body text >= 14 px at 800x360 and >= 16 px at
	-- 1280x720, left-aligned row text; every menu tile carries a label at least MENU_LABEL_MIN.
	["D2b: docked sheets share the shell look with readable text and every menu tile is labelled"] = function()
		local Theme = require("../../core/ui-kit/Theme")
		local body = Theme.sheet.colors.body
		for _, view in { { 800, 360, true, 14 }, { 1280, 720, false, 16 } } do
			local at = view[1] .. "x" .. view[2]
			local h = harness({ width = view[1], height = view[2], touch = view[3] })
			h.publish({ market = MARKET, operations = {} })
			local checked = 0
			for _, tile in h.tiles() do
				local id = string.sub(tile.Name, 6)
				if not tile.Visible then
					continue
				end
				local label = tile:FindFirstChild("MenuLabel")
				assert(label and label.Text ~= "", id .. " tile has no label at " .. at)
				assert(label.TextSize >= Panels.MENU_LABEL_MIN, id .. " tile label under the minimum at " .. at)
				if LAUNCHERS[id] then
					continue
				end
				h.step()
				h.click(h.toggle)
				h.click(tile)
				local open = h.sheets()
				if #open == 1 and open[1].frame:GetAttribute("ForgeShellPanel") == nil then
					local frame, close = open[1].frame, open[1].close
					local header = frame:FindFirstChild("Header")
					-- Components.modalSheet sheets (Header + Content scroll); the sea chart draws its own map.
					if header and frame:FindFirstChild("Content") then
						checked += 1
						local function walk(item: any)
							for _, child in item:GetChildren() do
								local text = child.ClassName == "TextLabel" or child.ClassName == "TextButton"
								if text and child.Visible ~= false and child.Text ~= "" and not child.TextScaled then
									assert(
										child.TextSize >= view[4],
										string.format(
											"%s: %q is %d px (< %d) at %s",
											id,
											child.Text,
											child.TextSize,
											view[4],
											at
										)
									)
									if child.ClassName == "TextLabel" and item.Name == "Content" then
										assert(
											child.TextXAlignment == roblox.Enum.TextXAlignment.Left,
											string.format("%s: row %q is not left-aligned at %s", id, child.Text, at)
										)
									end
								end
								walk(child)
							end
						end
						walk(frame)
						local c = frame.BackgroundColor3
						assert(
							math.floor(c.R * 255 + 0.5) == body.r and math.floor(c.G * 255 + 0.5) == body.g,
							id .. " sheet body is not the shell parchment at " .. at
						)
						assert(header:FindFirstChild("ShellIcon"), id .. " header has no icon at " .. at)
						local title = assert(header:FindFirstChild("Title"), id .. " title")
						assert(title.TextXAlignment == roblox.Enum.TextXAlignment.Left, id .. " title centred")
						assert(title.TextSize >= view[4] + 2, id .. " title under " .. (view[4] + 2) .. " px at " .. at)
						local x = rect(close)
						assert(x.width >= 44 and x.height >= 44, id .. " close under 44 px at " .. at)
						assert(
							x.x >= 0 and x.y >= 0 and x.x + x.width <= view[1] and x.y + x.height <= view[2],
							id .. " close off screen at " .. at
						)
					end
				end
				for _, sheet in h.sheets() do
					h.click(sheet.close)
				end
				h.hud.close()
			end
			assert(checked >= 12, checked .. " shell sheets checked at " .. at)
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	["U3b: every menu tile and sheet header shows a pack icon or a clean glyph, never an empty dark square"] = function()
		local Theme = require("../../core/ui-kit/Theme")
		local missing: { string } = {}
		-- An icon badge reads as an empty slot when its frame is filled and it shows no art: the glyph
		-- is hidden only by a published Asset image (IconFallback hides it once the image loads).
		local function clean(badge: any, where: string)
			assert(badge and badge.ClassName == "Frame", "icon badge at " .. where)
			assert(badge.BackgroundTransparency == 1, "filled (dark square) icon badge at " .. where)
			local asset, glyph = badge:FindFirstChild("Asset"), badge:FindFirstChild("Glyph")
			local image = asset ~= nil and asset.Image ~= nil and asset.Image ~= ""
			assert(image or (glyph and glyph:FindFirstChild("Shape1")), "no art and no glyph at " .. where)
			return image
		end
		for _, view in { { 800, 360, true }, { 1280, 720, false } } do
			local at = view[1] .. "x" .. view[2]
			local h = harness({ width = view[1], height = view[2], touch = view[3] })
			h.publish({ market = MARKET, operations = {} })
			for _, tile in h.tiles() do
				local id = string.sub(tile.Name, 6)
				if tile.Visible then
					if not clean(tile:FindFirstChild("MenuIconFallback"), id .. " tile at " .. at) then
						table.insert(missing, id)
					end
				end
				if not tile.Visible or LAUNCHERS[id] then
					continue
				end
				h.step()
				h.click(h.toggle)
				h.click(tile)
				for _, sheet in h.sheets() do
					local header = sheet.frame:FindFirstChild("Header")
					if
						header
						and sheet.frame:FindFirstChild("Content")
						and sheet.frame:GetAttribute("ForgeShellPanel") == nil
					then
						clean(header:FindFirstChild("ShellIcon"), id .. " header at " .. at)
					end
				end
				for _, sheet in h.sheets() do
					h.click(sheet.close)
				end
				h.hud.close()
			end
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
		-- Every visible dock id has published art (assets/icons + manifest), not just the glyph.
		assert(#missing == 0, "dock ids without a pack icon: " .. table.concat(missing, ", "))
		assert(Theme.sheet ~= nil, "sheet tokens")
	end,
	["U3b: bag, craft, skills and build sheets wear the shell tokens with 14/16 px text floors"] = function()
		local Theme = require("../../core/ui-kit/Theme")
		local C = Theme.sheet.colors
		local function same(c: any, token: any): boolean
			return math.floor(c.R * 255 + 0.5) == token.r
				and math.floor(c.G * 255 + 0.5) == token.g
				and math.floor(c.B * 255 + 0.5) == token.b
		end
		local actions = {}
		for _, verb in { "food", "gear-equip", "transfer-deposit", "craft-reserve", "recipe-mark", "skill-learn" } do
			table.insert(actions, "survival-coop:" .. verb)
		end
		local function stack(id: string, catalogId: string, quantity: number): any
			return {
				itemId = id,
				catalogId = catalogId,
				quantity = quantity,
				qualityMilli = 1000,
				durabilityMilli = 1000,
			}
		end
		local packet = {
			revision = 1,
			durable = { actions = actions, epochs = {} },
			snapshots = {
				["survival-coop"] = {
					balance = 100,
					vitals = { healthMilli = 90000, hungerMilli = 70000, fatigueMilli = 20000 },
					progression = { level = 2, sp = 4, xp = 10, paid = {}, version = 1 },
					inventory = {
						{
							kind = "carried",
							items = { a = stack("a", "bone", 5), b = stack("b", "fiber", 12) },
							reservations = {},
							limits = { slots = 20, softWeightMilli = 40000, hardWeightMilli = 60000 },
							weightMilli = 2000,
						},
					},
				},
				survivalExtensions = {},
			},
		}
		-- 800x360 phone (floor 14) and 1280x720 PC (floor 16), plus U4's 58 px top bar on PC.
		for _, view in { { 800, 360, 0, true, 14 }, { 1280, 720, 58, false, 16 } } do
			local at = view[1] .. "x" .. view[2]
			local h = harness({ width = view[1], height = view[2], inset = view[3], touch = view[4], realHud = true })
			h.packet(packet)
			local _, frame, close = sheetParts(h)
			for _, section in { "bag", "craft", "skills", "build" } do
				local where = section .. " " .. at
				h.hud.open(section)
				h.step()
				assert(frame.Visible, section .. " open at " .. at)
				assert(same(frame.BackgroundColor3, C.body), where .. ": body is not the shell parchment")
				assert(same(frame:FindFirstChild("Header").BackgroundColor3, C.header), where .. ": header not leather")
				assert(same(close.BackgroundColor3, C.close), where .. ": close not the shell close")
				local x = h.rect(close)
				assert(x.width >= 44 and x.height >= 44 and x.y >= view[3], where .. ": close 44 px below the top bar")
				local rows, counts = 0, 0
				local function walk(item: any)
					for _, child in item:GetChildren() do
						if child.Visible == false then
							continue
						end
						local class = child.ClassName
						if (class == "TextLabel" or class == "TextButton") and child.Text ~= "" then
							assert(not child.TextScaled, string.format("%s: %q is TextScaled", where, child.Text))
							assert(
								child.TextSize >= view[5],
								string.format("%s: %q is %d px (< %d)", where, child.Text, child.TextSize, view[5])
							)
							if child.Name == "RowCount" or child.Name == "Quantity" then
								counts += 1
								assert(
									child.TextXAlignment == roblox.Enum.TextXAlignment.Right,
									where .. ": count " .. child.Text .. " not right-aligned"
								)
							elseif
								class == "TextLabel"
								and child.Parent.ClassName ~= "TextButton"
								and child.Name ~= "Currency"
							then
								rows += 1
								assert(
									child.TextXAlignment == roblox.Enum.TextXAlignment.Left,
									string.format("%s: row %q is not left-aligned", where, child.Text)
								)
							end
						end
						if class == "Frame" and child.Name == "IconFallback" then
							assert(
								child.BackgroundTransparency == 1,
								where .. ": dark icon square in " .. child.Parent.Name
							)
						end
						walk(child)
					end
				end
				walk(frame)
				assert(rows > 0, where .. ": no rows")
				if section == "bag" or section == "craft" then
					assert(counts > 0, where .. ": no item counts")
				end
				if section == "bag" then
					-- p134 v53 (phone): each slot's count box covered the lower half of its icon. The count
					-- is a compact bottom-right corner badge; the icon centre and most of the icon stay clear.
					local grid
					for _, item in frame:GetDescendants() do
						grid = grid or (if item.Name == "InventoryGrid" then item else nil)
					end
					assert(grid, where .. ": bag grid")
					local cell = grid:FindFirstChildOfClass("UIGridLayout").CellSize
					local edge = cell.X.Offset
					assert(edge > 0 and cell.Y.Offset == edge and cell.X.Scale == 0, where .. ": square px slots")
					local slots = 0
					for _, slot in grid:GetChildren() do
						local badge, icon = slot:FindFirstChild("Quantity"), slot:FindFirstChild("IconFallback")
						if not (badge and icon) then
							continue
						end
						slots += 1
						local function box(item: any): any
							assert(item.Size.X.Scale == 0 and item.Position.X.Scale == 0, where .. ": offset rects")
							assert(item.Size.Y.Scale == 0 and item.Position.Y.Scale == 0, where .. ": offset rects")
							local left, top = item.Position.X.Offset, item.Position.Y.Offset
							return { x = left, y = top, r = left + item.Size.X.Offset, b = top + item.Size.Y.Offset }
						end
						local q, i = box(badge), box(icon)
						local slotAt = where .. " slot " .. badge.Text
						assert(
							q.x >= 0 and q.y >= 0 and q.r <= edge and q.b <= edge,
							slotAt .. ": badge inside the slot"
						)
						assert(edge - q.r <= 4 and edge - q.b <= 4, slotAt .. ": badge in the bottom-right corner")
						assert(q.b - q.y <= badge.TextSize + 6, slotAt .. ": badge one compact line")
						assert((q.r - q.x) * (q.b - q.y) <= edge * edge * 0.22, slotAt .. ": badge compact")
						local cx, cy = (i.x + i.r) / 2, (i.y + i.b) / 2
						assert(q.x > cx and q.y > cy, slotAt .. ": badge clear of the icon centre")
						local ow = math.max(0, math.min(q.r, i.r) - math.max(q.x, i.x))
						local oh = math.max(0, math.min(q.b, i.b) - math.max(q.y, i.y))
						local area = (i.r - i.x) * (i.b - i.y)
						assert(ow * oh <= area * 0.2, slotAt .. ": badge covers " .. (ow * oh) .. " of " .. area)
						assert(badge.ZIndex > icon.ZIndex, slotAt .. ": badge draws over the icon")
					end
					assert(slots == 2, where .. ": both stacks have a slot, got " .. slots)
				end
				laneClear(h, { { name = section .. " close", rect = x } }, where)
				h.click(close)
				assert(not frame.Visible, where .. ": X closes")
			end
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	["U3b: character and guides show an empty state, not the failure line, before any record exists"] = function()
		for _, locale in { "ko-kr", "en-us" } do
			local h = harness({ width = 800, height = 360, touch = true, locale = locale })
			h.publish({})
			for _, id in { "character", "guides" } do
				h.step()
				h.click(h.toggle)
				h.click(h.tile(id))
				local open = h.sheets()
				assert(#open == 1, id .. " opens")
				local texts = {}
				for _, item in open[1].frame:GetDescendants() do
					if (item.ClassName == "TextLabel" or item.ClassName == "TextButton") and item.Text ~= "" then
						table.insert(texts, item.Text)
					end
				end
				local all = table.concat(texts, "|")
				assert(
					not string.find(all, "실패", 1, true) and not string.find(all, "did not work", 1, true),
					id .. ": " .. all
				)
				local expected = if locale == "ko-kr" then "아직 없어요" else "Nothing here yet"
				assert(string.find(all, expected, 1, true), id .. " empty state missing: " .. all)
				h.click(open[1].close)
			end
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	-- text audit: the Korean skills sheet showed catalog English ("carcass meat extraction") as the
	-- node effect. Every category of the real SurvivalHUD skills sheet, plus bag, craft and build,
	-- is rendered in ko-kr at 800x360 and 1280x720 and every visible string is scanned: no English
	-- word of 3+ letters (SP / XP / HP units and Roblox names excepted) may reach the player.
	["text audit: the Korean survival sheets render no catalog English"] = function()
		local ALLOWED = { SP = true, XP = true, HP = true, Lv = true }
		local function english(text: string): string?
			for word in string.gmatch(text, "%a%a%a+") do
				if not ALLOWED[word] then
					return word
				end
			end
			return nil
		end
		local function shown(item: any, root: any): boolean
			local current = item
			while current and current ~= root do
				if current.Visible == false then
					return false
				end
				current = current.Parent
			end
			return true
		end
		local function scan(frame: any, where: string): number
			local count = 0
			for _, item in frame:GetDescendants() do
				local class = item.ClassName
				if (class == "TextLabel" or class == "TextButton") and item.Text ~= "" and shown(item, frame) then
					count += 1
					local word = english(item.Text)
					assert(word == nil, string.format("%s: English '%s' in %q", where, tostring(word), item.Text))
				end
			end
			return count
		end
		local actions = {}
		for _, verb in { "food", "gear-equip", "transfer-deposit", "craft-reserve", "skill-learn", "skill-reset" } do
			table.insert(actions, "survival-coop:" .. verb)
		end
		local packet = {
			revision = 1,
			durable = { actions = actions, epochs = {} },
			snapshots = {
				["survival-coop"] = {
					balance = 100,
					vitals = { healthMilli = 90000, hungerMilli = 70000, fatigueMilli = 20000 },
					progression = { level = 3, sp = 40, xp = 10, paid = { survival_1 = 1 }, version = 1 },
					inventory = {
						{
							kind = "carried",
							items = {
								a = {
									itemId = "a",
									catalogId = "fiber",
									quantity = 12,
									qualityMilli = 1000,
									durabilityMilli = 1000,
								},
							},
							reservations = {},
							limits = { slots = 20, softWeightMilli = 40000, hardWeightMilli = 60000 },
							weightMilli = 2000,
						},
					},
				},
				survivalExtensions = {},
			},
		}
		local content: any = require("./src/shared/SurvivalContent")
		for _, view in { { 800, 360, true }, { 1280, 720, false } } do
			local at = view[1] .. "x" .. view[2]
			local h = harness({ width = view[1], height = view[2], touch = view[3], realHud = true })
			h.packet(packet)
			local _, frame = sheetParts(h)
			for _, section in { "bag", "craft", "build" } do
				h.hud.open(section)
				h.step()
				assert(scan(frame, section .. " " .. at) > 0, section .. " rendered nothing at " .. at)
			end
			h.hud.open("skills")
			h.step()
			local categories: { [string]: boolean } = {}
			for _, node in content.skillNodes do
				categories[node.category] = true
			end
			local visited = 0
			for category in categories do
				local cell
				for _, item in frame:GetDescendants() do
					cell = cell or (if item.Name == "skill-" .. category then item else nil)
				end
				assert(cell, "skill cell " .. category .. " at " .. at)
				h.click(cell)
				local effect
				for _, item in frame:GetDescendants() do
					effect = effect or (if item.Name == "SkillEffect" then item else nil)
				end
				assert(effect and effect.Text ~= "", category .. ": no effect line at " .. at)
				scan(frame, "skills/" .. category .. " " .. at)
				visited += 1
			end
			assert(visited == 12, visited .. " skill categories rendered at " .. at)
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
		-- Every docked menu sheet (journal, guides, contracts, camp, market, shop, taming, ...) in ko-kr.
		local h = harness({ width = 1280, height = 720, touch = false })
		h.publish({ market = MARKET, operations = {}, camp = { role = "guest", hosts = { ["2"] = true } } })
		local scanned = 0
		for _, tile in h.tiles() do
			local id = string.sub(tile.Name, 6)
			if not tile.Visible or LAUNCHERS[id] then
				continue
			end
			h.step()
			h.click(h.toggle)
			h.click(tile)
			for _, sheet in h.sheets() do
				scanned += scan(sheet.frame, "sheet " .. id)
				h.click(sheet.close)
			end
			h.hud.close()
		end
		assert(scanned > 100, scanned .. " docked sheet strings scanned")
		assert(#h.errors == 0, table.concat(h.errors, "\n"))
	end,
	-- text audit goal 2: at 800x360 the skills grid showed ~2.5 of 7 rows with a thin bar, so it
	-- did not read as scrollable. A wide opaque bar, a fade and a "more below" pill over the last
	-- visible row show the rest; the hint goes once the grid is scrolled to its end.
	["text audit: the skills grid shows it scrolls at 800x360 and the hint clears at the bottom"] = function()
		local packet = {
			revision = 1,
			durable = { actions = { "survival-coop:skill-learn" }, epochs = {} },
			snapshots = {
				["survival-coop"] = {
					progression = { level = 1, sp = 3, xp = 0, paid = {}, version = 1 },
					inventory = {},
				},
				survivalExtensions = {},
			},
		}
		for _, view in { { 800, 360, true }, { 1280, 720, false } } do
			local at = view[1] .. "x" .. view[2]
			local h = harness({ width = view[1], height = view[2], touch = view[3], realHud = true, locale = "ko-kr" })
			h.packet(packet)
			local _, frame = sheetParts(h)
			h.hud.open("skills")
			h.step()
			local list, fade, more
			for _, item in frame:GetDescendants() do
				list = list or (if item.Name == "SkillCategories" then item else nil)
				fade = fade or (if item.Name == "SkillMoreFade" then item else nil)
				more = more or (if item.Name == "SkillMore" then item else nil)
			end
			assert(list and fade and more, "skills grid, fade and pill at " .. at)
			assert(list.ScrollBarThickness >= 10 and list.ScrollBarImageTransparency == 0, "bold bar at " .. at)
			local cells = 0
			for _, child in list:GetChildren() do
				cells += if child.ClassName == "TextButton" then 1 else 0
			end
			local grid = list:FindFirstChildOfClass("UIGridLayout")
			local canvas = math.ceil(cells / 2) * (grid.CellSize.Y.Offset + grid.CellPadding.Y.Offset)
			local height = list.AbsoluteSize.Y
			if view[1] == 800 then
				assert(canvas > height, string.format("phone grid %d px in %d px: expected to scroll", canvas, height))
			end
			assert(fade.Visible == (canvas - height > 8), string.format("fade at %s (%d in %d)", at, canvas, height))
			if fade.Visible then
				assert(more.Text == "아래에 더 있어요", "pill text " .. more.Text)
				assert(more.TextSize >= 14, "pill text size at " .. at)
				list.CanvasPosition = roblox.Vector2.new(0, canvas - height)
				list:GetPropertyChangedSignal("CanvasPosition"):Fire()
				assert(not fade.Visible, "hint clears at the bottom at " .. at)
			end
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	-- sheets4 (phone v61 build sheet 3/5): cards grouped by tab (shelter, storage, stations, farm, deco),
	-- each with kit art, material chips whose have/need count is green when covered and red when short,
	-- one Build button that starts placement, and the green / red footprint hint. Fits 800x360 and 1280x720.
	["sheets4: build cards sit in group tabs with art, green/red material chips and one Build button"] = function()
		local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
		local packet = {
			revision = 1,
			durable = { actions = { "survival-coop:settlement-reserve" }, epochs = {} },
			snapshots = {
				["survival-coop"] = {
					progression = { level = 3, sp = 0, xp = 0, paid = {}, version = 1 },
					inventory = {},
					warehouse = {
						kind = "warehouse",
						items = {
							w = {
								itemId = "w",
								catalogId = "wood",
								quantity = 6,
								qualityMilli = 1000,
								durabilityMilli = 0,
							},
						},
						reservations = {},
					},
				},
				survivalExtensions = {},
			},
		}
		local content: any = require("./src/shared/SurvivalContent")
		for _, view in { { 800, 360, true }, { 1280, 720, false } } do
			local at = view[1] .. "x" .. view[2]
			local h = harness({ width = view[1], height = view[2], touch = view[3], realHud = true, locale = "ko-kr" })
			h.packet(packet)
			local _, frame = sheetParts(h)
			h.hud.open("build")
			h.step()
			local scroll = assert(frame:FindFirstChild("Content"), "sheet scroll")
			-- sheets4b: the tabs and the (?) hint toggle live in the header, between the title and Close.
			local header = frame:FindFirstChild("Header")
			local head = assert(header:FindFirstChild("BuildHead"), "build header strip at " .. at)
			local tabs = assert(head:FindFirstChild("BuildTabs"), "build tabs in the header at " .. at)
			assert(scroll:FindFirstChild("BuildTabs") == nil, "no tab row in the body at " .. at)
			local cards = assert(scroll:FindFirstChild("BuildCards"), "build cards")
			local hr, cr2 = h.rect(head), h.rect(header:FindFirstChild("Close"))
			local tr = h.rect(header:FindFirstChild("Title"))
			assert(hr.x + hr.width <= cr2.x + 0.5, "tab strip clears Close at " .. at)
			assert(tr.x + tr.width <= hr.x + 0.5, "title clears the tab strip at " .. at)
			assert(hr.y >= h.rect(header).y - 0.5 and hr.height <= 44, "tab strip inside the header at " .. at)
			local seen = {}
			for _, group in Model.BUILD_GROUPS do
				local tab = assert(tabs:FindFirstChild("BuildTab-" .. group), group .. " tab at " .. at)
				assert(tab.Visible and tab:GetAttribute("ForgeLabel") ~= "", group .. " tab label")
				-- Phone: icon-only 40 px tabs (the label stays as an attribute); PC: the label shows.
				if view[3] then
					assert(tab.Text == "" and tab.Size.X.Offset == 40, group .. " icon-only tab on the phone")
				else
					assert(tab.Text == tab:GetAttribute("ForgeLabel"), group .. " labelled tab on PC")
					assert(tab.TextSize >= 16, group .. " tab text floor on PC")
				end
				assert(tab.Size.Y.Offset >= 36, group .. " tab touch height")
				local icon = tab:FindFirstChild("IconFallback")
				assert(icon and icon:FindFirstChild("Asset"), group .. " tab icon from the atlas")
				h.click(tab)
				assert(tab:GetAttribute("ForgeSelected") == true, group .. " tab selected")
				local shown = {}
				for _, card in cards:GetChildren() do
					if card.ClassName == "Frame" and card.Visible then
						table.insert(shown, card)
					end
				end
				local expected = Model.buildList(content.structures, group)
				assert(
					#shown == #expected and #shown > 0,
					string.format("%s: %d cards, want %d", group, #shown, #expected)
				)
				for _, card in shown do
					local id = string.sub(card.Name, 11)
					assert(not seen[id], id .. " in two tabs")
					seen[id] = true
					assert(Model.buildGroup({ id = id, station = false }) ~= nil, id)
					local art = card:FindFirstChild("ArtBed") and card.ArtBed:FindFirstChild("IconFallback")
					local image = art and art:FindFirstChild("Asset")
					assert(image and string.match(image.Image, "^rbxassetid://%d+$"), id .. " card art at " .. at)
					local builds = 0
					for _, child in card:GetChildren() do
						if child.ClassName == "TextButton" then
							builds += 1
							assert(
								child.Name == "Structure-" .. id and child.Text == "건설",
								id .. " build button " .. child.Text
							)
							local cell = cards:FindFirstChildOfClass("UIGridLayout").CellSize
							local bottom = child.Position.Y.Scale * cell.Y.Offset
								+ child.Position.Y.Offset
								+ child.Size.Y.Offset
							assert(bottom <= cell.Y.Offset and child.Size.Y.Offset >= 40, id .. " build inside card")
						elseif string.sub(child.Name, 1, 5) == "Cost-" then
							local count = assert(child:FindFirstChild("RowCount"), "count")
							local have, need = string.match(count.Text, "^(%d+)/(%d+)$")
							assert(have and need, id .. " have/need " .. count.Text)
							local green = tonumber(have) >= tonumber(need)
							local c = count.TextColor3
							if green then
								assert(c.G > c.R, id .. " covered count is green at " .. at)
							else
								assert(c.R > c.G, id .. " short count is red at " .. at)
							end
							local name = assert(child:FindFirstChild("RowName"), "name")
							local nr, cr = h.rect(name), h.rect(count)
							assert(nr.x + nr.width <= cr.x + 0.5, id .. " name clears count at " .. at)
							assert(cr.x + cr.width <= h.rect(child).x + h.rect(child).width + 0.5, "count inside chip")
							assert(name.TextSize >= 14 and count.TextSize >= 14, "chip text floor")
						end
					end
					assert(builds == 1, id .. " has " .. builds .. " buttons at " .. at)
					local grid = cards:FindFirstChildOfClass("UIGridLayout")
					local columns = math.floor(1 / grid.CellSize.X.Scale + 0.5)
					local width = h.rect(cards).width
					local cellWidth = grid.CellSize.X.Scale * width + grid.CellSize.X.Offset
					assert(
						columns * cellWidth + (columns - 1) * grid.CellPadding.X.Offset <= width + 0.5,
						id .. " cards clipped sideways at " .. at
					)
				end
			end
			for _, definition in content.structures do
				assert(seen[definition.id], definition.id .. " is in no tab")
			end
			-- Wood 6/4 covers the campfire: green, ready badge.
			h.click(tabs:FindFirstChild("BuildTab-station"))
			local camp = assert(cards:FindFirstChild("BuildCard-campfire"), "campfire card")
			assert(camp:FindFirstChild("ReadyBadge").Visible, "campfire ready with 6 wood")
			-- sheets4b: the cards start the body, so the first card row is whole without scrolling.
			local function hintShown(): boolean
				for _, item in scroll:GetChildren() do
					if item.ClassName == "TextLabel" and item.Visible and string.find(item.Text, "초록", 1, true) then
						return true
					end
				end
				return false
			end
			assert(not hintShown(), "placement hint folded behind (?) at " .. at)
			local grid = cards:FindFirstChildOfClass("UIGridLayout")
			local body = h.rect(scroll)
			local before = 8 -- scroll top padding; nothing else above the cards
			for _, item in scroll:GetChildren() do
				if
					item.Visible ~= false
					and item ~= cards
					and item.ClassName ~= "UIListLayout"
					and item.ClassName ~= "UIPadding"
				then
					assert((item.LayoutOrder or 0) > cards.LayoutOrder, item.Name .. " above the cards at " .. at)
				end
			end
			assert(
				before + grid.CellSize.Y.Offset <= body.height,
				string.format(
					"first card row %d px in a %d px body at %s",
					before + grid.CellSize.Y.Offset,
					body.height,
					at
				)
			)
			h.click(head:FindFirstChild("BuildHelp"))
			assert(hintShown(), "(?) shows the placement preview hint at " .. at)
			h.click(head:FindFirstChild("BuildHelp"))
			assert(not hintShown(), "(?) folds the hint again at " .. at)
			h.click(camp:FindFirstChild("Structure-campfire"))
			assert(not frame.Visible, "Build starts placement (sheet yields to the placement bar) at " .. at)
			assert(#h.errors == 0, table.concat(h.errors, "; "))
		end
	end,
	["L9: the down panel renders its cards with pack art and no script error"] = function()
		local h = harness({ width = 800, height = 360, touch = true })
		h.publish({ rescue = { down = true, options = { "rift", "camp", "rescue" }, flares = {} } })
		h.publish({ rescue = { down = true, options = { "rift", "camp", "rescue" }, flares = {} } })
		assert(#h.errors == 0, table.concat(h.errors, "; "))
		local gui = assert(h.playerGui:FindFirstChild("ForgeDownPanel"), "down panel gui")
		assert(gui.Enabled == true, "down panel shows while down")
		local shown = 0
		for _, card in gui:GetDescendants() do
			if card.Name == "DownCard" and card.Visible then
				local inner = card:FindFirstChild("Icon") and card.Icon:FindFirstChild("Image")
				assert(
					inner and string.match(inner.Image, "^rbxassetid://%d+$"),
					"card art for " .. tostring(card:GetAttribute("ForgeIcon"))
				)
				shown += 1
			end
		end
		assert(shown == 3, "three down cards, got " .. shown)
	end,
	-- Single-player mode (owner: multiplayer on hold; game.yml play_mode): no screen that only acts
	-- on other players is reachable from the menu or the navigator, the HUD row has no chat token,
	-- and the camp panel (from the camp sheet's 프로젝트) shows no visitor / rejoin chips, no friend
	-- visit, no item picker and no loans: one 재료 넣기 per project.
	["solo: menu, navigator, HUD row and camp panel show nothing that needs another player"] = function()
		local PlayMode = require("./src/shared/PlayMode")
		local CAMP_SLICE = {
			role = "member",
			version = 2,
			rung = 0,
			facilities = {},
			completed = {},
			active = {},
			cooldowns = { ["9"] = 99999 },
			passes = { ["8"] = { expiresAt = 99999999999 } },
			loans = {},
			ladder = {
				rungs = { { rung = 1, completions = 1, facility = "camp-cache" } },
				projects = {
					windbreak = { id = "windbreak", rung = 1, cost = { { item = "fiber", quantity = 40 } } },
				},
				leagueRung = 1,
			},
		}
		for _, view in { { 800, 360, true }, { 1280, 720, false } } do
			local at = view[1] .. "x" .. view[2]
			local h = harness({
				width = view[1],
				height = view[2],
				touch = view[3],
				realHud = true,
				chat = PlayMode.chat,
				clanTag = PlayMode.clanTag,
			})
			h.packet({
				revision = 1,
				durable = { actions = { "survival-coop:camp-contribute" }, epochs = {} },
				snapshots = {
					["survival-coop"] = {
						inventory = {
							{
								kind = "carried",
								items = {
									f = {
										itemId = "f",
										catalogId = "fiber",
										quantity = 12,
										qualityMilli = 1000,
										durabilityMilli = 0,
									},
								},
								reservations = {},
							},
						},
					},
					survivalExtensions = { camp = CAMP_SLICE, market = MARKET, operations = {} },
				},
			})
			for _, tile in h.tiles() do
				local id = string.sub(tile.Name, 6)
				assert(not (PlayMode.held[id] and tile.Visible), id .. " (other players only) is on the menu at " .. at)
			end
			-- Navigator: no row leads to a held screen, and the 함께 (Together) row is gone.
			h.click(h.toggle)
			h.click(h.tile("navigator"))
			local rows = {}
			for _, item in h.playerGui:GetDescendants() do
				if item.ClassName == "TextButton" and string.sub(item.Name, 1, 4) == "Nav-" then
					local id = string.sub(item.Name, 5)
					table.insert(rows, id)
					assert(not PlayMode.held[id], "navigator row " .. id .. " opens a held screen at " .. at)
				end
			end
			assert(#rows > 10, "navigator rows at " .. at .. ": " .. #rows)
			assert(not table.find(rows, "camp"), "the Together row (camp) is on the solo navigator at " .. at)
			for _, sheet in h.sheets() do
				h.click(sheet.close)
			end
			-- HUD row: menu + emote, no chat token.
			local hudGui = assert(h.playerGui:FindFirstChild("ForgeSurvivalHUD"), "hud")
			assert(hudGui:FindFirstChild("Token-emote"), "emote token at " .. at)
			assert(not hudGui:FindFirstChild("Token-chat"), "chat token on the solo HUD at " .. at)
			-- Camp panel (the camp sheet's 프로젝트 button): no chips, no visit, no picker, no loans.
			local camp = assert(h.playerGui:FindFirstChild("CampPanel"), "camp panel gui")
			local texts, names = {}, {}
			for _, item in camp:GetDescendants() do
				if (item.ClassName == "TextLabel" or item.ClassName == "TextButton") and item.Text ~= "" then
					table.insert(texts, item.Text)
				end
				names[item.Name] = item
			end
			local all = table.concat(texts, " | ")
			for _, word in { "방문자", "재가입", "방문", "빌려", "기부" } do
				assert(not string.find(all, word, 1, true), word .. " on the solo camp panel at " .. at .. ": " .. all)
			end
			assert(not names.ItemPicker, "item picker on the solo camp panel")
			local put = assert(names["PutIn-windbreak"], "재료 넣기 on the windbreak at " .. at .. ": " .. all)
			assert(put.Text == "재료 넣기", "solo action: " .. put.Text)
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	-- Solo follow-up (after captures: 파티 still opened via ForgeQAOpen and told the player to invite
	-- others). Party, players, clan and trade-with-player sheets have no way in: not the menu, not a
	-- navigator row, not ctx.open (QA, shortcuts, in-panel buttons). The trading post keeps only the
	-- harbor (NPC) sell tab, and score import drops the shared score-id lookup.
	["solo: no route into a multiplayer-only sheet; navigator rows all work alone"] = function()
		local PlayMode = require("./src/shared/PlayMode")
		-- Every navigator row id in solo, and the reason it works alone.
		local SOLO_ROWS = {
			survival = "camp projects (one contributor)",
			craft = "own recipes",
			build = "own island",
			skills = "own skill points",
			journal = "own quests",
			explore = "routes depart alone",
			market = "harbor (NPC) sell only",
			music = "own instrument",
			["score-import"] = "own JSON score; no shared score-id lookup",
			inbox = "own craft jobs, expedition results and market claims",
			["recipe-tracker"] = "own recipes",
			["score-library"] = "own saved scores",
			["build-manage"] = "own pieces",
			arrival = "own route arrival",
			jobs = "own craft jobs",
			audio = "settings",
		}
		for _, view in { { 800, 360, true }, { 1280, 720, false } } do
			local at = view[1] .. "x" .. view[2]
			local h = harness({ width = view[1], height = view[2], touch = view[3] })
			h.publish({
				market = MARKET,
				["harbor-buyback"] = { prices = { antler = 4 }, remaining = 50, dailyUnits = 50 },
			})
			h.click(h.toggle)
			h.click(h.tile("navigator"))
			local rows = {}
			for _, item in h.playerGui:GetDescendants() do
				if item.ClassName == "TextButton" and string.sub(item.Name, 1, 4) == "Nav-" then
					local id = string.sub(item.Name, 5)
					table.insert(rows, id)
					assert(SOLO_ROWS[id], "navigator row " .. id .. " is not on the solo list at " .. at)
				end
			end
			assert(#rows >= 12, "solo navigator rows at " .. at .. ": " .. table.concat(rows, ","))
			for _, sheet in h.sheets() do
				h.click(sheet.close)
			end
			-- Party, players, clan, direct trade and every other held sheet: ctx.open (ForgeQAOpen,
			-- shortcuts, in-panel buttons) refuses, and nothing comes on screen.
			for id in PlayMode.held do
				assert(h.panels.open(id) == false, id .. " opened by id in solo at " .. at)
				h.step()
				assert(#h.sheets() == 0, id .. " put a sheet on screen in solo at " .. at)
			end
			-- Trading post: one tab (sell to the harbor), no list price, no buy, no collection box.
			assert(h.panels.open("market"), "market opens at " .. at)
			h.step()
			local open = h.sheets()
			assert(#open == 1 and open[1].frame.Name == "TradeSheet", "trading post at " .. at)
			local market = open[1].frame
			local texts = {}
			for _, item in market:GetDescendants() do
				if (item.ClassName == "TextLabel" or item.ClassName == "TextButton") and item.Text ~= "" then
					table.insert(texts, item.Text)
				end
			end
			local all = table.concat(texts, " | ")
			assert(string.find(all, "항구에 팔기", 1, true), "harbor sell tab at " .. at .. ": " .. all)
			for _, word in { "사기", "내 물건", "수령함", "등록", "수수료", "묶음 가격" } do
				assert(
					not string.find(all, word, 1, true),
					word .. " on the solo trading post at " .. at .. ": " .. all
				)
			end
			assert(string.find(all, "개당 4", 1, true) or string.find(all, "4", 1, true), "harbor price at " .. at)
			for _, sheet in h.sheets() do
				h.click(sheet.close)
			end
			-- Score import: JSON stays, the shared score-id lookup is gone.
			assert(h.panels.open("score-import"), "score import opens at " .. at)
			local named = {}
			for _, item in h.playerGui:GetDescendants() do
				named[item.Name] = true
			end
			assert(named.ImportText, "JSON import box at " .. at)
			assert(not named.ScoreLookup, "shared score-id lookup in solo at " .. at)
			assert(#h.errors == 0, table.concat(h.errors, "; "))
		end
	end,
	-- p134 v61 phone text leftovers: craft time "3s", desktop key hints on a phone ("가방(I)을",
	-- "Y로 회전한 뒤"), the "* 꼰 끈" favorite asterisk and "내구도 0" on a material in the bag.
	["v61 text: Korean craft seconds, no key hints on a phone, no asterisk, no durability on materials"] = function()
		local function stack(id: string, catalogId: string, quantity: number): any
			return {
				itemId = id,
				catalogId = catalogId,
				quantity = quantity,
				qualityMilli = 1000,
				durabilityMilli = 0,
				attributes = {},
			}
		end
		local actions = {}
		for _, verb in { "food", "gear-equip", "craft-reserve", "recipe-mark", "building-place" } do
			table.insert(actions, "survival-coop:" .. verb)
		end
		for _, view in { { 800, 360, true }, { 1280, 720, false } } do
			local at = view[1] .. "x" .. view[2]
			local touch = view[3]
			local h = harness({ width = view[1], height = view[2], touch = touch, realHud = true, locale = "ko-kr" })
			h.packet({
				revision = 1,
				durable = { actions = actions, epochs = {} },
				snapshots = {
					["survival-coop"] = {
						vitals = { healthMilli = 90000, hungerMilli = 10000, fatigueMilli = 0 },
						progression = { level = 2, sp = 0, xp = 0, paid = {}, version = 1 },
						recipeMarks = { favorites = { cord = true }, todo = {} },
						-- Keyed by container name, as CraftingAdapter publishes it.
						inventory = {
							bag = {
								kind = "carried",
								items = {
									c = stack("c", "cord", 2),
									b = stack("b", "berry", 3),
									f = stack("f", "fiber", 9),
								},
								reservations = {},
								limits = { slots = 20, softWeightMilli = 40000, hardWeightMilli = 60000 },
								weightMilli = 1000,
							},
						},
					},
					survivalExtensions = {},
				},
			})
			local gui, frame = sheetParts(h)
			local function texts(root: any): string
				local out = {}
				for _, item in root:GetDescendants() do
					if (item.ClassName == "TextLabel" or item.ClassName == "TextButton") and item.Text ~= "" then
						table.insert(out, item.Text)
					end
				end
				return table.concat(out, " | ")
			end
			-- Hunger caption (status line): the bag key only with a keyboard.
			local status = texts(gui)
			assert(string.find(status, "배가 고파요", 1, true), "hunger caption at " .. at .. ": " .. status)
			assert(
				(string.find(status, "(I)", 1, true) ~= nil) == not touch,
				"hunger (I) hint at " .. at .. ": " .. status
			)
			h.hud.open("craft")
			h.step()
			local craft = texts(frame)
			assert(not string.find(craft, "* ", 1, true), "asterisk in the craft list at " .. at .. ": " .. craft)
			assert(string.find(craft, "%d초"), "craft time in 초 at " .. at .. ": " .. craft)
			assert(not string.find(craft, "%d+s%f[%A]"), "craft time in s at " .. at .. ": " .. craft)
			h.hud.open("build")
			h.step()
			-- sheets4b: the build hint sits behind the header's (?) toggle.
			h.click(frame:FindFirstChild("Header"):FindFirstChild("BuildHead"):FindFirstChild("BuildHelp"))
			local build = texts(frame)
			assert(string.find(build, "바닥을 터치하세요", 1, true), "build hint at " .. at)
			assert((string.find(build, "Y로", 1, true) ~= nil) == not touch, "Y hint at " .. at .. ": " .. build)
			assert(not string.find(build, "{{", 1, true), "raw hint braces at " .. at)
			h.hud.open("bag")
			h.step()
			for _, item in frame:GetDescendants() do
				if item.ClassName == "TextButton" and string.find(item.Text, "꼰 끈", 1, true) then
					h.click(item)
					break
				end
			end
			local bag = texts(frame)
			assert(string.find(bag, "품질", 1, true), "item detail open at " .. at .. ": " .. bag)
			assert(not string.find(bag, "내구도 0", 1, true), "durability 0 on a material at " .. at .. ": " .. bag)
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	-- p134 v61: the "아래에 더 있어요" pill sat on the faded row and touched its name, and the
	-- parchment-tinted bar could not be seen in a still capture.
	["v61 skills: the more pill has its own strip under the grid and the bar is dark on a track"] = function()
		local packet = {
			revision = 1,
			durable = { actions = { "survival-coop:skill-learn" }, epochs = {} },
			snapshots = {
				["survival-coop"] = {
					progression = { level = 1, sp = 3, xp = 0, paid = {}, version = 1 },
					inventory = {},
				},
				survivalExtensions = {},
			},
		}
		local h = harness({ width = 800, height = 360, touch = true, realHud = true, locale = "ko-kr" })
		h.packet(packet)
		local _, frame = sheetParts(h)
		h.hud.open("skills")
		h.step()
		local list, more, track
		for _, item in frame:GetDescendants() do
			list = list or (if item.Name == "SkillCategories" then item else nil)
			more = more or (if item.Name == "SkillMore" then item else nil)
			track = track or (if item.Name == "SkillScrollTrack" then item else nil)
		end
		assert(list and more, "grid and pill")
		local bar = list.ScrollBarImageColor3
		assert(bar.R + bar.G + bar.B < 1.2, string.format("bar too light (%.2f %.2f %.2f)", bar.R, bar.G, bar.B))
		assert(track and track.Visible and track.BackgroundTransparency < 0.5, "visible scroll track")
		assert(more.Text ~= "", "pill shows at the top")
		local pill, grid = h.rect(more), h.rect(list)
		assert(
			pill.y >= grid.y + grid.height,
			string.format("pill (y %d) overlaps the grid rows (bottom %d)", pill.y, grid.y + grid.height)
		)
		assert(#h.errors == 0, table.concat(h.errors, "\n"))
	end,
}
