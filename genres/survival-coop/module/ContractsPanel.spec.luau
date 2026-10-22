--!strict
local ContractsPanel = require("./ContractsPanel")

return {
	["the board keeps its buttons across snapshots that change nothing it renders"] = function()
		local offer: any = { id = "c1", deliver = { { item = "wood", quantity = 3 } }, reward = {}, trust = 10 }
		local state: any = { offers = { offer }, trust = {} }
		local first = ContractsPanel.renderKey(ContractsPanel.model("ko-kr", state, {}))
		-- A fresh, equal snapshot (a vitals tick re-sends the same contracts) must not rebuild the rows.
		local again: any = { offers = { table.clone(offer) }, trust = {} }
		assert(ContractsPanel.renderKey(ContractsPanel.model("ko-kr", again, {})) == first, "equal state, same key")
		local taken = table.clone(offer)
		taken.accepted = true
		local accepted: any = { offers = { taken }, trust = {} }
		assert(
			ContractsPanel.renderKey(ContractsPanel.model("ko-kr", accepted, {})) ~= first,
			"accepting a contract turns Accept- into Deliver-, so the rows must rebuild"
		)
		local more: any = { offers = { offer, { id = "c2", deliver = {}, reward = {}, trust = 5 } }, trust = {} }
		assert(
			ContractsPanel.renderKey(ContractsPanel.model("ko-kr", more, {})) ~= first,
			"a new offer changes the key"
		)
	end,
	["contract rows prefer the pack's display names over genre fallbacks"] = function()
		local state = {
			offers = {
				{
					id = "c1",
					deliver = { { item = "wood", quantity = 3 } },
					reward = { { item = "cord", quantity = 1 } },
					trust = 40,
				},
			},
			trust = {},
		}
		local view = ContractsPanel.model("ko-kr", state, { wood = "쓰러진 통나무", cord = "섬유 끈" })
		assert(view.rows[1].goal == "쓰러진 통나무 x3", view.rows[1].goal)
		assert(view.rows[1].reward == "섬유 끈 x1", view.rows[1].reward)
	end,
	["a coin reward is shown in both languages after the item rewards"] = function()
		local withCoins: any =
			{ id = "c1", deliver = {}, reward = { { item = "cord", quantity = 1 } }, coins = 15, trust = 10 }
		local without: any = { id = "c2", deliver = {}, reward = {}, trust = 10 }
		local state: any = {
			offers = { withCoins, without },
			trust = {},
		}
		local ko = ContractsPanel.model("ko-kr", state, { cord = "섬유 끈" })
		assert(ko.rows[1].reward == "섬유 끈 x1, 조개돈 15", ko.rows[1].reward)
		assert(ko.rows[2].reward == "", "no coins, no coin text")
		local en = ContractsPanel.model("en-us", state, { cord = "Twisted Cord" })
		assert(en.rows[1].reward == "Twisted Cord x1, Shellmoney 15", en.rows[1].reward)
	end,
	["refusals map to player sentences, never the raw reason code"] = function()
		local insufficient = ContractsPanel.refusal("ko-kr", "INSUFFICIENT_ITEMS")
		assert(insufficient == "납품할 아이템이 아직 부족해요.", insufficient)
		assert(ContractsPanel.refusal("en", "BAG_FULL") == "Your bag is full. Make room first.", "bag full")
		for _, reason in { "INSUFFICIENT_ITEMS", "BAG_FULL", "CONTRACT_PENDING", "REQUEST_CONFLICT", nil :: any } do
			local text = ContractsPanel.refusal("ko-kr", reason)
			assert(not string.find(text, "%u%u%u"), "raw code leaked: " .. text)
		end
	end,
	["a short delivery names what to carry in the bag in both languages"] = function()
		local short = { item = "wood", have = 1, need = 3 }
		local en = ContractsPanel.refusal("en-us", "INSUFFICIENT_ITEMS", short, { wood = "Driftwood" })
		assert(en == "Carry Driftwood x3 in your bag (have 1).", en)
		local ko = ContractsPanel.refusal("ko-kr", "INSUFFICIENT_ITEMS", short, { wood = "쓰러진 통나무" })
		assert(ko == "가방에 쓰러진 통나무 3개를 들고 오세요 (현재 1개).", ko)
	end,
}
