--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local CampExtension = require("./CampExtension")
local CampPanel = require("./CampPanel")
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
		assert(CampPanel.model(slice, 130).pass == nil, "expired pass hidden")
		assert(CampPanel.model(nil, 0) == nil, "no slice, no model")
	end,
}
