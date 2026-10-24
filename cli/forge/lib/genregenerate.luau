--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local contract = require("./genrecontract")
local registryLib = require("./genreregistry")
local publish = require("./genrepublish")
local run = require("./run")
local scaffold = require("./scaffold")
local procgen = require("./procgen")
local launchart = require("./launchart")
local audio = require("./audiocues")
local project = require("./genreproject")
local runtime = require("./genrerender")
local genrespec = require("./genrespec")
local qagen = require("./qagen")
local qascenario = require("./qascenario")
local qualityscaffold = require("./qualityscaffold")
local worldbake = require("./worldbake")
local Options = require("../../../core/infra/genre/Options")
local crafting = require("./craftinggenerate")
local cliutil = require("./cliutil")
local M = {}
export type Assembly = {
	files: { [string]: string },
	order: { string },
	generation: { string },
	legacy: boolean,
	pack: any,
}
M.absolute = project.absolute
M.relative = project.relative
M.renderConfig = project.renderConfig
M.project = project.project
M.ensureDir = publish.ensureDir
local function assemble(
	registry: registryLib.Registry,
	selected: any,
	input: contract.GenerateInput,
	destination: string,
	runtimeMode: string?
): Assembly
	assert(runtimeMode == nil or runtimeMode == "crafting", "unsupported generation mode")
	if runtimeMode then
		assert(
			type(selected) == "table" and #selected == 1 and selected[1] == "survival-coop",
			"crafting generation requires survival-coop alone"
		)
	end
	local order, owner, errors = registryLib.select(registry, selected)
	assert(order ~= nil, table.concat(errors, "; "))
	local canonical = order :: { string }
	local qaErrors = require("../commands/qa").validateRegistry(registry)
	assert(#qaErrors == 0, table.concat(qaErrors, "; "))
	local files: { [string]: string } = {}
	local configs, controls, capabilities, assets, cues, qaNames = {}, {}, {}, {}, {}, {}
	local declaredKeys: { [string]: boolean } = {}
	local legacy = #canonical == 1 and registry.packages[canonical[1]].generator.legacy ~= nil
	for _, id in canonical do
		local generator = registry.packages[id].generator
		local generated = if legacy then (generator.legacy :: any).generate(input) else generator.generate(input)
		if runtimeMode == "crafting" then
			generated = crafting.generate(generated)
		end
		local generatedErrors = contract.validateGenerated(generated, generator)
		assert(#generatedErrors == 0, id .. ": " .. table.concat(generatedErrors, "; "))
		configs[id] = generated.config
		for _, key in generated.assetKeys do
			assert(not declaredKeys[key], "duplicate asset key: " .. key)
			declaredKeys[key] = true
		end
		for _, artifact in generated.artifacts do
			assert(files[artifact.path] == nil, "duplicate artifact: " .. artifact.path)
			files[artifact.path] = artifact.content
		end
		for _, control in generated.controls do
			local namespaced = table.clone(control)
			if not string.find(namespaced.id, ":", 1, true) then
				namespaced.id = id .. ":" .. namespaced.id
			end
			table.insert(controls, namespaced)
		end
		if not legacy and runtimeMode == nil then
			-- The derived GenreUI is the spec's control list, so the spec and the
			-- generator must declare the same controls: one source, two readers.
			local expected: { [string]: boolean } = {}
			for _, name in genrespec.controlIds(registry.packages[id].spec) do
				expected[name] = true
			end
			for _, control in generated.controls do
				local name = control.id
				if not string.find(name, ":", 1, true) then
					name = id .. ":" .. name
				end
				assert(expected[name], "spec declares no control for generated " .. name)
				expected[name] = nil
			end
			local unmatched = next(expected)
			assert(unmatched == nil, "generator declares no control for spec action " .. tostring(unmatched))
		end
		for _, step in generated.generation do
			capabilities[step] = true
		end
		for _, name in generator.qa.scenarios do
			table.insert(qaNames, id .. ":" .. name)
		end
		if not legacy then
			for _, spec in
				{
					{ file = "procgen.yml", field = "assets", entries = assets },
					{ file = "audio.yml", field = "cues", entries = cues },
				}
			do
				local text = files["assets/" .. id .. "/" .. spec.file]
				if text then
					local decoded = serde.decode("yaml", text)
					assert(type(decoded) == "table" and contract.dense(decoded[spec.field], 1024), "invalid asset list")
					for _, entry in decoded[spec.field] do
						table.insert(spec.entries, entry)
					end
				end
			end
		end
	end
	local pack = {
		api = 1,
		order = canonical,
		configs = configs,
		recipe = if owner and owner.recipe then owner.recipe.id else nil,
	}
	local packErrors = contract.validatePack(pack, registry.runtimes)
	if owner and owner.recipe then
		local recipes = registry.packages[owner.id].generator.recipes
		local recipe = if recipes then recipes[owner.recipe.id] else nil
		assert(recipe, "recipe generation capability missing")
		pack.configs = recipe.normalize(configs)
		packErrors = contract.validatePack(pack, registry.runtimes)
	end
	assert(#packErrors == 0, table.concat(packErrors, "; "))
	local common: { [string]: string } = {}
	local worldEntry: any = nil
	-- The spec whose genre owns the pack's loop: a multi-genre recipe pack carries
	-- its owner's spec, which is the genre whose adapter owns the loop.
	local specId = if owner ~= nil then owner.id else canonical[1]
	if legacy then
		local package = registry.packages[canonical[1]]
		local resolvedCore = project.coreRoot(registry)
		if files["game.yml"] == nil then
			files["game.yml"] = scaffold.gameYml(input.slug, canonical)
		end
		if files["econ.yml"] == nil then
			files["econ.yml"] = fs.readFile(package.path .. "/econ-template.yml")
		end
		if files["design/README.md"] == nil then
			files["design/README.md"] = fs.readFile(package.path .. "/design-template.md")
		end
		files["src/shared/EconConfig.luau"] = (package.generator.legacy :: any).codegen(files["econ.yml"])
		for path, text in files do
			if string.match(path, "%.luau$") then
				local directory = destination .. "/" .. (string.match(path, "^(.*)/[^/]+$") or "")
				local replacements: { [string]: string } = {}
				for target in string.gmatch(text, 'require%("(%.%./[^"]+)"%)') do
					local tail = target
					while string.sub(tail, 1, 3) == "../" do
						tail = string.sub(tail, 4)
					end
					local genre, suffix = string.match(tail, "^genres/([^/]+)/(.+)$")
					local resolved = if genre
							and suffix
							and registry.packages[genre]
						then registry.packages[genre].path .. "/" .. suffix
						else nil
					if not resolved then
						local core = string.match(tail, "^core/(.+)$")
						if core then
							resolved = resolvedCore .. "/" .. core
						end
					end
					replacements[target] = if resolved
						then "require(" .. string.format("%q", M.relative(directory, resolved)) .. ")"
						else 'require("' .. target .. '")'
				end
				files[path] = string.gsub(text, 'require%("(%.%./[^"]+)"%)', function(target)
					return replacements[target]
				end)
			end
		end
	end
	if not legacy then
		local descriptors, hooks = {}, {}
		for _, id in canonical do
			table.insert(descriptors, registry.runtimes[id])
			for _, name in registry.runtimes[id].hooks do
				hooks[id .. ":" .. name] = function(_event) end
			end
		end
		Options.validate({
			packConfig = pack,
			contracts = descriptors,
			controls = controls,
			storeName = string.sub(input.slug, 1, 41) .. "-genre-v1",
			hooks = hooks,
			durable = if runtimeMode == "crafting" then crafting.policy() else nil,
		})
		local seenAssets = {}
		for _, list in { assets, cues } do
			for _, entry in list do
				assert(
					type(entry) == "table"
						and type(entry.key) == "string"
						and declaredKeys[entry.key]
						and not seenAssets[entry.key],
					"invalid/duplicate/undeclared asset key"
				)
				seenAssets[entry.key] = true
			end
		end
		for key in declaredKeys do
			assert(seenAssets[key], "missing declared asset: " .. key)
		end
		common = runtime.render(registry, canonical, owner, input, destination, pack, controls, assets, cues, qaNames)
		local spec: any = registry.packages[specId].spec
		-- A genre that declares no zones declares no world: it ships no world spec and
		-- no baked model, and its world column can never read PASS.
		local declaredWorld = type(spec.world) == "table"
			and type(spec.world.zones) == "table"
			and #spec.world.zones > 0
		if declaredWorld then
			common["src/shared/WorldSpec.luau"] =
				genrespec.stabilize(genrespec.serializeWorld(spec.world), "WorldSpec.luau")
		end
		if runtimeMode == "crafting" then
			crafting.render(common, registry, input, destination, pack)
		end
		-- A world override module is a server authority (survival-coop's SurvivalWorld
		-- registers stations, nodes and wildlife), not a visual world builder: the one
		-- generated pack that builds its own geometry is the crafting bootstrap, which
		-- ships its own developmental island. Every other pack bakes the spec's world
		-- into the place, which is what makes the built place carry real ground, props
		-- and lighting instead of falling back to the generic starter floor.
		local buildsOwnWorld = runtimeMode == "crafting"
		if declaredWorld and not buildsOwnWorld then
			local bytes, _, bakeErrors = worldbake.render(spec.world, nil)
			assert(bytes ~= nil and #bakeErrors == 0, table.concat(bakeErrors, "; "))
			local worldPath = worldbake.path(input.pascal)
			common[worldPath] = bytes :: string
			worldEntry = {
				path = worldPath,
				name = if type(spec.world) == "table" and type(spec.world.name) == "string"
					then spec.world.name
					else "World",
			}
			common["src/server/" .. input.pascal .. "World.server.luau"] = runtime.worldServerSource(input)
			-- The world entry owns the server start and the project mounts no plain
			-- server script, so publishing one would ship an orphan source file.
			common["src/server/" .. input.pascal .. "Server.server.luau"] = nil
		end
	end
	-- A legacy pack ships its own gameplay server and owns its own runtime, so no second
	-- `core.infra.genre.Server` is mounted beside it: a parallel contract runtime would expose a
	-- ForgeQA surface whose dispatch/snapshot/save validate a fixture instead of the playable loop.
	-- The legacy scaffold publishes its own ForgeQA surface over its real runtime instead.
	common["default.project.json"] = M.project(input, canonical, destination, registry, worldEntry)
	-- The declarative spec is serialized into every pack, legacy included: it is
	-- the single source the presentation layer and the derived QA read. A
	-- multi-genre recipe pack carries its owner's spec, which is the genre whose
	-- adapter owns the pack's loop.
	common["src/shared/GenreSpec.luau"] =
		genrespec.stabilize(genrespec.serialize(registry.packages[specId].spec), "GenreSpec.luau")
	-- The derived native scenario is published with the pack, so `qa run` and
	-- `forge sweep` execute the pack's own QA rather than the genre directory's.
	local primary: any = registry.packages[specId].spec
	local packMode: string? = nil
	local genreConfig: any = if type(pack.configs) == "table" then pack.configs[specId] else nil
	if type(genreConfig) == "table" and type(genreConfig.mode) == "string" then
		packMode = genreConfig.mode
	end
	local block: any = qagen.block(primary, packMode)
	-- A recipe pack's loop is the recipe's, not the owner genre's single-genre loop: the
	-- recipe normalizes partner configs (survival-coop's wallet moves to grow-harvest), so
	-- the owner's golden path would assert state the pack never has. A recipe declares
	-- its own `qa` block in the same shape as a spec's, and that block is derived instead.
	local qaSource: any = primary
	if owner and owner.recipe then
		local recipes = registry.packages[owner.id].generator.recipes
		local recipe: any = if recipes then recipes[owner.recipe.id] else nil
		qaSource = { qa = if recipe and type(recipe.qa) == "table" then recipe.qa else {} }
		block = qagen.block(qaSource, nil)
	end
	-- A legacy pack's playable loop is engine-side, so a derived native scenario would exercise the
	-- generic contract runtime rather than the game: the legacy pack's own smoke and Studio
	-- scenarios are its verification, and no parallel-runtime scenario is published with it.
	if not legacy and type(block) == "table" and type(block.goldenPath) == "table" and #block.goldenPath > 0 then
		local derived = qagen.derive(qaSource, {
			name = qagen.name(qaSource),
			genre = specId,
			pack = input.slug,
		}, if qaSource == primary then packMode else nil)
		if qaSource ~= primary and owner and owner.recipe then
			local partners: { string } = {}
			for _, partner in owner.recipe.partners do
				if partner ~= specId then
					table.insert(partners, partner)
				end
			end
			derived.partners = partners
		end
		local derivedErrors = qascenario.validate(derived)
		assert(#derivedErrors == 0, "derived scenario: " .. table.concat(derivedErrors, "; "))
		common["qa-scenarios/" .. qagen.fileName(specId, derived.name)] = serde.encode("yaml", derived)
	end
	-- The derived world path is the studio scenario that walks to a spec node and
	-- triggers its ProximityPrompt with real input, so the pack carries that
	-- evidence beside the native golden path. A genre with no prompt-bearing node
	-- publishes none, and nothing is asserted here about the world's behaviour.
	local worldPath = qagen.deriveWorldPath(primary, {
		name = "world-path",
		genre = specId,
		pack = input.slug,
	}, packMode)
	if worldPath ~= nil then
		local worldPathErrors = qascenario.validate(worldPath)
		assert(#worldPathErrors == 0, "derived world path: " .. table.concat(worldPathErrors, "; "))
		common["qa-scenarios/" .. qagen.fileName(specId, worldPath.name)] = serde.encode("yaml", worldPath)
	end

	if runtimeMode == "crafting" then
		local tree = serde.decode("json", common["default.project.json"])
		tree.tree.ServerScriptService.SurvivalWorldBootstrap = { ["$path"] = "src/server/SurvivalWorldBootstrap.luau" }
		for _, name in { "SurvivalFactory", "SurvivalProvision", "SurvivalProvisionConfig", "PersistenceConfig" } do
			tree.tree.ServerScriptService[name] = { ["$path"] = "src/server/" .. name .. ".luau" }
		end
		common["default.project.json"] = serde.encode("json", tree, true) .. "\n"
	end
	local core = serde.decode("yaml", fs.readFile(project.coreRoot(registry) .. "/forge-package.yml"))
	local pins = {}
	for _, id in canonical do
		pins[id] = registry.packages[id].manifest.version
	end
	common["forge-lock.yml"] = serde.encode("yaml", { core = core.version, genres = pins })
	-- A generated pack declares only the tier it can back: a starter declaration
	-- that is explicitly not a release claim, with the loop text taken from the
	-- genre spec this pack ships. The evidence receipt a sweep records is
	-- validated against this declared tier, never against a claimed one.
	common["quality.yml"] = qualityscaffold.profile(input.slug, registry.packages[specId].spec)
	for path, text in common do
		assert(files[path] == nil or legacy, "common artifact collision: " .. path)
		files[path] = text
	end
	local sequence = {}
	for _, step in { "procedural", "launchart", "audio" } do
		if capabilities[step] then
			table.insert(sequence, step)
		end
	end
	if capabilities.procedural or capabilities.launchart then
		assert(files["assets/procgen.yml"] ~= nil, "missing procedural input")
		local game = serde.decode("yaml", files["game.yml"])
		local resolved, planErrors = procgen.plan(serde.decode("yaml", files["assets/procgen.yml"]), game.poly_budget)
		assert(resolved ~= nil and #planErrors == 0, table.concat(planErrors, "; "))
		if capabilities.launchart then
			local creatures = launchart.split(resolved :: { procgen.Resolved })
			assert(#creatures > 0, "assets/procgen.yml has no creature entries to render")
		end
	end
	if capabilities.audio then
		assert(files["assets/audio.yml"] ~= nil, "missing audio input")
		local _, parseErrors = audio.plan(serde.decode("yaml", files["assets/audio.yml"]))
		assert(#parseErrors == 0, table.concat(parseErrors, "; "))
	end
	-- The pack config is returned with the assembly: a legacy pack carries no
	-- genre_contract document, so a caller that needs a harness target must use
	-- the config generation already validated rather than re-reading econ.yml.
	return { files = files, order = canonical, generation = sequence, legacy = legacy, pack = pack }
end

function M.assemble(
	registry: registryLib.Registry,
	selected: any,
	input: contract.GenerateInput,
	destination: string,
	runtimeMode: string?
): Assembly
	local ready, prerequisiteError = run.preflight({ "stylua" })
	assert(ready, prerequisiteError)
	local recovered, recoveryError = publish.recover(destination)
	assert(recovered, recoveryError)
	assert(cliutil.isSafeInteger(input.seed), "FORGE_INVALID_INPUT: seed must be a safe integer")
	assert(scaffold.isValidSlug(input.slug), "FORGE_INVALID_INPUT: invalid slug")
	local ok, result = pcall(assemble, registry, selected, input, destination, runtimeMode)
	if not ok then
		error("FORGE_INVALID_CATALOG: " .. tostring(result), 0)
	end
	local assembly: Assembly = result
	local path = "src/server/GenreHooks.luau"
	local hooks = assembly.files[path]
	if hooks then
		local marker = "-- forge-hooks:1:" .. table.concat(assembly.order, ",") .. "\n"
		if fs.isFile(destination .. "/" .. path) then
			local existing = fs.readFile(destination .. "/" .. path)
			local version = string.match(existing, "%-%- forge%-hooks:([^\n]+)")
			if string.find(existing, "forge-hooks:", 1, true) then
				assert(
					version == "1:" .. table.concat(assembly.order, ","),
					"FORGE_REGEN_CONFLICT: unsupported hook version or changed genre selection"
				)
			else
				local decoded, game = pcall(function()
					return serde.decode("yaml", fs.readFile(destination .. "/game.yml"))
				end)
				assert(
					decoded
						and type(game) == "table"
						and game.genre_contract == 1
						and contract.dense(game.genres, 64)
						and contract.serialize(game.genres) == contract.serialize(assembly.order),
					"FORGE_REGEN_CONFLICT: unversioned hooks require matching API 1 game metadata"
				)
			end
			assembly.files[path] = existing
		else
			assembly.files[path] = string.gsub(hooks, "^%-%-!strict\n", "--!strict\n" .. marker, 1)
		end
	end
	return assembly
end

M.write = publish.write
return M
