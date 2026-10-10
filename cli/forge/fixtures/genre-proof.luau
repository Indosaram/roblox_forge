--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local luau = require("@lune/luau")
local registryLib = require("../lib/genreregistry")
local genresim = require("../lib/genresim")
local Options = require("../../../core/infra/genre/Options")
local run = require("../lib/run")
local roblox = require("@lune/roblox")
local new = require("../commands/new")
local plan = require("../commands/plan")
local qa = require("../commands/qa")
local codegen = require("../commands/codegen")
local econ = require("../commands/econ")
local smokeCommand = require("../commands/smoke")
local generate = require("../lib/genregenerate")
local dynamicRequire = require :: any
local M = {}
function M.run(): { string }
	local root = generate.absolute(
		(process.env.TEMP or process.env.TMP or ".omo/wip")
			.. "/forge-genre-proof-"
			.. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
	)
	local context = {
		packsDir = root .. "/packs",
		reportsDir = root .. "/reports",
		genresDir = generate.absolute("cli/forge/fixtures/genres"),
	}
	local receipt = {}
	local ok, reason = xpcall(function()
		generate.ensureDir(root)
		assert(new.run({ "new", "counter-new", "--genre", "fixture-counter" }, context), "new failed")
		assert(
			plan.run({
				"plan",
				"--concept",
				"Counter proof",
				"--genre",
				"fixture-counter",
				"--pack",
				"counter-plan",
				"--seed",
				"7",
			}, context),
			"plan failed"
		)
		assert(qa.run({ "qa", "validate" }, context), "qa validate failed")
		local registry, registryErrors = registryLib.discover(context.genresDir)
		assert(registry ~= nil, table.concat(registryErrors, "; "))
		for _, slug in { "counter-new", "counter-plan" } do
			assert(qa.run({ "qa", "plan", "--pack", slug }, context), "qa plan failed")
			assert(codegen.run({ "codegen", slug }, context), "codegen failed")
			local package = registry.packages["fixture-counter"]
			local forge = { genres = { [package.id] = { module = { Contract = package.path .. "/module/Contract" } } } }
			local runtime = luau.load(fs.readFile(root .. "/packs/" .. slug .. "/src/shared/GenreRuntime.luau"), {
				environment = {
					game = {
						GetService = function(_self, _name)
							return {
								WaitForChild = function(_storage, _child)
									return forge
								end,
							}
						end,
					},
					require = function(target: string)
						return dynamicRequire("./" .. generate.relative("cli/forge/fixtures", target))
					end,
				},
			})()
			assert(#runtime == 1 and runtime[1] == package.runtime, "generated runtime selected wrong contract")
			local controls = luau.load(fs.readFile(root .. "/packs/" .. slug .. "/src/shared/GenreUI.luau"))()
			local hooks = luau.load(fs.readFile(root .. "/packs/" .. slug .. "/src/server/GenreHooks.luau"))()
			local document = serde.decode("yaml", fs.readFile(root .. "/packs/" .. slug .. "/econ.yml"))
			Options.validate({
				packConfig = document.genre_contract,
				contracts = runtime,
				controls = controls,
				storeName = slug .. "-genre-v1",
				hooks = hooks,
			})
			local executor = genresim.create(document.genre_contract, registry, 7)
			assert(executor.join("generated-runtime").ok, "generated runtime join failed")
			assert(
				executor.dispatchClient("generated-runtime", runtime[1].id .. ":increment", {}).ok,
				"generated action failed"
			)
			assert(
				executor.snapshot("generated-runtime")[runtime[1].id].count == 1,
				"generated runtime mutation missing"
			)
			assert(
				econ.run({ "econ", "sim", "--pack", slug, "--players", "2", "--days", "1" }, context),
				"econ sim failed"
			)
			local smoke = dynamicRequire(
				"./" .. generate.relative("cli/forge/fixtures", root .. "/packs/" .. slug .. "/smoke/smoke")
			)
			assert(smokeCommand.run({ "smoke", "--pack", slug, "--local" }, context), "real smoke command failed")
			local checks = smoke.run(nil)
			assert(#checks > 0, "empty generated checks")
			for _, check in checks do
				assert(check.ok, check.name)
				table.insert(receipt, slug .. ": " .. check.name .. " PASS")
			end
			local output = root .. "/" .. slug .. ".rbxl"
			local built =
				run.exec("rojo", { "build", root .. "/packs/" .. slug .. "/default.project.json", "-o", output })
			assert(built.ok, "rojo build failed: " .. built.stderr)
			table.insert(
				receipt,
				"rojo build "
					.. root
					.. "/packs/"
					.. slug
					.. "/default.project.json -o "
					.. output
					.. " exit "
					.. built.code
			)
			local place = roblox.deserializePlace(fs.readFile(output))
			local server = place:FindFirstChild("ServerScriptService")
			assert(server and server:FindFirstChild("GenreHooks"), "built server hooks missing")
			assert(
				server and server:FindFirstChild(slug == "counter-new" and "CounterNewServer" or "CounterPlanServer"),
				"built server missing"
			)
			local mounted: roblox.Instance = place
			for _, name in { "ReplicatedStorage", "Forge", "genres", "fixture-counter", "module", "Contract" } do
				local child = mounted:FindFirstChild(name)
				assert(child, "built runtime mount missing: " .. name)
				mounted = child
			end
			table.insert(receipt, slug .. ": built starter and runtime mounts PASS")
		end
		local before = fs.readDir(root .. "/packs")
		assert(not new.run({ "new", "unknown", "--genre", "unknown" }, context), "unknown accepted")
		assert(
			not new.run({ "new", "duplicate", "--genre", "fixture-counter,fixture-counter" }, context),
			"duplicate accepted"
		)
		assert(#fs.readDir(root .. "/packs") == #before, "negative input wrote files")
		local args = {
			"plan",
			"--concept",
			"Counter proof",
			"--genre",
			"fixture-counter",
			"--pack",
			"counter-plan",
			"--seed",
			"7",
		}
		local packDir = root .. "/packs/counter-plan"
		local deploy = "environments: {staging: {universeId: 42, placeId: 24}}\n"
		fs.writeFile(packDir .. "/deploy.yml", deploy)
		local manifest = packDir .. "/assets/manifest.yml"
		local document = serde.decode("yaml", fs.readFile(manifest))
		for _, entry in document.assets do
			entry.assetId = 12345
			entry.moderation = "Approved"
		end
		document.custom_metadata = "retained"
		table.insert(document.assets, {
			key = "custom-prop",
			kind = "model",
			assetId = 67890,
			moderation = "Approved",
			tool = "forge-procgen",
			license = "framework",
			source = "custom",
		})
		fs.writeFile(manifest, serde.encode("yaml", document))
		assert(plan.run(args, context), "regeneration failed")
		assert(fs.readFile(packDir .. "/deploy.yml") == deploy, "deploy bytes changed")
		local restored = serde.decode("yaml", fs.readFile(manifest))
		assert(restored.custom_metadata == "retained", "manifest metadata lost")
		local keys = {}
		for _, entry in restored.assets do
			keys[entry.key] = entry.assetId
		end
		assert(
			keys["fixture-counter-starter-prop"] == 12345
				and keys["fixture-counter-action"] == 12345
				and keys["custom-prop"] == 67890,
			"published fields/custom asset lost: " .. serde.encode("json", keys)
		)
		local bytes = fs.readFile(packDir .. "/src/shared/GenreConfig.luau")
		assert(plan.run(args, context), "second regeneration failed")
		assert(fs.readFile(packDir .. "/src/shared/GenreConfig.luau") == bytes, "regeneration drift")
	end, debug.traceback)
	local cleaned, cleanupError = pcall(function()
		if fs.isDir(root) then
			fs.removeDir(root)
		end
	end)
	assert(cleaned, "cleanup failed: " .. tostring(cleanupError) .. "; original: " .. tostring(reason))
	table.insert(receipt, "removed " .. root)
	assert(ok, tostring(reason))
	return receipt
end
return M
