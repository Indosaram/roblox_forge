--!strict
-- Expedition-lane screens (ui.routes, ui.party, ui.route-invite, ui.depart-confirm, ui.travel,
-- ui.expedition, ui.expedition-results, ui.hazard, ui.knockout) at PC 1280x720, portrait 360x640
-- and short landscape 640x339, in English and Korean. Geometry is the contextual sheet rect that
-- ExtensionPanels.place assigns; rows stack in the modalSheet list (8 px padding, 6 px gap).
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local Models = require("../../genres/survival-coop/module/ExpeditionModels")
local HudFit = require("../../core/ui-kit/genre/HudFit")
local Content: any = require("./src/shared/SurvivalContent")
local Party = require("../../core/domain/island/Party")

local VIEWPORTS = { { 1280, 720, false }, { 360, 640, true }, { 640, 339, true } }
local LOCALES = { "en-us", "ko-kr" }

local function fits(text: string, width: number, height: number, label: string)
	assert(text ~= "", label .. " blank")
	for size = 15, 11, -1 do
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

local function noop() end

local function screens(locale: string): { { string | { any } } }
	local facts = { level = 2, developmentRank = 2, instabilityAccess = 1 }
	local state: any = {
		now = 100,
		routes = Party.routes(Content, facts, 100, 1800),
		party = {
			id = "party-1",
			leader = "7",
			members = { "7", "12345678901" },
			capacity = 8,
			pending = 1,
			route = 1,
			invites = {},
			roster = {
				{ id = "7", leader = true, ready = true },
				{ id = "12345678901", leader = false, ready = false },
			},
		},
		tracker = {
			route = 5,
			stage = 4,
			expiresAt = 1800,
			unlocked = false,
			objectives = {
				{ id = "o1", action = "transport", target = "relief-unit", progress = 2, quantity = 5 },
				{ id = "o2", action = "survey", target = "rw.a5.s4.survey", progress = 0, quantity = 1 },
			},
		},
	}
	local invite = { from = "12345678901", route = 2, expiresAt = 220, members = 7, capacity = 8 }
	local results = {
		id = "trip",
		status = "expired",
		rows = {
			{ mission = "rw.m1.transport", xp = 120, coins = 30, trust = 20, repeatClear = true, delivered = false },
		},
	}
	local hazard = { kind = "hot-spring", intensity = 3, refuge = true, volcano = { health = 1, fatigue = 2 } }
	local taming = { companions = { pets = { p = { species = "boar", phase = "Downed", injuredUntil = 160000 } } } }
	local others = { { id = "8", name = "LongDisplayName_Twenty" } }
	local list = {}
	local function add(id: string, title: string, items: { any })
		table.insert(list, { id, title, items } :: any)
	end
	add("ui.routes", Models.routes(locale, state, {}, noop))
	add("ui.party", Models.party(locale, state, "7", others, noop))
	add("ui.route-invite", Models.invite(locale, state, invite, noop))
	add("ui.depart-confirm", Models.confirm(locale, state, 2, { confirm = noop, stay = noop }))
	add("ui.travel", Models.travel(locale, 1, "expiry_imminent", noop, noop))
	add("ui.expedition", Models.expedition(locale, state, {}, noop))
	add("ui.expedition-results", Models.results(locale, results, {}, noop))
	add("ui.hazard", Models.hazard(locale, hazard, {}))
	add("ui.knockout", Models.knockout(locale, { respawnWaitMillis = 10000 }, "danger", taming, 100000, noop))
	return list
end

return {
	["every expedition-lane screen fits PC portrait and short landscape in English and Korean"] = function()
		local checked = 0
		for _, viewport in VIEWPORTS do
			local width, height, touch = viewport[1], viewport[2], viewport[3]
			local x, y, w, h = Model.contextSheet(width, height, touch)
			assert(x >= 0 and y >= 0 and x + w <= width and y + h <= height and w > 0 and h > 0, "sheet clipped")
			local rowWidth = w - 16 - 6
			local visible = h - 44 - 8
			for _, locale in LOCALES do
				for _, screen in screens(locale) do
					local id, title, items = screen[1] :: string, screen[2] :: string, screen[3] :: { any }
					local where = string.format("%s %s %dx%d", id, locale, width, height)
					fits(title, w - 70, 44, where .. " title")
					assert(#items > 0, where .. " blank")
					local top = 0
					local firstButton: number? = nil
					for index, item in items do
						assert(item.height >= (if item.kind == "button" then 44 else 1), where .. " touch size")
						fits(item.text, rowWidth, item.height, where .. " row " .. index)
						if item.kind == "button" and firstButton == nil then
							firstButton = top + item.height
						end
						top += item.height + 6
					end
					-- The primary action of every screen is on screen without scrolling.
					if firstButton then
						assert(firstButton <= visible, where .. " first action below the fold")
					end
					checked += 1
				end
			end
		end
		assert(checked == 9 * 2 * 3, "all screens checked")
	end,
}
