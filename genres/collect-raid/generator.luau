--!strict
local Package = require("../../cli/forge/lib/genrecontract")
local Executor = require("../../core/domain/genre/Executor")
local Runtime = require("./module/Contract")
local Fixture = require("./module/Adapter.fixture")
local Scaffold = require("./generation/scaffold")
local Planner = require("./generation/planner")
local Codegen = require("../../cli/forge/lib/codegen")
local Defaults = require("./generation/defaults")
local serde = require("@lune/serde")
local template = Defaults.template
local design = Defaults.design
local function generate(input: Package.GenerateInput): Package.Generated
	local files: { [string]: string }
	local assetKeys: { string } = {}
	if input.mode == "new" then
		files = Scaffold.collectRaidFiles(input.slug, input.pascal)
	else
		local title = if input.title ~= ""
			then Planner.sanitizeTitle(input.title)
			else Planner.deriveTitle(input.concept)
		local roster = Planner.buildRoster(input.concept, template, input.seed)
		local tune = Planner.tune(template, roster)
		assert(tune.ok, "no collect balance solution")
		local economy = Planner.buildEconomy(template, roster, tune.priceMultiplier, tune.productionMultiplier)
		assert(#Planner.validate(economy, title) == 0, "invalid collect economy")
		local slots = math.max(#roster.creatures, template.incubators + 4)
		local by = string.format(
			"lune run cli/forge plan --concept %q --genre collect-raid --pack %s --seed %d --title %q --teams %s --debug-name %s --gui-name %s --force",
			input.concept,
			input.slug,
			input.seed,
			title,
			table.concat(input.teams, ","),
			input.debugName,
			input.guiName
		)
		local econ = Planner.renderEconYml(economy)
		files = {
			["game.yml"] = Planner.renderGameYml(template, economy, title, input.slug, "collect-raid", by),
			["econ.yml"] = econ,
			["default.project.json"] = Planner.renderProjectJson(input.slug, input.pascal, "collect-raid"),
			["liveops.yml"] = Planner.renderLiveopsYml(),
			["deploy.yml"] = Planner.renderDeployYml(),
			["design/README.md"] = Planner.renderDesignReadme(design, template, economy, title, input.concept),
			["design/balance.md"] = Planner.renderBalance(economy, template, tune, title, input.slug),
			["design/monetization.md"] = Planner.renderMonetization(template, economy, title),
			["design/store-listing.md"] = Planner.renderStoreListing(template, economy, title, input.concept),
			["design/launch-checklist.md"] = Planner.renderLaunchChecklist(
				template,
				economy,
				title,
				input.slug,
				"collect-raid"
			),
			["design/perf.md"] = Planner.renderPerf(title, input.pascal .. "World"),
			["assets/procgen.yml"] = Planner.renderProcgen(roster, title),
			["assets/audio.yml"] = Planner.renderAudioYml(title, input.slug, input.seed),
			["src/shared/Config.luau"] = Planner.renderConfig(roster, title, template),
			["src/shared/EconConfig.luau"] = Codegen.generate(econ),
			["src/shared/Catalog.luau"] = Planner.renderCatalog(economy, roster),
			["src/shared/Catalog.spec.luau"] = Planner.renderCatalogSpec(),
			["src/shared/Remotes.luau"] = Planner.renderRemotes(title),
			["src/shared/Messages.luau"] = Planner.renderMessages(title),
			["src/shared/Copy.luau"] = Planner.renderCopy(title, input.guiName),
			["src/shared/AudioConfig.luau"] = Planner.renderAudioConfig(title, input.teams),
			["src/shared/CreatureModels.luau"] = Planner.renderCreatureModels(roster),
			["src/shared/Fx.luau"] = Planner.renderFx(roster),
			["src/shared/WorldLayout.luau"] = Planner.renderWorldLayout(
				roster,
				title,
				input.teams,
				input.pascal,
				slots
			),
			["src/shared/WorldLayout.spec.luau"] = Planner.renderWorldLayoutSpec(input.teams, slots),
			["src/shared/WorldTheme.luau"] = Planner.renderWorldTheme(roster, title, input.teams),
			["src/server/World.luau"] = Planner.renderWorld(input.slug),
			["src/server/" .. input.pascal .. "Server.server.luau"] = Planner.renderServer(
				input.slug,
				input.pascal,
				input.teams,
				input.debugName,
				slots
			),
			["src/client/" .. input.pascal .. "Client.client.luau"] = Planner.renderClient(
				input.slug,
				input.pascal,
				input.teams,
				slots
			),
			["locale/strings.csv"] = Planner.renderLocaleCsv(roster, economy, input.teams),
			["smoke/smoke.luau"] = Planner.renderSmoke(roster.eggs[1].id),
			["smoke/smoke.spec.luau"] = Planner.renderSmokeSpec(input.slug),
			["smoke/fixtures/corrupt-save.json"] = Planner.renderCorruptFixture(),
		}
	end
	for _, asset in serde.decode("yaml", files["assets/procgen.yml"]).assets do
		table.insert(assetKeys, asset.key)
	end
	for _, cue in serde.decode("yaml", files["assets/audio.yml"]).cues do
		table.insert(assetKeys, cue.key)
	end
	local artifacts: { Package.Artifact } = {}
	for path, content in files do
		table.insert(artifacts, { path = path, content = content })
	end
	table.sort(artifacts, function(a, b)
		return a.path < b.path
	end)
	return {
		config = Fixture.config(),
		artifacts = artifacts,
		controls = {},
		assetKeys = assetKeys,
		generation = { "procedural", "launchart", "audio" },
	}
end
local function run(executor: Executor.Executor, _input: Package.GenerateInput): { Package.Check }
	assert(executor.join("collect-a", nil).ok and executor.join("collect-b", nil).ok, "generator.luau invariant")
	local snapshot = executor.snapshot("collect-a")["collect-raid"]
	local buy = executor.dispatchClient("collect-a", "collect-raid:buy-source", { "ember" }).ok
	local early = not executor.dispatchClient("collect-a", "collect-raid:hatch", { 1 }).ok
	executor.advance(5)
	local hatch = executor.dispatchClient("collect-a", "collect-raid:hatch", { 1 }).ok
	local creature = executor.snapshot("collect-a")["collect-raid"].creatures[1]
	local deposit = executor.dispatchServer("collect-b", "collect-raid:collect", { creature, false }).ok
	executor.advance(10)
	local raid = executor.dispatchClient("collect-a", "collect-raid:raid", { "blue" }).ok
	local saved = executor.save("collect-a")
	executor.leave("collect-a")
	local restored = executor.join("collect-a", saved).ok
	local after = executor.snapshot("collect-a")["collect-raid"]
	executor.leave("collect-a")
	executor.leave("collect-b")
	return {
		{ name = "server-owned alternating teams", ok = snapshot.team == "red" },
		{ name = "native source and exact-ready hatch", ok = buy and early and hatch },
		{
			name = "native vault and rival raid",
			ok = deposit and raid and after.counts.red == 1 and after.counts.blue == 0,
		},
		{ name = "native loop restore", ok = restored and after.creatures[1] == creature },
	}
end
local generator: Package.Generator = {
	api = 1,
	id = "collect-raid",
	configVersion = 1,
	runtime = Runtime,
	-- The contract generation a multi-genre recipe pack (pvp-arena's arena-bounty-v1) composes:
	-- namespaced controls, assets and design notes only. A collect-raid-only pack keeps the
	-- custom scaffold through `legacy`.
	generate = function(input)
		return {
			config = Fixture.config(),
			controls = {
				{
					id = "collect-raid:buy-source",
					action = "collect-raid:buy-source",
					args = { "ember" },
					label = "Buy source",
					kind = "prompt",
				},
				{
					id = "collect-raid:hatch",
					action = "collect-raid:hatch",
					args = { 1 },
					label = "Hatch egg",
					kind = "prompt",
				},
				{
					id = "collect-raid:merge",
					action = "collect-raid:merge",
					args = { "ember", 1 },
					label = "Merge",
					kind = "button",
				},
				{
					id = "collect-raid:raid",
					action = "collect-raid:raid",
					args = { "blue" },
					label = "Raid rival",
					kind = "button",
				},
				{
					id = "collect-raid:claim-quest",
					action = "collect-raid:claim-quest",
					args = { "hatch" },
					label = "Claim quest",
					kind = "button",
				},
			},
			assetKeys = { "collect-raid-starter-prop", "collect-raid-buy", "collect-raid-hatch" },
			generation = { "procedural", "audio" },
			artifacts = {
				{
					path = "design/collect-raid/loop.md",
					content = "# Collect and siege\nBuy a source, hatch it on free Coins, merge, and raid rival team vaults during the siege window.\n",
				},
				{
					path = "assets/collect-raid/procgen.yml",
					content = string.format(
						"assets:\n  - key: collect-raid-starter-prop\n    kind: prop\n    archetype: crate\n    scale: 1\n    body: [200, 120, 60]\n    accent: [250, 210, 90]\n    seed: %d\n",
						input.seed
					),
				},
				{
					path = "assets/collect-raid/audio.yml",
					content = string.format(
						"cues:\n  - key: collect-raid-buy\n    kind: sfx\n    type: coin\n    duration: 0.2\n    seed: %d\n"
							.. "  - key: collect-raid-hatch\n    kind: sfx\n    type: hatch\n    duration: 0.4\n    seed: %d\n",
						input.seed,
						input.seed + 1
					),
				},
			},
		}
	end,
	legacy = { generate = generate, codegen = Codegen.generate },
	driver = {
		run = run,
		simulate = function(executor, _input, count, days)
			local balances: { [string]: number } = {}
			local accepted, rejected, sink = 0, 0, 0
			for i = 1, count do
				local player = "collect-sim-" .. tostring(i)
				assert(executor.join(player, nil).ok, "generator.luau invariant")
				if executor.dispatchClient(player, "collect-raid:buy-source", { "ember" }).ok then
					accepted += 1
					sink += 50
				else
					rejected += 1
				end
			end
			executor.advance(5)
			for i = 1, count do
				if executor.dispatchClient("collect-sim-" .. tostring(i), "collect-raid:hatch", { 1 }).ok then
					accepted += 1
				else
					rejected += 1
				end
			end
			executor.advance(math.max(5, days * 86400))
			local source = 0
			for i = 1, count do
				local player = "collect-sim-" .. tostring(i)
				balances[player] = executor.snapshot(player)["collect-raid"].coins
				source += balances[player] - 50
				executor.leave(player)
			end
			return {
				balances = balances,
				sourceTotal = source,
				sinkTotal = sink,
				acceptedActions = accepted,
				rejectedActions = rejected,
			}
		end,
	},
	qa = {
		scenarios = { "contract-loop", "contract-rejoin" },
		operations = { "get", "snapshot" },
		targets = { "collect-raid:buy-source", "collect-raid:hatch", "collect-raid:raid" },
	},
}
return generator
