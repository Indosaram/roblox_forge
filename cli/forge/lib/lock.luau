--!strict
-- lock: pure validation of a pack's forge-lock.yml against package manifests.
-- The check [lock] stage reads the YAML files and calls this module, which does
-- no IO so every rule is unit-testable.

export type Lock = {
	core: string?,
	genres: { [string]: string },
}

export type Expected = {
	core: string,
	genres: { [string]: string },
	packGenres: { string },
}

local M = {}

local function stringField(value: any, key: string): string?
	if typeof(value) ~= "table" then
		return nil
	end
	local raw = value[key]
	if typeof(raw) == "string" and raw ~= "" then
		return raw
	end
	return nil
end

--- Normalizes a decoded forge-lock.yml document into a Lock. Missing or
--- non-string entries become nil/absent so validate() can report them.
function M.fromTable(decoded: any): Lock
	local genres: { [string]: string } = {}
	local rawGenres = if typeof(decoded) == "table" then decoded.genres else nil
	if typeof(rawGenres) == "table" then
		for name, version in rawGenres do
			if typeof(name) == "string" and typeof(version) == "string" then
				genres[name] = version
			end
		end
	end
	return {
		core = stringField(decoded, "core"),
		genres = genres,
	}
end

local function listed(packGenres: { string }, name: string): boolean
	for _, genre in packGenres do
		if genre == name then
			return true
		end
	end
	return false
end

--- Validates a lock against the versions the pack references. Returns a list of
--- human-readable errors; an empty list means the pins are correct.
function M.validate(lock: Lock, expected: Expected): { string }
	local errors: { string } = {}

	if lock.core == nil then
		table.insert(errors, "core: missing from forge-lock.yml (expected " .. expected.core .. ")")
	elseif lock.core ~= expected.core then
		table.insert(errors, "core: locked " .. lock.core .. " but core/forge-package.yml has " .. expected.core)
	end

	for _, genre in expected.packGenres do
		local wanted = expected.genres[genre]
		local locked = lock.genres[genre]
		if wanted == nil then
			table.insert(
				errors,
				"genre " .. genre .. ": listed in game.yml but no genres/" .. genre .. "/forge-package.yml"
			)
		elseif locked == nil then
			table.insert(errors, "genre " .. genre .. ": missing from forge-lock.yml (expected " .. wanted .. ")")
		elseif locked ~= wanted then
			table.insert(
				errors,
				"genre "
					.. genre
					.. ": locked "
					.. locked
					.. " but genres/"
					.. genre
					.. "/forge-package.yml has "
					.. wanted
			)
		end
	end

	-- A pin for a package the pack never references is drift too.
	for genre, locked in lock.genres do
		if not listed(expected.packGenres, genre) then
			if expected.genres[genre] == nil then
				table.insert(
					errors,
					"genre " .. genre .. ": locked at " .. locked .. " but no genres/" .. genre .. "/forge-package.yml"
				)
			else
				table.insert(errors, "genre " .. genre .. ": locked but not listed in game.yml")
			end
		end
	end

	return errors
end

return M
