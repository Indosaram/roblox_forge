--- `forge gen icons --pack <slug>`: reads games/<pack>/assets/procgen.yml and
--- renders a 128px .ppm preview for every creature and egg entry with the pure
--- Pixels/Icons painters, then refreshes one forge-procgen/Approved manifest
--- entry per planned icon (key `icon-<name>`, no upload, no API keys).
--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local assetsCommand = require("./assets")
local cliutil = require("../lib/cliutil")
local iconplan = require("../lib/iconplan")
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
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge gen icons\n")
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

	local jobs, errors = iconplan.plan(doc)
	if jobs == nil or #errors > 0 then
		for _, err in errors do
			stdio.ewrite("Error: " .. err .. "\n")
		end
		return false
	end
	local planned = jobs :: { iconplan.Job }

	manifest.ensureDir(packDir .. "/assets")
	manifest.ensureDir(packDir .. "/assets/icons")
	local digests: { [string]: string } = {}
	for _, job in planned do
		local canvas = iconplan.render(job)
		local ppm = canvas:toPPM()
		local outPath = packDir .. "/assets/icons/" .. job.key .. ".ppm"
		fs.writeFile(outPath, ppm)
		digests[job.key] = serde.hash("sha256", ppm)
		stdio.write(string.format("%s icon %dx%d\n", job.key, job.size, job.size))
	end

	-- Refresh one manifest entry per planned icon. The entry records lawful,
	-- reproducible provenance for the bytes just rendered; `moderation` remains
	-- the platform's own verdict and no quality approval is implied.
	local manifestPath = packDir .. "/assets/manifest.yml"
	for _, job in planned do
		local key = "icon-" .. job.key
		local block = table.concat({
			"  - key: " .. key,
			"    kind: image",
			"    tool: forge-procgen",
			"    source: " .. manifest.yamlQuote("procedural icon/" .. job.key),
			"    assetId: 0",
			"    moderation: Approved",
			"    provenance:",
			"      digest: sha256:" .. digests[job.key],
			"      recipe:",
			"        id: gen-icons",
			"        version: " .. iconplan.RECIPE_VERSION,
			"        input: " .. manifest.yamlQuote("assets/procgen.yml#" .. job.key),
			"        inputVersion: sha256:" .. serde.hash("sha256", serde.encode("json", job)),
			"      provider:",
			"        name: forge-procgen",
			"        version: " .. iconplan.RECIPE_VERSION,
			"      rights:",
			"        source: " .. manifest.yamlQuote("first-party generator in this repository"),
			"        ownership: first-party",
		}, "\n") .. "\n"
		manifest.upsertAsset(manifestPath, key, block)
	end
	if not assetsCommand.run({ "assets", "codegen", "--pack", pack }, context) then
		return false
	end
	stdio.write(string.format("gen icons: wrote %d previews to %s/assets/icons\n", #planned, packDir))
	stdio.write(string.format("gen icons: refreshed %d manifest entries for %s\n", #planned, pack))
	return true
end
return M
