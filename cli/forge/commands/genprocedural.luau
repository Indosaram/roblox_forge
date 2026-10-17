--- `forge gen procedural --pack <slug> [--obj] [--preview]`: reads
--- games/<pack>/assets/procgen.yml and game.yml poly_budget, generates every
--- mesh under Lune with the pure core generators, refuses if any asset exceeds
--- its triangle budget, writes the generated games/<pack>/src/shared/ProcAssets.luau
--- specs module, and upserts each asset into manifest.yml as
--- forge-procgen/Approved. With --obj it dumps a Wavefront OBJ per key, and with
--- --preview it renders a front/side PPM per key plus a contact sheet.ppm under
--- assets/preview/ (gitignored) with the framework's own rasterizer.
--- No API keys, no network, no upload.
--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local assetsCommand = require("./assets")
local cliutil = require("../lib/cliutil")
local procgen = require("../lib/procgen")
local rasterize = require("../lib/rasterize")
local manifest = require("./genmanifest")
local M = {}
local DEFAULT_PACK = "kaiju-egg-raiders"
local PREVIEW_SIZE = 256
function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	local pack = DEFAULT_PACK
	local obj = false
	local preview = false
	local stamp: { author: string?, created: string? } = {}
	local index = 3
	while index <= #args do
		local flag = args[index]
		if flag == "--pack" then
			local value = args[index + 1]
			if value == nil or value == "" then
				stdio.ewrite("Error: --pack requires a value\n")
				return false
			end
			pack = value
			index += 2
		elseif flag == "--obj" then
			obj = true
			index += 1
		elseif flag == "--preview" then
			preview = true
			index += 1
		elseif flag == "--author" or flag == "--created" then
			local stampErr = manifest.parseStamp(flag, args[index + 1], stamp)
			if stampErr ~= nil then
				stdio.ewrite(stampErr)
				return false
			end
			index += 2
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge gen procedural\n")
			return false
		end
	end

	local packDir = (if context and context.packsDir then context.packsDir else "games") .. "/" .. pack
	if not fs.isDir(packDir) then
		stdio.ewrite("Error: unknown game pack '" .. pack .. "' (missing " .. packDir .. "/)\n")
		return false
	end

	local procgenPath = packDir .. "/assets/procgen.yml"
	if not fs.isFile(procgenPath) then
		stdio.ewrite("Error: missing " .. procgenPath .. "\n")
		return false
	end
	local decodeOk, doc = pcall(function()
		return serde.decode("yaml", fs.readFile(procgenPath))
	end)
	if not decodeOk or typeof(doc) ~= "table" then
		stdio.ewrite("Error: failed to decode " .. procgenPath .. "\n")
		return false
	end

	local polyBudget: any = {}
	local gamePath = packDir .. "/game.yml"
	if fs.isFile(gamePath) then
		local gameOk, game = pcall(function()
			return serde.decode("yaml", fs.readFile(gamePath))
		end)
		if gameOk and typeof(game) == "table" and typeof(game.poly_budget) == "table" then
			polyBudget = game.poly_budget
		end
	end

	local stampLines, stampErr = manifest.stampLines(stamp)
	if stampErr ~= nil then
		stdio.ewrite(stampErr)
		return false
	end

	local resolved, errors = procgen.plan(doc, polyBudget)
	if resolved == nil or #errors > 0 then
		for _, err in errors do
			stdio.ewrite("Error: " .. err .. "\n")
		end
		return false
	end
	local specs = resolved :: { procgen.Resolved }

	manifest.ensureDir(packDir .. "/src")
	manifest.ensureDir(packDir .. "/src/shared")
	manifest.ensureDir(packDir .. "/assets")
	local luauPath = packDir .. "/src/shared/ProcAssets.luau"
	fs.writeFile(luauPath, procgen.renderLuau(specs))

	local manifestPath = packDir .. "/assets/manifest.yml"
	for _, entry in specs do
		local source = "procedural " .. entry.kind .. "/" .. entry.archetype
		-- A procedural model has no artifact file of its own: the shipped bytes
		-- are the generated mesh. Digest the mesh the generator just produced, so
		-- the manifest records the exact geometry this recipe emits.
		local mesh = procgen.buildMesh(entry)
		local digest = serde.hash("sha256", procgen.renderObj(mesh))
		local block = table.concat({
			"  - key: " .. entry.key,
			"    kind: model",
			"    tool: forge-procgen",
			"    source: " .. manifest.yamlQuote(source),
			"    assetId: 0",
			"    moderation: Approved",
			"    provenance:",
			"      digest: sha256:" .. digest,
			"      recipe:",
			"        id: gen-procedural",
			"        version: " .. procgen.RECIPE_VERSION,
			"        input: " .. manifest.yamlQuote("assets/procgen.yml#" .. entry.key),
			"        inputVersion: sha256:" .. serde.hash("sha256", serde.encode("json", entry)),
			"      provider:",
			"        name: forge-procgen",
			"        version: " .. procgen.RECIPE_VERSION,
			"      rights:",
			"        source: " .. manifest.yamlQuote("first-party generator in this repository"),
			"        ownership: first-party",
			table.unpack(stampLines),
		}, "\n") .. "\n"
		manifest.upsertAsset(manifestPath, entry.key, block)
	end

	-- Refresh the generated src/shared/Assets.luau from the manifest we just
	-- upserted, via the same path as `forge assets codegen --pack <pack>`:
	-- `forge check` gates on Assets.luau drift and would otherwise fail right
	-- after a successful gen procedural.
	if not assetsCommand.run({ "assets", "codegen", "--pack", pack }, context) then
		return false
	end

	for _, entry in specs do
		stdio.write(
			string.format(
				"%s %s/%s tris=%d budget=%d\n",
				entry.key,
				entry.kind,
				entry.archetype,
				entry.triangleCount,
				entry.budget
			)
		)
	end
	if obj then
		manifest.ensureDir(packDir .. "/assets/preview")
		for _, entry in specs do
			local mesh = procgen.buildMesh(entry)
			fs.writeFile(packDir .. "/assets/preview/" .. entry.key .. ".obj", procgen.renderObj(mesh))
		end
		stdio.write(string.format("gen procedural: wrote %d OBJ previews to %s/assets/preview\n", #specs, packDir))
	end
	if preview then
		manifest.ensureDir(packDir .. "/assets/preview")
		local tiles: { any } = {}
		local written: { string } = {}
		for _, entry in specs do
			local mesh = procgen.buildMesh(entry)
			local views = {
				{ suffix = "front", yaw = 0, pitch = 0.28 },
				{ suffix = "side", yaw = math.pi / 2, pitch = 0.14 },
			}
			for _, view in views do
				local canvas = rasterize.render(mesh, {
					width = PREVIEW_SIZE,
					height = PREVIEW_SIZE,
					yaw = view.yaw,
					pitch = view.pitch,
				})
				local ppm = canvas:toPPM()
				local path = packDir .. "/assets/preview/" .. entry.key .. "-" .. view.suffix .. ".ppm"
				fs.writeFile(path, ppm)
				table.insert(tiles, canvas)
				table.insert(written, string.format("%s-%s.ppm %d bytes", entry.key, view.suffix, #ppm))
			end
		end
		local sheet = rasterize.sheet(tiles, { columns = 4, gap = 8 })
		local sheetPPM = sheet:toPPM()
		fs.writeFile(packDir .. "/assets/preview/sheet.ppm", sheetPPM)
		for _, line in written do
			stdio.write(line .. "\n")
		end
		stdio.write(string.format("sheet.ppm %d bytes\n", #sheetPPM))
		stdio.write(
			string.format("gen procedural: wrote %d previews + sheet.ppm to %s/assets/preview\n", #tiles, packDir)
		)
	end
	stdio.write(string.format("gen procedural: wrote %s (%d assets)\n", luauPath, #specs))
	return true
end
return M
