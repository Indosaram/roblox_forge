--!strict
-- Validate: pure, engine-free guards for untrusted remote arguments.

local Validate = {}

-- True when `value` is a string no longer than `maxLen` characters.
function Validate.isString(value: any, maxLen: number): boolean
	return type(value) == "string" and #value <= maxLen
end

-- True when `value` is an integer within [min, max] inclusive.
function Validate.isIndex(value: any, min: number, max: number): boolean
	if type(value) ~= "number" then
		return false
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return false
	end
	return value % 1 == 0 and value >= min and value <= max
end

-- True when `value` is a real number (finite, not NaN or infinity).
function Validate.isFiniteNumber(value: any): boolean
	if type(value) ~= "number" then
		return false
	end
	return value == value and value ~= math.huge and value ~= -math.huge
end

return Validate
