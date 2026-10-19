--!strict
-- MarketPanel pure surface: namespaced durable action ids, item display names, sell rows only for
-- goods the player holds, clamped list drafts and the en/ko string table mirrored in the pack CSV.
local fs = require("@lune/fs")
local Contract = require("./Contract")
local Panel = require("./MarketPanel")

local function market(): any
	return {
		balance = 120,
		feeBasisPoints = 500,
		minFee = 1,
		holdings = { wood = 6 },
		catalogs = {
			{ catalogId = "wood", listings = { { id = "mk:9:1", seller = "9", quantity = 2, unitPrice = 30 } } },
			{ catalogId = "fiber", listings = {} },
			{ catalogId = "berry", listings = { { id = "mk:7:2", seller = "7", quantity = 1, unitPrice = 4 } } },
		},
		listed = {
			["mk:7:2"] = { catalogId = "berry", quantity = 1, unitPrice = 4, status = "active" },
			["mk:7:1"] = { catalogId = "wood", quantity = 1, unitPrice = 9, status = "returned" },
		},
	}
end

return {
	["every panel action id is a namespaced survival-coop contract action"] = function()
		local declared: { [string]: boolean } = {}
		for _, action in Contract.actions do
			declared[Contract.id .. ":" .. action.id] = true
		end
		for _, id in Panel.ACTIONS do
			assert(string.sub(id, 1, #"survival-coop:") == "survival-coop:", "unprefixed panel action: " .. id)
			assert(declared[id], "panel action not declared by the contract: " .. id)
			local bare = string.sub(id, #"survival-coop:" + 1)
			assert(table.find(Contract.extensionActions :: { string }, bare), "not an extension action: " .. id)
		end
	end,
	["item names come from ctx.names with the raw id as fallback"] = function()
		local names = { wood = "쓰러진 통나무" }
		assert(Panel.name(names, "wood") == "쓰러진 통나무" and Panel.name(names, "reed") == "reed", "lookup")
		assert(Panel.name(nil, "wood") == "wood", "no names")
		local model = Panel.model(market(), names, {}, "7")
		assert(model.sell[1].name == "쓰러진 통나무", "sell row name")
		assert(model.browse[1].name == "쓰러진 통나무", "browse row name")
		assert(model.mine[1].name == "berry", "own row falls back to the id")
	end,
	["sell rows list only held goods with a clamped draft and the server fee"] = function()
		local drafts = {}
		local model = Panel.model(market(), nil, drafts, "7")
		assert(#model.sell == 1 and model.sell[1].catalogId == "wood" and model.sell[1].held == 6, "held only")
		local draft = model.sell[1].draft
		assert(draft.quantity == 1 and draft.price == 30, "defaults to 1 at the lowest listed price")
		assert(model.sell[1].fee == 1, "minFee")
		drafts.wood = { quantity = 50, price = 0 }
		local clamped = Panel.model(market(), nil, drafts, "7").sell[1]
		assert(clamped.draft.quantity == 6 and clamped.draft.price == 1, "clamped to holdings and >= 1")
		local empty = market()
		empty.holdings = {}
		assert(#Panel.model(empty, nil, {}, "7").sell == 0, "nothing held -> empty-state hint")
	end,
	["the server gate closes trading with a localized reason up front"] = function()
		local open = Panel.model(market(), nil, {}, "7")
		assert(open.eligible and open.gate == nil, "eligible or legacy snapshot keeps trading open")
		local closed = market()
		closed.eligible, closed.ineligibleReason = false, "INELIGIBLE_TUTORIAL"
		local model = Panel.model(closed, nil, {}, "7")
		assert(not model.eligible and model.gate == "market_gate_tutorial", "tutorial gate")
		assert(
			Panel.text("ko-kr", model.gate :: string) == "첫 안내를 끝내야 시장 거래가 열려요",
			"ko reason"
		)
		assert(#model.sell == 1 and #model.browse == 1, "rows stay visible, only actions are disabled")
		for reason, key in
			{
				INELIGIBLE_ACCOUNT_AGE = "market_gate_age",
				INELIGIBLE_PLAYTIME = "market_gate_playtime",
				DAILY_TRADE_CAP = "market_gate_cap",
				SOMETHING_NEW = "market_ineligible",
			}
		do
			closed.ineligibleReason = reason
			assert(Panel.model(closed, nil, {}, "7").gate == key, reason)
		end
	end,
	["a new player's first contract pays more than the minimum listing fee"] = function()
		local content = require("@lune/serde").decode("yaml", fs.readFile("games/robango-island/content.yml"))
		local first = content.contracts.firstDay[1]
		local coins = 0
		for _, entry in content.contracts.entries do
			if entry.id == first then
				coins = entry.coins or 0
			end
		end
		local fee = Panel.fee({ feeBasisPoints = 500, minFee = 1 }, 1, 10)
		assert(coins > fee, "first contract coins " .. coins .. " must exceed the fee " .. fee)
	end,
	["browse hides own listings and mine shows only active ones"] = function()
		local model = Panel.model(market(), nil, {}, "7")
		assert(#model.browse == 1 and model.browse[1].listings[1].id == "mk:9:1", "others' listings only")
		assert(#model.mine == 1 and model.mine[1].id == "mk:7:2", "own active listing")
	end,
	["steppers move quantity within holdings and price by magnitude"] = function()
		local draft = { quantity = 1, price = 10 }
		assert(Panel.step(draft, "quantity", 1, 6).quantity == 2, "qty up")
		assert(Panel.step(draft, "quantity", -1, 6).quantity == 1, "qty floor")
		assert(Panel.step({ quantity = 6, price = 10 }, "quantity", 1, 6).quantity == 6, "qty ceiling")
		assert(Panel.step(draft, "price", 1, 6).price == 11, "price +1 under 100")
		assert(Panel.step({ quantity = 1, price = 250 }, "price", 1, 6).price == 260, "price +10 at 100s")
		assert(Panel.step({ quantity = 1, price = 1 }, "price", -1, 6).price == 1, "price floor")
	end,
	["fee preview matches core Market"] = function()
		local Core = require("../../../core/domain/market/Market")
		local core = Core.new({
			store = { update = function() end } :: any,
			transfer = function()
				return false
			end,
			wallet = function() end :: any,
		})
		local view = { feeBasisPoints = 500, minFee = 1 }
		for _, case in { { 1, 1 }, { 4, 25 }, { 10, 999 } } do
			assert(Panel.fee(view, case[1], case[2]) == core:fee(case[1], case[2]), "fee parity")
		end
	end,
	["strings are mirrored in the pack locale in both languages"] = function()
		local csv = fs.readFile("games/robango-island/locale/strings.csv")
		local rows: { [string]: string } = {}
		for _, line in string.split(csv, "\n") do
			local key = string.match(line, "^([%w_]+),")
			if key then
				rows[key] = line
			end
		end
		for key, entry in Panel.STRINGS :: { [string]: { string } } do
			local row = rows[key]
			assert(row, key .. ": missing from strings.csv")
			assert(string.find(row, entry[1], 1, true), key .. ": en mismatch")
			assert(string.find(row, entry[2], 1, true), key .. ": ko mismatch")
		end
		assert(Panel.text("ko-kr", "market_have", "통나무", 3) == "통나무 (보유 3)", "ko format")
		assert(Panel.refusal("en-us", "INSUFFICIENT_FUNDS") == "Not enough Shellmoney", "refusal map")
		assert(Panel.refusal("en-us", "WHATEVER") == Panel.text("en-us", "market_failed"), "fallback")
	end,
}
