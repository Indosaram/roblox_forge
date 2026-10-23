--!strict
-- G004 layout audit: every robango-island screen at PC 1280x720 and mobile 360x640.
-- Geometry comes from the same pure functions the client places frames with.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local Panels = require("../../genres/survival-coop/module/ExtensionPanels")
local Clan = require("../../genres/survival-coop/module/ClanPanel")
local Editor = require("../../genres/survival-coop/module/ScoreEditorPanel")
local Brawl = require("../../genres/survival-coop/module/BrawlPanel")
local Locale = require("../../genres/survival-coop/module/SurvivalHUDLocale")
local HudFit = require("../../core/ui-kit/genre/HudFit")
local Content: any = require("./src/shared/SurvivalContent")
local EntityNames = require("./PackText.fixture").names
local Shop = require("../../genres/survival-coop/module/ShopPanel")
local Catalog: any = require("./src/shared/MonetizationCatalog")

local VIEWPORTS = { { 1280, 720, false }, { 360, 640, true } }
-- SurvivalHUD sheets also cover short landscape phones (Studio device-simulator 640x339).
local HUD_VIEWPORTS = { VIEWPORTS[1], VIEWPORTS[2], { 640, 339, true }, { 740, 360, true }, { 932, 430, true } }

local function overlaps(a: any, b: any): boolean
	return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

local function inside(rect: any, width: number, height: number, label: string)
	assert(
		rect.x >= 0 and rect.y >= 0 and rect.x + rect.width <= width and rect.y + rect.height <= height,
		label .. " clipped at " .. width .. "x" .. height
	)
	assert(rect.width > 0 and rect.height > 0, label .. " blank at " .. width .. "x" .. height)
end

-- Fitted sheet rect exactly as ExtensionPanels.place computes it for contextual packs (dockGui
-- is a full-viewport ScreenGui with CoreUISafeInsets, so no SafeArea offset).
local function sheet(width: number, height: number, touch: boolean): any
	local x, y, sw, sh = Model.contextSheet(width, height, touch)
	return { x = x, y = y, width = sw, height = sh }
end

-- Horizontal splits of one 48px row (scale x, scale width) inside a sheet's padded content width.
local ROWS: { [string]: { { number } } } = {
	shop = { { 0, 0.62 }, { 0.64, 0.36 } },
	taming = { { 0, 0.5 }, { 0.51, 0.23 }, { 0.76, 0.23 } },
	tamingOffer = { { 0, 0.62 }, { 0.64, 0.36 } },
	camp = { { 0, 0.52 }, { 0.54, 0.14 }, { 0.69, 0.14 }, { 0.84, 0.14 } },
	tamingActions = { { 0, 0.5 }, { 0.5, 0.5 } },
}

-- SurvivalHUD (contextual) sheet in viewport space: resize() feeds the SafeArea root
-- (viewport inset 12,8 and -24,-16) into SurvivalHUDModel.contextSheet.
local function hudSheet(width: number, height: number, touch: boolean): any
	local x, y, sw, sh = Model.contextSheet(width - 24, height - 16, touch)
	return { x = x + 12, y = y + 8, width = sw, height = sh }
end

-- Craft list/detail rects in sheet space, from SurvivalHUD's own fitPanes source.
local function craftPanes(width: number, height: number): (any, any)
	local source = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
	local first = assert(source:find("local function fitPanes()", 1, true))
	local last = assert(source:find("listPane:GetPropertyChangedSignal", first, true))
	local function dim(xs, xo, ys, yo)
		return { xs = xs, xo = xo, ys = ys, yo = yo }
	end
	local list: any, detail: any = { Position = dim(0, 0, 0, 0) }, {}
	luau.load(source:sub(first, last - 1) .. "fitPanes()", {
		environment = {
			Model = Model,
			sheet = { frame = { AbsoluteSize = { X = width, Y = height } } },
			panes = {},
			listPane = list,
			detailPane = detail,
			craftActions = { Visible = true },
			UDim2 = {
				new = dim,
				fromOffset = function(x, y)
					return dim(0, x, 0, y)
				end,
			},
			Enum = { AutomaticSize = { None = "None" } },
		},
	})()
	local function rect(pane: any): any
		local p = width - 16
		return {
			x = 8 + pane.Position.xs * p + pane.Position.xo,
			y = 44 + pane.Position.yo,
			width = pane.Size.xs * p + pane.Size.xo,
			height = pane.Size.yo,
		}
	end
	return rect(list), rect(detail)
end

-- Estimated text fit with HudFit.textWidth: every line wraps into width minus padding and the
-- wrapped lines (1.2 line height) fit height at some size between maxSize and minSize.
local function fits(text: string, width: number, height: number, maxSize: number, minSize: number, label: string)
	assert(text ~= "", label .. " blank")
	for size = maxSize, minSize, -1 do
		local lines = 0
		for _, line in string.split(text, "\n") do
			lines += math.max(1, math.ceil(HudFit.textWidth(line, size) / (width - HudFit.PADDING * 2)))
		end
		if lines * size * 1.2 <= height then
			return
		end
	end
	error(string.format("%s overflows %dx%d: %q", label, width, height, text))
end

local function disjoint(rects: { any }, label: string)
	for i, a in rects do
		assert(a.width >= 44 and a.height >= 40, label .. " control under touch size")
		for j = i + 1, #rects do
			assert(not overlaps(a, rects[j]), label .. " controls overlap")
		end
	end
end

-- Longest localized string of a list, by estimated width.
local function longest(list: { string }): string
	local best = ""
	for _, text in list do
		if HudFit.textWidth(text, 15) > HudFit.textWidth(best, 15) then
			best = text
		end
	end
	return best
end

local LOCALES = { "en-us", "ko-kr" }
local function namer(locale: string): (string) -> string
	local names = EntityNames(locale)
	return function(id: string): string
		return names[id] or Locale.text(locale, id)
	end
end
local function ids(list: { any }, name: (string) -> string): { string }
	local out = {}
	for _, entry in list do
		table.insert(out, name(entry.id))
	end
	return out
end

return {
	["every fitted sheet stays inside the viewport with a reachable header close"] = function()
		for _, viewport in HUD_VIEWPORTS do
			local width, height, touch = viewport[1], viewport[2], viewport[3]
			local rect = sheet(width, height, touch)
			-- shop, taming, camp, death-zone, market, journal, building, audio, clan input, clan,
			-- outposts and brawl all register through ctx.fitSheet and share this rect.
			inside(rect, width, height, "sheet")
			assert(rect.height >= 44 + 48 * 3, "header plus three 48px rows visible")
			local close = { x = rect.x + rect.width - 50, y = rect.y, width = 44, height = 44 }
			local title = { x = rect.x + 14, y = rect.y, width = rect.width - 70, height = 44 }
			inside(close, width, height, "sheet close")
			assert(not overlaps(close, title) and title.width > 0, "title clears close")
			local hud = Model.contextHudBounds(width, height)
			assert(not overlaps(rect, hud.biome), "sheet clears biome toast")
			-- BrawlPanel overlays its own close and unavailable notice inside the fitted root.
			local brawlClose = { x = rect.width - 100, y = rect.height - 56, width = 88, height = 44 }
			local notice = { x = 12, y = 12, width = rect.width - 24, height = 88 }
			inside(brawlClose, rect.width, rect.height, "brawl close")
			assert(not overlaps(brawlClose, notice), "brawl close clears notice")
		end
	end,
	["row controls in every sheet are disjoint and touch sized"] = function()
		for _, viewport in HUD_VIEWPORTS do
			local rect = sheet(viewport[1], viewport[2], viewport[3])
			local content = rect.width - 16 - 6
			for name, splits in ROWS do
				local controls = {}
				for _, split in splits do
					local control = { x = split[1] * content, y = 0, width = split[2] * content, height = 48 }
					inside(control, content, 48, name)
					assert(control.width >= 44, name .. " control under 44px at " .. viewport[1])
					for _, other in controls do
						assert(not overlaps(control, other), name .. " controls overlap at " .. viewport[1])
					end
					table.insert(controls, control)
				end
			end
		end
	end,
	["short landscape phones keep header and a full row in every extension sheet"] = function()
		local source = fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")
		local anchor = "HUDModel.contextSheet(size.X, size.Y, input.TouchEnabled)"
		assert(string.find(source, anchor, 1, true), "ExtensionPanels places sheets with the shared contextSheet")
		for i = 3, #HUD_VIEWPORTS do
			local width, height = HUD_VIEWPORTS[i][1], HUD_VIEWPORTS[i][2]
			local rect, at = sheet(width, height, true), width .. "x" .. height
			inside(rect, width, height, "sheet")
			-- Header 44 + one 48px row; contracts adds its 56px notice strip (scroll -100).
			assert(rect.height >= 44 + 48 and rect.height >= 100 + 48, "contracts notice plus one row at " .. at)
			assert(
				rect.x >= Model.THUMB_GUTTER and rect.x + rect.width <= width - Model.THUMB_GUTTER,
				"extension sheet clears thumb gutters at " .. at
			)
		end
	end,
	["shop rows show every SKU description inside the row at every HUD viewport"] = function()
		for _, viewport in HUD_VIEWPORTS do
			local rect = sheet(viewport[1], viewport[2], viewport[3])
			local content = rect.width - 16 - 6
			assert(rect.height >= 44 + Shop.ROW_HEIGHT + Shop.DESCRIPTION_HEIGHT, "one full shop row visible")
			for _, locale in LOCALES do
				local names = EntityNames(locale)
				for _, section in { Catalog.gamepasses, Catalog.products, Catalog.subscriptions } do
					for _, listing in section do
						local text = names["shopdesc:" .. listing.key]
						assert(text ~= nil and text ~= "", locale .. " description missing: " .. listing.key)
						local size = Shop.DESCRIPTION_TEXT_SIZE
						fits(text, content, Shop.DESCRIPTION_HEIGHT, size, size, "shop description " .. listing.key)
					end
				end
			end
		end
	end,
	["standalone panels fit both target viewports"] = function()
		for _, viewport in VIEWPORTS do
			local width, height = viewport[1], viewport[2]
			local clan = Clan.bounds(width, height)
			inside(clan, width, height, "clan")
			local editor = Editor.bounds(width, height)
			inside(editor, width, height, "score editor")
			local close = { x = editor.width - 92, y = 2, width = 88, height = 44 }
			assert(close.x >= 0 and close.y + close.height <= 48, "score editor close inside header strip")
			local brawl = Brawl.layout(width, height)
			inside({
				x = (width - brawl.width) / 2,
				y = (height - brawl.height) / 2,
				width = brawl.width,
				height = brawl.height,
			}, width, height, "brawl")
		end
	end,
	["menu HUD photo controls and biome toast fit without overlap"] = function()
		for _, viewport in VIEWPORTS do
			local width, height = viewport[1], viewport[2]
			local hud = Model.contextHudBounds(width, height)
			for key, rect in hud do
				inside(rect, width, height, key)
			end
			local menuWidth, columns, tileHeight, top = Panels.menuBounds(width, height)
			inside(
				{ x = (width - menuWidth) / 2, y = top, width = menuWidth, height = tileHeight },
				width,
				height,
				"menu"
			)
			assert((menuWidth - (columns - 1) * 6) / columns >= 44, "menu tile under 44px")
			-- Photo mode: UIGridLayout of 1/3 - 6 cells, 40px high, 4px row gap; Toggle stays hidden.
			local photo = { width = math.min(520, width - 24), height = 92 }
			local cell = photo.width / 3 - 6
			local rows = math.ceil(6 / 3)
			assert(cell >= 88, "photo button too narrow for its label")
			assert(rows * 40 + (rows - 1) * 4 <= photo.height, "photo buttons clipped")
		end
	end,
	["every panel string has non-empty English and Korean text"] = function()
		local sources = {
			"games/robango-island/src/client/RobangoIslandClient.client.luau",
		}
		for _, name in
			{
				"ShopPanel",
				"TamingPanel",
				"DeathZonePanel",
				"MarketPanel",
				"CampPanelModel",
				"BrawlPanel",
				"FarmCraftText",
			}
		do
			table.insert(sources, "genres/survival-coop/module/" .. name .. ".luau")
		end
		local count = 0
		for _, path in sources do
			for key, en, ko in fs.readFile(path):gmatch('([%w_]+) = { "([^"]*)", "([^"]*)" }') do
				count += 1
				-- brawl_feedback is the intentionally blank result slot filled after an action.
				assert(key == "brawl_feedback" or (en ~= "" and ko ~= ""), path .. " blank " .. key)
			end
		end
		assert(count > 100, "string tables discovered")
	end,
	["survival HUD sheets keep header and close inside both target viewports"] = function()
		local source = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		-- Mirrored constants below; fail loudly if SurvivalHUD drifts from them.
		for _, anchor in
			{
				"UDim2.new(0, 8, 1, -56), UDim2.new(1, -16, 0, 48)",
				"UDim2.fromOffset(8, 44), UDim2.new(1, -16, 0, bounds.height)",
				"child.Size = UDim2.new(1 / 3, -6, 0, 48)",
				"UDim2.new(1 / columns, -8, 0, 44 + rows * 40)",
				"elseif sheet.frame.AbsoluteSize.X >= 480 then 2",
				"UDim2.new(if wide then 0.52 else 1, if wide then -8 else 0, 0, 0)",
				"UDim2.fromOffset(328, 48), UDim2.new(0.5, -164, 1, -Model.PLACEMENT_BOTTOM)",
				'{ "RowName", name(id), UDim2.new(1, -72, 1, 0)',
				"UDim2.fromOffset(68, 40),",
			}
		do
			assert(string.find(source, anchor, 1, true), "SurvivalHUD layout constant moved: " .. anchor)
		end
		assert(
			string.find(fs.readFile("core/ui-kit/InventoryGrid.luau"), "UDim2.new(0.333, -6, 0, 92)", 1, true),
			"inventory cell constant moved"
		)
		for _, viewport in HUD_VIEWPORTS do
			local width, height, touch = viewport[1], viewport[2], viewport[3]
			local s = hudSheet(width, height, touch)
			inside(s, width, height, "survival sheet")
			assert(not overlaps(s, Model.contextHudBounds(width, height).biome), "survival sheet clears biome toast")
			local close = { x = s.width - 50, y = 0, width = 44, height = 44 }
			local title = { x = 14, y = 0, width = s.width - 70, height = 44 }
			inside(close, s.width, 44, "survival close")
			assert(not overlaps(close, title), "survival title clears close")
			for _, locale in LOCALES do
				for _, key in { "bag", "craft", "build", "skills" } do
					local text = Locale.text(locale, key)
					fits(if touch then (string.gsub(text, " %[%u%]$", "")) else text, title.width, 44, 18, 18, key)
				end
			end
		end
	end,
	["craft sheet keeps filter toggle pinned axe list detail and fixed footer apart"] = function()
		local rows = Model.recipeOrder({ items = {}, reservations = {} }, Content.recipes, function()
			return false
		end, Content.items, { pin = "starter-axe", jobs = {} })
		assert(rows[1] and rows[1].recipe.id == "starter-axe", "tutorial axe pinned first in filtered list")
		assert(#rows < #Content.recipes, "nearby filter narrows the list")
		for _, viewport in HUD_VIEWPORTS do
			local s = hudSheet(viewport[1], viewport[2], viewport[3])
			local list, detail = craftPanes(s.width, s.height)
			local footer = { x = 8, y = s.height - 56, width = s.width - 16, height = 48 }
			for _, rect in { list, detail, footer } do
				inside(rect, s.width, s.height, "craft pane")
			end
			disjoint({ list, detail, footer }, "craft panes")
			-- Filter toggle row then the pinned first recipe row, both without scrolling.
			assert(list.height >= 48 + 6 + 48, "filter toggle and pinned recipe visible")
			local buttons = {}
			for i = 0, 2 do
				table.insert(buttons, { x = i * footer.width / 3, y = 0, width = footer.width / 3 - 6, height = 48 })
			end
			disjoint(buttons, "craft footer")
			inside(buttons[3], footer.width, 48, "craft footer button")
			for _, locale in LOCALES do
				local name, t = namer(locale), function(key)
					return Locale.text(locale, key)
				end
				for _, key in { "craft_nearby", "craft_all" } do
					fits(t(key), list.width - 8, 48, 15, 10, "filter toggle")
				end
				local statuses = { t("reserve") .. " +", t("missing") }
				for _, recipe in Content.recipes do
					table.insert(statuses, t("station") .. ": " .. name(recipe.station or "hand"))
				end
				local recipe = longest(ids(Content.recipes, name)) .. "\n" .. longest(statuses)
				fits(recipe, list.width - 8 - 40, 48, 15, 10, "recipe row")
				for _, label in
					{
						t("reserve"),
						t("cancel"),
						t("Reserved") .. " / " .. t("start"),
						t("Running") .. " / " .. t("complete"),
						t("Ready") .. " / " .. t("complete"),
					}
				do
					fits(label, buttons[1].width, 48, 15, 10, "craft footer")
				end
				fits(longest(ids(Content.items, name)), detail.width - 8 - 40 - 72, 40, 15, 10, "ingredient name")
			end
		end
	end,
	["harbor sell, repair and home preset controls fit at 1280x720, 360x640 and 640x339"] = function()
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		local send = 'ctx.send("survival-coop:home-preset", { presets.id, { preset = preset } })'
		assert(string.find(client, send, 1, true), "preset button sends home-preset with the home id")
		-- Preset buttons are the sheet's first children (LayoutOrder -3..-1; every other child is 0).
		assert(string.find(client, "presets[preset].LayoutOrder = preset - 4", 1, true), "preset buttons first")
		local first = assert(string.find(client, "\tfor preset = 1, 3 do\n\t\tpresets[preset] = button(", 1, true))
		local last = assert(string.find(client, "\n\tend\n", first, true))
		for _, case in { { true, "ko-kr", "지형 2 적용됨" }, { false, "en-us", "Terrain 2: Patron Pass" } } do
			local status, presets, clicks = {}, {}, {}
			luau.load(string.sub(client, first, last + 5), {
				environment = {
					presets = presets,
					status = status,
					locale = case[2],
					HudLocale = Locale,
					button = function(_, fn)
						table.insert(clicks, fn)
						return {}
					end,
					ctx = {
						send = function(action)
							assert(action == "survival-coop:home-preset", action)
							return { ok = case[1], reason = "PRESET_LOCKED" }
						end,
					},
				},
			})()
			clicks[2]()
			assert(status.Text == case[3], "preset status: " .. tostring(status.Text))
		end
		local longestRaw = longest({ "wood", "stone", "fiber", "meat" })
		for _, viewport in { HUD_VIEWPORTS[1], HUD_VIEWPORTS[2], HUD_VIEWPORTS[3] } do
			local rect = sheet(viewport[1], viewport[2], viewport[3])
			inside(rect, viewport[1], viewport[2], "harbor/home sheet")
			-- Preset buttons: header 44 + top padding 8 + three 48px rows (6px gaps), no scrolling.
			inside(
				{ x = rect.x + 8, y = rect.y + 52, width = rect.width - 16, height = 48 },
				viewport[1],
				viewport[2],
				"preset row"
			)
			assert(52 + 156 <= rect.height, "preset buttons above the fold")
			-- Header plus the cap line, quantity box and Sell button (48px rows) at least scroll into view.
			assert(rect.height >= 44 + 48 * 2, "harbor cap and one sell row visible")
			local s = hudSheet(viewport[1], viewport[2], viewport[3])
			local panes = s.width - 16 - 8
			local detail = if s.width >= 600 then 0.48 * panes - 8 else panes
			for _, locale in LOCALES do
				local name = namer(locale)
				local function fmt(key: string, ...): string
					return string.format(Locale.text(locale, key), ...)
				end
				fits(fmt("harbor", 200, 200), rect.width - 16, 48, 15, 10, "harbor cap")
				fits(fmt("sell", name(longestRaw), 2), rect.width - 16, 48, 15, 10, "harbor sell")
				fits(fmt("preset", 3) .. " *", rect.width - 16, 48, 15, 10, "preset")
				fits(fmt("PRESET_LOCKED", 3), rect.width - 16, 48, 15, 10, "locked preset")
				fits(fmt("preset_applied", 3), rect.width - 16, 64, 15, 10, "preset applied")
				for _, reason in { "DAILY_CAP", "NOT_AT_HARBOR", "INSUFFICIENT_ITEMS", "INSUFFICIENT_FUNDS" } do
					fits(Locale.refusal(locale, reason), rect.width - 16, 48, 15, 10, reason)
				end
				fits(fmt("repair", 30), detail - 8, 48, 15, 10, "repair")
			end
		end
	end,
	["bag sheet grid detail and warehouse rows fit both target viewports"] = function()
		for _, viewport in HUD_VIEWPORTS do
			local s = hudSheet(viewport[1], viewport[2], viewport[3])
			local panes = s.width - 16 - 8
			local wide = s.width >= 600
			local list = { x = 0, y = 0, width = if wide then 0.52 * panes - 8 else panes, height = 300 }
			local detail = if wide
				then { x = 0.52 * panes + 8, y = 0, width = 0.48 * panes - 8, height = 300 }
				else { x = 0, y = 312, width = panes, height = 300 }
			inside(list, panes, 612, "bag list")
			inside(detail, panes, 612, "bag detail")
			disjoint({ list, detail }, "bag panes")
			local grid = list.width - 8
			local cell = grid * 0.333 - 6
			local cells = {}
			for i = 0, 2 do
				table.insert(cells, { x = i * (cell + 8), y = 0, width = cell, height = 92 })
			end
			disjoint(cells, "inventory grid")
			inside(cells[3], grid, 92, "inventory cell")
			for _, locale in LOCALES do
				local name = namer(locale)
				local item = longest(ids(Content.items, name))
				fits(item, cell - 8 + HudFit.PADDING * 2, 42, 12, 12, "inventory caption")
				for _, key in { "eat", "deposit" } do
					fits(Locale.text(locale, key), detail.width - 8, 48, 15, 10, key)
				end
				fits(
					Locale.text(locale, "withdraw") .. " - " .. item .. " x999",
					detail.width - 8,
					48,
					15,
					10,
					"withdraw"
				)
				fits(Locale.text(locale, "select"), detail.width - 8, 48, 15, 15, "select hint")
			end
		end
	end,
	["build sheet cards chips and placement bar fit both target viewports"] = function()
		local costRows = 1
		for _, definition in Content.structures do
			costRows = math.max(costRows, #definition.cost)
		end
		for _, viewport in HUD_VIEWPORTS do
			local width, height = viewport[1], viewport[2]
			local s = hudSheet(width, height, viewport[3])
			local cards = s.width - 16 - 8
			local columns = if s.width >= 600 then 3 elseif s.width >= 480 then 2 else 1
			local cell = { width = cards / columns - 8, height = 44 + costRows * 40 }
			local row = {}
			for i = 0, columns - 1 do
				table.insert(row, { x = i * (cell.width + 8), y = 0, width = cell.width, height = cell.height })
			end
			disjoint(row, "build cards")
			inside(row[columns], cards, cell.height, "build card")
			local title = { x = 40, y = 0, width = cell.width - 44, height = 40 }
			local parts = { { x = 6, y = 6, width = 28, height = 28 }, title }
			for i = 1, costRows do
				table.insert(parts, { x = 4, y = 42 + (i - 1) * 40, width = cell.width - 8, height = 40 })
			end
			for i, a in parts do
				inside(a, cell.width, cell.height, "card part")
				for j = i + 1, #parts do
					assert(not overlaps(a, parts[j]), "card parts overlap")
				end
			end
			local bar = { x = width / 2 - 164, y = height - Model.PLACEMENT_BOTTOM, width = 328, height = 48 }
			inside(bar, width, height, "placement bar")
			local placement = {
				{ x = 0, y = 0, width = 80, height = 48 },
				{ x = 88, y = 0, width = 116, height = 48 },
				{ x = 212, y = 0, width = 116, height = 48 },
			}
			disjoint(placement, "placement bar")
			for _, locale in LOCALES do
				local name, t = namer(locale), function(key)
					return Locale.text(locale, key)
				end
				fits(longest(ids(Content.structures, name)), title.width, 40, 15, 10, "structure title")
				local costs = {}
				for _, definition in Content.structures do
					for _, cost in definition.cost do
						table.insert(costs, name(cost.item))
					end
				end
				fits(longest(costs), cell.width - 8 - 40 - 72, 40, 15, 10, "cost chip name")
				fits(t("buildHint"), s.width - 24, 48, 15, 15, "build hint")
				fits(t("rotate"), 80, 48, 15, 10, "rotate")
				for _, key in { "place", "reserve", "cancel" } do
					fits(t(key), 116, 48, 15, 10, "placement " .. key)
				end
			end
		end
	end,
	["short landscape phones show one full row or card in every survival sheet"] = function()
		local costRows = 1
		for _, definition in Content.structures do
			costRows = math.max(costRows, #definition.cost)
		end
		for _, viewport in HUD_VIEWPORTS do
			local width, height, touch = viewport[1], viewport[2], viewport[3]
			local s = hudSheet(width, height, touch)
			inside(s, width, height, "survival sheet")
			-- Scroll body below the 44px header with 8px padding; first rows as each section renders them.
			local body = s.height - 44 - 8
			local at = width .. "x" .. height
			-- One whole build card fits the body once the hint scrolls away (cell 44 + rows * 40).
			assert(body >= 44 + costRows * 40, "one full build card at " .. at)
			assert(body >= 8 + 6 + 92, "bag capacity bar plus one inventory row at " .. at)
			assert(body >= 48 + 6 + 48, "skills level plus one skill row at " .. at)
			local list, detail = craftPanes(s.width, s.height)
			assert(list.height >= 48 + 6 + 48 and detail.height >= 48, "craft rows at " .. at)
			assert(math.max(list.y + list.height, detail.y + detail.height) <= s.height - 56, "craft footer " .. at)
			if touch and width > height then
				-- Thumbstick and jump button stay uncovered beside the sheet.
				assert(
					s.x >= 12 + Model.THUMB_GUTTER and s.x + s.width <= width - 12 - Model.THUMB_GUTTER,
					"gutters " .. at
				)
			end
		end
	end,
	["skills sheet buttons are full width touch rows with fitting labels"] = function()
		assert(#Content.skillNodes > 0, "skill nodes present")
		for _, viewport in HUD_VIEWPORTS do
			local s = hudSheet(viewport[1], viewport[2], viewport[3])
			local width = s.width - 16 - 8
			disjoint(
				{ { x = 0, y = 0, width = width, height = 48 }, { x = 0, y = 54, width = width, height = 48 } },
				"skills"
			)
			local nodes = {}
			for _, node in Content.skillNodes do
				table.insert(nodes, node.id .. " / " .. tostring(node.cost) .. " SP")
			end
			for _, locale in LOCALES do
				for _, label in
					{
						longest(nodes),
						Locale.text(locale, "skill_reset"),
						Locale.text(locale, "refresh"),
						Locale.text(locale, "cameraHelp"),
					}
				do
					fits(label, width, 48, 15, 10, "skills button")
				end
				fits("Level 100 / SP 999", width, 40, 15, 15, "skills level")
			end
		end
	end,
	["context menu shows a full tile row and scrolls to every tile at every HUD viewport"] = function()
		local source = fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")
		assert(string.find(source, "M.menuRect(size.X, size.Y, input.TouchEnabled)", 1, true), "dock uses menuRect")
		-- The canvas grows with the tile rows (menuCanvas), so every launcher scrolls into the viewport.
		assert(string.find(source, 'set(menuList, "CanvasSize", UDim2.fromOffset(0, canvas))', 1, true), "menu scrolls")
		for _, viewport in HUD_VIEWPORTS do
			-- The dock ScreenGui uses CoreUISafeInsets: touch phones lose the 56px topbar.
			local width, height, touch = viewport[1], viewport[2] - (if viewport[3] then 56 else 0), viewport[3]
			local x, y, w, h, columns, tile = Panels.menuRect(width, height, touch)
			x, y, w, h = Model.chatSafe(width, height, x, y, w, h)
			local at = width .. "x" .. height
			inside({ x = x, y = y, width = w, height = h }, width, height, "menu " .. at)
			assert(h >= tile, "menu shows one full " .. tile .. "px tile row at " .. at)
			local cell = math.floor((w - (columns - 1) * 6) / columns)
			assert(cell >= 44, "menu tile under 44px at " .. at)
		end
	end,
	["HUD coin chip fits beside vitals at every HUD viewport"] = function()
		for _, viewport in HUD_VIEWPORTS do
			local width, height = viewport[1], viewport[2]
			local hud = Model.contextHudBounds(width, height)
			-- SurvivalHUD places the 100x28 chip in SafeArea space (viewport minus 12,8), left of vitals.
			local hudSource = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
			assert(
				string.find(hudSource, "UDim2.fromOffset(hud.coins.x - 12, hud.coins.y - 8)", 1, true),
				"HUD chip anchor moved"
			)
			hud.coins = { x = hud.coins.x, y = hud.coins.y, width = 100, height = 28 }
			inside(hud.coins, width, height, "coins")
			for _, key in { "vitals", "objective", "menu", "biome" } do
				assert(not overlaps(hud.coins, hud[key]), "coins overlap " .. key .. " at " .. width)
			end
			for _, locale in LOCALES do
				fits(string.format(Locale.text(locale, "coins"), 999999), hud.coins.width, 28, 13, 10, "coins")
			end
		end
	end,
	["camp cost line fits under its project label"] = function()
		local Camp = require("../../genres/survival-coop/module/CampPanelModel")
		for _, viewport in HUD_VIEWPORTS do
			local content = sheet(viewport[1], viewport[2], viewport[3]).width - 16 - 6
			for _, locale in LOCALES do
				for _, project in Content.camp.projects do
					local costs = {}
					for _, cost in project.cost do
						table.insert(costs, { item = cost.item, delivered = cost.quantity, need = cost.quantity })
					end
					local line = Camp.costLine(locale, { costs = costs } :: any, EntityNames(locale))
					-- Full row width, below the 44px give button.
					fits(line, content, 18, 12, 9, "camp cost " .. project.id)
				end
			end
		end
	end,
}
