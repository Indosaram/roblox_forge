--!strict
-- Every Roblox asset id the shipped Robango source names literally is a manifest row (p134 v68: one
-- image failed to load at the harbor arrival, hash 94ff12cc..., AssetDelivery404 wasModerated). A
-- literal id outside assets/manifest.yml escapes the moderation refresh (`forge assets status`) and
-- the universe Use grant (`forge assets grant`), so a moderated or ungranted image could ship unseen.
-- Scope: the pack's own source, the survival-coop genre and core, as shipped (specs, fixtures and
-- the generated Assets/ProcAssets tables are excluded; Assets.luau is codegen from the manifest).
-- Roblox catalog items the survivor presets dress (SurvivorAvatar bundle parts, faces, clothes) are
-- bare numbers checked against the catalog there, not `rbxassetid://` literals, and stay out of scope.
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local ROOTS = {
	"games/robango-island/src",
	"games/robango-island/default.project.json",
	"genres/survival-coop/module",
	"core",
}

-- Literal asset ids in `text`: rbxassetid://<n> and the web asset URLs (asset/?id=<n>, asset?id=<n>).
local function literalIds(text: string): { string }
	local out = {}
	for id in string.gmatch(text, "rbxassetid://(%d+)") do
		table.insert(out, id)
	end
	for id in string.gmatch(text, "asset/?%?id=(%d+)") do
		table.insert(out, id)
	end
	return out
end

local function shipped(path: string): boolean
	local name = string.match(path, "[^/]+$") or path
	if string.find(name, "%.spec%.luau$") or string.find(name, "%.fixture%.luau$") then
		return false
	end
	if name == "Assets.luau" or name == "ProcAssets.luau" then
		return false
	end
	return string.find(name, "%.luau$") ~= nil or string.find(name, "%.json$") ~= nil
end

local function walk(path: string, out: { string })
	if fs.isFile(path) then
		if shipped(path) then
			table.insert(out, path)
		end
		return
	end
	for _, name in fs.readDir(path) do
		local child = path .. "/" .. name
		if fs.isDir(child) then
			if name ~= "fixtures" then
				walk(child, out)
			end
		elseif shipped(child) then
			table.insert(out, child)
		end
	end
end

local function manifestIds(): { [string]: string }
	local manifest = serde.decode("yaml", fs.readFile("games/robango-island/assets/manifest.yml"))
	local ids: { [string]: string } = {}
	for _, row in manifest.assets do
		for _, field in { "assetId", "decalAssetId" } do
			local value = row[field]
			if type(value) == "number" and value > 0 then
				ids[string.format("%.0f", value)] = row.key
			elseif type(value) == "string" and string.match(value, "^%d+$") and value ~= "0" then
				ids[value] = row.key
			end
		end
	end
	return ids
end

return {
	["the literal id scanner finds rbxassetid and web asset URLs"] = function()
		local found = literalIds('a = "rbxassetid://123" b = "http://www.roblox.com/asset/?id=456" c = "rbxasset://x"')
		assert(#found == 2 and found[1] == "123" and found[2] == "456", table.concat(found, ","))
	end,
	["every rbxassetid named in shipped source is a manifest row"] = function()
		local known = manifestIds()
		local files: { string } = {}
		for _, root in ROOTS do
			walk(root, files)
		end
		assert(#files > 100, "scanned the shipped source, got " .. #files .. " files")
		local missing: { string } = {}
		local seen = 0
		for _, path in files do
			for _, id in literalIds(fs.readFile(path)) do
				seen += 1
				if not known[id] then
					table.insert(missing, path .. ": " .. id)
				end
			end
		end
		assert(seen >= 1, "the title key art id is a literal in TitleFlow")
		assert(#missing == 0, "asset ids outside assets/manifest.yml:\n" .. table.concat(missing, "\n"))
	end,
	["the arrival art is approved manifest images"] = function()
		local Travel = (require :: any)("./src/first/TravelScreen")
		local Flow = (require :: any)("./src/first/TitleFlow")
		local manifest = serde.decode("yaml", fs.readFile("games/robango-island/assets/manifest.yml"))
		local rows: { [string]: any } = {}
		for _, row in manifest.assets do
			rows[row.key] = row
		end
		local keys: { string } = {}
		for _, key in Travel.ISLAND_ART do
			table.insert(keys, key)
		end
		for _, key in Travel.BIOME_ART do
			table.insert(keys, key)
		end
		for _, key in keys do
			local row = rows[key]
			assert(row and row.kind == "image" and row.moderation == "Approved", key .. " is an approved image row")
		end
		local art = string.match(Flow.ART_IMAGE, "^rbxassetid://(%d+)$")
		assert(art and string.format("%.0f", rows["ui-title-key-art"].assetId) == art, "title art is the manifest row")
		assert(rows["ui-title-key-art"].moderation == "Approved", "title art approved")
	end,
}
