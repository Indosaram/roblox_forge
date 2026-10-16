--!strict
-- CurrencyLedger: per-source tagged balances for one soft currency (plan §8.2,
-- ADR-07). Every credit carries a source tag: "earned" (gameplay) or "paid"
-- (anything a Robux purchase or subscription touched). Only the earned-only
-- balance may pay for a free random surface, so no Robux path ever reaches a
-- random outcome (QA-BM-05). Every attempt is appended to an audit log.

local CurrencyLedger = {}
CurrencyLedger.__index = CurrencyLedger

export type Tag = "earned" | "paid"

export type LogEntry = {
	op: "credit" | "debit" | "randomDebit",
	tag: Tag?,
	amount: number,
	ok: boolean,
	reason: string?,
}

export type CurrencyLedger = typeof(setmetatable(
	{} :: { _earned: number, _paid: number, _log: { LogEntry } },
	CurrencyLedger
))

local MAX_SAFE_BALANCE = 2 ^ 53 - 1

local function isValidAmount(amount: any): boolean
	return type(amount) == "number"
		and amount == amount
		and amount > 0
		and amount ~= math.huge
		and amount % 1 == 0
		and amount <= MAX_SAFE_BALANCE
end

function CurrencyLedger.new(): CurrencyLedger
	return setmetatable({ _earned = 0, _paid = 0, _log = {} :: { LogEntry } }, CurrencyLedger)
end

function CurrencyLedger.balance(self: CurrencyLedger): number
	return self._earned + self._paid
end

function CurrencyLedger.earnedOnly(self: CurrencyLedger): number
	return self._earned
end

function CurrencyLedger.log(self: CurrencyLedger): { LogEntry }
	return table.clone(self._log)
end

local function record(self: CurrencyLedger, entry: LogEntry): boolean
	table.insert(self._log, entry)
	return entry.ok
end

--- Credits `amount` under `tag`. Unknown tags and invalid amounts are refused
--- (returns false, state unchanged) so an untagged credit can never count as earned.
function CurrencyLedger.credit(self: CurrencyLedger, tag: any, amount: any): boolean
	if tag ~= "earned" and tag ~= "paid" then
		return record(self, { op = "credit", amount = tonumber(amount) or 0, ok = false, reason = "unknown tag" })
	end
	if not isValidAmount(amount) or self:balance() + amount > MAX_SAFE_BALANCE then
		return record(self, { op = "credit", tag = tag, amount = tonumber(amount) or 0, ok = false, reason = "amount" })
	end
	if tag == "earned" then
		self._earned += amount
	else
		self._paid += amount
	end
	return record(self, { op = "credit", tag = tag, amount = amount, ok = true })
end

--- Ordinary deterministic spend. Draws the paid-tagged balance first so the
--- earned-only balance is never consumed while paid currency is available.
function CurrencyLedger.debit(self: CurrencyLedger, amount: any): boolean
	if not isValidAmount(amount) or self:balance() < amount then
		return record(self, { op = "debit", amount = tonumber(amount) or 0, ok = false, reason = "insufficient" })
	end
	local fromPaid = math.min(self._paid, amount)
	self._paid -= fromPaid
	self._earned -= amount - fromPaid
	return record(self, { op = "debit", amount = amount, ok = true })
end

--- Spend for a free random surface (reroll, free draw): accepts the
--- earned-only balance alone. A shortfall is refused with state unchanged even
--- when paid-tagged currency would cover it.
function CurrencyLedger.debitForRandom(self: CurrencyLedger, amount: any): boolean
	if not isValidAmount(amount) or self._earned < amount then
		return record(self, {
			op = "randomDebit",
			tag = "earned",
			amount = tonumber(amount) or 0,
			ok = false,
			reason = "earned-only balance required",
		})
	end
	self._earned -= amount
	return record(self, { op = "randomDebit", tag = "earned", amount = amount, ok = true })
end

return CurrencyLedger
