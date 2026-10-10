--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local assets = require("../lib/assets")
local generate = require("../lib/genregenerate")
return {
	["planner restoration refreshes real asset codegen on external disk fixture"] = function()
		local root = generate.absolute(
			(process.env.TEMP or process.env.TMP or "C:/Windows/Temp")
				.. "/forge-plan-assets-"
				.. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
		)
		local packDir = root .. "/fixture"
		local context = { packsDir = root }
		local ok, reason = xpcall(function()
			generate.ensureDir(packDir .. "/assets")
			local manifestPath = packDir .. "/assets/manifest.yml"
			local published = [[assets:
  - key: creature
    kind: model
    tool: forge-procgen
    source: procedural
    assetId: 12345
    moderation: Approved
]]
			fs.writeFile(manifestPath, published)
			local assembly = {
				files = { ["game.yml"] = [[name: Fixture
slug: fixture
]], ["assets/manifest.yml"] = "assets: []\n" },
				order = { "fixture" },
				generation = {},
				legacy = false,
			}
			local written, writeError = generate.write(assembly, packDir, "fixture", context)
			assert(written, writeError)
			local manifest, parseError = assets.parseManifest(serde.decode("yaml", fs.readFile(manifestPath)))
			assert(manifest, parseError)
			assert(manifest.assets[1].assetId == 12345, "uploaded ID preserved")
			assert(
				fs.readFile(packDir .. "/src/shared/Assets.luau") == assets.renderLuau(manifest, "fixture"),
				"asset codegen drift"
			)
			assert(
				fs.readFile(packDir .. "/asphalt.toml") == assets.asphaltConfig("fixture", manifest),
				"asphalt refreshed"
			)
			local failed = generate.write(assembly, packDir, "fixture", { packsDir = root .. "/missing" })
			assert(not failed, "actual asset codegen failure must abort generation")
		end, debug.traceback)
		local cleaned, cleanupError = pcall(function()
			if fs.isDir(root) then
				fs.removeDir(root)
			end
		end)
		assert(cleaned, tostring(cleanupError))
		assert(ok, tostring(reason))
	end,
}
