--!strict
-- Specs for the pure `forge new` templates: a scaffolded game.yml must pass the
-- check [game] validation, the project maps the framework, and every generated
-- collect-raid file is placeholder-free and data the runtime can consume.

local serde = require("@lune/serde")
local luau = require("@lune/luau")

local Scaffold = require("./scaffold")
local GameYml = require("./gameyml")

local function decodeYaml(text: string): any
	return serde.decode("yaml", text)
end

return {
	["slug validation accepts kebab and rejects everything else"] = function()
		assert(Scaffold.isValidSlug("forge-demo"), "forge-demo should be valid")
		assert(Scaffold.isValidSlug("a1"), "a1 should be valid")
		assert(not Scaffold.isValidSlug(""), "empty should be invalid")
		assert(not Scaffold.isValidSlug("Forge"), "uppercase should be invalid")
		assert(not Scaffold.isValidSlug("-lead"), "leading hyphen should be invalid")
		assert(not Scaffold.isValidSlug("trail-"), "trailing hyphen should be invalid")
		assert(not Scaffold.isValidSlug("double--hyphen"), "double hyphen should be invalid")
	end,

	["title and pascal case join slug words"] = function()
		assert(Scaffold.titleCase("forge-demo") == "Forge Demo", "titleCase must join words")
		assert(Scaffold.pascalCase("forge-demo") == "ForgeDemo", "pascalCase must join words")
		assert(Scaffold.pascalCase("kaiju-egg-raiders") == "KaijuEggRaiders", "pascalCase must handle three words")
	end,

	["fill replaces placeholders literally"] = function()
		local out = Scaffold.fill("a __X__ b __X__ c", { __X__ = "100%" })
		assert(out == "a 100% b 100% c", "percent signs must survive: " .. out)
	end,

	["the scaffolded game.yml passes the check validation"] = function()
		local game = decodeYaml(Scaffold.gameYml("forge-demo", { "collect-raid" }))
		local result = GameYml.validate(game)
		assert(result.ok, "scaffolded game.yml must validate: " .. table.concat(result.errors, "; "))
		assert(game.art_style ~= "TBD", "art_style must be a real default")
		assert(type(game.poly_budget) == "table" and next(game.poly_budget) ~= nil, "poly_budget must be filled")
	end,

	["the project maps core, genres, the pack, remotes, and both scripts"] = function()
		local project = serde.decode("json", Scaffold.projectJson("forge-demo", "ForgeDemo", { "collect-raid" }))
		local rs = project.tree.ReplicatedStorage
		assert(rs.Remotes ~= nil, "Remotes folder must be mapped")
		assert(rs.Forge.core.domain["$path"] == "../../core/domain", "domain path")
		assert(rs.Forge.core.infra["$path"] == "../../core/infra", "infra path")
		assert(rs.Forge.core["ui-kit"]["$path"] == "../../core/ui-kit", "ui-kit path")
		assert(rs.Forge.core.anticheat["$path"] == "../../core/anticheat", "anticheat path")
		assert(rs.Forge.genres["collect-raid"].module["$path"] == "../../genres/collect-raid/module", "genre path")
		assert(rs.Forge.games["forge-demo"].src.shared["$path"] == "src/shared", "pack shared path")
		assert(
			project.tree.ServerScriptService.ForgeDemoServer["$path"] == "src/server/ForgeDemoServer.server.luau",
			"server script path"
		)
		assert(
			project.tree.StarterPlayer.StarterPlayerScripts.ForgeDemoClient["$path"]
				== "src/client/ForgeDemoClient.client.luau",
			"client script path"
		)
	end,

	["a multi-genre project maps every requested genre module"] = function()
		local project =
			serde.decode("json", Scaffold.projectJson("mix-pack", "MixPack", { "grow-harvest", "collect-raid" }))
		local genres = project.tree.ReplicatedStorage.Forge.genres
		assert(genres["grow-harvest"].module["$path"] == "../../genres/grow-harvest/module", "grow-harvest path")
		assert(genres["collect-raid"].module["$path"] == "../../genres/collect-raid/module", "collect-raid path")
	end,

	["collect-raid files are placeholder-free and include both scripts"] = function()
		local files = Scaffold.collectRaidFiles("forge-demo", "ForgeDemo")
		local expected = {
			"assets/procgen.yml",
			"assets/audio.yml",
			"src/shared/Config.luau",
			"src/shared/WorldLayout.luau",
			"src/shared/WorldTheme.luau",
			"src/shared/ProcAssets.luau",
			"src/server/ForgeDemoServer.server.luau",
			"src/client/ForgeDemoClient.client.luau",
		}
		for _, path in expected do
			assert(files[path] ~= nil, "missing generated file " .. path)
		end
		for path, content in files do
			assert(string.find(content, "__SLUG__", 1, true) == nil, path .. " left __SLUG__")
			assert(string.find(content, "__PASCAL__", 1, true) == nil, path .. " left __PASCAL__")
			assert(string.find(content, "__TITLE__", 1, true) == nil, path .. " left __TITLE__")
		end
	end,

	["the starter procgen.yml lists two creatures and two props"] = function()
		local preset = decodeYaml(Scaffold.collectRaidFiles("forge-demo", "ForgeDemo")["assets/procgen.yml"])
		assert(type(preset.assets) == "table" and #preset.assets == 4, "expected 4 asset specs")

		local creatures = 0
		local props = 0
		for _, asset in preset.assets do
			assert(type(asset.key) == "string" and asset.key ~= "", "asset key must be a string")
			assert(type(asset.scale) == "number" and asset.scale > 0, "scale must be positive")
			assert(type(asset.seed) == "number", "seed must be a number")
			for _, channel in { "body", "accent", "eye" } do
				local rgb = asset[channel]
				assert(type(rgb) == "table" and #rgb == 3, asset.key .. "." .. channel .. " must be an RGB triple")
			end
			if asset.kind == "creature" then
				creatures += 1
			elseif asset.kind == "prop" then
				props += 1
			else
				error("unexpected asset kind: " .. tostring(asset.kind))
			end
		end
		assert(creatures == 2, "expected 2 creatures, got " .. tostring(creatures))
		assert(props == 2, "expected 2 props (egg + decor-rock), got " .. tostring(props))
	end,

	["the starter audio.yml plans a music loop plus hatch and coin sfx"] = function()
		local doc = decodeYaml(Scaffold.collectRaidFiles("forge-demo", "ForgeDemo")["assets/audio.yml"])
		assert(type(doc.cues) == "table" and #doc.cues == 3, "expected 3 audio cues")
		local kinds: { [string]: string } = {}
		for _, cue in doc.cues do
			assert(type(cue.key) == "string" and cue.key ~= "", "cue key must be a string")
			assert(type(cue.duration) == "number" and cue.duration > 0, "cue duration must be positive")
			assert(type(cue.seed) == "number", "cue seed must be a number")
			kinds[cue.key] = cue.kind
		end
		assert(kinds.musicExplore == "music", "musicExplore must be a music cue")
		assert(kinds.sfxHatch == "sfx", "sfxHatch must be an sfx cue")
		assert(kinds.sfxCoin == "sfx", "sfxCoin must be an sfx cue")
	end,

	["the server spawns an invisible tagged placeholder instead of building a model"] = function()
		local server = Scaffold.collectRaidFiles("forge-demo", "ForgeDemo")["src/server/ForgeDemoServer.server.luau"]
		assert(
			string.find(server, "core.infra.render.ProcAssets", 1, true) == nil,
			"server must not require the render-side ProcAssets module"
		)
		assert(string.find(server, 'SetAttribute("CreatureKey"', 1, true) ~= nil, "placeholder needs CreatureKey")
		assert(string.find(server, 'SetAttribute("ProcSeed"', 1, true) ~= nil, "placeholder needs ProcSeed")
		assert(string.find(server, "part.Transparency = 1", 1, true) ~= nil, "placeholder must be invisible")
		assert(string.find(server, "WorldBuilder.build", 1, true) ~= nil, "server must build the world")
		assert(string.find(server, "ProximityPrompt", 1, true) ~= nil, "incubators need a hatch prompt")
		assert(string.find(server, "Production.accrue", 1, true) ~= nil, "creatures must produce Coins")
	end,

	["the client renders procgen creatures/decor client-side and plays generated audio"] = function()
		local client = Scaffold.collectRaidFiles("forge-demo", "ForgeDemo")["src/client/ForgeDemoClient.client.luau"]
		assert(string.find(client, "CreatureView", 1, true) ~= nil, "client must require CreatureView")
		assert(string.find(client, "CreatureView.watchCreatures", 1, true) ~= nil, "client must watch creatures")
		assert(string.find(client, "DecorView", 1, true) ~= nil, "client must require DecorView")
		assert(string.find(client, "DecorView.watchDecor", 1, true) ~= nil, "client must watch decor")
		assert(string.find(client, "SoundBank", 1, true) ~= nil, "client must require SoundBank")
		assert(string.find(client, "Assets.musicExplore", 1, true) ~= nil, "client must play generated music")
		assert(string.find(client, "Assets.sfxHatch", 1, true) ~= nil, "client must play generated hatch sfx")
		assert(string.find(client, "Assets.sfxCoin", 1, true) ~= nil, "client must play generated coin sfx")
	end,

	["F1: a fresh pack scaffolds src/shared/Assets.luau with every key the client requires"] = function()
		local files = Scaffold.collectRaidFiles("forge-demo", "ForgeDemo")
		local assetsSrc = files["src/shared/Assets.luau"]
		assert(assetsSrc ~= nil, "forge new must scaffold src/shared/Assets.luau (client requires it at line ~743)")
		local text = assetsSrc :: string
		assert(string.sub(text, 1, 9) == "--!strict", "Assets.luau must start with --!strict")
		-- Compact codegen omits unpublished rows; the module's metatable resolves them to "".
		local runtime = luau.load(text)()
		for _, key in { "musicExplore", "sfxHatch", "sfxCoin" } do
			assert(
				type(runtime[key]) == "string",
				"Assets.luau must resolve key " .. key .. " (the client indexes Assets." .. key .. ")"
			)
		end
	end,
}
