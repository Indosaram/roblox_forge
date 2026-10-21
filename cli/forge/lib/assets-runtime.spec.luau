--!strict
local luau = require("@lune/luau")
local Assets = require("./assets")

return {
	["compact assets preserve published, unpublished and unknown lookups"] = function()
		local manifest = assert(Assets.parseManifest({
			assets = {
				{
					key = "published",
					kind = "image",
					tool = "studio-mcp",
					source = "art",
					assetId = 999999999999999,
					moderation = "Approved",
				},
				{
					key = "pending",
					kind = "image",
					tool = "studio-mcp",
					source = "art",
					assetId = 123,
					moderation = "PendingModeration",
				},
				{
					key = "unpublished",
					kind = "image",
					tool = "studio-mcp",
					source = "art",
					assetId = 0,
					moderation = "NotUploaded",
				},
			},
		}))
		local runtime = luau.load(Assets.renderLuau(manifest))()
		assert(runtime.published == "rbxassetid://999999999999999", "15-digit IDs must retain every digit")
		assert(
			runtime.pending == "" and runtime.unpublished == "" and runtime.unknown == "",
			"missing assets resolve to empty strings"
		)
		local count = 0
		for _, value in runtime do
			assert(value == runtime.published, "iteration exposes resolved URLs, not numeric IDs")
			count += 1
		end
		assert(count == 1, "only playable assets occupy table entries")
	end,
	["generated audio prefers uploads and preserves zero-ID development URLs"] = function()
		local entries = {}
		for _, kind in { "sfx", "bgm" } do
			for _, id in { 0, 123 } do
				table.insert(entries, {
					key = kind .. tostring(id),
					kind = kind,
					tool = "forge-procgen",
					source = "procedural audio",
					path = "assets/audio/" .. kind .. ".wav",
					assetId = id,
					moderation = "Approved",
				})
			end
		end
		local manifest = assert(Assets.parseManifest({ assets = entries }))
		local runtime = luau.load(Assets.renderLuau(manifest, "fixture"))()
		local noPack = luau.load(Assets.renderLuau(manifest))()
		for _, kind in { "sfx", "bgm" } do
			assert(runtime[kind .. "123"] == "rbxassetid://123", "uploaded WAV must use its published ID")
			assert(
				runtime[kind .. "0"] == "rbxasset://forge/fixture/" .. kind .. ".wav",
				'runtime[kind .. "0"] == "rbxasset://forge/fixture/" .. kind .. ".wav"'
			)
			assert(
				noPack[kind .. "123"] == "rbxassetid://123" and noPack[kind .. "0"] == "",
				'noPack[kind .. "123"] == "rbxassetid://123" and noPack[kind .. "0"] == ""'
			)
		end
		local production = assert(Assets.parseManifest({ assets = { entries[2], entries[4] } }))
		assert(Assets.check(production, "production").ok, 'Assets.check(production, "production").ok')
		assert(not Assets.check(manifest, "production").ok, 'not Assets.check(manifest, "production").ok')
	end,
}
