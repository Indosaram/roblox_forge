--!strict
-- MemoryBackend: in-memory atomic update backend for Lune specs and local runs.

export type Transform = (old: any) -> any

export type Backend = {
	update: (key: string, transform: Transform) -> (boolean, any),
}

export type Memory = Backend & {
	failNext: (n: number) -> (),
}

local MemoryBackend = {}

local function deepClone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = deepClone(item)
	end
	return copy
end

function MemoryBackend.new(): Memory
	local data: { [string]: any } = {}
	local failures = 0

	return {
		update = function(key: string, transform: Transform): (boolean, any)
			if failures > 0 then
				failures -= 1
				return false, "throttled"
			end
			local newValue = transform(deepClone(data[key]))
			data[key] = deepClone(newValue)
			return true, newValue
		end,
		failNext = function(n: number): ()
			failures = n
		end,
	}
end

return MemoryBackend
