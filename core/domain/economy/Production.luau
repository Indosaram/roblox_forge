--!strict
-- Production: fractional accrual that carries remainders so output never drifts.

export type Accumulator = { carry: number }

local EPSILON = 1e-9

local Production = {}

local function checkNonNegative(value: number, label: string): ()
	if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
		error("invalid " .. label)
	end
end

function Production.new(): Accumulator
	return { carry = 0 }
end

function Production.accrue(acc: Accumulator, ratePerSecond: number, dt: number): number
	checkNonNegative(ratePerSecond, "rate")
	checkNonNegative(dt, "dt")
	local total = acc.carry + ratePerSecond * dt
	local whole = math.floor(total + EPSILON)
	acc.carry = total - whole
	return whole
end

return Production
