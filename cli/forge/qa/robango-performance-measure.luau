--!strict
-- Run after forge test qa-evidence to report its fully-published source budget.
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local assets = require("../lib/assets")
local pack = "games/robango-island"
local place: any = roblox.deserializePlace(fs.readFile("build/qa-perf-01.rbxl"))
local sourceBytes = 0
for _, value in place:GetDescendants() do
	if value:IsA("LuaSourceContainer") then
		sourceBytes += #value.Source
	end
end
local manifest = assert(assets.parseManifest(serde.decode("yaml", fs.readFile(pack .. "/assets/manifest.yml"))))
for _, asset in manifest.assets do
	asset.assetId, asset.moderation = 999999999999999, "Approved"
end
local futureBytes = sourceBytes
	- #fs.readFile(pack .. "/src/shared/Assets.luau")
	+ #assets.renderLuau(manifest, "robango-island")
print(
	"QA-PERF-01 sourceBytes="
		.. sourceBytes
		.. " futureBytes="
		.. futureBytes
		.. " headroom="
		.. (2485000 - futureBytes)
)
