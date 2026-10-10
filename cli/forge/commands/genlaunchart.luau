--- `forge gen launchart --pack <slug>`: renders the pack's store art - two
--- 512x512 icons and two 1920x1080 thumbnails - from its procedural meshes with
--- the framework rasterizer + Pixels, writes deterministic PNGs under
--- assets/icon and assets/thumbnails, and upserts the four entries as
--- forge-procgen/Approved. No API keys, no upload, no network.
--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local assetsCommand = require("./assets")
local cliutil = require("../lib/cliutil")
local procgen = require("../lib/procgen")
local launchart = require("../lib/launchart")
local png = require("../lib/png")
local manifest = require("./genmanifest")
local M = {}
local DEFAULT_PACK = "kaiju-egg-raiders"
function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	local pack = DEFAULT_PACK
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
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge gen launchart\n")
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

	local resolved, errors = procgen.plan(doc, manifest.loadPolyBudget(packDir))
	if resolved == nil or #errors > 0 then
		for _, err in errors do
			stdio.ewrite("Error: " .. err .. "\n")
		end
		return false
	end
	local specs = resolved :: { procgen.Resolved }

	local creatures, eggs = launchart.split(specs)
	if #creatures == 0 then
		stdio.ewrite("Error: " .. procgenPath .. " has no creature entries to render\n")
		return false
	end

	local econDoc: any = nil
	local econPath = packDir .. "/econ.yml"
	if fs.isFile(econPath) then
		local econOk, decodedEcon = pcall(function()
			return serde.decode("yaml", fs.readFile(econPath))
		end)
		if econOk then
			econDoc = decodedEcon
		end
	end
	local rarest = launchart.rarestKey(econDoc, creatures)

	manifest.ensureDir(packDir .. "/assets")
	manifest.ensureDir(packDir .. "/assets/icon")
	manifest.ensureDir(packDir .. "/assets/thumbnails")

	local jobs = {
		{ key = "iconA", path = "assets/icon/icon-a.png", canvas = launchart.iconA(creatures, eggs, rarest) },
		{ key = "iconB", path = "assets/icon/icon-b.png", canvas = launchart.iconB(creatures, eggs, rarest) },
		{ key = "thumbA", path = "assets/thumbnails/thumb-a.png", canvas = launchart.thumbnail(creatures, "a") },
		{ key = "thumbB", path = "assets/thumbnails/thumb-b.png", canvas = launchart.thumbnail(creatures, "b") },
	}
	local manifestPath = packDir .. "/assets/manifest.yml"
	local source = "procedural launch art (forge gen launchart)"
	-- The render inputs are the procgen specs plus the rarest-key choice; hash
	-- them so a changed roster is a changed recipe input version.
	local inputVersion = "sha256:" .. serde.hash("sha256", serde.encode("json", { specs = specs, rarest = rarest }))
	for _, job in jobs do
		local bytes = png.encode(job.canvas)
		fs.writeFile(packDir .. "/" .. job.path, bytes)
		local digest = serde.hash("sha256", buffer.tostring(bytes))
		stdio.write(
			string.format(
				"%s %dx%d %d bytes sha256=%s\n",
				job.path,
				job.canvas.width,
				job.canvas.height,
				buffer.len(bytes),
				digest
			)
		)
		local block = table.concat({
			"  - key: " .. job.key,
			"    kind: image",
			"    tool: forge-procgen",
			"    source: " .. manifest.yamlQuote(source),
			"    path: " .. job.path,
			"    assetId: 0",
			"    moderation: Approved",
			-- Lawful and reproducible provenance only: moderation above is the
			-- platform's verdict, and the artwork still carries no quality report.
			"    provenance:",
			"      digest: sha256:" .. digest,
			"      recipe:",
			"        id: gen-launchart",
			"        version: " .. launchart.RECIPE_VERSION,
			"        input: " .. manifest.yamlQuote("assets/procgen.yml#" .. job.key),
			"        inputVersion: " .. inputVersion,
			"      provider:",
			"        name: forge-procgen",
			"        version: " .. launchart.RECIPE_VERSION,
			"      rights:",
			"        source: " .. manifest.yamlQuote("first-party generator in this repository"),
			"        ownership: first-party",
		}, "\n") .. "\n"
		manifest.upsertAsset(manifestPath, job.key, block)
	end

	if not assetsCommand.run({ "assets", "codegen", "--pack", pack }, context) then
		return false
	end
	stdio.write(string.format("gen launchart: wrote %d files for %s\n", #jobs, pack))
	return true
end
return M
