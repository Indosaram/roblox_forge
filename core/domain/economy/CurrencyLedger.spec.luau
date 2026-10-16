--!strict
-- Specs for CurrencyLedger (QA-BM-05): Robux-path credits never reach a free
-- random surface; only earned-only currency pays for one.

local CurrencyLedger = require("./CurrencyLedger")

return {
	["paid-tagged currency is refused by a free random surface and state is unchanged"] = function()
		local ledger = CurrencyLedger.new()
		assert(ledger:credit("paid", 500), "a paid credit is recorded")
		local before = ledger:balance()
		assert(ledger:debitForRandom(100) == false, "paid currency must not pay for a random draw")
		assert(ledger:balance() == before and ledger:earnedOnly() == 0, "refusal leaves state unchanged")
		local log = ledger:log()
		local last = log[#log]
		assert(last.op == "randomDebit" and last.ok == false, "the refused attempt is logged")
	end,

	["a mixed balance cannot top up a random draw with paid currency"] = function()
		local ledger = CurrencyLedger.new()
		ledger:credit("earned", 40)
		ledger:credit("paid", 1000)
		assert(ledger:debitForRandom(50) == false, "40 earned + paid must not cover a 50 draw")
		assert(ledger:earnedOnly() == 40 and ledger:balance() == 1040, "state unchanged")
	end,

	["earned-only currency pays for a free random surface"] = function()
		local ledger = CurrencyLedger.new()
		ledger:credit("earned", 120)
		ledger:credit("paid", 30)
		assert(ledger:debitForRandom(100) == true, "earned currency pays")
		assert(ledger:earnedOnly() == 20 and ledger:balance() == 50, "only the earned balance is drawn")
	end,

	["ordinary spend draws paid currency first and preserves earned-only"] = function()
		local ledger = CurrencyLedger.new()
		ledger:credit("earned", 100)
		ledger:credit("paid", 60)
		assert(ledger:debit(80), "deterministic spend succeeds")
		assert(ledger:earnedOnly() == 80, "paid 60 is spent before earned, got " .. ledger:earnedOnly())
		assert(ledger:debit(81) == false and ledger:balance() == 80, "overspend refused")
	end,

	["untagged or invalid credits are refused and never count as earned"] = function()
		local ledger = CurrencyLedger.new()
		for _, tag in { "robux", "", nil, 1 } :: { any } do
			assert(ledger:credit(tag, 10) == false, "unknown tag refused: " .. tostring(tag))
		end
		for _, amount in { 0, -1, 1.5, 0 / 0, math.huge, "10" } :: { any } do
			assert(ledger:credit("earned", amount) == false, "invalid amount refused: " .. tostring(amount))
		end
		assert(ledger:balance() == 0 and ledger:earnedOnly() == 0, "nothing credited")
	end,
}
