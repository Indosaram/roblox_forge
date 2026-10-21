--!strict
-- Host-only (luau-lsp lune set): the robango-island generated catalog is not mounted by other game packs; marker: require("@lune/task")
local Ledger = require("./BrawlLedger")
local Match = require("../../../core/domain/brawl/Match")
local Data = require("../../../core/domain/genre/SerializedData")
local Policy =
	assert(require("../../../games/robango-island/src/shared/SurvivalContent").brawlPolicy, "generated brawl policy")
return {
	["wallet receipt quota share one replayable CAS and preserve envelope"] = function()
		local document: any = { survival = { balance = 0 }, otherGenre = { value = 7 } }
		local fail = false
		local locked = false
		local ledger = Ledger.new({
			store = {
				UpdateAsync = function(_: any, _: string, transform: any): any
					transform(Data.clone(document))
					if fail then
						error("save failed")
					end
					local value = transform(Data.clone(document))
					if value then
						document = Data.clone(value)
					end
					return value
				end,
			},
			key = function(actor: string): string
				return actor
			end,
			select = function(value: any): any
				return value.survival
			end,
			authorize = function(): boolean
				return not locked
			end,
		})
		local state = Match.new("m", Policy)
		state.phase, state.actors, state.winner = "finished", { a = {} }, "a"
		locked = true
		assert(
			ledger.claim("a", state, 0).reason == "PERSONAL_LOCKED" and document.survival.brawl == nil,
			"live writer excluded"
		)
		locked = false
		fail = true
		assert(not ledger.claim("a", state, 0).ok and document.survival.brawl == nil, "failure consumes nothing")
		fail = false
		for i = 1, Policy.dailySettlements + 1 do
			state.id = "m" .. i
			assert(ledger.claim("a", state, 0).ok, "claim")
			assert(ledger.claim("a", state, 0).amount == 0, "duplicate")
		end
		local reward = Policy.participationReward + Policy.winReward
		assert(document.survival.balance == Policy.dailySettlements * reward, "daily quota")
		state.id = "next-day"
		assert(ledger.claim("a", state, Policy.daySeconds).amount == reward, "UTC rollover")
		assert(document.otherGenre.value == 7, "envelope preserved")
		document.survival.balance = Policy.maximumBalance
		state.id = "full"
		assert(ledger.claim("a", state, Policy.daySeconds).reason == "WALLET_FULL", "capacity")
		assert(not document.survival.brawl.receipts.full, "no premature receipt")
	end,
}
