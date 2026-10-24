--!strict
-- G004 layout audit, second half: extension sheets that ui-layout.spec only covered as a
-- whole sheet rect (taming, death zone, harbor market, brawl, audio, clan membership).
-- Row geometry is read from each panel's own source so a resized row fails here.
local fs = require("@lune/fs")
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local HudFit = require("../../core/ui-kit/genre/HudFit")
local Taming = require("../../genres/survival-coop/module/TamingPanel")
local Zone = require("../../genres/survival-coop/module/DeathZonePanel")
local MusicText = require("../../genres/survival-coop/module/MusicText")
local Music = require("../../genres/survival-coop/module/MusicScreens")
local Navigator = require("../../genres/survival-coop/module/NavigatorPanel")

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
				"position = UDim2.new((index - 1) % 2 / 2, 0, 0, 72 + math.floor((index - 1) / 2) * 52),",
				'"Companion-" .. id, 1, UDim2.new(1, 0, 0, 172), rows',
				"size = UDim2.fromScale(0.23, 1),",
				"size = UDim2.fromScale(0.36, 1),",
			}
		do
			assert(string.find(source, anchor, 1, true), "TamingPanel layout constant moved: " .. anchor)
		end
		-- Most verbs a phase shows (Taming: feed, claim, cancel) in a 2-column grid under the
		-- 28px title and 40px stats line.
		local rows = math.ceil(3 / 2)
		assert(72 + (rows - 1) * 52 + 48 <= 172, "companion action grid fits its 172px card")
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
	["brawl sheet rows wrap, stack and keep touch controls in every phase at every target viewport"] = function()
		-- p83 defect 5: the brawl panel was an unstyled frame with raw weather ids and 'a | b | c'
		-- rows that wrapped into each other at 360. It now renders through the shared SocialSheet
		-- (ui-kit modalSheet in the fitted rect), and every row is sized from its own wrapped text.
		local source = read("BrawlPanel")
		assert(string.find(source, "Sheet.mount(ctx, {", 1, true), "brawl mounts the shared kit sheet")
		assert(not string.find(source, 'Instance.new("TextLabel")', 1, true), "no hand-built default labels")
		local Sheet = require("../../genres/survival-coop/module/SocialSheet")
		local Brawl = require("../../genres/survival-coop/module/BrawlPanel")
		local Match = require("../../core/domain/brawl/Match")
		local Content: any = require("./src/shared/SurvivalContent")
		local policy = Content.brawlPolicy
		local ids = {}
		for _, weather in policy.weather do
			table.insert(ids, weather.id)
		end
		local function states(): { { any } }
			local out = {}
			local empty = Match.new("m", policy)
			table.insert(out, { empty, "a", 0, "queue empty" })
			local queued = Match.new("m", policy)
			assert(Match.join(queued, "a", { level = policy.minimumLevel, maxHealth = 100, equipment = {} }), "join")
			table.insert(out, { queued, "a", 0, "queued" })
			local live = Match.new("m", policy)
			for _, actor in { "a", "b", "c" } do
				assert(Match.join(live, actor, { level = policy.minimumLevel, maxHealth = 100, equipment = {} }), actor)
			end
			assert(Match.start(live, 0), "start")
			table.insert(out, { live, "a", 10, "preparing" })
			for _, weather in policy.weather do
				local active = table.clone(live)
				active.phase = "active"
				table.insert(out, { active, "a", live.startsAt + weather.at + 1, "active " .. weather.id })
			end
			local finished = table.clone(live)
			finished.phase, finished.winner = "finished", "a"
			table.insert(out, { finished, "a", live.startsAt + policy.durationSeconds, "finished" })
			return out
		end
		local act = setmetatable({}, {
			__index = function()
				return function() end
			end,
		})
		for _, viewport in VIEWPORTS do
			local x, y, sw, sh = Model.contextSheet(viewport[1], viewport[2], viewport[3])
			assert(x >= 0 and y >= 0 and x + sw <= viewport[1] and y + sh <= viewport[2], "brawl sheet in viewport")
			local width = Sheet.contentWidth(sw)
			for _, locale in LOCALES do
				local sets: { { any } } = { { Brawl.rows(locale, nil, policy, act), "unavailable" } }
				for _, case in states() do
					local model = Brawl.model(case[1], case[2], case[3], nil)
					table.insert(sets, { Brawl.rows(locale, model, policy, act), case[4] })
				end
				for _, set in sets do
					local rows, where = set[1], set[2] .. " " .. at(viewport, locale)
					assert(#rows >= 3, where .. ": rows present")
					local top, buttons = 8, 0
					for _, row in rows do
						assert(type(row.text) == "string" and row.text ~= "", where .. ": blank row")
						assert(not string.find(row.text, " | ", 1, true), where .. ": cryptic pipe row " .. row.text)
						assert(not string.find(row.text, "%%[ds]"), where .. ": unformatted " .. row.text)
						for _, id in ids do
							-- Raw lowercase weather ids never reach the player (EN names are capitalized).
							assert(
								not string.find(row.text, "%f[%a]" .. id .. "%f[%A]"),
								where .. ": raw id " .. row.text
							)
						end
						local textWidth = width - (if row.icon then Sheet.ICON_INSET else 0)
						local height = Sheet.rowHeight(row.text, textWidth)
						assert(height >= 48, where .. ": row under touch height")
						wraps(row.text, textWidth, height - 12, Sheet.TEXT_SIZE, where)
						if row.onClick then
							buttons += 1
							-- Kit buttons are one 48px row: the label must fit on one line.
							single(row.text, textWidth - 2 * HudFit.PADDING, where .. " button")
							assert(height == Sheet.MIN_ROW, where .. ": button grew past one row")
						end
						top += height + 6
					end
					if set[2] ~= "unavailable" then
						assert(buttons >= 1, where .. ": no reachable control")
					end
					if set[2] == "queue empty" then
						-- Status, the empty-queue line, entry rule and Join all sit above the fold.
						local fold = 8
						for index = 1, 3 do
							fold += Sheet.rowHeight(rows[index].text, width) + 6
						end
						assert(44 + fold <= sh, where .. ": queue summary above the fold")
					end
				end
			end
		end
		-- Every weather id has a distinct localized name and a weather icon key in both locales.
		for _, id in ids do
			local en, ko = Brawl.weatherName("en-us", id), Brawl.weatherName("ko-kr", id)
			assert(en ~= id and ko ~= id and en ~= ko, "weather name " .. id)
			assert(Brawl.weatherIcon(id) == "weather." .. id, "weather icon key " .. id)
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
	["death zone refusal status line holds every refusal at every target viewport"] = function()
		-- The generic refusal wraps to two lines at 360x640 (EN and KO); the label holds both.
		local status = rowHeight(read("DeathZonePanel"), "local status = ui.components.label")
		for _, viewport in VIEWPORTS do
			local width = content(viewport)
			for _, locale in LOCALES do
				local where = at(viewport, locale)
				wraps(Zone.refusal(locale, "NOT_ALIVE"), width, status, BODY, "zone dead " .. where)
				wraps(Zone.refusal(locale, nil), width, status, BODY, "zone failed " .. where)
			end
		end
	end,
	["navigator rows show every destination and lock reason at every target viewport"] = function()
		local source = read("MusicSheet")
		assert(rowHeight(source, "function api.button") == 48, "music sheet button row moved")
		assert(rowHeight(source, "function api.label") == 48, "music sheet label row moved")
		for _, viewport in VIEWPORTS do
			local width = content(viewport)
			for _, locale in LOCALES do
				local where = at(viewport, locale)
				-- Locked: every row shows "Label: reason"; unlocked: the label alone.
				for _, open in { false, true } do
					local rows = Navigator.model(locale, function()
						return true, open, if open then nil else "lock_unsaved"
					end)
					assert(#rows == #Navigator.ROWS, "every destination listed")
					for _, row in rows do
						wraps(row.text, width, 48, BODY, "navigator " .. where)
					end
				end
				for _, key in { "lock_unknown", "lock_unavailable", "lock_unsaved" } do
					wraps(MusicText.text(locale, key), width, 48, BODY, key .. " " .. where)
				end
			end
		end
	end,
	["score import, share and ensemble sheets fit labels, buttons and refusals at every target viewport"] = function()
		local refusals = {}
		for key in MusicText.strings do
			if string.find(key, "^score%.") or string.find(key, "^ensemble%.") then
				table.insert(refusals, key)
			end
		end
		assert(#refusals >= 20, "music refusals discovered")
		local name = string.rep("W", 20)
		for _, viewport in VIEWPORTS do
			local width = content(viewport)
			for _, locale in LOCALES do
				local where = at(viewport, locale)
				local function text(key: string, ...: any): string
					return MusicText.text(locale, key, ...)
				end
				for _, key in refusals do
					wraps(MusicText.refusal(locale, key), width, 48, BODY, key .. " " .. where)
				end
				local field = MusicText.refusal(locale, "score.parts[6].notes[16384].durationTicks")
				wraps(field, width, 48, BODY, "field refusal " .. where)
				for _, line in
					{
						text("import_hint"),
						text("import_preview", 200, 6, 98304, 180),
						text("import_saved", "12345678901:score:123#456"),
						text("import_selected", "12345678901:score:123#456"),
						text("share_ref", "12345678901:score:123#456"),
						text("share_note"),
						text("share_done", "12345678901:score:123#456"),
						text("lobby_score", "12345678901:score:123#456"),
						text("lobby_none"),
						text("lobby_slot", 6, name, 6, text("lobby_ready_tag") .. text("lobby_host_tag")),
						text("lobby_in_range"),
						text("lobby_out_range"),
					}
				do
					wraps(line, width, 48, BODY, "music label " .. where)
				end
				for _, line in
					{
						text("import_check"),
						text("import_save"),
						text("import_use"),
						text("share_send"),
						text("lobby_part", 6),
						text("lobby_join", 6),
						text("lobby_ready"),
						text("lobby_unready"),
						text("lobby_start"),
						text("lobby_leave"),
					}
				do
					single(line, width, "music button " .. where)
				end
			end
		end
	end,
	["ensemble play overlay stays clear of the HUD, chat and thumb zones and fits its text"] = function()
		for _, viewport in VIEWPORTS do
			local width, height = viewport[1], viewport[2]
			local x, y, w, h = Music.playBounds(width, height)
			local overlay = { x = x, y = y, width = w, height = h }
			local where = width .. "x" .. height
			assert(
				x >= 0 and y >= 64 and x + w <= width and y + h <= height - 128,
				"overlay inside safe area " .. where
			)
			local hud = Model.contextHudBounds(width, height)
			for _, key in { "vitals", "objective", "menu", "biome" } do
				local rect = hud[key]
				local hit = overlay.x < rect.x + rect.width
					and rect.x < overlay.x + overlay.width
					and overlay.y < rect.y + rect.height
					and rect.y < overlay.y + overlay.height
				assert(not hit, "overlay overlaps " .. key .. " at " .. where)
			end
			assert(width < 1000 or x >= 548 or y >= 328, "overlay clears desktop chat")
			assert(h >= 4 + 32 + 32 + 4 + 48, "overlay rows fit")
			for _, locale in LOCALES do
				local label = at(viewport, locale)
				wraps(MusicText.text(locale, "play_countdown", 2), w - 16, 32, BODY, "countdown " .. label)
				wraps(MusicText.text(locale, "play_progress", 6, 16384, 16384), w - 16, 32, BODY, "progress " .. label)
				for _, key in { "play_sync", "play_late" } do
					wraps(MusicText.text(locale, key), w - 16, 32, 13, key .. " " .. label)
				end
				single(MusicText.text(locale, "play_leave"), w - 16, "leave " .. label)
				single(MusicText.text(locale, "play_rejoin", 6), w - 16, "rejoin " .. label)
			end
		end
	end,
}
