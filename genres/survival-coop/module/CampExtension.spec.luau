--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local CampExtension = require("./CampExtension")
local CampPanel = require("./CampPanelModel")
local Content = require("../../../core/domain/survival/Content")

local function content(): Content.Document
	return assert(Content.canonicalize(serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))))
end

return {
	["the pack ladder is built from content.yml camp section"] = function()
		local ladder = assert(CampExtension.ladder(content()), "pack declares a camp")
		assert(#ladder.rungs == 2 and ladder.leagueRung == 2, "rungs and league rung")
		assert(ladder.projects["windbreak"].rung == 1 and ladder.projects["drying-rack"].rung == 2, "projects")
	end,
	["a document without a camp section disables the extension"] = function()
		local document = table.clone(content())
		document.camp = nil
		assert(CampExtension.ladder(document) == nil, "no ladder")
		assert(CampExtension.new({ content = document } :: any) == nil, "factory returns nil")
	end,
	["content schema rejects malformed camp sections"] = function()
		local raw = serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))
		raw.camp.rungs[2].completions = 1
		raw.camp.projects[1].cost = { { item = "no-such-item", quantity = 1 } }
		raw.camp.leagueRung = 9
		local document, errors = Content.canonicalize(raw)
		assert(document == nil, "invalid camp refused")
		local text = table.concat(errors, "\n")
		assert(string.find(text, "camp.rungs[2].completions", 1, true), text)
		assert(string.find(text, "unknown item no-such-item", 1, true), text)
		assert(string.find(text, "camp.leagueRung", 1, true), text)
	end,
	["panel model reports progress, lock and visitor pass"] = function()
		local slice = {
			role = "visitor",
			rung = 0,
			version = 3,
			facilities = {},
			cooldowns = {},
			pass = { hostId = "owner", expiresAt = 130 },
			active = { windbreak = { delivered = { fiber = 4 }, contributors = {} } },
			ladder = {
				rungs = { {}, {} },
				projects = {
					windbreak = { id = "windbreak", rung = 1, cost = { { item = "fiber", quantity = 8 } } },
					["drying-rack"] = { id = "drying-rack", rung = 2, cost = { { item = "fiber", quantity = 4 } } },
				},
			},
		}
		local model = assert(CampPanel.model(slice, 100))
		assert(model.pass == 30 and #model.rows == 2, "pass seconds and rows")
		assert(
			model.rows[2].id == "windbreak" and model.rows[2].delivered == 4 and not model.rows[2].locked,
			"progress"
		)
		assert(model.rows[1].id == "drying-rack" and model.rows[1].locked, "rung 2 locked at rung 0")
		assert(assert(CampPanel.model(slice, 130)).pass == nil, "expired pass hidden")
		assert(CampPanel.model(nil, 0) == nil, "no slice, no model")
	end,
	["a guest model lists friend-visit candidates by roster name"] = function()
		local slice = { role = "guest", hosts = { ["2"] = true, ["1"] = true } }
		local model = assert(CampPanel.model(slice, 0, { roster = { { id = "2", name = "Maru" } } }))
		assert(model.role == "guest" and #model.rows == 0, "guest sees no projects")
		assert(model.hosts[1].id == "1" and model.hosts[1].name == "1", "unnamed host falls back to its id")
		assert(model.hosts[2].id == "2" and model.hosts[2].name == "Maru", "named host")
		assert(CampPanel.model({ role = "guest", hosts = {} }, 0) == nil, "nobody to visit, no panel")
	end,
	["the item picker is built from the unreserved bag stacks"] = function()
		local packet = {
			snapshots = {
				["survival-coop"] = {
					inventory = {
						{
							kind = "carried",
							items = {
								b = { itemId = "b", catalogId = "berry", quantity = 3 },
								a = { itemId = "a", catalogId = "fiber", quantity = 12 },
								c = { itemId = "c", catalogId = "wood", quantity = 2 },
							},
							reservations = { job = { a = 4, c = 2 } },
						},
					},
				},
			},
		}
		local choices = CampPanel.choices("en", packet)
		assert(#choices == 2, "a fully reserved stack is not offered")
		assert(
			choices[1].itemId == "a" and choices[1].available == 8 and choices[1].label == "Fiber",
			"reserved units excluded"
		)
		assert(choices[2].itemId == "b" and choices[2].available == 3, "second stack")
		assert(CampPanel.choices("ko", packet)[1].label == "섬유", "labels follow the locale")
		assert(#CampPanel.choices("en", {}) == 0 and #CampPanel.choices("en", nil) == 0, "no snapshot, no choices")
		assert(assert(CampPanel.select(choices, "b")).itemId == "b", "kept pick")
		assert(assert(CampPanel.select(choices, "gone")).itemId == "a", "stale pick falls back")
		assert(CampPanel.select({}, nil) == nil, "empty bag selects nothing")
		assert(CampPanel.cycle(choices, "a", 1) == "b" and CampPanel.cycle(choices, "b", 1) == "a", "cycle wraps")
		assert(CampPanel.cycle({}, nil, 1) == nil, "nothing to cycle")
		assert(
			CampPanel.clamp(0, 8) == 1 and CampPanel.clamp(99, 8) == 8 and CampPanel.clamp(2.7, 8) == 2,
			"quantity clamps"
		)
		assert(CampPanel.clamp(5, 5000) == 5 and CampPanel.clamp(5000, 5000) == CampPanel.MAX_QUANTITY, "server cap")
	end,
	["every camp panel string has en-us and ko-kr locale rows"] = function()
		local csv = fs.readFile("games/robango-island/locale/strings.csv")
		for _, key in CampPanel.keys() do
			local row = string.match(csv, "\n" .. key .. ",([^\n]*)")
			assert(row, key .. ": missing from strings.csv")
			assert(string.find(row, CampPanel.text("en", key), 1, true), key .. ": en-us text differs from the panel")
			assert(string.find(row, CampPanel.text("ko", key), 1, true), key .. ": ko-kr text differs from the panel")
		end
		assert(CampPanel.refusal("en", "NOT_FRIEND") == CampPanel.text("en", "camp_not_friend"), "friend refusal")
		assert(CampPanel.refusal("ko", "SOMETHING_ELSE") == CampPanel.text("ko", "camp_refused"), "generic refusal")
	end,
}
