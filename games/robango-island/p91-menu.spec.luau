--!strict
-- p91: the p83 Studio audit (PC 1280x720, mobile 360x640) failed the dock menu: every tile label
-- was 11px under an 11px category caption, the 360x640 grid showed only 3 of 13 rows, and the
-- menu offered context-only screens (dialogue, transaction, siege match/results) that opened
-- empty. This drives the real ExtensionPanels geometry and the real panel modules.
local fs = require("@lune/fs")
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local Panels = require("../../genres/survival-coop/module/ExtensionPanels")
local HudFit = require("../../core/ui-kit/genre/HudFit")

-- { width, height (below the 56px touch topbar inset), touch }.
local VIEWPORTS = { { 360, 584, true }, { 390, 788, true }, { 640, 339, true }, { 1280, 720, false } }
-- The longest dock labels robango registers (EN and KO).
local LABELS = {
	"Practice and instruments",
	"연습과 악기",
	"Clan membership",
	"부족 가입",
	"Recipe preview",
	"제작 미리보기",
	"Tamed animals",
	"길들인 동물",
	"Open journal",
	"Team siege",
	"Island view",
	"Crop book",
}

local function frame(width: number, height: number, touch: boolean): any
	local x, y, w, h, columns, tile = Panels.menuRect(width, height, touch)
	x, y, w, h = Model.chatSafe(width, height, x, y, w, h)
	return { x = x, y = y, width = w, height = Panels.menuRows(h, tile), columns = columns, tile = tile }
end

return {
	["menu tile labels are at least 14px and fit two lines beside the icon at every viewport"] = function()
		assert(Panels.MENU_LABEL_MIN and Panels.MENU_LABEL_MIN >= 14, "menu label minimum under 14px")
		assert(Panels.MENU_LABEL_SIZE >= Panels.MENU_LABEL_MIN, "menu label size")
		local source = fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")
		local first = assert(string.find(source, "local function styleTile", 1, true))
		local last = assert(string.find(source, "local locks:", first, true))
		local tile = string.sub(source, first, last)
		assert(not string.find(tile, "textSize = 11", 1, true), "11px text left in the menu tile")
		assert(
			string.find(tile, "limit.MinTextSize, limit.MaxTextSize, limit.Parent = M.MENU_LABEL_MIN", 1, true),
			"tile label never scales under MENU_LABEL_MIN"
		)
		for _, viewport in VIEWPORTS do
			local f = frame(viewport[1], viewport[2], viewport[3])
			local cell = Panels.menuCell(f.width, f.columns)
			local x, width = Panels.menuLabel(cell)
			local at = viewport[1] .. "x" .. viewport[2]
			assert(cell >= Panels.MENU_MIN_CELL and f.tile >= 48, "tile under its readable size at " .. at)
			assert(x >= Panels.MENU_ICON + 6, "label overlaps the icon at " .. at)
			for _, text in LABELS do
				local lines = math.ceil(HudFit.textWidth(text, Panels.MENU_LABEL_MIN) / width)
				assert(
					lines <= 2 and lines * Panels.MENU_LABEL_MIN * 1.2 <= f.tile - 4,
					string.format("%q does not fit a %dpx label at %s", text, width, at)
				)
			end
		end
	end,
	["portrait phone menu shows many whole rows and scrolls to every tile"] = function()
		for _, viewport in { { 360, 584 }, { 390, 788 } } do
			local width, height = viewport[1], viewport[2]
			local f = frame(width, height, true)
			local rows = f.height // (f.tile + Panels.MENU_GAP)
			local at = width .. "x" .. height
			-- p83: 210px = 3 rows at 360x640. The open menu is modal and runs to the bottom margin.
			assert(rows >= 6, rows .. " rows visible at " .. at)
			assert(f.height % (f.tile + Panels.MENU_GAP) == 0, "partial row at " .. at)
			assert(f.y + f.height <= height - 8, "menu below the screen at " .. at)
			for _, count in { 13, 39 } do
				local canvas = Panels.menuCanvas(count, f.columns, f.tile)
				local scroll = math.max(0, canvas - f.height)
				local lastTop = Panels.MENU_GAP + (math.ceil(count / f.columns) - 1) * (f.tile + Panels.MENU_GAP)
				assert(lastTop - scroll >= 0 and lastTop - scroll + f.tile <= f.height, "last row at " .. at)
			end
		end
	end,
	["context-only screens have no menu tile and still open from their trigger"] = function()
		local module = "genres/survival-coop/module/"
		local sheet = fs.readFile(module .. "SocialSheet.luau")
		assert(string.find(sheet, "hidden = spec.hidden,", 1, true), "SocialSheet passes hidden to the dock")
		for _, name in { "DialoguePanel", "TransactionPanel", "SiegeMatchPanel", "SiegeResultsPanel" } do
			local source = fs.readFile(module .. name .. ".luau")
			local mount = assert(string.find(source, "Sheet.mount(ctx, {", 1, true), name)
			local close = assert(string.find(source, "rows = ", mount, true), name .. " rows")
			assert(string.find(string.sub(source, mount, close), "hidden = true,", 1, true), name .. " has a menu tile")
		end
	end,
	["journal rows are sized to their text and the score grid is above the fold"] = function()
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		local per = string.match(
			client,
			"journalContext%.rowSize = function%(lines: number%)%s*return UDim2%.new%(1, 0, 0, lines %* (%d+) %+ (%d+)%)"
		)
		assert(per and tonumber(per) <= 20, "journal row height per line: " .. tostring(per))
		assert(string.find(client, "journalContext.fitRow = function", 1, true), "journal rows grow with wraps")
		assert(string.find(fs.readFile("genres/survival-coop/module/JournalPanel.luau"), "ctx.fitRow(label)", 1, true))
		-- Docked editor rows are 48px + 6px gap: everything stacked before NoteGrid plus the 224px
		-- grid must fit the sheet body (header 44, padding 16) at Studio PC and portrait phone.
		local source = fs.readFile("genres/survival-coop/module/ScoreEditorPanel.luau")
		local grid = assert(string.find(source, 'place(grid, "NoteGrid", 224)', 1, true))
		local before = 0
		for _ in string.gmatch(string.sub(source, 1, grid), 'control%("Text%a+", "') do
			before += 1
		end
		local parts = assert(string.find(source, '"Part" .. index', 1, true))
		if parts < grid then
			before += 6 - 1
		end
		for _, viewport in { { 1280, 662, false }, { 360, 584, true } } do
			local _, _, _, h = Model.contextSheet(viewport[1], viewport[2], viewport[3])
			assert(
				before * 54 + 224 <= h - 44 - 16,
				string.format("note grid below the fold at %dx%d (%d rows above)", viewport[1], viewport[2], before)
			)
		end
	end,
	["settings sheet has separate channels with selected values and persists them"] = function()
		local Settings = require("./src/shared/SettingsModel")
		local Contract = require("../../genres/survival-coop/module/Contract")
		local Schema = require("../../core/infra/net/Schema")
		local rows = Settings.rows("ko-kr", { muted = false, volume = 0.5 })
		local keys = {}
		for _, row in rows do
			keys[row[1]] = row[2]
		end
		for _, key in { "muted", "volume", "music", "sfx", "ensemble", "reducedEffects" } do
			assert(keys[key], "settings row missing: " .. key)
		end
		assert(string.find(keys.volume, "50%", 1, true), "selected master value shown: " .. keys.volume)
		assert(Settings.nextStep(1) == 0 and Settings.nextStep(0.25) == 0.5, "volume steps")
		local args = Settings.args({ muted = false, volume = 1 }, "music", 0.25)
		assert(args[3].music == 0.25 and args[3].sfx == 1, "one channel changes alone")
		assert(Settings.groupGain(0.4, { volume = 0.5, music = 0.25 }, "Music") == 0.4 * 0.5 * 0.25, "music gain")
		assert(Settings.groupGain(0.4, { volume = 0.5, music = 0.25 }, "SFX") == 0.4 * 0.5, "sfx untouched")
		local descriptor
		for _, action in Contract.actions do
			if action.id == "audio-settings" then
				descriptor = action
			end
		end
		local tuple = Schema.tuple(descriptor.args)
		assert(Schema.check(tuple, args), "contract accepts per-channel settings")
		assert(Schema.check(tuple, { true, 0.5 }), "older two-argument form still accepted")
		local server = fs.readFile("games/robango-island/src/server/SurvivalFactory.luau")
		assert(string.find(server, "ensemble = extra.ensemble,", 1, true), "server persists channels")
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(string.find(client, "Settings.rows(locale, current)", 1, true), "sheet renders the settings rows")
		local audio = fs.readFile("games/robango-island/src/client/RobangoAudio.luau")
		assert(string.find(audio, "Settings.groupGain(gain, settings, group)", 1, true), "channels applied")
	end,
}
