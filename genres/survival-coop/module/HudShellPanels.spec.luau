--!strict
-- Full-screen panels (ui-spec section 6, Robango C8): craft, trading post and bag at the two
-- SM-N981N landscape guis (800x360 and 850x411, CoreUISafeInsets so topClear 0) and a 1920x1080 PC
-- (top bar 58). Every rect sits inside the gui, nothing overlaps, touch targets stay >= 44 px and
-- text >= 13 px; the columns keep the spec's left-to-right order and width fractions.
local Shell = require("./HudShell")
local Locale = require("./SurvivalHUDLocale")
-- Installs the strings.csv lookup the genre text tables read.
local _packText = (require :: any)("../../../games/robango-island/PackText.fixture")

local VIEWS: { { any } } = {
	{ 800, 360, 0 },
	{ 850, 411, 0 },
	{ 1920, 1080, 58 },
}
local KINDS = { "craft", "market", "bag" }
local RECTS = { "title", "currency", "close", "categories", "list", "detailBody", "primary" }

local function label(kind: string, view: { any }, what: string): string
	return string.format("%s %dx%d: %s", kind, view[1], view[2], what)
end

return {
	["panels fit, never overlap and keep touch and text minimums"] = function()
		for _, view in VIEWS do
			for _, kind in KINDS do
				local p = Shell.panel(view[1], view[2], view[3], kind)
				assert(Shell.inside(p.frame, view[1], view[2], view[3]), label(kind, view, "frame inside"))
				assert(
					p.frame.y == view[3] and p.frame.height == view[2] - view[3],
					label(kind, view, "frame covers the safe area")
				)
				for _, id in RECTS do
					local r = (p :: any)[id]
					assert(Shell.inside(r, view[1], view[2], view[3]), label(kind, view, id .. " inside"))
					assert(r.width > 0 and r.height > 0, label(kind, view, id .. " not empty"))
				end
				for i, a in RECTS do
					for j = i + 1, #RECTS do
						local b = RECTS[j]
						assert(
							not Shell.overlaps((p :: any)[a], (p :: any)[b]),
							label(kind, view, a .. " overlaps " .. b)
						)
					end
				end
				-- Title bar items sit inside the bar; the columns below it.
				for _, id in { "title", "currency", "close" } do
					local r = (p :: any)[id]
					assert(
						r.y >= p.bar.y and r.y + r.height <= p.bar.y + p.bar.height,
						label(kind, view, id .. " in bar")
					)
				end
				for _, id in { "categories", "list", "detailBody", "primary" } do
					assert((p :: any)[id].y >= p.bar.y + p.bar.height, label(kind, view, id .. " under the bar"))
				end
				-- Touch targets and text.
				assert(
					p.close.width >= Shell.MIN_TOUCH and p.close.height >= Shell.MIN_TOUCH,
					label(kind, view, "close")
				)
				assert(p.primary.height >= Shell.MIN_TOUCH, label(kind, view, "primary height"))
				assert(p.categoryRow >= Shell.MIN_TOUCH and p.listRow >= Shell.MIN_TOUCH, label(kind, view, "rows"))
				if kind ~= "craft" then
					-- Bag grid (6 columns) and trading post category grid (4); craft uses list rows.
					assert(p.cell >= Shell.MIN_TOUCH, label(kind, view, "grid cell " .. p.cell))
				end
				for style, size in p.text do
					assert(size >= 13, label(kind, view, style .. " text " .. size))
				end
				-- Categories left, list middle, detail right, primary at the detail's bottom right.
				assert(p.categories.x + p.categories.width <= p.list.x, label(kind, view, "categories left"))
				assert(p.list.x + p.list.width <= p.detail.x, label(kind, view, "detail right"))
				assert(
					p.primary.x == p.detail.x and p.primary.y + p.primary.height == p.detail.y + p.detail.height,
					label(kind, view, "primary at the detail bottom")
				)
				-- At least two whole category rows and list rows fit their columns.
				assert(p.categories.height >= 2 * p.categoryRow, label(kind, view, "category rows fit"))
				assert(p.list.height >= 2 * p.listRow, label(kind, view, "list rows fit"))
			end
		end
	end,

	["column widths follow the spec fractions"] = function()
		for _, view in VIEWS do
			for _, kind in KINDS do
				local p = Shell.panel(view[1], view[2], view[3], kind)
				local body = p.categories.width + p.list.width + p.detail.width
				local want = Shell.PANEL_COLUMNS[kind]
				for index, id in { "categories", "list", "detail" } do
					local got = (p :: any)[id].width / body
					assert(math.abs(got - want[index]) <= 0.01, label(kind, view, id .. " width " .. got))
				end
			end
		end
	end,

	["phone category rail holds the label at 13 px"] = function()
		-- The narrowest rail is the trading post's at 800 px (0.12 SW): its tab labels are short words.
		local p = Shell.panel(800, 360, 0, "market")
		assert(p.categories.width >= 80, "market rail " .. p.categories.width)
		local craft = Shell.panel(800, 360, 0, "craft")
		assert(craft.categories.width >= 110, "craft rail " .. craft.categories.width)
	end,

	["categories: all first, spec order, only non-empty"] = function()
		local got = Shell.panelCategories({ "food", "tool", "wood", "armor", "tool" })
		assert(table.concat(got, ",") == "all,tool,clothing,food,material", table.concat(got, ","))
		assert(Shell.panelCategory("seed") == "farm" and Shell.panelCategory(nil) == "material", "mapping")
		assert(#Shell.panelCategories({}) == 1, "all only")
	end,

	["every panel label has KO and EN text"] = function()
		local keys = {}
		for _, id in Shell.PANEL_CATEGORY_ORDER do
			table.insert(keys, "cat." .. id)
		end
		for _, tab in Shell.MARKET_TABS do
			table.insert(keys, "panel.tab." .. tab)
		end
		for _, key in
			{
				"panel.trading_post",
				"panel.buy",
				"panel.list",
				"panel.withdraw",
				"panel.collect",
				"panel.equip",
				"panel.done",
				"panel.back",
				"panel.more",
				"panel.bundle",
				"panel.quantity",
				"panel.price",
				"panel.no_match",
				"panel.no_bundles",
				"panel.nothing_to_sell",
				"panel.no_listings",
				"panel.no_claims",
				"panel.market_unavailable",
			}
		do
			table.insert(keys, key)
		end
		for _, key in keys do
			local en, ko = Locale.text("en-us", key), Locale.text("ko-kr", key)
			assert(en ~= key and ko ~= key and en ~= ko, "KO/EN row for " .. key)
		end
	end,

	["price steppers are -100/-10/+10/+100 and stay positive"] = function()
		assert(table.concat(Shell.PRICE_STEPS, ",") == "-100,-10,10,100", "steps")
		assert(Shell.stepPrice(50, -100) == 1 and Shell.stepPrice(50, 10) == 60, "clamped")
		assert(#Shell.MARKET_TABS == 4 and Shell.MARKET_TABS[1] == "buy", "rail tabs")
	end,
}
