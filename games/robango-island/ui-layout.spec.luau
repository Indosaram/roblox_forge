--!strict
-- G004 layout audit: every robango-island screen at PC 1280x720 and mobile 360x640.
-- Geometry comes from the same pure functions the client places frames with.
local fs = require("@lune/fs")
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local Panels = require("../../genres/survival-coop/module/ExtensionPanels")
local Clan = require("../../genres/survival-coop/module/ClanPanel")
local Editor = require("../../genres/survival-coop/module/ScoreEditorPanel")
local Brawl = require("../../genres/survival-coop/module/BrawlPanel")

local VIEWPORTS = { { 1280, 720, false }, { 360, 640, true } }

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

-- Fitted sheet rect exactly as ExtensionPanels.place computes it for contextual packs.
local function sheet(width: number, height: number, touch: boolean): any
	local w, h, top, right = Model.contextSheetBounds(width, height, touch)
	local x, y, sw, sh = Model.chatSafe(width, height, width - right - w, top, w, h)
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

return {
	["every fitted sheet stays inside the viewport with a reachable header close"] = function()
		for _, viewport in VIEWPORTS do
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
		for _, viewport in VIEWPORTS do
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
		for _, name in { "ShopPanel", "TamingPanel", "DeathZonePanel", "MarketPanel", "CampPanelModel", "BrawlPanel" } do
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
}
