--!strict
-- G004 layout audit, second half: extension sheets that ui-layout.spec only covered as a
-- whole sheet rect (taming, death zone, harbor market, brawl, audio, clan membership).
-- Row geometry is read from each panel's own source so a resized row fails here.
local fs = require("@lune/fs")
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local HudFit = require("../../core/ui-kit/genre/HudFit")
local Taming = require("../../genres/survival-coop/module/TamingPanel")
local Zone = require("../../genres/survival-coop/module/DeathZonePanel")

-- PC, portrait phone and the Studio short-landscape phone (device simulator 640x339).
local VIEWPORTS = { { 1280, 720, false }, { 360, 640, true }, { 640, 339, true } }
local LOCALES = { "en-us", "ko-kr" }
-- ExtensionPanels merges theme body 15 for every dock panel.
local BODY = 15

local function read(name: string): string
	return fs.readFile("genres/survival-coop/module/" .. name .. ".luau")
end

-- Padded content width of a fitted extension sheet (8px padding each side, 6px scrollbar).
local function content(viewport: { any }): number
	local _, _, width = Model.contextSheet(viewport[1], viewport[2], viewport[3])
	return width - 16 - 6
end

local function lines(text: string, width: number, size: number): number
	local count = 0
	for _, line in string.split(text, "\n") do
		count += math.max(1, math.ceil(HudFit.textWidth(line, size) / (width - HudFit.PADDING * 2)))
	end
	return count
end

-- A wrapped label: every line at `size` with 1.2 line height fits `height`.
local function wraps(text: string, width: number, height: number, size: number, label: string)
	assert(text ~= "", label .. " blank")
	local need = lines(text, width, size) * size * 1.2
	assert(need <= height, string.format("%s overflows %dx%d (needs %d): %q", label, width, height, need, text))
end

-- A button label: TextButton does not wrap, so one line must fit the button width.
-- Components.button adds no UIPadding, so the glyph estimate alone must fit.
local function single(text: string, width: number, label: string)
	assert(text ~= "", label .. " blank")
	local need = math.ceil(HudFit.textWidth(text, BODY))
	assert(need <= width, string.format("%s clipped: needs %d, has %d: %q", label, need, width, text))
end

-- Pixel height of the first `UDim2.new(1, 0, 0, N)` after `anchor` in `source`.
local function rowHeight(source: string, anchor: string): number
	local at = assert(string.find(source, anchor, 1, true), "anchor moved: " .. anchor)
	local size = assert(string.match(source, "UDim2%.new%(1, 0, 0, (%d+)%)", at), "row size " .. anchor)
	return tonumber(size) :: number
end

local function at(viewport: { any }, locale: string): string
	return viewport[1] .. "x" .. viewport[2] .. " " .. locale
end

return {
	["taming companion pen and ride rows fit their buttons at every target viewport"] = function()
		local source = read("TamingPanel")
		for _, anchor in
			{
				"size = UDim2.new(0.5, -4, 0, 48),",
				"position = UDim2.new((index - 1) % 2 / 2, 0, 0, 36 + math.floor((index - 1) / 2) * 52),",
				'"Companion-" .. id, 1, UDim2.new(1, 0, 0, 160), rows',
				"size = UDim2.fromScale(0.23, 1),",
				"size = UDim2.fromScale(0.36, 1),",
			}
		do
			assert(string.find(source, anchor, 1, true), "TamingPanel layout constant moved: " .. anchor)
		end
		-- Most verbs a phase shows (Deployed: feed, recall, mount, dismount) in a 2-column grid.
		local rows = math.ceil(4 / 2)
		assert(36 + (rows - 1) * 52 + 48 <= 160, "companion action grid fits its 160px card")
		for _, viewport in VIEWPORTS do
			local width = content(viewport)
			local half, quarter, ride = width * 0.5 - 4, width * 0.23, width * 0.36
			assert(half >= 44 and quarter >= 44 and ride >= 44, "taming control under 44px at " .. width)
			for _, locale in LOCALES do
				local where = at(viewport, locale)
				for _, verb in
					{ "place", "train", "feed", "claim", "cancel", "deploy", "recall", "saddle", "mount", "dismount" }
				do
					single(Taming.text(locale, "companion_" .. verb), half, "companion " .. verb .. " " .. where)
				end
				for _, verb in { "release", "recover" } do
					single(Taming.text(locale, "companion_" .. verb), half, "companion " .. verb .. " " .. where)
				end
				single(Taming.text(locale, "tame_feed"), quarter, "pen feed " .. where)
				single(Taming.text(locale, "tame_mount"), quarter, "pen mount " .. where)
				single(Taming.text(locale, "tame_dismount"), ride, "dismount " .. where)
				local longest = Taming.species(locale, "bluff-bounder") .. "  " .. Taming.pen(locale, 599000)
				wraps(longest, width * 0.5, 48, BODY, "pen row " .. where)
				wraps(
					Taming.text(locale, "tame_mounted", Taming.species(locale, "bluff-bounder")),
					width * 0.62,
					48,
					BODY,
					"mounted " .. where
				)
				wraps(
					Taming.gauge(locale, { species = "bluff-bounder", level = 100, max = 100 }),
					width,
					22,
					BODY,
					"gauge"
				)
				for _, reason in { "CLUB_REQUIRED", "CAPTURE_GATED", "NO_ROPE", "NO_FEED_ITEM" } do
					wraps(Taming.refusal(locale, { ok = false, reason = reason }), width, 28, BODY, reason)
				end
			end
		end
	end,
	["death zone warning indicator and buttons fit at every target viewport"] = function()
		local source = read("DeathZonePanel")
		local indicator = rowHeight(source, "local indicator = ui.components.label")
		local warning = rowHeight(source, "local warning = ui.components.label")
		local button = rowHeight(source, "toggle = ui.components.button")
		assert(button >= 44, "death zone button under touch size")
		for _, viewport in VIEWPORTS do
			local width = content(viewport)
			local _, _, _, sheetHeight = Model.contextSheet(viewport[1], viewport[2], viewport[3])
			-- Confirm state shows warning + Enter anyway + Stay safe; all must sit in one screen.
			assert(44 + warning + 2 * button + 3 * 6 <= sheetHeight, "confirm state fits without scrolling")
			for _, locale in LOCALES do
				local where = at(viewport, locale)
				wraps(Zone.text(locale, "zone_warning"), width, warning, BODY, "zone warning " .. where)
				wraps(Zone.text(locale, "zone_safe"), width, indicator, BODY, "zone safe " .. where)
				wraps(Zone.text(locale, "zone_danger"), width, indicator, BODY, "zone danger " .. where)
				for _, key in { "zone_enter", "zone_leave", "zone_confirm", "zone_cancel" } do
					single(Zone.text(locale, key), width, key .. " " .. where)
				end
			end
		end
	end,
	["harbor market rows and buttons fit at every target viewport"] = function()
		local source = read("CrossServerMarketPanel")
		local found = {}
		for en, ko in string.gmatch(source, 'text%(%s*"([^"]*)",%s*"([^"]*)"%s*%)') do
			table.insert(found, { en, ko })
		end
		assert(#found >= 15, "harbor market strings discovered")
		local BUTTONS = {
			{ "Refresh listings", "판매 목록 새로고침" },
			{ "Cancel to collection box", "취소 후 수령함으로" },
			{ "Buy bundle", "묶음 구매" },
			{ "Collect", "수령" },
			{ "Previous page", "이전 쪽" },
			{ "Next page", "다음 쪽" },
		}
		for _, pair in BUTTONS do
			assert(string.find(source, '"' .. pair[1] .. '"', 1, true), "market button label moved: " .. pair[1])
		end
		assert(rowHeight(source, "local function label(value)") == 48, "market label row height moved")
		assert(rowHeight(source, "local function button(value, callback)") == 48, "market button row moved")
		for _, viewport in VIEWPORTS do
			local width = content(viewport)
			for index, locale in LOCALES do
				for _, pair in found do
					-- Rows are full-width 48px: wrapped labels may take two lines, buttons one.
					wraps(pair[index], width, 48, BODY, "harbor market " .. at(viewport, locale))
				end
				-- Buttons do not wrap: their labels must fit one line.
				for _, pair in BUTTONS do
					single(pair[index], width, "harbor market button " .. at(viewport, locale))
				end
			end
		end
	end,
	["brawl buttons and notices fit the fitted sheet at every target viewport"] = function()
		local source = read("BrawlPanel")
		assert(string.find(source, "Size = ui.UDim2.new(1, -8, 0, 44),", 1, true), "brawl row constant moved")
		assert(string.find(source, "TextSize = 18,", 1, true), "brawl text size moved")
		local en, ko = {}, {}
		for key, a, b in string.gmatch(source, '\n%s*([%w_]+) = { "([^"]*)", "([^"]*)" }') do
			if key ~= "brawl_feedback" then
				table.insert(en, a)
				table.insert(ko, b)
			end
		end
		assert(#en >= 18, "brawl strings discovered")
		for _, viewport in VIEWPORTS do
			-- Scroll padding 12 each side, row width 1, -8.
			local width = content(viewport) + 6 - 24 - 8
			for index, list in { en, ko } do
				for _, text in list do
					local need = HudFit.textWidth(text, 18) + HudFit.PADDING * 2
					assert(
						need <= width,
						string.format(
							"brawl %q clipped at %s (%d > %d)",
							text,
							at(viewport, LOCALES[index]),
							need,
							width
						)
					)
				end
			end
		end
	end,
	["audio and clan membership sheets keep full-width touch rows"] = function()
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		local labels = {
			{ "Mute", "음소거" },
			{ "Unmute", "음소거 해제" },
			{ "Join invited clan", "초대받은 부족 가입" },
			{ "Clan membership", "부족 가입" },
		}
		for _, pair in labels do
			assert(string.find(client, pair[1], 1, true), "client label moved: " .. pair[1])
		end
		-- Volume buttons render tostring(gain * 100) .. "%".
		assert(string.find(client, 'tostring(gain * 100) .. "%"', 1, true), "volume label moved")
		table.insert(labels, { "100%", "100%" })
		for _, viewport in VIEWPORTS do
			local width = content(viewport)
			for index, locale in LOCALES do
				for _, pair in labels do
					single(pair[index], width, "audio/clan " .. at(viewport, locale))
				end
			end
		end
	end,
}
