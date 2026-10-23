--!strict
local fs = require("@lune/fs")
local Panel = require("./OperationPanel")

return {
	["rows show inputs, station and gate; locked rows offer no make button"] = function()
		local rows = Panel.rows("en-us", {
			operations = {
				{
					id = "practice-seedbed",
					inputs = { { item = "fiber", quantity = 2 }, { item = "water", quantity = 1 } },
					outputs = { { item = "practice-seedbed", quantity = 1 } },
				},
				{
					id = "instrument-flute",
					station = "workbench",
					inputs = { { item = "dried-wood", quantity = 3 } },
					outputs = { { item = "instrument-flute", quantity = 1 } },
					reason = "CHARACTER_LEVEL_GATE",
				},
			},
		}, { fiber = "Fiber", ["instrument-flute"] = "Flute" })
		assert(rows[1].inputs == "Fiber x2, water x1" and rows[1].locked == nil, "open practice row")
		assert(rows[1].where == "By hand", "practice needs no station")
		assert(rows[2].label == "Flute" and rows[2].where == "Workbench nearby", "label from the output item")
		assert(rows[2].locked == "Character level too low", "gate reason localized")
		assert(#Panel.rows("en-us", nil) == 0, "no snapshot, no rows")
		assert(Panel.refusal("ko-kr", "STATION_GATE") == "작업대 옆에 서세요", "korean refusal")
		assert(Panel.refusal("en-us", "???") == Panel.text("en-us", "operation_failed"), "fallback refusal")
	end,
	["every operation panel string has matching en-us and ko-kr locale rows"] = function()
		local csv = fs.readFile("games/robango-island/locale/strings.csv")
		for _, key in Panel.keys() do
			local row = string.match(csv, "\n" .. key .. ",([^\n]*)")
			assert(row, key .. ": missing from strings.csv")
			assert(string.find(row, Panel.text("en", key), 1, true), key .. ": en-us text differs")
			assert(string.find(row, Panel.text("ko", key), 1, true), key .. ": ko-kr text differs")
		end
	end,
	["the panel sends the durable operation-run id"] = function()
		local source = fs.readFile("genres/survival-coop/module/OperationPanel.luau")
		assert(string.find(source, "ctx.send(M.RUN, { row.id, stationId(row.station) })", 1, true), "make sends")
		assert(Panel.RUN == "survival-coop:operation-run", "namespaced durable id")
		local panels = fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")
		assert(string.find(panels, 'require("./OperationPanel").factory', 1, true), "panel registered")
		assert(string.find(panels, 'GetAttribute("ForgeOperation")', 1, true), "world prompt runs its operation")
	end,
}
