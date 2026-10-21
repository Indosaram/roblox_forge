--!strict
-- audioassets: pure planning, response parsing and manifest write-back for
-- publishing a pack's synthesised WAV cues to the Open Cloud Assets API.
-- Nothing here performs a network call or reads a file, so the plan, the
-- operation parsing and the manifest edit are all testable without a key.
--
-- Only audio cues are ever published by this module: a mesh, model or image in
-- the same manifest is never uploaded here, whatever it declares. A cue is
-- uploadable only when it is an audio kind, carries a local `path`, and its
-- artifact digest is known - an asset with no bytes on disk cannot be published
-- and is reported rather than silently skipped.

local assetsLib = require("./assets")
local cliutil = require("./cliutil")
local serde = require("@lune/serde")

local M = {}

-- The kinds this command publishes. `image`/`mesh`/`model` are deliberately
-- absent: a launch icon or a mesh is not a sound cue.
local UPLOAD_KINDS: { [string]: boolean } = { sfx = true, bgm = true }
M.UPLOAD_KINDS = UPLOAD_KINDS

-- The Open Cloud Assets API names its in-review state "Reviewing"; the manifest
-- contract (lib/assets.luau) calls the same state "PendingModeration", so the
-- mapping is explicit rather than a passthrough. An unknown state is never
-- mapped: the caller refuses rather than recording a state it does not know.
local API_MODERATION_STATE: { [string]: assetsLib.Moderation } = {
	Approved = "Approved",
	Rejected = "Rejected",
	Reviewing = "PendingModeration",
}

--- The manifest moderation state for an Open Cloud `moderationState`, or nil
--- for a state this contract does not know (the caller refuses rather than
--- recording a state it cannot name).
function M.moderationOf(state: any): assetsLib.Moderation?
	if type(state) ~= "string" then
		return nil
	end
	return API_MODERATION_STATE[state]
end

export type Cue = {
	key: string,
	kind: assetsLib.Kind,
	path: string,
	sha256: string,
}

export type UploadUpdate = {
	assetId: number,
	moderation: assetsLib.Moderation,
	decalAssetId: number?,
}

--- The uploadable cues of a manifest, in manifest order: audio kinds whose
--- local artifact digest is known. `skipped` names every audio cue that could
--- not be planned and why, so an absent WAV is reported rather than dropped.
function M.plan(manifest: assetsLib.Manifest, digests: { [string]: string }): ({ Cue }, { string })
	local cues: { Cue } = {}
	local skipped: { string } = {}
	for _, asset in manifest.assets do
		if UPLOAD_KINDS[asset.kind] then
			local path = asset.path
			local digest = digests[asset.key]
			if path == nil or path == "" then
				table.insert(skipped, asset.key .. ": no local path")
			elseif digest == nil then
				table.insert(skipped, asset.key .. ": no artifact digest (missing or unreadable " .. path .. ")")
			else
				table.insert(cues, { key = asset.key, kind = asset.kind, path = path, sha256 = digest })
			end
		end
	end
	return cues, skipped
end

--- The bare sha256 hex of a `sha256:<hex>` digest, which is the cache key: the
--- same bytes published for any pack reuse one asset id.
function M.digestHex(digest: string): string?
	return string.match(digest, "^sha256:([0-9a-f]+)$")
end

--- The operation id of a Create Asset response, taken from the returned
--- `operationId` or the trailing segment of the returned `path`
--- (`operations/<id>`). Returns (nil, reason) when neither is present.
function M.parseCreateResponse(body: string): (string?, string?)
	local ok, decoded = pcall(function()
		return serde.decode("json", body)
	end)
	if not ok or type(decoded) ~= "table" then
		return nil, "create response is not a JSON object"
	end
	local operationId = decoded.operationId
	if type(operationId) == "string" and operationId ~= "" then
		return operationId, nil
	end
	local path = decoded.path
	if type(path) == "string" then
		local tail = string.match(path, "operations/(.+)$")
		if tail ~= nil and tail ~= "" then
			return tail, nil
		end
	end
	return nil, "create response carried no operationId or operations/<id> path"
end

export type OperationState = {
	done: boolean,
	assetId: number?,
	moderationState: string?,
	error: string?,
}

--- Parses an operation poll reply. `done` is true only for an explicit
--- `done: true`; an in-flight operation returns done=false with no assetId. A
--- done operation must carry a positive integer assetId (the API returns it as
--- a JSON string), otherwise the reply is refused rather than read as a
--- success.
function M.parseOperationResponse(body: string): (OperationState?, string?)
	local ok, decoded = pcall(function()
		return serde.decode("json", body)
	end)
	if not ok or type(decoded) ~= "table" then
		return nil, "operation response is not a JSON object"
	end
	if decoded.done ~= true then
		return { done = false }, nil
	end
	local errorMessage: string? = nil
	if type(decoded.error) == "table" and decoded.error.message ~= nil then
		errorMessage = tostring(decoded.error.message)
	end
	local response = decoded.response
	local assetId: number? = nil
	if type(response) == "table" then
		local raw = response.assetId
		if type(raw) == "string" then
			local parsed = tonumber(raw)
			if parsed ~= nil and parsed % 1 == 0 and parsed > 0 then
				assetId = parsed
			end
		elseif type(raw) == "number" and raw % 1 == 0 and raw > 0 then
			assetId = raw
		end
	end
	-- A finished Create Asset operation nests the created asset under
	-- `response`, so its moderationResult lives there; an earlier reply carried
	-- the same field at the top level. Both are read so the state is never lost
	-- for reply shape alone.
	local moderationState: string? = nil
	for _, node in { response, decoded } do
		if moderationState == nil and type(node) == "table" then
			local moderation = node.moderationResult
			if type(moderation) == "table" and type(moderation.moderationState) == "string" then
				moderationState = moderation.moderationState
			end
		end
	end
	if assetId == nil then
		return nil, errorMessage or "operation finished without a positive assetId"
	end
	return { done = true, assetId = assetId, moderationState = moderationState, error = errorMessage }, nil
end

-- Rewrites the `assetId:`/`moderation:` lines of every `- key: <k>` block named
-- in `updates`, in place: comments and field order survive, and a fresh
-- `assetId`/`moderation` line is appended to a block that lacks one.
local function setBlockFields(lines: { string }, text: string, updates: { [string]: UploadUpdate }): string
	local hadTrailingNewline = string.sub(text, -1) == "\n"
	local sequence = cliutil.assetSequence(lines)
	if sequence == nil then
		return text
	end
	local result: { string } = {}
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
			local update = updates[cliutil.unquoteYamlKey(keyValue)]
			local lastIndex = cliutil.findBlockEnd(lines, i)
			local fieldIndent = itemIndent .. "  "
			local sawAssetId = false
			local sawModeration = false
			local sawDecal = false
			for j = i, lastIndex do
				if update ~= nil and string.match(lines[j], "^" .. fieldIndent .. "assetId:") ~= nil then
					table.insert(result, fieldIndent .. "assetId: " .. tostring(update.assetId))
					sawAssetId = true
				elseif update ~= nil and string.match(lines[j], "^" .. fieldIndent .. "moderation:") ~= nil then
					table.insert(result, fieldIndent .. "moderation: " .. update.moderation)
					sawModeration = true
				elseif
					update ~= nil
					and update.decalAssetId ~= nil
					and string.match(lines[j], "^" .. fieldIndent .. "decalAssetId:") ~= nil
				then
					table.insert(result, fieldIndent .. "decalAssetId: " .. tostring(update.decalAssetId))
					sawDecal = true
				else
					table.insert(result, lines[j])
				end
			end
			if update ~= nil and not sawAssetId then
				table.insert(result, fieldIndent .. "assetId: " .. tostring(update.assetId))
			end
			if update ~= nil and update.decalAssetId ~= nil and not sawDecal then
				table.insert(result, fieldIndent .. "decalAssetId: " .. tostring(update.decalAssetId))
			end
			if update ~= nil and not sawModeration then
				table.insert(result, fieldIndent .. "moderation: " .. update.moderation)
			end
			i = lastIndex + 1
		else
			table.insert(result, line)
			i += 1
		end
	end
	return table.concat(result, "\n") .. (if hadTrailingNewline then "\n" else "")
end

--- Rewrites the `assetId:`/`moderation:` fields of every asset named in
--- `updates`. Two manifest styles are supported:
---   * the hand-written block style (`- key: <k>` items) is edited in place, so
---     comments and field order survive - a fresh `assetId`/`moderation` line is
---     inserted when the block lacks one;
---   * any other style (the serde-encoded scratch manifests `forge sweep`
---     writes) is decoded and re-encoded, which round-trips byte-identically
---     apart from the fields this call changes.
function M.applyUploads(text: string, updates: { [string]: UploadUpdate }): string
	if next(updates) == nil then
		return text
	end
	local lines = cliutil.splitLines(text)
	if cliutil.assetSequence(lines) ~= nil then
		return setBlockFields(lines, text, updates)
	end
	local ok, decoded = pcall(function()
		return serde.decode("yaml", text)
	end)
	if not ok or type(decoded) ~= "table" or type(decoded.assets) ~= "table" then
		return text
	end
	for _, asset in decoded.assets do
		if type(asset) == "table" and type(asset.key) == "string" then
			local update = updates[asset.key]
			if update ~= nil then
				asset.assetId = update.assetId
				asset.moderation = update.moderation
				if update.decalAssetId ~= nil then
					asset.decalAssetId = update.decalAssetId
				end
			end
		end
	end
	return serde.encode("yaml", decoded)
end

--- True when the manifest already records this exact id and moderation for the
--- key, so a re-run writes nothing.
function M.isCurrent(manifest: assetsLib.Manifest, updates: { [string]: UploadUpdate }): boolean
	local byKey: { [string]: assetsLib.Asset } = {}
	for _, asset in manifest.assets do
		byKey[asset.key] = asset
	end
	for key, update in updates do
		local asset = byKey[key]
		if asset == nil or asset.assetId ~= update.assetId or asset.moderation ~= update.moderation then
			return false
		end
	end
	return true
end

return M
