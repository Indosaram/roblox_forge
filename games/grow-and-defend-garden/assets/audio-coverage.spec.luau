--!strict
-- Every cue the grow-harvest genre binds to a committed action must resolve to a
-- playable Roblox content id. A cue that falls back to an unshipped local
-- rbxasset:// path (or to the empty-string default) is silent in a live place, so
-- this spec fails instead of shipping quiet gameplay.
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local ROOT = "games/grow-and-defend-garden/"
local GENRE = require("../../../genres/grow-harvest/module/Audio")
local Assets = require("../src/shared/Assets")

local function manifestByKey(): { [string]: any }
	local doc = serde.decode("yaml", fs.readFile(ROOT .. "assets/manifest.yml"))
	local byKey = {}
	for _, asset in doc.assets do
		byKey[asset.key] = asset
	end
	return byKey
end

local function isContentId(value: any): boolean
	return type(value) == "string" and string.match(value, "^rbxassetid://[1-9]%d*$") ~= nil
end

return {
	["every bound cue resolves to an uploaded Roblox asset id"] = function()
		local byKey = manifestByKey()
		local bound = {}
		for _, binding in GENRE.bindings do
			bound[binding.cue] = true
		end
		for cue in bound do
			local asset = byKey[cue]
			assert(asset ~= nil, "genre binds cue " .. cue .. " but the manifest has no such asset")
			assert(type(asset.assetId) == "number" and asset.assetId > 0, cue .. " has no uploaded assetId")
			assert(asset.moderation ~= "NotUploaded", cue .. " still reports NotUploaded")
			local resolved = Assets[cue]
			assert(
				isContentId(resolved),
				cue .. " resolves to " .. tostring(resolved) .. ", which a live place cannot load"
			)
			assert(
				resolved == "rbxassetid://" .. string.format("%.0f", asset.assetId),
				cue .. " resolves to a different id than the manifest records"
			)
		end
	end,

	["every declared cue has a generated wav on disk"] = function()
		local byKey = manifestByKey()
		for _, cue in GENRE.cues do
			local asset = byKey[cue.key]
			assert(asset ~= nil, "declared cue " .. cue.key .. " has no manifest asset")
			assert(type(asset.path) == "string" and fs.isFile(ROOT .. asset.path), cue.key .. " wav is missing")
		end
	end,
}
