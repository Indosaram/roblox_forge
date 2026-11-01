--!strict
-- R14 (D2 phone scoring 2.75): the solo trading post was a dark-teal panel whose sell tiles showed
-- only "x5". It renders here on the shipped panel wiring (PanelHarness: RobangoIslandClient's panel
-- section, the real ui-kit and the real SurvivalHUD) at the 2400x1080 SM-N981N landscape gui
-- (800x360 at 3x, 850x411 under the 58 px Studio band) and at a 1920x1080 PC, in ko-kr and en-us.
-- The sell sheet wears the craft sheet's Theme.sheet parchment, and every tile names the item and
-- shows its quality, held count and harbor unit price; the right column previews the sale and the
-- primary sells.
local harness = require("./PanelHarness.fixture").harness
local Theme = require("../../core/ui-kit/Theme")
local Locale = require("../../genres/survival-coop/module/SurvivalHUDLocale")
local Social = require("../../genres/survival-coop/module/SocialSheet")
local PackText = require("./PackText.fixture")

local VIEWS = { { 800, 360, 0, true }, { 850, 411, 58, true }, { 1920, 1080, 58, false } }
local PRICES = { antler = 4, berry = 1, fiber = 2 }

local function stack(id: string, catalogId: string, quantity: number, quality: number): any
	return {
		itemId = id,
		catalogId = catalogId,
		quantity = quantity,
		qualityMilli = quality * 1000,
		durabilityMilli = 0,
		attributes = {},
	}
end

local MARKET: any = {
	balance = 60,
	items = {
		a = stack("a", "antler", 5, 2),
		b = stack("b", "berry", 12, 1),
		f = stack("f", "fiber", 30, 0),
		s = stack("s", "stone-axe", 1, 1),
	},
	catalogIds = { "antler" },
	listed = {},
	listings = {},
	claims = {},
	page = 1,
	pages = 0,
	eligible = true,
}

local function same(c: any, token: any): boolean
	return math.floor(c.R * 255 + 0.5) == token.r
		and math.floor(c.G * 255 + 0.5) == token.g
		and math.floor(c.B * 255 + 0.5) == token.b
end

local function find(root: any, name: string): any
	for _, item in root:GetDescendants() do
		if item.Name == name then
			return item
		end
	end
	return nil
end

local function texts(root: any): { string }
	local out = {}
	for _, item in root:GetDescendants() do
		if (item.ClassName == "TextLabel" or item.ClassName == "TextButton") and item.Text ~= "" then
			table.insert(out, item.Text)
		end
	end
	return out
end

local function inside(r: any, bounds: any): boolean
	return r.x >= bounds.x - 0.5
		and r.y >= bounds.y - 0.5
		and r.x + r.width <= bounds.x + bounds.width + 0.5
		and r.y + r.height <= bounds.y + bounds.height + 0.5
end

-- Opens the solo trading post at `view` in `locale`; returns the harness and the sheet frame.
local function openMarket(view: { any }, locale: string): (any, any)
	local h = harness({
		width = view[1],
		height = view[2],
		inset = view[3],
		touch = view[4],
		locale = locale,
		realHud = true,
	})
	h.publish({
		market = MARKET,
		["harbor-buyback"] = { prices = PRICES, dailyUnits = 200, remaining = 140 },
	})
	assert(h.panels.open("market"), "market opens")
	h.step()
	local open = h.sheets()
	assert(#open == 1 and open[1].frame.Name == "TradeSheet", "trading post on screen")
	return h, open[1].frame
end

return {
	["R14: the solo sell sheet wears the craft sheet's parchment palette at phone and PC"] = function()
		local C = Theme.sheet.colors
		for _, view in VIEWS do
			for _, locale in { "ko-kr", "en-us" } do
				local where = string.format("%dx%d %s", view[1], view[2], locale)
				-- The craft sheet (SurvivalHUD) at the same screen: the palette the market must match.
				local h, frame = openMarket(view, locale)
				local gui = assert(h.playerGui:FindFirstChild("ForgeSurvivalHUD"), "survival hud")
				local craft = gui:FindFirstChild("SafeArea"):FindFirstChild("SurvivalSheet")
				h.hud.open("craft")
				h.step()
				local craftHeader = craft:FindFirstChild("Header")
				assert(same(craft.BackgroundColor3, C.body), where .. ": craft reference is parchment")
				local craftBody, craftBar = craft.BackgroundColor3, craftHeader.BackgroundColor3
				h.hud.close()
				h.step()
				local header = frame:FindFirstChild("Header")
				for _, pair in
					{
						{ frame.BackgroundColor3, craftBody, "body" },
						{ header.BackgroundColor3, craftBar, "header" },
					}
				do
					assert(
						pair[1] == pair[2],
						string.format(
							"%s: market %s %s is not the craft sheet's %s",
							where,
							pair[3],
							tostring(pair[1]),
							tostring(pair[2])
						)
					)
				end
				assert(frame.BackgroundTransparency == 0, where .. ": opaque parchment")
				-- Rail chips: the selected tab and category are sea-glass, the others parchment chips.
				local rail = assert(frame:FindFirstChild("Rail"), "rail")
				local tab, all = nil, nil
				for _, child in rail:GetChildren() do
					if child.ClassName == "TextButton" then
						if child.Name == "SellCategory-all" then
							all = child
						elseif child.Text == Locale.text(locale, "panel.tab.sell_solo") then
							tab = child
						end
					end
				end
				assert(tab and same(tab.BackgroundColor3, C.button), where .. ": selected sell tab is sea-glass")
				assert(all and same(all.BackgroundColor3, C.button), where .. ": selected 'all' category is sea-glass")
				local food = find(rail, "SellCategory-food")
				assert(food and same(food.BackgroundColor3, C.chip), where .. ": unselected category is a chip")
				assert(same(food.TextColor3, C.ink), where .. ": chip text is ink")
				local primary = assert(frame:FindFirstChild("Primary"), "primary")
				assert(primary.Visible and same(primary.BackgroundColor3, C.button), where .. ": primary is sea-glass")
				-- No dark-teal left anywhere in the sheet.
				for _, item in frame:GetDescendants() do
					local filled = item.BackgroundColor3 ~= nil and (item.BackgroundTransparency or 0) < 1
					if (item.ClassName == "Frame" or item.ClassName == "TextButton") and filled then
						local c = item.BackgroundColor3
						local teal = c.R < 0.2 and c.G > c.R + 0.05 and c.B > c.R + 0.05
						assert(not teal, string.format("%s: dark-teal %s %s", where, item.ClassName, item.Name))
					end
				end
				assert(#h.errors == 0, table.concat(h.errors, "\n"))
			end
		end
	end,
	["R14: every sell tile shows name, quality, held count and harbor price (KO/EN) and fits its cell"] = function()
		for _, view in VIEWS do
			for _, locale in { "ko-kr", "en-us" } do
				local where = string.format("%dx%d %s", view[1], view[2], locale)
				local names = PackText.names(locale)
				local h, frame = openMarket(view, locale)
				local tiles = assert(find(frame, "SellTiles"), where .. ": sell tile grid")
				local list = h.rect(frame:FindFirstChild("List"))
				-- UIGridLayout placement (the fake engine lays out offsets only): cells in LayoutOrder.
				local grid = tiles:FindFirstChildOfClass("UIGridLayout")
				local origin = h.rect(tiles)
				local size, gap = grid.CellSize, grid.CellPadding
				local across = math.max(1, (origin.width + gap.X.Offset) // (size.X.Offset + gap.X.Offset))
				local function cellRect(tile: any): any
					local index = tile.LayoutOrder - 1
					return {
						x = origin.x + (index % across) * (size.X.Offset + gap.X.Offset),
						y = origin.y + (index // across) * (size.Y.Offset + gap.Y.Offset),
						width = size.X.Offset,
						height = size.Y.Offset,
					}
				end
				local function labelRect(label: any, cell: any): any
					local p, s = label.Position, label.Size
					return {
						x = cell.x + p.X.Scale * cell.width + p.X.Offset,
						y = cell.y + p.Y.Scale * cell.height + p.Y.Offset,
						width = s.X.Scale * cell.width + s.X.Offset,
						height = s.Y.Scale * cell.height + s.Y.Offset,
					}
				end
				local seen = 0
				for _, tile in tiles:GetChildren() do
					if string.sub(tile.Name, 1, 9) ~= "SellTile-" then
						continue
					end
					seen += 1
					local item = MARKET.items[string.sub(tile.Name, 10)]
					local name = tile:FindFirstChild("TileName")
					assert(
						name and name.Text == names[item.catalogId],
						where .. ": tile name " .. tostring(name and name.Text)
					)
					local quality = assert(tile:FindFirstChild("TileMeta1"), "quality row")
					assert(
						quality.Text == Locale.text(locale, "quality") .. " " .. item.qualityMilli // 1000,
						where .. ": quality row " .. quality.Text
					)
					local held = assert(tile:FindFirstChild("TileMeta2"), "held row")
					assert(held.Text == string.format(Locale.text(locale, "panel.tile_held"), item.quantity), held.Text)
					local price = assert(tile:FindFirstChild("TilePrice"), "price row")
					assert(
						price.Text == string.format(Locale.text(locale, "panel.tile_price"), PRICES[item.catalogId]),
						where .. ": price row " .. price.Text
					)
					local cell = cellRect(tile)
					assert(cell.width >= 120 and cell.height >= 44, where .. ": tile touch size")
					assert(
						cell.x >= list.x - 0.5 and cell.x + cell.width <= list.x + list.width + 0.5,
						where .. ": tile in list"
					)
					for _, label in { name, quality, held, price } do
						assert(label.TextSize >= 14, where .. ": tile text " .. label.TextSize)
						local r = labelRect(label, cell)
						assert(inside(r, cell), where .. ": " .. label.Name .. " outside its tile")
						assert(
							Social.textWidth(label.Text, label.TextSize) <= r.width,
							string.format("%s: '%s' clipped (%d px row)", where, label.Text, r.width)
						)
					end
				end
				assert(seen == 3, where .. ": the three harbor-bought stacks are tiles, the axe is not: " .. seen)
				-- Detail: the picked stack's card, a sale preview and the primary sells it.
				local all = table.concat(texts(frame:FindFirstChild("Detail")), " | ")
				assert(find(frame, "SellCard"), where .. ": picked stack card")
				local preview = assert(find(frame, "SalePreview"), where .. ": sale preview")
				assert(
					preview.Text == string.format(Locale.text(locale, "panel.sale_preview"), 1, 4),
					where .. ": preview " .. preview.Text .. " | " .. all
				)
				local primary = frame:FindFirstChild("Primary")
				local label = string.format(Locale.text(locale, "sell"), names.antler, 4)
				assert(primary.Text == label, where .. ": primary " .. primary.Text)
				-- The harness transport refuses every command; the press still reports back in the sheet.
				h.click(primary)
				local status = find(frame, "MarketStatus")
				assert(status and status.Text ~= "", where .. ": the sell press reports back")
				-- Picking another tile moves the card and the primary to it.
				h.click(find(tiles, "SellTile-b"))
				assert(
					frame:FindFirstChild("Primary").Text == string.format(Locale.text(locale, "sell"), names.berry, 1),
					where .. ": primary follows the picked tile"
				)
				assert(#h.errors == 0, table.concat(h.errors, "\n"))
			end
		end
	end,
	["R14: the market tile copy has KO and EN rows"] = function()
		for _, key in
			{ "panel.tile_level", "panel.tile_held", "panel.tile_price", "panel.tile_no_price", "panel.sale_preview" }
		do
			local en, ko = Locale.text("en-us", key), Locale.text("ko-kr", key)
			assert(en ~= key and ko ~= key, "KO/EN row for " .. key)
		end
		local Panel = require("../../genres/survival-coop/module/CrossServerMarketPanel")
		local quality, held, price = Panel.tileLines("ko-kr", stack("x", "spear", 2, 3), nil)
		assert(quality == "품질 3" and held == "보유 2", quality .. " / " .. held)
		assert(price == Locale.text("ko-kr", "panel.tile_no_price"), price)
		local leveled = stack("y", "spear", 1, 2)
		leveled.attributes = { level = 7 }
		assert((Panel.tileLines("en-us", leveled, 9)) == "Quality 2 · Lv 7", "level joins the quality row")
		assert(select(3, Panel.tileLines("en-us", leveled, 9)) == "9 each", "unit price")
	end,
}
