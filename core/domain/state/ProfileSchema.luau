--!strict
-- ProfileSchema: engine-free versioned migration for persisted profile records.

export type Data = { [string]: any }
export type Defaults = () -> Data
export type MigrationStep = (Data) -> Data
export type Steps = { [number]: MigrationStep }

local ProfileSchema = {}

local function applyDefaults(target: Data, defaults: Defaults): ()
	for key, value in pairs(defaults()) do
		if target[key] == nil then
			target[key] = value
		end
	end
end

-- Recursively copies a payload so migration steps can freely mutate the
-- result without aliasing the caller's `raw` table (or any of its nested
-- tables).
local function deepClone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in pairs(value) do
		copy[key] = deepClone(inner)
	end
	return copy
end

-- Brings any stored payload up to `current`, applying steps[version] .. steps[current - 1].
function ProfileSchema.migrate(raw: any, current: number, defaults: Defaults, steps: Steps): Data
	if type(raw) ~= "table" then
		local fresh = defaults()
		fresh.version = current
		return fresh
	end

	local source = raw :: Data
	local version = source.version
	if type(version) ~= "number" or version ~= version or version % 1 ~= 0 or version < 0 then
		version = 0
	end
	if version > current then
		error("future version: " .. tostring(version) .. " > " .. tostring(current), 2)
	end

	local data = deepClone(source) :: Data

	local v = version
	while v < current do
		local step = steps[v]
		if step ~= nil then
			data = step(data)
		end
		v += 1
	end

	applyDefaults(data, defaults)
	data.version = current
	return data
end

return ProfileSchema
