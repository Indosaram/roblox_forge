--!strict
local Model = require("./SurvivalHUDModel")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Locale = require("./SurvivalHUDLocale")

return {
	["focused recipes pin tutorial and retain pending jobs while all restores catalog"] = function()
		local recipes = {
			{ id = "remote", station = "kiln", inputs = { { item = "ore", quantity = 2 } } },
			{ id = "materials", station = "kiln", inputs = {} },
			{ id = "nearby", station = "workbench", inputs = { { item = "ore", quantity = 2 } } },
			{ id = "starter-axe", station = "workbench", inputs = {} },
		}
		local function station(id)
			return id == "workbench"
		end
		local filter: { pin: string, jobs: { [string]: boolean? }, all: boolean? } = { pin = "starter-axe", jobs = {} }
		local rows = Model.recipeOrder(nil, recipes, station, {}, filter)
		assert(#rows == 3 and rows[1].recipe.id == "starter-axe", "tutorial pinned before station groups")
		filter.jobs.remote = true
		assert(#Model.recipeOrder(nil, recipes, station, {}, filter) == 4, "job remains claimable away from station")
		filter.jobs.remote = nil
		filter.all = true
		assert(#Model.recipeOrder(nil, recipes, station, {}, filter) == 4, "all shows unavailable recipes")
	end,
	["crafting panes and fixed actions fit phone and desktop without scrolling"] = function()
		local source = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		local first = assert(source:find("local function fitPanes()", 1, true))
		local last = assert(source:find("listPane:GetPropertyChangedSignal", first, true))
		local dim = {
			new = function(xs, xo, ys, yo)
				return { x = xs, dx = xo, y = ys, dy = yo }
			end,
			fromOffset = function(x, y)
				return { x = 0, dx = x, y = 0, dy = y }
			end,
		}
		for _, size in { { 1280, 720 }, { 360, 640 } } do
			local w, h = Model.contextSheetBounds(size[1] - 24, size[2] - 72, size[1] < 700)
			local frame = { AbsoluteSize = { X = w, Y = h } }
			local panes: any, list: any, detail: any = {}, {}, {}
			luau.load(source:sub(first, last - 1) .. "fitPanes()", {
				environment = {
					Model = Model,
					sheet = { frame = frame },
					panes = panes,
					listPane = list,
					detailPane = detail,
					craftActions = { Visible = true },
					UDim2 = dim,
					Enum = { AutomaticSize = { None = "None" } },
				},
			})()
			assert(panes.Parent == frame and panes.Position.dy == 44, "catalog outside scrolling sheet below header")
			local right = detail.Position.x * (w - 16) + detail.Position.dx + detail.Size.x * (w - 16) + detail.Size.dx
			assert(right <= w - 16, "detail pane not clipped horizontally")
			local bottom = detail.Position.dy + detail.Size.dy + 44
			assert(bottom <= h - 64 and list.Size.dy >= 80, "panes clear fixed actions")
			assert(h - 56 >= bottom and h - 8 <= h, "48 pixel actions remain inside sheet")
		end
	end,
	["missing weapon refusal is surfaced on closed HUD for both locales"] = function()
		local source = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		local first = assert(source:find('if model.reason == "WEAPON_UNAVAILABLE"', 1, true))
		local last = assert(source:find("resultEvent:Fire", first, true))
		for _, locale in { "ko-KR", "en-US" } do
			local toast: any = { Visible = false }
			luau.load(source:sub(first, last - 1), {
				environment = {
					model = { reason = "WEAPON_UNAVAILABLE" },
					toast = toast,
					Locale = Locale,
					locale = locale,
				},
			})()
			assert(
				toast.Visible and toast.Text == Locale.refusal(locale, "WEAPON_UNAVAILABLE"),
				"visible localized refusal"
			)
			assert(toast.Text ~= Locale.refusal(locale, "unknown"), "actionable mapping exists")
		end
	end,
}
