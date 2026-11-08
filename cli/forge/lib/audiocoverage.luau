--!strict
-- Audiocoverage: which cues a pack's genre declares but the pack ships no audio
-- for. A cue whose asset is missing resolves to an empty contentId in
-- core/ui-kit/genre/AudioKit, which then plays nothing and records the cue in
-- the ForgeHudAudio UnavailableCues attribute. That is a runtime breadcrumb, not
-- a build failure, so a pack can ship silent and still pass every stage. This
-- module turns the same question into a build-time answer.
--
-- Pure data + fs: no Roblox APIs, so `forge check` and Lune specs share it.

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Audiocoverage = {}

export type Cue = { key: string }

local function loadChunk(path: string): (boolean, any)
	-- Loaded as a chunk rather than required: the genre Audio module is a pure
	-- data table, and a require of its own would be the defect being caught.
	local ok, result = pcall(function()
		local luau = require("@lune/luau")
		return luau.load(fs.readFile(path))()
	end)
	return ok, result
end

--- Cue keys a genre declares, or nil when the genre ships no Audio module (a
--- genre whose client reads the declaration out of the serialized spec instead).
function Audiocoverage.declaredCues(genre: string): { string }?
	local path = "genres/" .. genre .. "/module/Audio.luau"
	if not fs.isFile(path) then
		return nil
	end
	local ok, loaded = loadChunk(path)
	if not ok or type(loaded) ~= "table" or type(loaded.cues) ~= "table" then
		return nil
	end
	local keys: { string } = {}
	for _, cue in loaded.cues do
		if type(cue) == "table" and type(cue.key) == "string" then
			table.insert(keys, cue.key)
		end
	end
	return keys
end

--- Every cue key the pack's genres declare that the pack's manifest does not
--- provide audio for, sorted. `manifest` is the decoded assets/manifest.yml.
function Audiocoverage.missingContentIds(pack: string, manifest: any): { string }
	local gamePath = "games/" .. pack .. "/game.yml"
	if not fs.isFile(gamePath) then
		return {}
	end
	local decodedOk, game = pcall(function()
		return serde.decode("yaml", fs.readFile(gamePath))
	end)
	if not decodedOk or type(game) ~= "table" or type(game.genres) ~= "table" then
		return {}
	end

	local provided: { [string]: boolean } = {}
	if type(manifest) == "table" and type(manifest.assets) == "table" then
		for _, entry in manifest.assets do
			if type(entry) == "table" and type(entry.key) == "string" then
				provided[entry.key] = true
			end
		end
	end

	local missing: { [string]: boolean } = {}
	for _, genre in game.genres do
		if type(genre) == "string" then
			local cues = Audiocoverage.declaredCues(genre)
			if cues ~= nil then
				for _, key in cues do
					if not provided[key] then
						missing[key] = true
					end
				end
			end
		end
	end

	local out: { string } = {}
	for key in missing do
		table.insert(out, key)
	end
	table.sort(out)
	return out
end

return Audiocoverage
