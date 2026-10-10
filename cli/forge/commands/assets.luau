--!strict
-- `forge assets check|codegen|status|upload-audio [--pack <slug>] [--env staging|production]
--   [--manifest <path>] [--quality-profile <path>] [--pack-dir <dir>]`:
--   check        - gate a manifest's provenance (lawful tool/provider, recorded
--                  recipe and rights, digest matching the artifact bytes on disk)
--                  and its moderation state. With --quality-profile it additionally
--                  requires a quality report bound to each asset's exact digest.
--   codegen      - write games/<pack>/src/shared/Assets.luau and games/<pack>/asphalt.toml
--   status       - refresh moderation for uploaded assets through the Open Cloud Assets API
--   upload-audio - publish the pack's synthesised WAV cues (sfx/bgm) through the
--                  Open Cloud Assets API, poll each operation, and record the
--                  returned rbxassetid plus moderation state in the manifest. The
--                  upload is idempotent by artifact sha256: an identical WAV that
--                  was published before is reused from build/audio-upload-cache.json
--                  instead of re-uploaded. Pending moderation is reported, never
--                  treated as playable.
-- The status and upload-audio commands make no network call until
-- ROBLOX_API_KEY is present. check never makes one at all.

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local assetsLib = require("../lib/assets")
local audioassets = require("../lib/audioassets")
local cliutil = require("../lib/cliutil")
local qualityprofile = require("../lib/qualityprofile")

local M = {}

local DEFAULT_PACK = "kaiju-egg-raiders"
local ENVS = { "staging", "production" }
local SUBS = { "check", "codegen", "status", "upload-audio" }

-- Open Cloud Assets API endpoints and the publishing defaults. Audio uploads
-- are free; nothing here spends Robux. The creator is the pack's group by
-- default, matching the deployed staging group.
local ASSETS_URL = "https://apis.roblox.com/assets/v1/assets"
local OPERATIONS_URL = "https://apis.roblox.com/assets/v1/operations/"
local DEFAULT_CREATOR_GROUP = 570462331
local DEFAULT_CACHE_PATH = "build/audio-upload-cache.json"
local UPLOAD_POLL_INTERVAL_SECONDS = 1
local UPLOAD_POLL_ATTEMPTS = 60

local function isIn(values: { string }, value: string): boolean
	for _, known in values do
		if known == value then
			return true
		end
	end
	return false
end

local function ensureDir(path: string)
	if not fs.isDir(path) then
		fs.writeDir(path)
	end
end

local function decodeYaml(path: string): any
	local ok, decoded = pcall(function()
		return serde.decode("yaml", fs.readFile(path))
	end)
	if not ok or typeof(decoded) ~= "table" then
		return nil
	end
	return decoded
end

local function loadManifest(path: string): (assetsLib.Manifest?, string?)
	if not fs.isFile(path) then
		return nil, "Error: missing " .. path
	end
	local decoded = decodeYaml(path)
	if decoded == nil then
		return nil, "Error: failed to decode " .. path
	end
	return assetsLib.parseManifest(decoded)
end

-- Hashes every asset artifact that has a local `path`, relative to the
-- manifest's own directory. A key whose file is absent gets no digest (there
-- are no bytes to compare); a key whose file exists but cannot be read is
-- reported as unreadable so the gate refuses rather than passing it silently.
local function artifactDigests(
	manifest: assetsLib.Manifest,
	baseDir: string
): ({ [string]: string }, { [string]: boolean })
	local digests: { [string]: string } = {}
	local unreadable: { [string]: boolean } = {}
	for _, asset in manifest.assets do
		local path = asset.path
		if asset.provenance ~= nil and path ~= nil then
			local full = baseDir .. "/" .. path
			if fs.isFile(full) then
				local ok, bytes = pcall(fs.readFile, full)
				if ok then
					digests[asset.key] = assetsLib.digestOf(serde.hash("sha256", bytes))
				else
					unreadable[asset.key] = true
				end
			else
				unreadable[asset.key] = true
			end
		end
	end
	return digests, unreadable
end

-- The directory an asset's relative `path` resolves against. A manifest in a
-- pack's assets/ directory resolves against the pack root (paths are written
-- as `assets/<kind>/<file>`); a manifest kept anywhere else resolves against
-- its own directory, so a standalone manifest still finds its artifacts
-- instead of silently reporting every one of them unreadable.
local function packRootOf(manifestPath: string): string
	local dir = string.match(manifestPath, "^(.*)/[^/]+$")
	if dir == nil then
		return "."
	end
	local parent, leaf = string.match(dir, "^(.*)/([^/]+)$")
	if leaf == "assets" and parent ~= nil and parent ~= "" then
		return parent
	end
	if dir == "assets" then
		return "."
	end
	return dir
end

local function runCheck(
	manifest: assetsLib.Manifest,
	env: string,
	manifestPath: string,
	qualityProfilePath: string?
): boolean
	local result = assetsLib.check(manifest, env)
	local digests, unreadable = artifactDigests(manifest, packRootOf(manifestPath))
	local provenance = assetsLib.checkProvenance(manifest, { digests = digests, unreadable = unreadable })

	local errors: { string } = {}
	for _, err in result.errors do
		table.insert(errors, err)
	end
	for _, err in provenance.errors do
		table.insert(errors, err)
	end

	-- The quality verdict is a separate gate with its own evidence: without a
	-- profile this command reports provenance only and never implies approval.
	local quality: assetsLib.GateResult? = nil
	if qualityProfilePath ~= nil then
		local ok, checked = pcall(function(): assetsLib.GateResult
			local packDir = packRootOf(manifestPath)
			assert(
				manifestPath == packDir .. "/assets/manifest.yml",
				"quality approval requires the canonical pack manifest"
			)
			assert(
				qualityProfilePath == packDir .. "/quality.yml",
				"quality approval requires the canonical pack quality.yml"
			)
			local profile, profileErrors = qualityprofile.parse(decodeYaml(qualityProfilePath))
			assert(profile, table.concat(profileErrors, "; "))
			assert(profile.receiptPath, "missing canonical evaluation_receipt")
			local receipt = serde.decode("json", fs.readFile(profile.receiptPath))
			assert(type(receipt) == "table" and type(receipt.inputs) == "table", "missing attested receipt inputs")
			return assetsLib.checkQuality(
				manifest,
				profile,
				{
					root = ".",
					packDir = packDir,
					receiptPath = profile.receiptPath,
					buildPath = receipt.inputs.buildPath,
					evidenceDir = receipt.inputs.evidenceDir,
					evidence = receipt.inputs.evidence,
				},
				receipt,
				{
					identity = process.env.FORGE_QUALITY_EVALUATOR or "",
					attestationPath = process.env.FORGE_QUALITY_ATTESTATION or "",
				}
			)
		end)
		if not ok then
			stdio.ewrite("assets quality: FAIL " .. tostring(checked) .. "\n")
			return false
		end
		quality = checked

		for _, err in (quality :: assetsLib.GateResult).errors do
			table.insert(errors, err)
		end
	end

	if #errors > 0 then
		for _, err in errors do
			stdio.write(err .. "\n")
		end
		stdio.write("assets check: FAIL\n")
		return false
	end

	stdio.write(
		string.format(
			"assets provenance: PASS (%d assets, manifest version %d, env=%s)\n",
			#manifest.assets,
			manifest.version,
			env
		)
	)
	-- Moderation and quality are reported on their own lines: a platform
	-- moderation state is not a local quality verdict, and vice versa.
	stdio.write(string.format("assets moderation: %d entries reported\n", #provenance.moderation))
	if quality == nil then
		stdio.write(
			string.format(
				"assets quality: NOT EVALUATED (%d awaiting a quality report; pass --quality-profile to evaluate)\n",
				#provenance.pending
			)
		)
	else
		stdio.write(string.format("assets quality: PASS (%d approved)\n", #(quality :: assetsLib.GateResult).approved))
	end
	stdio.write("assets check: PASS\n")
	return true
end

local function runCodegen(pack: string, manifest: assetsLib.Manifest, context: cliutil.CommandContext?): boolean
	local packDir = (if context and context.packsDir then context.packsDir else "games") .. "/" .. pack
	if not fs.isDir(packDir) then
		stdio.ewrite("Error: unknown game pack '" .. pack .. "' (missing " .. packDir .. "/)\n")
		return false
	end

	local luauPath = packDir .. "/src/shared/Assets.luau"
	ensureDir(packDir .. "/src")
	ensureDir(packDir .. "/src/shared")
	fs.writeFile(luauPath, assetsLib.renderLuau(manifest, pack))

	local asphaltPath = packDir .. "/asphalt.toml"
	fs.writeFile(asphaltPath, assetsLib.asphaltConfig(pack, manifest))

	stdio.write("assets codegen: wrote " .. luauPath .. "\n")
	stdio.write("assets codegen: wrote " .. asphaltPath .. "\n")
	return true
end

-- Maps the Open Cloud Assets API's moderationResult.moderationState onto our
-- Moderation enum. The API's in-review state is named "Reviewing"; our
-- manifest contract (lib/assets.luau) calls the same state
-- "PendingModeration", so it needs an explicit rename rather than a passthrough.
local API_MODERATION_STATE: { [string]: assetsLib.Moderation } = {
	Approved = "Approved",
	Rejected = "Rejected",
	Reviewing = "PendingModeration",
}

-- Refresh moderation within each asset block, inserting the optional field
-- before the block closes. Reuse the manifest editor's dedent rules so trailing
-- metadata/comments stay outside the asset, including for indentless lists.
-- Exported so specs can exercise runStatus's write-back without Open Cloud.
function M.applyModerationUpdates(text: string, linesByKey: { [string]: string }): string
	local lines = cliutil.splitLines(text)
	local hadTrailingNewline = string.sub(text, -1) == "\n"

	local result: { string } = {}
	local sequence = cliutil.assetSequence(lines)
	if sequence == nil then
		return text
	end
	local i = 1
	while i <= #lines do
		local line = lines[i]
		local itemIndent, keyValue = string.match(line, "^( *)%- key:%s*(.-)%s*$")
		if
			i >= sequence.first
			and i < sequence.limit
			and keyValue ~= nil
			and itemIndent ~= nil
			and itemIndent == sequence.indent
		then
			local moderation = linesByKey[cliutil.unquoteYamlKey(keyValue)]
			local lastIndex = cliutil.findBlockEnd(lines, i)
			local fieldIndent = itemIndent .. "  "
			local sawModeration = false
			for j = i, lastIndex do
				local indent = string.match(lines[j], "^( *)moderation:")
				if moderation ~= nil and indent ~= nil and indent == fieldIndent then
					table.insert(result, indent .. "moderation: " .. moderation)
					sawModeration = true
				else
					table.insert(result, lines[j])
				end
			end
			if moderation ~= nil and not sawModeration then
				table.insert(result, fieldIndent .. "moderation: " .. moderation)
			end
			i = lastIndex + 1
		else
			table.insert(result, line)
			i += 1
		end
	end

	return table.concat(result, "\n") .. (if hadTrailingNewline then "\n" else "")
end

local function runStatus(pack: string, manifestPath: string, manifest: assetsLib.Manifest): boolean
	local apiKey = process.env["ROBLOX_API_KEY"]
	if apiKey == nil or apiKey == "" then
		stdio.ewrite("Error: ROBLOX_API_KEY is not set; assets status needs Open Cloud access\n")
		return false
	end

	local refreshed = 0
	local linesByKey: { [string]: string } = {}
	for _, asset in manifest.assets do
		if asset.assetId > 0 then
			local url = "https://apis.roblox.com/assets/v1/assets/" .. tostring(asset.assetId)
			local response = net.request({
				url = url,
				method = "GET",
				headers = { ["x-api-key"] = apiKey },
			})
			if not response.ok then
				stdio.ewrite(
					string.format("asset %s: HTTP %d %s\n", asset.key, response.statusCode, response.statusMessage)
				)
				return false
			end
			local decodedOk, body = pcall(function()
				return serde.decode("json", response.body)
			end)
			local apiState = if decodedOk
					and typeof(body) == "table"
					and typeof(body.moderationResult) == "table"
					and typeof(body.moderationResult.moderationState) == "string"
				then body.moderationResult.moderationState
				else nil
			if apiState == nil then
				stdio.ewrite("asset " .. asset.key .. ": response had no moderationResult.moderationState\n")
				return false
			end
			local mapped: assetsLib.Moderation? = API_MODERATION_STATE[apiState]
			if mapped == nil then
				stdio.ewrite(
					"asset " .. asset.key .. ": unknown moderation state '" .. apiState .. "' from Open Cloud\n"
				)
				return false
			end
			local finalMapped: assetsLib.Moderation = mapped :: any
			asset.moderation = finalMapped
			linesByKey[asset.key] = finalMapped
			stdio.write("asset " .. asset.key .. ": " .. mapped .. "\n")
			refreshed += 1
		end
	end

	-- Update the `moderation:` line per refreshed key in place (F2/finding 5): a
	-- full serde.encode re-encode drops every hand-written comment and reorders
	-- keys, and a block with no existing moderation: line still needs one
	-- inserted rather than silently skipped.
	if refreshed > 0 then
		local text = fs.readFile(manifestPath)
		fs.writeFile(manifestPath, M.applyModerationUpdates(text, linesByKey))
	end
	stdio.write(string.format("assets status: PASS (%d uploaded assets refreshed for %s)\n", refreshed, pack))
	return true
end

-- ---------------------------------------------------------------------------
-- upload-audio: publish a pack's synthesised WAV cues through Open Cloud.
-- ---------------------------------------------------------------------------

local function basename(path: string): string
	return string.match(path, "[^/]+$") or path
end

-- Builds a multipart/form-data body as a byte string. Lune strings are byte
-- strings, so the WAV bytes are concatenated verbatim; the boundary is derived
-- from the artifact's own sha256, which makes it both unique per content and
-- deterministic, so the same cue always produces the same request bytes.
function M.multipartBody(boundary: string, requestJson: string, filename: string, bytes: string): string
	return table.concat({
		"--" .. boundary .. "\r\n",
		'Content-Disposition: form-data; name="request"\r\n',
		"Content-Type: application/json\r\n\r\n",
		requestJson .. "\r\n",
		"--" .. boundary .. "\r\n",
		'Content-Disposition: form-data; name="fileContent"; filename="' .. filename .. '"\r\n',
		"Content-Type: audio/wav\r\n\r\n",
		bytes .. "\r\n",
		"--" .. boundary .. "--\r\n",
	})
end

-- The cache is a small JSON document under build/ keyed by the artifact's bare
-- sha256 hex, so one published WAV serves every pack and sweep that carries the
-- same bytes. `creatorGroup` is stored so an id owned by a different creator is
-- never reused for this group.
local function loadCache(path: string): { [string]: any }
	if not fs.isFile(path) then
		return {}
	end
	local ok, decoded = pcall(function()
		return serde.decode("json", fs.readFile(path))
	end)
	if not ok or typeof(decoded) ~= "table" or typeof(decoded.entries) ~= "table" then
		return {}
	end
	return decoded.entries
end

local function saveCache(path: string, entries: { [string]: any })
	local dir = string.match(path, "^(.*)/[^/]+$")
	if dir ~= nil and not fs.isDir(dir) then
		ensureDir(dir)
	end
	fs.writeFile(path, serde.encode("json", { schemaVersion = 1, entries = entries }, true) .. "\n")
end

-- Reads and hashes every uploadable cue's artifact, relative to the pack root.
-- A cue whose file is absent or unreadable is left without a digest so
-- audioassets.plan reports it rather than uploading nothing silently.
local function cueDigests(manifest: assetsLib.Manifest, packDir: string): { [string]: string }
	local digests: { [string]: string } = {}
	for _, asset in manifest.assets do
		if audioassets.UPLOAD_KINDS[asset.kind] and asset.path ~= nil and asset.path ~= "" then
			local full = packDir .. "/" .. asset.path
			if fs.isFile(full) then
				local ok, bytes = pcall(fs.readFile, full)
				if ok then
					digests[asset.key] = assetsLib.digestOf(serde.hash("sha256", bytes))
				end
			end
		end
	end
	return digests
end

export type PublishOutcome = { assetId: number, moderation: assetsLib.Moderation }

-- One Create Asset request + operation poll. Returns the published id and
-- moderation state, or (nil, message) with the exact API text for the caller
-- to print.
local function publishCue(
	apiKey: string,
	group: number,
	cue: audioassets.Cue,
	bytes: string
): (PublishOutcome?, string?)
	local boundary = "----forgeaudio" .. (audioassets.digestHex(cue.sha256) or "")
	local requestJson = serde.encode("json", {
		assetType = "Audio",
		displayName = cue.key,
		description = "Forge procedural cue " .. cue.key,
		creationContext = { creator = { groupId = tostring(group) } },
	})
	local body = M.multipartBody(boundary, requestJson, cue.key .. ".wav", bytes)
	local createHeaders: net.HttpHeaderMap = {
		["x-api-key"] = apiKey,
		["content-type"] = "multipart/form-data; boundary=" .. boundary,
	}
	local createParams: net.FetchParams = {
		url = ASSETS_URL,
		method = "POST",
		headers = createHeaders,
		body = body,
	}
	local sent, response = pcall(net.request, createParams)
	if not sent then
		return nil, "create request failed: " .. tostring(response)
	end
	if not response.ok then
		return nil, string.format("create HTTP %d %s: %s", response.statusCode, response.statusMessage, response.body)
	end
	local operationId, createErr = audioassets.parseCreateResponse(response.body)
	if operationId == nil then
		return nil, createErr
	end
	local pollHeaders: net.HttpHeaderMap = { ["x-api-key"] = apiKey }
	for _ = 1, UPLOAD_POLL_ATTEMPTS do
		local pollParams: net.FetchParams = {
			url = OPERATIONS_URL .. operationId,
			method = "GET",
			headers = pollHeaders,
		}
		local polled, poll = pcall(net.request, pollParams)
		if not polled then
			return nil, "operation poll failed: " .. tostring(poll)
		end
		if not poll.ok then
			return nil, string.format("operation HTTP %d %s: %s", poll.statusCode, poll.statusMessage, poll.body)
		end
		local state, parseErr = audioassets.parseOperationResponse(poll.body)
		if state == nil then
			return nil, parseErr
		end
		if state.done then
			if state.error ~= nil then
				return nil, "operation failed: " .. state.error
			end
			local assetId = state.assetId :: number
			local stateName = state.moderationState
			if stateName == nil then
				return nil, "operation finished without moderationResult.moderationState"
			end
			local mapped = audioassets.moderationOf(stateName)
			if mapped == nil then
				return nil, "unknown moderation state '" .. stateName .. "' from Open Cloud"
			end
			return { assetId = assetId, moderation = mapped :: any }, nil
		end
		task.wait(UPLOAD_POLL_INTERVAL_SECONDS)
	end
	return nil, "operation did not finish after " .. tostring(UPLOAD_POLL_ATTEMPTS) .. " polls"
end

local function runUploadAudio(options: {
	pack: string,
	packDir: string,
	manifestPath: string,
	manifest: assetsLib.Manifest,
	creatorGroup: number,
	cachePath: string,
	dryRun: boolean,
}): boolean
	local manifest = options.manifest
	local digests = cueDigests(manifest, options.packDir)
	local cues, skipped = audioassets.plan(manifest, digests)
	for _, reason in skipped do
		stdio.write("audio skip: " .. reason .. "\n")
	end
	if #cues == 0 then
		stdio.write("audio upload-audio: nothing to publish (" .. options.pack .. ")\n")
		return #skipped == 0
	end

	local apiKey = process.env["ROBLOX_API_KEY"]
	if not options.dryRun and (apiKey == nil or apiKey == "") then
		stdio.ewrite("Error: ROBLOX_API_KEY is not set; assets upload-audio needs Open Cloud access\n")
		return false
	end

	local entries = loadCache(options.cachePath)
	local updates: { [string]: audioassets.UploadUpdate } = {}
	local published, reused, pending, approved = 0, 0, 0, 0
	local failures = 0

	for _, cue in cues do
		local hex = audioassets.digestHex(cue.sha256)
		local cached = if hex ~= nil then entries[hex] else nil
		if
			options.dryRun
			or (
				cached ~= nil
				and type(cached.assetId) == "number"
				and cached.assetId > 0
				and cached.creatorGroup == options.creatorGroup
			)
		then
			local assetId: number = if cached ~= nil then cached.assetId else 0
			local moderation: assetsLib.Moderation = (
				audioassets.moderationOf(cached and cached.moderation) or "PendingModeration"
			) :: any
			if options.dryRun then
				stdio.write(string.format("audio %s: would publish sha256=%s\n", cue.key, cue.sha256))
				continue
			end
			reused += 1
			updates[cue.key] = { assetId = assetId, moderation = moderation }
			if moderation == "Approved" then
				approved += 1
			elseif moderation == "PendingModeration" then
				pending += 1
			end
			stdio.write(string.format("audio %s: reused id=%d moderation=%s\n", cue.key, assetId, moderation))
			continue
		end

		local bytes = fs.readFile(options.packDir .. "/" .. cue.path)
		local outcome, err = publishCue(apiKey :: string, options.creatorGroup, cue, bytes)
		if outcome == nil then
			failures += 1
			stdio.ewrite(string.format("audio %s: FAIL %s\n", cue.key, tostring(err)))
			continue
		end
		local assetId: number = outcome.assetId
		local moderation: assetsLib.Moderation = outcome.moderation
		published += 1
		if moderation == "Approved" then
			approved += 1
		elseif moderation == "PendingModeration" then
			pending += 1
		end
		if hex ~= nil then
			entries[hex] = {
				assetId = assetId,
				moderation = moderation,
				creatorGroup = options.creatorGroup,
				key = cue.key,
				sha256 = cue.sha256,
			}
		end
		updates[cue.key] = { assetId = assetId, moderation = moderation }
		stdio.write(
			string.format(
				"audio %s: published id=%d moderation=%s sha256=%s\n",
				cue.key,
				assetId,
				moderation,
				cue.sha256
			)
		)
	end

	if options.dryRun then
		stdio.write(string.format("audio upload-audio: DRY-RUN (%d cues) for %s\n", #cues, options.pack))
		return failures == 0
	end

	-- Record the ids (and moderation) in the manifest and refresh the pack's own
	-- Assets table, so the cues resolve to their published ids instead of a
	-- rbxasset:// dev path. The manifest is only rewritten when a field changed.
	if not audioassets.isCurrent(manifest, updates) then
		local text = fs.readFile(options.manifestPath)
		fs.writeFile(options.manifestPath, audioassets.applyUploads(text, updates))
		for _, asset in manifest.assets do
			local update = updates[asset.key]
			if update ~= nil then
				asset.assetId = update.assetId
				asset.moderation = update.moderation
			end
		end
		local luauPath = options.packDir .. "/src/shared/Assets.luau"
		if fs.isDir(options.packDir .. "/src/shared") then
			fs.writeFile(luauPath, assetsLib.renderLuau(manifest, basename(options.packDir)))
			stdio.write("audio codegen: wrote " .. luauPath .. "\n")
		end
	end
	saveCache(options.cachePath, entries)

	stdio.write(
		string.format(
			"audio upload-audio: %d published, %d reused from cache (%d approved, %d pending moderation)\n",
			published,
			reused,
			approved,
			pending
		)
	)
	-- Moderation pending is a real, expected state: it is reported on its own
	-- line and never folded into a playable verdict.
	stdio.write(string.format("audio playable: %d of %d cues approved\n", approved, #cues))
	if failures > 0 then
		stdio.ewrite(string.format("assets upload-audio: FAIL (%d cues could not be published)\n", failures))
		return false
	end
	stdio.write(string.format("assets upload-audio: PASS (%s)\n", options.pack))
	return true
end

--- Dispatches one of the assets subcommands. Returns false with a printed
--- reason on any refusal so the CLI can exit 1.
function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	local sub = args[2]
	if sub == nil or not isIn(SUBS, sub) then
		stdio.ewrite("Error: forge assets requires a subcommand (" .. table.concat(SUBS, "|") .. ")\n")
		return false
	end

	local pack = DEFAULT_PACK
	local env = "staging"
	local manifestPath: string? = nil
	local qualityProfilePath: string? = nil
	local packDirArg: string? = nil
	local creatorGroup = DEFAULT_CREATOR_GROUP
	local cachePath = DEFAULT_CACHE_PATH
	local dryRun = false
	local index = 3
	while index <= #args do
		local flag = args[index]
		if flag == "--dry-run" then
			dryRun = true
			index += 1
		elseif
			flag == "--pack"
			or flag == "--env"
			or flag == "--manifest"
			or flag == "--quality-profile"
			or flag == "--pack-dir"
			or flag == "--creator-group"
			or flag == "--cache"
		then
			local value = args[index + 1]
			if value == nil or value == "" then
				stdio.ewrite("Error: " .. flag .. " requires a value\n")
				return false
			end
			if flag == "--pack" then
				pack = value
			elseif flag == "--env" then
				env = value
			elseif flag == "--quality-profile" then
				qualityProfilePath = value
			elseif flag == "--pack-dir" then
				packDirArg = string.gsub(value, "\\", "/")
			elseif flag == "--cache" then
				cachePath = string.gsub(value, "\\", "/")
			elseif flag == "--creator-group" then
				local parsed = cliutil.parseFiniteInt(value)
				if parsed == nil or parsed <= 0 then
					stdio.ewrite("Error: --creator-group requires a positive integer\n")
					return false
				end
				creatorGroup = parsed
			else
				manifestPath = value
			end
			index += 2
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge assets\n")
			return false
		end
	end

	if sub == "upload-audio" then
		local packDir = packDirArg
			or ((if context and context.packsDir then context.packsDir else "games") .. "/" .. pack)
		local slug = if packDirArg ~= nil then basename(packDir) else pack
		local uploadManifestPath = manifestPath or (packDir .. "/assets/manifest.yml")
		if qualityProfilePath ~= nil then
			stdio.ewrite("Error: --quality-profile is only valid for forge assets check\n")
			return false
		end
		if not fs.isDir(packDir) then
			stdio.ewrite("Error: unknown pack directory '" .. packDir .. "'\n")
			return false
		end
		local uploadManifest, uploadErr = loadManifest(uploadManifestPath)
		if uploadManifest == nil then
			stdio.ewrite((uploadErr or "Error: invalid manifest") .. "\n")
			return false
		end
		return runUploadAudio({
			pack = slug,
			packDir = packDir,
			manifestPath = uploadManifestPath,
			manifest = uploadManifest :: assetsLib.Manifest,
			creatorGroup = creatorGroup,
			cachePath = cachePath,
			dryRun = dryRun,
		})
	end

	if not isIn(ENVS, env) then
		stdio.ewrite("Error: --env must be " .. table.concat(ENVS, "|") .. "\n")
		return false
	end
	if qualityProfilePath ~= nil and sub ~= "check" then
		stdio.ewrite("Error: --quality-profile is only valid for forge assets check\n")
		return false
	end

	local path = manifestPath
		or (
			(if context and context.packsDir then context.packsDir else "games")
			.. "/"
			.. pack
			.. "/assets/manifest.yml"
		)
	local manifest, err = loadManifest(path)
	if manifest == nil then
		stdio.ewrite((err or "Error: invalid manifest") .. "\n")
		return false
	end
	local typed = manifest :: assetsLib.Manifest

	if sub == "check" then
		return runCheck(typed, env, path, qualityProfilePath)
	elseif sub == "codegen" then
		return runCodegen(pack, typed, context)
	end
	return runStatus(pack, path, typed)
end

return M
