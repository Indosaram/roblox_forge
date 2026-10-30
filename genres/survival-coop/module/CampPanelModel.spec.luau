--!strict
local _packText = (require :: any)("../../../games/robango-island/PackText.fixture") -- installs the strings.csv lookup
local Model = require("./CampPanelModel")

local function slice(): any
	return {
		role = "member",
		rung = 0,
		version = 3,
		facilities = {},
		ladder = {
			rungs = { {} },
			projects = {
				{
					id = "windbreak",
					rung = 1,
					cost = { { item = "fiber", quantity = 40 }, { item = "branch", quantity = 30 } },
				},
			},
		},
		active = { windbreak = { delivered = { fiber = 12, branch = 99 } } },
	}
end

return {
	-- Single-player 재료 넣기: put in only what the project still needs from your own bag, one
	-- camp-contribute per stack with the version each accept returns, then camp-complete when full.
	["solo put-in fills the missing materials from the bag and finishes a full project"] = function()
		local row = assert(Model.model(slice(), 0)).rows[1] -- fiber 12/40, branch 30/30
		local choices = {
			{ itemId = "f1", catalogId = "fiber", label = "f", available = 20 },
			{ itemId = "f2", catalogId = "fiber", label = "f", available = 20 },
			{ itemId = "b1", catalogId = "branch", label = "b", available = 5 },
			{ itemId = "w1", catalogId = "wood", label = "w", available = 9 },
		}
		local fill = Model.fill(row, choices)
		assert(#fill == 2 and fill[1].itemId == "f1" and fill[1].quantity == 20, "first fiber stack")
		assert(fill[2].itemId == "f2" and fill[2].quantity == 8, "the rest of the 28 missing fibers")
		local sent = {}
		local version = 3
		local result, given = Model.putIn(function(action, args)
			table.insert(sent, { action = action, args = args })
			version += 1
			return { ok = true, data = { camp = version } }
		end, row, choices, 3)
		assert(result.ok and given == 28, "put in 28")
		assert(#sent == 3, "two contributes and a complete: " .. #sent)
		assert(sent[1].action == "survival-coop:camp-contribute" and sent[1].args[4] == 3, "first at version 3")
		assert(sent[2].args[4] == 4, "second uses the version the first returned")
		assert(sent[3].action == "survival-coop:camp-complete" and sent[3].args[1] == "windbreak", "complete")
		assert(sent[3].args[2] == 5, "complete at the latest version")
		-- Not enough to finish: contribute only, no complete; nothing that fits: no command at all.
		local partial = {}
		Model.putIn(function(action, _args)
			table.insert(partial, action)
			return { ok = true, data = { camp = 4 } }
		end, row, { choices[1] }, 3)
		assert(#partial == 1 and partial[1] == "survival-coop:camp-contribute", "partial put-in")
		local none, count = Model.putIn(function()
			error("no command")
		end, row, { choices[4] }, 3)
		assert(not none.ok and none.reason == "ITEM_NOT_NEEDED" and count == 0, "nothing fits")
	end,
	["camp rows keep each material's delivered and needed amount"] = function()
		local row = assert(Model.model(slice(), 0)).rows[1]
		assert(row.delivered == 42 and row.need == 70, "total still summed")
		assert(#row.costs == 2, "one cost per material")
		assert(row.costs[1].item == "fiber" and row.costs[1].delivered == 12 and row.costs[1].need == 40, "fiber")
		assert(row.costs[2].item == "branch" and row.costs[2].delivered == 30 and row.costs[2].need == 30, "capped")
	end,
	["cost line names each material through pack names, else the HUD locale"] = function()
		local row = assert(Model.model(slice(), 0)).rows[1]
		local line = Model.costLine("ko-kr", row, { branch = "나뭇가지" })
		assert(line == "섬유 12/40 · 나뭇가지 30/30", line)
		assert(Model.costLine("en-us", row, nil) == "Fiber 12/40 · branch 30/30", Model.costLine("en-us", row, nil))
	end,
	["p111 loans: lend, borrow, return and recall rows send the exact camp-loan args"] = function()
		local HUDModel = require("./SurvivalHUDModel")
		local VIEW: { { any } } = { { 1280, 720, false }, { 360, 640, true } }
		local Sheet = require("./SocialSheet")
		local camp = slice()
		local choice = { itemId = "spare-hat", label = "Hat", available = 1 }
		for _, locale in { "en-us", "ko-kr" } do
			local function fits(rows: { any }, label: string)
				for _, row in rows do
					assert(
						row.text ~= "" and not string.find(row.text, "%%[ds]") and not string.find(row.text, "camp_"),
						label
					)
					for _, viewport in VIEW do
						local _, _, w =
							HUDModel.contextSheet(viewport[1] :: number, viewport[2] :: number, viewport[3] :: boolean)
						-- CampPanel draws every loan row as a 48 px control.
						assert(
							Sheet.rowHeight(row.text, Sheet.contentWidth(w)) <= 48,
							label .. " overflows: " .. row.text
						)
					end
				end
			end
			camp.loans = nil
			local empty = Model.loans(locale, camp, "a", choice, {}, { ["cold-head"] = "Cap" })
			fits(empty, "empty " .. locale)
			local offer = empty[1].args :: { string }
			assert(offer[1] == "offer" and offer[2] == "spare-hat", "offer args")
			assert(empty[2].name == "LoanEmpty" and empty[2].args == nil, "empty state")
			local none = Model.loans(locale, camp, "a", nil, {}, {})
			assert(none[1].args == nil and none[1].text == Model.text(locale, "camp_loan_nothing"), "nothing to lend")
			camp.loans = {
				L1 = { lender = "b", catalogId = "cold-head" },
				L2 = { lender = "a", catalogId = "cold-head" },
				L3 = { lender = "b", catalogId = "cold-head", borrower = "a" },
				L4 = { lender = "a", catalogId = "cold-head", borrower = "b" },
				L5 = { lender = "b", catalogId = "cold-head", borrower = "c" },
			}
			local rows = Model.loans(locale, camp, "a", choice, { b = "Bo", c = "Cy" }, { ["cold-head"] = "Cap" })
			fits(rows, "loans " .. locale)
			local by = {}
			for _, row in rows do
				by[row.name] = row
			end
			assert(
				(by["Loan-L1"].args :: { string })[1] == "take" and (by["Loan-L1"].args :: { string })[2] == "L1",
				"borrow"
			)
			assert(
				by["Loan-L1"].text == string.format(Model.text(locale, "camp_loan_take"), "Cap", "Bo"),
				by["Loan-L1"].text
			)
			assert(
				(by["Loan-L2"].args :: { string })[1] == "recall" and (by["Loan-L2"].args :: { string })[2] == "L2",
				"recall"
			)
			assert(
				(by["Loan-L3"].args :: { string })[1] == "return" and (by["Loan-L3"].args :: { string })[2] == "L3",
				"return"
			)
			assert(by["Loan-L4"].args == nil and by["Loan-L5"].args == nil, "borrowed by others: status only")
			assert(Model.loans(locale, { role = "guest" }, "a", choice, {}, {})[1] == nil, "guests see no loans")
			for _, code in Model.loanRefusalCodes() do
				local text = Model.refusal(locale, code, true)
				assert(text ~= Model.text(locale, "camp_refused"), code .. " has its own loan line")
				fits({ { text = text } }, code)
			end
			assert(Model.refusal(locale, "FORBIDDEN", true) ~= Model.refusal(locale, "FORBIDDEN"), "loan FORBIDDEN")
		end
	end,
}
