--!strict
local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local genproviders = require("../lib/genproviders")
local cliutil = require("../lib/cliutil")
local manifest = require("./genmanifest")
local M = {}
local DEFAULT_PACK = "kaiju-egg-raiders"
local function parseFlags(args: { string }): (boolean, { pack: string, key: string, prompt: string, dryRun: boolean }?)
	local pack = DEFAULT_PACK
	local key: string? = nil
	local prompt: string? = nil
	local dryRun = false
	local index = 3
	while index <= #args do
		local flag = args[index]
		if flag == "--pack" or flag == "--key" or flag == "--prompt" then
			local value = args[index + 1]
			if value == nil or value == "" then
				stdio.ewrite("Error: " .. flag .. " requires a value\n")
				return false, nil
			end
			if flag == "--pack" then
				pack = value
			elseif flag == "--key" then
				key = value
			else
				prompt = value
			end
			index += 2
		elseif flag == "--dry-run" then
			dryRun = true
			index += 1
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge gen\n")
			return false, nil
		end
	end

	if prompt == nil then
		stdio.ewrite("Error: gen requires --prompt <text>\n")
		return false, nil
	end
	if key == nil then
		stdio.ewrite("Error: gen requires --key <assetKey>\n")
		return false, nil
	end
	if string.match(key, cliutil.KEY_PATTERN) == nil then
		stdio.ewrite("Error: invalid --key '" .. key .. "' (must match [a-zA-Z][a-zA-Z0-9_-]*)\n")
		return false, nil
	end
	return true, { pack = pack, key = key, prompt = prompt, dryRun = dryRun }
end

--- Generates one asset via its licensed provider and records it in the pack
--- manifest. Returns false with a stderr message on any refusal.
function M.run(args: { string }, _context: cliutil.CommandContext?): boolean
	local kind = args[2]
	if kind == nil or not genproviders.isKind(kind) then
		stdio.ewrite(
			"Error: unknown asset kind '"
				.. tostring(kind)
				.. "'; valid kinds: "
				.. table.concat(genproviders.kinds, ", ")
				.. "\n"
		)
		return false
	end

	local parsedOk, flags = parseFlags(args)
	if not parsedOk or flags == nil then
		return false
	end
	local opts = flags :: { pack: string, key: string, prompt: string, dryRun: boolean }

	local packDir = "games/" .. opts.pack
	if not fs.isDir(packDir) then
		stdio.ewrite("Error: unknown game pack '" .. opts.pack .. "' (missing " .. packDir .. "/)\n")
		return false
	end

	local request, routeErr = genproviders.buildRequest(kind, opts.prompt, process.env)
	if request == nil then
		stdio.ewrite("Error: " .. tostring(routeErr) .. "\n")
		return false
	end
	local req = request :: genproviders.Request

	local targetPath = genproviders.targetPath(opts.pack, kind, opts.key, req.ext)
	local preview = genproviders.renderPreview(req, targetPath)

	if opts.dryRun then
		stdio.write(preview)
		return true
	end

	local missingErr = genproviders.missingEnv(req)
	if missingErr ~= nil then
		stdio.write(preview)
		stdio.ewrite(missingErr .. "\n")
		return false
	end

	manifest.ensureDir(packDir .. "/assets")
	manifest.ensureDir(packDir .. "/assets/" .. kind)

	local body, sendErr = genproviders.send(req, net.request)
	if body == nil then
		stdio.ewrite("Error: " .. tostring(sendErr) .. "\n")
		return false
	end

	fs.writeFile(targetPath, body)
	stdio.write("gen: wrote " .. targetPath .. " (" .. req.provider .. ")\n")

	local manifestPath = packDir .. "/assets/manifest.yml"
	local relPath = "assets/" .. kind .. "/" .. opts.key .. "." .. req.ext
	-- Record how this artifact was produced, digest included, so the asset gate
	-- can verify the bytes on disk are still the ones this provider returned.
	-- No quality verdict is implied: the entry is lawful and reproducible, and
	-- still awaits a quality report.
	manifest.upsertAsset(
		manifestPath,
		opts.key,
		genproviders.manifestBlock(opts.key, kind, req.provider, opts.prompt, relPath, {
			digest = "sha256:" .. serde.hash("sha256", body),
			recipeId = "gen-" .. kind,
			recipeVersion = genproviders.RECIPE_VERSION,
			inputVersion = "sha256:" .. serde.hash("sha256", opts.prompt),
			-- The provider does not report a version, so record the exact endpoint
			-- identity that produced these bytes instead of inventing one.
			providerVersion = "endpoint:" .. string.sub(serde.hash("sha256", req.url), 1, 16),
			rightsSource = req.provider,
			ownership = "licensed",
		})
	)
	stdio.write("gen: upserted " .. opts.key .. " in " .. manifestPath .. " (NotUploaded, " .. req.provider .. ")\n")
	return true
end
return M
