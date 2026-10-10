--!strict
-- Wallet: per-currency balances with validated credit and debit operations.

local Wallet = {}
Wallet.__index = Wallet

export type Wallet = typeof(setmetatable({} :: { _balances: { [string]: number } }, Wallet))

-- The economy's integrity boundary: no balance may exceed the largest integer
-- that double-precision floats represent exactly, so every credit stays exact
-- and can never silently round or overflow to infinity.
local MAX_SAFE_BALANCE = 2 ^ 53 - 1

local function checkCurrency(currency: string): ()
	if type(currency) ~= "string" or currency == "" then
		error("invalid currency")
	end
end

local function isValidAmount(amount: number): boolean
	if type(amount) ~= "number" then
		return false
	end
	if amount ~= amount or amount <= 0 or amount == math.huge then
		return false
	end
	return amount % 1 == 0
end

-- Initial balances may be zero but never negative, fractional, or above the max safe balance.
local function isValidInitial(amount: number): boolean
	if type(amount) ~= "number" then
		return false
	end
	if amount ~= amount or amount < 0 or amount == math.huge or amount > MAX_SAFE_BALANCE then
		return false
	end
	return amount % 1 == 0
end

function Wallet.new(initial: { [string]: number }?): Wallet
	local self = setmetatable({ _balances = {} :: { [string]: number } }, Wallet)
	if initial ~= nil then
		for currency, amount in pairs(initial) do
			checkCurrency(currency)
			if not isValidInitial(amount) then
				error("invalid amount")
			end
			self._balances[currency] = amount
		end
	end
	return self
end

function Wallet.balance(self: Wallet, currency: string): number
	checkCurrency(currency)
	return self._balances[currency] or 0
end

function Wallet.canAfford(self: Wallet, currency: string, amount: number): boolean
	checkCurrency(currency)
	if not isValidAmount(amount) then
		return false
	end
	return (self._balances[currency] or 0) >= amount
end

function Wallet.credit(self: Wallet, currency: string, amount: number): ()
	checkCurrency(currency)
	if not isValidAmount(amount) then
		error("invalid amount")
	end
	local result = (self._balances[currency] or 0) + amount
	if result ~= result or result == math.huge or result > MAX_SAFE_BALANCE then
		error("credit would overflow balance past the max safe value")
	end
	self._balances[currency] = result
end

function Wallet.debit(self: Wallet, currency: string, amount: number): boolean
	checkCurrency(currency)
	if not isValidAmount(amount) then
		error("invalid amount")
	end
	local current = self._balances[currency] or 0
	if current < amount then
		return false
	end
	self._balances[currency] = current - amount
	return true
end

return Wallet
