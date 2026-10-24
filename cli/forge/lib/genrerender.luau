--!strict
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local contract = require("./genrecontract")
local registryLib = require("./genreregistry")
local genrespec = require("./genrespec")
local project = require("./genreproject")
local M = {}

-- The locales a generated pack ships. `en-us` is the source language, so the
-- spec's declared display strings are its translation; every other locale is a
-- column the pack fills in later.
local LOCALES = { "en-us", "ko-kr" }

--- The `Forge` expression for a genre-owned module path, e.g.
--- `genres/collect-raid/module/runtime/Hud` -> `Forge.genres["collect-raid"].module.runtime.Hud`.
local function forgeModulePath(module: string): string?
	local id, rest = string.match(module, "^genres/([^/]+)/module/(.+)$")
	if id == nil or rest == nil then
		return nil
	end
	return string.format("Forge.genres[%q].module.%s", id, (string.gsub(rest, "/", ".")))
end

--- The generated client. A genre with a declared client override binds its own
--- module (its HUD is richer than the kit); every other genre binds HudKit and
--- AudioKit. Both shapes publish their own dispatch results into
--- `ForgeHudResult`, so the HUD and the audio policy observe the same committed
--- outcomes the server pushed.
local function clientSource(
	input: contract.GenerateInput,
	hudExpression: string,
	override: boolean,
	withAudioKit: boolean,
	withWorldFeedback: boolean,
	locale: string
): string
	local lines: { string } = {
		"--!strict",
		'local Players = game:GetService("Players")',
		'local ReplicatedStorage = game:GetService("ReplicatedStorage")',
		'local Forge = ReplicatedStorage:WaitForChild("Forge")',
		"local Shared = Forge.games[" .. string.format("%q", input.slug) .. "].src.shared",
		"",
		"local Hud = require(" .. hudExpression .. ")",
		"local Spec = require(Shared.GenreSpec)",
		"local controls = require(Shared.GenreUI)",
		"local Assets = require(Shared.Assets)",
		"-- Every HUD string is rendered from the spec's own translations at the pack's",
		"-- default locale (game.yml `locale.default`), so one capture shows one language.",
		"local LocaleStrings = require(Shared.LocaleStrings)",
	}
	if override then
		table.insert(lines, "local packConfig = require(Shared.GenreConfig)")
	end
	if withAudioKit then
		table.insert(lines, 'local AudioKit = require(Forge.core["ui-kit"].genre.AudioKit)')
	end
	if withWorldFeedback then
		table.insert(lines, 'local WorldFeedback = require(Forge.core["ui-kit"].genre.WorldFeedbackRuntime)')
		table.insert(lines, "local WorldSpec = require(Shared.WorldSpec)")
	end
	if override then
		table.insert(lines, 'local Components = require(Forge.core["ui-kit"].Components)')
		table.insert(lines, 'local InventoryGrid = require(Forge.core["ui-kit"].InventoryGrid)')
	end
	table.insert(lines, 'local Theme = require(Forge.core["ui-kit"].Theme)')
	table.insert(
		lines,
		table.concat({
			"",
			'local action = ReplicatedStorage:WaitForChild("ForgeAction") :: RemoteFunction',
			'local state = ReplicatedStorage:WaitForChild("ForgeState") :: RemoteEvent',
			"local player = Players.LocalPlayer",
			"-- Dispatch results are published locally so the HUD and the audio policy",
			"-- observe exactly the outcomes the server committed.",
			'local results = Instance.new("BindableEvent")',
			'results.Name, results.Parent = "ForgeHudResult", player',
			"",
			"local function subscribe(callback: (any) -> ()): ()",
			"\tstate.OnClientEvent:Connect(callback)",
			"\tresults.Event:Connect(callback)",
			"end",
			"",
			"local function dispatch(actionId: string, args: { any }): any",
			"\tlocal result = action:InvokeServer(actionId, args)",
			"\tresults:Fire({ result = result, action = actionId })",
			"\treturn result",
			"end",
		}, "\n")
	)
	if override then
		table.insert(
			lines,
			table.concat({
				"",
				"-- A declared override owns its own HUD, so the pack hands it the spec, the",
				"-- derived control list and the pack's content document.",
				'local genreConfig: any = if type(packConfig) == "table" and type(packConfig.configs) == "table"\n'
					.. "\tthen packConfig.configs[Spec.id]\n\telse nil",
				'local content: any = if type(genreConfig) == "table"\n'
					.. '\t\tand type(genreConfig.inventory) == "table"\n'
					.. '\t\tand type(genreConfig.inventory.content) == "table"\n'
					.. "\tthen genreConfig.inventory.content\n"
					.. "\telse { items = {}, recipes = {}, structures = {}, wildlife = {} }",
			}, "\n")
		)
	end
	table.insert(
		lines,
		table.concat({
			"",
			"Hud.start({",
			"\tspec = Spec,",
			"\tcontrols = controls,",
			"\tsubscribe = subscribe,",
			"\tdispatch = dispatch,",
			"\tassets = Assets,",
			"\tstrings = LocaleStrings,",
			"\tlocale = " .. string.format("%q", locale) .. ",",
			"\tguiName = " .. string.format("%q", input.guiName) .. ",",
		}, "\n")
	)
	if override then
		table.insert(
			lines,
			table.concat({
				"\tui = { components = Components, grid = InventoryGrid, theme = Theme },",
				"\tcontent = content,",
				"\tsettlementOrigin = Vector3.new(0, 0, 0),",
			}, "\n")
		)
	else
		table.insert(lines, "\ttheme = Theme.default,")
	end
	table.insert(lines, "})")
	if withAudioKit then
		table.insert(
			lines,
			table.concat({
				"",
				"-- The server echoes the control id on a prompt trigger; the audio policy needs",
				"-- the action that control drives to find the spec's action binding.",
				"local controlActions: { [string]: string } = {}",
				"for _, control in controls do",
				"\tcontrolActions[control.id] = control.action",
				"end",
				"",
				-- The world-feedback layer plays cues through the kit, so only then is the
				-- handle kept; otherwise the kit runs on its own subscription.
				(if withWorldFeedback then "local audio = " else "") .. "AudioKit.start({",
				"\tgenre = Spec.id,",
				"\taudio = Spec.audio,",
				"\tcontentIds = Assets,",
				"\tcontrolActions = controlActions,",
				"\tsubscribe = subscribe,",
				"\tlocale = player.LocaleId,",
				"})",
			}, "\n")
		)
	end
	if withWorldFeedback then
		-- The world reacts to the same state the HUD reads: a crop grows, a health bar
		-- empties, a pad lights, an outfit is worn, a popup rises and the bound cue
		-- plays. The prompt itself is dispatched by the world server, so this layer is
		-- presentation only and computes no outcome.
		table.insert(
			lines,
			table.concat({
				"",
				"WorldFeedback.start({",
				"\tspec = Spec,",
				"\tworld = WorldSpec,",
				"\tsubscribe = subscribe,",
				"\tplay = audio.play,",
				-- The world's own floating text and health titles are the spec's declared copy in the
				-- pack's one language, so a capture shows one language on the HUD and in the world.
				"\tstrings = LocaleStrings,",
				"\tlocale = " .. string.format("%q", locale) .. ",",
				"})",
			}, "\n")
		)
	end
	return table.concat(lines, "\n") .. "\n"
end
--- True when the spec declares any world node feedback, so a pack whose world
--- reacts to its loop binds the world-feedback layer and one whose world does not
--- carries no dead module.
local function hasWorldFeedback(spec: any): boolean
	local world = if type(spec) == "table" then spec.world else nil
	for _, node in (if type(world) == "table" and type(world.nodes) == "table" then world.nodes else {}) do
		if type(node) == "table" and type(node.feedback) == "table" and #node.feedback > 0 then
			return true
		end
	end
	return false
end

function M.render(
	registry: registryLib.Registry,
	canonical: { string },
	owner: any,
	input: contract.GenerateInput,
	destination: string,
	pack: any,
	controls: { any },
	assets: { any },
	cues: { any },
	qaNames: { string }
): { [string]: string }
	local common: { [string]: string } = {}
	-- The genre whose spec owns the pack's loop, and the one language the pack
	-- renders. Both are read before game.yml so the pack's declared default locale
	-- is written where a reader looks for it.
	local specId = if owner ~= nil then owner.id else canonical[1]
	local spec: any = registry.packages[specId].spec
	local localeDefault = genrespec.localeDefault(spec)
	common["econ.yml"] = (if input.mode == "plan" then "# GENERATED by forge plan\n" else "")
		.. serde.encode("yaml", { genre_contract = pack })
	common["game.yml"] = serde.encode("yaml", {
		name = input.title,
		slug = input.slug,
		genres = canonical,
		genre_contract = 1,
		currencies = { "Coins" },
		monetization = { gamepasses = {}, products = {}, subscriptions = {} },
		art_style = "stylized low-poly",
		poly_budget = { prop = 800, world_parts_max = 5000 },
		locales = { "en-us", "ko-kr" },
		-- The one language a generated pack renders. Both columns of the pack's
		-- locale table are filled, so changing this line is all a switch needs.
		locale = { default = localeDefault },
		qa_scenarios = qaNames,
		liveops_cadence = "weekly",
		generated_by = string.format(
			"lune run cli/forge %s --concept %q --genre %s --pack %s --seed %d --title %q --teams %s --debug-name %s --gui-name %s",
			input.mode,
			input.concept,
			table.concat(canonical, ","),
			input.slug,
			input.seed,
			input.title,
			table.concat(input.teams, ","),
			input.debugName,
			input.guiName
		),
	})
	if input.mode == "new" then
		local game = serde.decode("yaml", common["game.yml"])
		game.generated_by =
			string.format("lune run cli/forge new %s --genre %s", input.slug, table.concat(canonical, ","))
		common["game.yml"] = serde.encode("yaml", game)
	end
	common["src/shared/GenreConfig.luau"] = project.renderConfig(pack)
	common["src/shared/Config.luau"] = '--!strict\nreturn require("./GenreConfig")\n'
	local overrides: any = if type(spec) == "table" then spec.overrides else nil
	-- GenreUI is the pack's declared control list. It is derived from the spec,
	-- which the assembly has already asserted equals the generator's own list.
	local declaredControls = genrespec.controls(spec)
	if #declaredControls == 0 then
		declaredControls = controls
	end
	common["src/shared/GenreUI.luau"] = '--!strict\nexport type Control = {\n id:string,\n action:string,\n args:{any},\n label:string,\n kind:"button"|"prompt"|"player-button",\n}\nlocal controls: { Control } = '
		.. contract.serialize(declaredControls)
		.. "\nreturn controls\n"
	local runtimeLines =
		{ "--!strict", 'local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")', "return {" }
	for _, id in canonical do
		table.insert(runtimeLines, "require(Forge.genres[" .. string.format("%q", id) .. "].module.Contract),")
	end
	table.insert(runtimeLines, "}\n")
	common["src/shared/GenreRuntime.luau"] = table.concat(runtimeLines, "\n")
	local hookLines = {
		"--!strict",
		"type Event = {genre:string,name:string,playerId:string?,data:{[string]:any}}",
		"local hooks: {[string]:(Event)->()} = {}",
	}
	for _, id in canonical do
		for _, name in registry.runtimes[id].hooks do
			table.insert(
				hookLines,
				"hooks["
					.. string.format("%q", id .. ":" .. name)
					.. "] = function(event) print(event.genre, event.name) end"
			)
		end
	end
	table.insert(hookLines, "return hooks\n")
	common["src/server/GenreHooks.luau"] = table.concat(hookLines, "\n")
	local binding = 'local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")\nlocal Shared = Forge.games['
		.. string.format("%q", input.slug)
		.. "].src.shared\n"
	local persistencePath = "src/server/PersistenceConfig.luau"
	common[persistencePath] = if fs.isFile(destination .. "/" .. persistencePath)
		then fs.readFile(destination .. "/" .. persistencePath)
		else '--!strict\nreturn {mode="memory",namespace="' .. input.slug:sub(1, 32) .. '"}\n'
	common["src/server/" .. input.pascal .. "Server.server.luau"] = "--!strict\n"
		.. binding
		.. "local Server = require(Forge.core.infra.genre.Server)\nlocal RuntimeBackend = require(Forge.core.infra.data.RuntimeBackend)\nServer.start({backend=RuntimeBackend.new(require(script.Parent.PersistenceConfig),"
		.. string.format("%q", string.sub(input.slug, 1, 41) .. "-genre-v1")
		.. "),packConfig=require(Shared.GenreConfig), spec=require(Shared.GenreSpec), contracts=require(Shared.GenreRuntime), controls=require(Shared.GenreUI), hooks=require(script.Parent.GenreHooks), storeName="
		.. string.format("%q", string.sub(input.slug, 1, 41) .. "-genre-v1")
		.. "})\n"
	local hudExpression: string
	local overrideClient = false
	local clientOverride: any = nil
	if type(overrides) == "table" and type(overrides.client) == "table" then
		local declared = overrides.client
		-- A client override may be scoped to one config mode: the crafting bootstrap binds its own
		-- HUD, while the default mode renders the kit's. An override with no mode applies always.
		local packMode: string? = nil
		local config = if type(pack) == "table" and type(pack.configs) == "table" then pack.configs[specId] else nil
		if type(config) == "table" and type(config.mode) == "string" then
			packMode = config.mode
		end
		if declared.mode == nil or declared.mode == packMode then
			clientOverride = declared
		end
	end
	if clientOverride ~= nil and type(clientOverride.module) == "string" then
		local resolved = forgeModulePath(clientOverride.module)
		assert(resolved ~= nil, "invalid client override module path")
		hudExpression = resolved :: string
		overrideClient = true
	else
		hudExpression = 'Forge.core["ui-kit"].genre.HudKit'
	end
	common["src/client/" .. input.pascal .. "Client.client.luau"] = clientSource(
		input,
		hudExpression,
		overrideClient,
		not overrideClient,
		not overrideClient and hasWorldFeedback(spec),
		localeDefault
	)
	common["assets/procgen.yml"] = serde.encode("yaml", { assets = assets })
	common["assets/audio.yml"] = serde.encode("yaml", { cues = cues })
	common["assets/manifest.yml"] = "assets: []\n"
	common["design/README.md"] = "# " .. input.title .. "\n"
	common["liveops.yml"] = "cadence: weekly\n"
	common["deploy.yml"] =
		"environments:\n  staging: {universeId: 0, placeId: 0}\n  production: {universeId: 0, placeId: 0}\n"
	common["locale/strings.csv"] = genrespec.renderLocaleCsv(spec, LOCALES)
	common["src/shared/LocaleStrings.luau"] =
		genrespec.stabilize(genrespec.serializeLocaleStrings(spec), "LocaleStrings.luau")
	local smoke = {
		"--!strict",
		"local Executor = require(" .. string.format(
			"%q",
			project.relative(destination .. "/smoke", project.coreRoot(registry) .. "/domain/genre/Executor")
		) .. ")",
		'local pack = require("../src/shared/GenreConfig")',
		"local contracts = {",
	}
	for _, id in canonical do
		table.insert(
			smoke,
			"require("
				.. string.format(
					"%q",
					project.relative(destination .. "/smoke", registry.packages[id].path .. "/module/Contract")
				)
				.. "),"
		)
	end
	table.insert(
		smoke,
		"}\nreturn {run=function(_fixturePath: string?)\nlocal epoch=0\nlocal executor=Executor.new(pack,contracts,{now=function() return epoch end,roll=function() return 0.25 end,emit=function() end})\nlocal advance=executor.advance\nexecutor.advance=function(value) epoch=value; advance(value) end\nlocal checks={}\n"
	)
	local driverIds: { string } = if owner then { owner.id } else canonical
	for _, id in driverIds do
		table.insert(
			smoke,
			"local driver=require("
				.. string.format(
					"%q",
					project.relative(destination .. "/smoke", registry.packages[id].path .. "/generator")
				)
				.. (if owner and owner.recipe
					then ").recipes["
						.. string.format("%q", owner.recipe.id)
						.. "].driver\nfor _, check in driver.run(executor,"
					else ").driver\nfor _, check in driver.run(executor,")
				.. contract.serialize(input)
				.. ") do table.insert(checks,check) end"
		)
	end
	table.insert(smoke, 'assert(#checks>0,"empty smoke checks")\nreturn checks\nend}\n')
	-- Formatted to stylua's fixed point: one formatter pass over the assembled
	-- source still re-indents the driver call, so `stylua --check` would fail.
	common["smoke/smoke.luau"] = genrespec.stabilize(table.concat(smoke, "\n"), "smoke.luau")
	return common
end
--- The standard-surface files a legacy pack no longer publishes: a legacy genre ships its own
--- gameplay server and owns its own runtime, so it must not be given a second, parallel
--- `core.infra.genre.Server` (which would expose a ForgeQA surface validating a fixture instead of
--- the playable loop). The legacy scaffold publishes its own ForgeQA surface over its real runtime.

--- The generated world server entry for a genre without a world override: it
--- starts the server with no starter world (the place already carries the baked
--- spec world) and wires every node prompt to the same dispatch path the generic
--- server uses for its own prompt stations.
function M.worldServerSource(input: contract.GenerateInput): string
	local store = string.sub(input.slug, 1, 41) .. "-genre-v1"
	return table.concat({
		"--!strict",
		'local ReplicatedStorage = game:GetService("ReplicatedStorage")',
		'local Forge = ReplicatedStorage:WaitForChild("Forge")',
		"local Shared = Forge.games[" .. string.format("%q", input.slug) .. "].src.shared",
		"",
		"local Server = require(Forge.core.infra.genre.Server)",
		"local RuntimeBackend = require(Forge.core.infra.data.RuntimeBackend)",
		'local WorldKit = require(Forge.core["ui-kit"].genre.WorldKit)',
		"local WorldSpec = require(Shared.WorldSpec)",
		"local controls = require(Shared.GenreUI)",
		"",
		"-- A prompt is named after the control it is bound to, and the server dispatches the",
		"-- *action* that control drives with the arguments the control declares. Dispatching",
		"-- the control id itself would name no action, and an empty argument tuple would",
		"-- miss the control's own arguments.",
		"local controlActions: { [string]: { action: string, args: { any } } } = {}",
		"for _, control in controls do",
		"\tcontrolActions[control.id] = { action = control.action, args = control.args or {} }",
		"end",
		"",
		"local session = Server.start({",
		"\tbackend = RuntimeBackend.new(require(script.Parent.PersistenceConfig), "
			.. string.format("%q", store)
			.. "),",
		"\tpackConfig = require(Shared.GenreConfig),",
		"\tspec = require(Shared.GenreSpec),",
		"\tcontracts = require(Shared.GenreRuntime),",
		"\tcontrols = require(Shared.GenreUI),",
		"\thooks = require(script.Parent.GenreHooks),",
		"\tstoreName = " .. string.format("%q", store) .. ",",
		"\tstarterWorld = false,",
		"})",
		"",
		'local state = ReplicatedStorage:WaitForChild("ForgeState") :: RemoteEvent',
		"local types = {",
		"\tinstance = function(class: string): Instance\n\t\treturn Instance.new(class)\n\tend,",
		"\tvector3 = function(x: number, y: number, z: number): Vector3\n\t\treturn Vector3.new(x, y, z)\n\tend,",
		"\tcolor3 = function(r: number, g: number, b: number): Color3\n\t\treturn Color3.fromRGB(r, g, b)\n\tend,",
		"\t-- Geometry is placed with a CFrame, never with Position/Rotation: the kit's",
		"\t-- plan carries a rotation, and a Position write cannot express one.",
		"\tcframe = function(x: number, y: number, z: number, rx: number?, ry: number?, rz: number?): CFrame",
		"\t\treturn CFrame.new(x, y, z) * CFrame.Angles(math.rad(rx or 0), math.rad(ry or 0), math.rad(rz or 0))",
		"\tend,",
		"\tenum = Enum,",
		"}",
		"",
		"-- The place is baked with this same environment; applying it here too keeps a",
		"-- pack whose place was built elsewhere from rendering as a bare grey void.",
		'WorldKit.applyEnvironment(game:GetService("Lighting"), types)',
		"",
		"WorldKit.start({",
		"\tspec = WorldSpec,",
		"\tparent = workspace,",
		"\ttypes = types,",
		"\tonPrompt = function(player: Player, control: string, _args: { any })",
		"\t\tlocal declared = controlActions[control]",
		"\t\tlocal result = if declared ~= nil",
		"\t\t\tthen session.dispatch(tostring(player.UserId), declared.action, declared.args)",
		'\t\t\telse { ok = false, reason = "UNDECLARED_CONTROL" }',
		"\t\t-- The committed result is published whether it succeeded or not: the client's",
		"\t\t-- audio policy and the QA driver both read it, and a refusal the client never",
		"\t\t-- learns about is a refusal a player cannot see.",
		"\t\tstate:FireClient(player, { result = result, control = control, action = if declared ~= nil then declared.action else nil })",
		"\tend,",
		"})",
		"",
	}, "\n")
end

return M
