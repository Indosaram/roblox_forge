--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local assetsLib = require("../lib/assets")
local licenses = require("../lib/licenses")
local cliutil = require("../lib/cliutil")
local manifest = require("./genmanifest")
local M = {}

-- Version of the import recipe: how this command turns a fulfilled request
-- into a manifest entry. Bump it when that mapping changes.
M.IMPORT_RECIPE_VERSION = "1"

--- True when `manifestPath` declares a manifest version that requires
--- provenance on every asset (version 2+). A missing file or a legacy document
--- with no `version:` key reads as version 1.
function M.manifestRequiresProvenance(manifestPath: string): boolean
	if not fs.isFile(manifestPath) then
		return false
	end
	local ok, decoded = pcall(function()
		return serde.decode("yaml", fs.readFile(manifestPath))
	end)
	if not ok or typeof(decoded) ~= "table" or typeof(decoded.version) ~= "number" then
		return false
	end
	return decoded.version >= 2
end

--- Renders the provenance lines for a fulfilled import request, or
--- (nil, reason) when the request does not record enough to reproduce or
--- verify the artifact. `digest` is the sha256 of the delivered bytes and
--- `providerVersion` identifies the provider build that produced them; the
--- rights always come from the license registry record for `tool`.
function M.importProvenance(request: any, tool: string): ({ string }?, string?)
	local digest = request.digest
	if digest == nil then
		return nil, "the request records no digest for the imported artifact"
	end
	if not assetsLib.isDigest(digest) then
		return nil, "digest '" .. tostring(digest) .. "' must be sha256:<64 hex>"
	end
	local providerVersion = request.providerVersion
	if type(providerVersion) ~= "string" or providerVersion == "" then
		return nil, "the request records no providerVersion"
	end
	if not cliutil.isSafeYamlScalar(providerVersion) then
		return nil, "providerVersion is not a valid single-line value"
	end
	local rights = licenses.rights(tool)
	if rights == nil then
		return nil, "no commercial rights record for tool '" .. tool .. "'"
	end
	local typedRights = rights :: licenses.Rights

	local recipeId = request.recipe
	if recipeId == nil then
		recipeId = "import"
	end
	if type(recipeId) ~= "string" or not cliutil.isSafeYamlScalar(recipeId) then
		return nil, "recipe is not a valid single-line value"
	end
	local input = request.prompt

	return {
		"    provenance:",
		"      digest: " .. digest,
		"      recipe:",
		"        id: " .. recipeId,
		"        version: " .. M.IMPORT_RECIPE_VERSION,
		"        input: " .. manifest.yamlQuote(input),
		"        inputVersion: sha256:" .. serde.hash("sha256", input),
		"      provider:",
		"        name: " .. tool,
		"        version: " .. providerVersion,
		"      rights:",
		"        source: " .. manifest.yamlQuote(typedRights.rightsSource),
		"        ownership: " .. typedRights.ownership,
	},
		nil
end
function M.isValidFulfillRequest(kind: string, tool: string): (boolean, string?)
	if not cliutil.isSafeYamlScalar(kind) then
		return false, "kind"
	end
	if not cliutil.isSafeYamlScalar(tool) then
		return false, "tool"
	end
	return true, nil
end

--- `forge gen fulfill <requestFile> --key <assetKey> [--asset-id <n>]`: append a
--- fulfilled request to the pack manifest and mark the request fulfilled.
function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	local requestFile = args[3]
	if requestFile == nil or requestFile == "" then
		stdio.ewrite(
			"Error: gen fulfill requires a request file, e.g. lune run cli/forge gen fulfill <request.json> --key <assetKey>\n"
		)
		return false
	end

	local key: string? = nil
	local assetId = 0
	local index = 4
	while index <= #args do
		local flag = args[index]
		if flag == "--key" or flag == "--asset-id" then
			local value = args[index + 1]
			if value == nil or value == "" then
				stdio.ewrite("Error: " .. flag .. " requires a value\n")
				return false
			end
			if flag == "--key" then
				key = value
			else
				local parsed = tonumber(value)
				if parsed == nil or parsed < 0 or parsed % 1 ~= 0 then
					stdio.ewrite("Error: --asset-id must be a non-negative integer\n")
					return false
				end
				assetId = parsed
			end
			index += 2
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge gen fulfill\n")
			return false
		end
	end

	if key == nil or key == "" then
		stdio.ewrite("Error: gen fulfill requires --key <assetKey>\n")
		return false
	end
	if not cliutil.isValidKey(key) then
		stdio.ewrite("Error: invalid --key '" .. key .. "' (must match [a-zA-Z][a-zA-Z0-9_-]*)\n")
		return false
	end
	local assetKey = key :: string

	if not fs.isFile(requestFile) then
		stdio.ewrite("Error: missing request file " .. requestFile .. "\n")
		return false
	end

	local decodeOk, request = pcall(function()
		return serde.decode("json", fs.readFile(requestFile))
	end)
	if not decodeOk or typeof(request) ~= "table" then
		stdio.ewrite("Error: failed to decode " .. requestFile .. "\n")
		return false
	end

	local kind = request.kind
	local prompt = request.prompt
	local tool = request.tool
	local pack = request.pack
	if type(kind) ~= "string" or type(prompt) ~= "string" or type(tool) ~= "string" or type(pack) ~= "string" then
		stdio.ewrite("Error: " .. requestFile .. " is missing kind/prompt/tool/pack\n")
		return false
	end
	-- F4: `kind` and `tool` are written straight into the manifest YAML block
	-- below as bare (unquoted) scalars, so both must be checked against the
	-- same registries `forge check` (via lib/assets.parseManifest / lib/licenses)
	-- will hold the manifest to, and neither may contain YAML-breaking text.
	-- `prompt` is excluded (finding 7): it is only ever emitted through
	-- yamlQuote below, which escapes `\`, `"` and newlines, so a normal prompt
	-- containing ": " (e.g. "Style: low-poly kaiju") cannot break out of its
	-- quoted scalar and must not be rejected by a check meant for bare scalars.
	local validRequest, invalidField = M.isValidFulfillRequest(kind, tool)
	if not validRequest then
		stdio.ewrite(
			"Error: "
				.. requestFile
				.. " has a "
				.. tostring(invalidField)
				.. " that is not a valid single-line value\n"
		)
		return false
	end
	local _, kindErr = assetsLib.parseManifest({
		assets = { { key = assetKey, kind = kind, tool = "forge-procgen", source = "x" } },
	})
	if kindErr ~= nil and string.find(kindErr, "invalid kind", 1, true) ~= nil then
		stdio.ewrite("Error: " .. requestFile .. " has an invalid kind '" .. kind .. "'\n")
		return false
	end
	local toolAllowed, toolReason = licenses.resolve(tool)
	if not toolAllowed then
		stdio.ewrite("Error: " .. requestFile .. " has a disallowed tool '" .. tool .. "': " .. toolReason .. "\n")
		return false
	end
	local packName = pack :: string

	local packDir = (if context and context.packsDir then context.packsDir else "games") .. "/" .. packName
	if not fs.isDir(packDir) then
		stdio.ewrite("Error: unknown game pack '" .. packName .. "' (missing " .. packDir .. "/)\n")
		return false
	end

	local manifestPath = packDir .. "/assets/manifest.yml"
	if manifest.manifestHasKey(manifestPath, assetKey) then
		stdio.ewrite("Error: asset " .. assetKey .. " already exists in " .. manifestPath .. "\n")
		return false
	end

	manifest.ensureDir(packDir .. "/assets")
	local moderation = if assetId > 0 then "PendingModeration" else "NotUploaded"
	local blockLines = {
		"  - key: " .. assetKey,
		"    kind: " .. (kind :: string),
		"    tool: " .. (tool :: string),
		"    source: " .. manifest.yamlQuote(prompt :: string),
		"    assetId: " .. tostring(assetId),
		"    moderation: " .. moderation,
	}

	-- An import is only reproducible if the request records the delivered bytes
	-- and the provider build that produced them. The commercial rights come from
	-- the license registry for the (already allowed) tool, never from the request
	-- file, so a request cannot claim rights the registry does not grant. A
	-- lawful import recorded this way still carries no quality approval.
	local provenance, provenanceErr = M.importProvenance(request, tool :: string)
	if provenance == nil then
		-- Legacy (version 1) manifests predate provenance and keep accepting bare
		-- imports; a manifest that declares version 2 requires it.
		if M.manifestRequiresProvenance(manifestPath) then
			stdio.ewrite(
				"Error: "
					.. requestFile
					.. " cannot be imported into "
					.. manifestPath
					.. ": "
					.. tostring(provenanceErr)
					.. "\n"
			)
			return false
		end
	else
		for _, line in provenance :: { string } do
			table.insert(blockLines, line)
		end
	end

	local block = table.concat(blockLines, "\n") .. "\n"
	manifest.upsertAsset(manifestPath, assetKey, block)
	stdio.write("gen fulfill: appended " .. assetKey .. " to " .. manifestPath .. " (" .. moderation .. ")\n")

	request.status = "fulfilled"
	manifest.writeJson(requestFile, request)
	stdio.write("gen fulfill: marked " .. requestFile .. " fulfilled\n")
	return true
end
return M
