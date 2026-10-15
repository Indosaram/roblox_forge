--!strict
-- Local evaluator attestation is an audit boundary, not a digital signature.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local qualityprofile = require("./qualityprofile")
local qualityregistration = require("./qualityregistration")
local buildidentity = require("./buildidentity")
local Validation = require("../../../core/domain/genre/Validation")
local qastudio = require("./qastudio")
local M = {}
M.SCHEMA_VERSION = 2

export type Evidence = {
	captures: { string },
	actions: { string },
	audio: { string },
	scenarios: { string },
	audiovisual: { string }?,
	avArtifacts: { string }?,
	reference: { string }?,
	referenceArtifacts: { string }?,
	rejoin: { string }?,
	rejoinArtifacts: { string }?,
}
export type Inputs = {
	root: string,
	packDir: string,
	buildPath: string,
	receiptPath: string,
	evidenceDir: string,
	evidence: Evidence,
}
export type Authority = { identity: string, attestationPath: string }
export type Snapshot = { [string]: string }
export type Result = { ok: boolean, code: string, errors: { string } }

-- Sorted keys and JSON scalars reuse serde while removing hash-table order.
local function canonical(value: any): string
	if type(value) ~= "table" then
		return serde.encode("json", value)
	end
	local keys = {}
	for key in value do
		assert(type(key) == "string" or type(key) == "number", "unsupported digest key")
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return type(a) .. tostring(a) < type(b) .. tostring(b)
	end)
	local parts = {}
	for _, key in keys do
		table.insert(parts, canonical(key) .. ":" .. canonical(value[key]))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

function M.digest(value: any): string
	return "sha256:" .. serde.hash("sha256", canonical(value))
end

local function relative(path: string): boolean
	return path ~= ""
		and not string.find(path, "\\", 1, true)
		and not string.match(path, "^/")
		and not string.find(path, ":", 1, true)
		and not string.match("/" .. path .. "/", "/%.%.?/")
end

local function inside(path: string, dir: string): boolean
	return path == dir or string.sub(path, 1, #dir + 1) == dir .. "/"
end

-- Windows device names (nul, con, prn, aux, com1-9, lpt1-9) are reserved with or without an extension.
function M.reservedDeviceName(name: string): boolean
	local stem = string.lower(string.match(name, "^([^.]*)") or name)
	stem = string.gsub(stem, "[ ]+$", "")
	return stem == "nul"
		or stem == "con"
		or stem == "prn"
		or stem == "aux"
		or string.match(stem, "^com[1-9]$") ~= nil
		or string.match(stem, "^lpt[1-9]$") ~= nil
end

local function snapshot(profile: qualityprofile.Profile, input: Inputs): Snapshot
	for _, path in { input.packDir, input.buildPath, input.receiptPath, input.evidenceDir } do
		assert(relative(path), "INVALID_PATH: " .. path)
	end
	assert(not inside(input.packDir, input.evidenceDir), "INVALID_PATH: evidence hides pack")
	assert(input.receiptPath ~= input.evidenceDir, "INVALID_PATH: receipt is evidence directory")
	assert(input.receiptPath ~= input.buildPath, "INVALID_PATH: receipt is build")
	assert(not inside(input.buildPath, input.evidenceDir), "INVALID_PATH: build overlaps evidence")
	for _, dir in { "core", "genres", "cli", "skills", input.packDir } do
		assert(not inside(input.evidenceDir, dir), "INVALID_PATH: evidence must be outside shipped directories")
		assert(not inside(dir, input.evidenceDir), "INVALID_PATH: evidence hides shipped directory")
		assert(not inside(input.receiptPath, dir), "INVALID_PATH: receipt must be outside shipped directories")
	end
	local function excluded(path: string): boolean
		return path == input.receiptPath or inside(path, input.evidenceDir)
	end
	local function bytes(path: string, allowEmpty: boolean?): string
		assert(relative(path), "INVALID_PATH: " .. path)
		assert(fs.isFile(input.root .. "/" .. path), "MISSING_FILE: " .. path)
		local value = fs.readFile(input.root .. "/" .. path)
		assert(allowEmpty or #value > 0, "EMPTY_FILE: " .. path)
		return "sha256:" .. serde.hash("sha256", value)
	end
	local source: { [string]: string } = {}
	local assets: { [string]: string } = {}
	local config: { [string]: string } = {}
	local function add(path: string)
		if excluded(path) then
			return
		end
		local hash = bytes(path, true)
		source[path] = hash
		if inside(path, input.packDir .. "/assets") then
			assets[path] = hash
		end
		if
			string.match(path, "%.ya?ml$")
			or string.match(path, "%.json$")
			or string.match(path, "%.toml$")
			or string.match(path, "%.lock$")
		then
			config[path] = hash
		end
	end
	local function walk(path: string)
		if excluded(path) then
			return
		end
		assert(fs.isDir(input.root .. "/" .. path), "MISSING_DIRECTORY: " .. path)
		for _, name in fs.readDir(input.root .. "/" .. path) do
			local child = path .. "/" .. name
			if fs.isDir(input.root .. "/" .. child) then
				walk(child)
			else
				add(child)
			end
		end
	end
	-- Filesystem traversal includes ignored/untracked shipped content and dirty bytes.
	for _, dir in { "core", "genres", "cli", "skills", input.packDir } do
		walk(dir)
	end
	for _, name in fs.readDir(input.root) do
		-- Reserved Windows device names make fs.isFile throw; one bad entry must not abort the scan.
		if M.reservedDeviceName(name) then
			continue
		end
		local statOk, isFile = pcall(fs.isFile, input.root .. "/" .. name)
		if statOk and isFile and name ~= ".git" then
			add(name)
		end
	end
	assert(next(assets) ~= nil, "MISSING_ASSET: pack assets")
	for _, name in { "game.yml", "default.project.json", "quality.yml", "forge-lock.yml", "assets/manifest.yml" } do
		assert(source[input.packDir .. "/" .. name] ~= nil, "MISSING_CONFIG: " .. name)
	end
	local manifest = serde.decode("yaml", fs.readFile(input.root .. "/" .. input.packDir .. "/assets/manifest.yml"))
	assert(type(manifest) == "table" and type(manifest.assets) == "table", "INVALID_ASSET_MANIFEST")
	for _, asset in manifest.assets do
		if type(asset) == "table" and asset.path ~= nil then
			assert(type(asset.path) == "string" and relative(asset.path), "INVALID_ASSET_PATH")
			local path = input.packDir .. "/" .. asset.path
			assert(not excluded(path), "INVALID_ASSET_PATH: excluded artifact")
			assets[path] = bytes(path)
			source[path] = assets[path]
		end
	end
	local references: { [string]: string } = {}
	for _, exemplar in profile.reference.exemplars do
		references[exemplar.path] = bytes(exemplar.path)
	end
	local evidence: { [string]: { [string]: string } } = {}
	for _, role in
		{
			"captures",
			"actions",
			"audio",
			"scenarios",
			"audiovisual",
			"avArtifacts",
			"reference",
			"referenceArtifacts",
			"rejoin",
			"rejoinArtifacts",
		}
	do
		local paths = (input.evidence :: any)[role]
		if
			paths == nil
			and table.find(
				{ "audiovisual", "avArtifacts", "reference", "referenceArtifacts", "rejoin", "rejoinArtifacts" },
				role
			)
		then
			continue -- Legacy inputs remain readable, but cannot pass AV admission.
		end
		assert(type(paths) == "table" and #paths > 0, "MISSING_EVIDENCE: " .. role)
		local entries: { [string]: string } = {}
		for _, path in paths do
			assert(type(path) == "string" and inside(path, input.evidenceDir), "INVALID_EVIDENCE: " .. role)
			assert(path ~= input.receiptPath, "INVALID_EVIDENCE: receipt is not evidence")
			entries[path] = bytes(path)
		end
		evidence[role] = entries
	end
	assert(not excluded(input.buildPath), "INVALID_PATH: excluded build")
	local git = process.exec("git", { "-C", input.root, "rev-parse", "HEAD^{tree}" })
	assert(git.ok, "MISSING_GIT_TREE: " .. git.stderr)
	return {
		tree = string.gsub(git.stdout, "%s+$", ""),
		source = M.digest(source),
		asset = M.digest(assets),
		config = M.digest(config),
		rubric = M.digest({ profile = profile, references = references }),
		evidence = M.digest(evidence),
		build = bytes(input.buildPath),
	}
end

function M.snapshot(profile: qualityprofile.Profile, input: Inputs): (Snapshot?, string?)
	local ok, value = pcall(snapshot, profile, input)
	if not ok then
		return nil, tostring(value)
	end
	return value, nil
end

local function fail(code: string, detail: string?): Result
	return { ok = false, code = code, errors = { detail or code } }
end

local function text(value: any): boolean
	return type(value) == "string" and string.find(value, "%S") ~= nil
end

-- Rejoin is separate from first-play and cannot replace same-session scenarios.
function M.validateRejoin(input: Inputs, receipt: any): (boolean, string?)
	local ok, reason = pcall(function()
		local paths, artifacts = input.evidence.rejoin, input.evidence.rejoinArtifacts
		assert(
			paths ~= nil
				and artifacts ~= nil
				and Validation.dense(paths, 128)
				and #paths > 0
				and Validation.dense(artifacts, 4096),
			"REJOIN_EVIDENCE_REQUIRED"
		)
		local function proof(entry: any): any
			assert(
				type(entry) == "table"
					and type(entry.path) == "string"
					and relative(entry.path)
					and inside(entry.path, input.evidenceDir)
					and table.find(artifacts, entry.path),
				"REJOIN_UNBOUND_PROOF"
			)
			local bytes = fs.readFile(input.root .. "/" .. entry.path)
			assert(entry.sha256 == serde.hash("sha256", bytes), "REJOIN_STALE_PROOF")
			return serde.decode("json", bytes)
		end
		for _, path in paths do
			assert(
				relative(path) and inside(path, input.evidenceDir) and not table.find(input.evidence.scenarios, path),
				"REJOIN_FIRSTPLAY_SEPARATION"
			)
			local document = serde.decode("json", fs.readFile(input.root .. "/" .. path))
			assert(
				document.schemaVersion == 1
					and document.kind == "physical-rejoin"
					and document.buildIdentity == receipt.buildIdentity.id,
				"REJOIN_SCHEMA"
			)
			assert(receipt.review.rejoinDigests[path] == M.digest(document), "REJOIN_REVIEW_BINDING")
			local capability = proof(document.capability)
			assert(
				capability.verified == true
					and capability.physicalClose == true
					and capability.physicalReconnect == true
					and capability.durableBackend == true
					and text(capability.backendIdentity)
					and text(capability.api),
				"REJOIN_CAPABILITY_REQUIRED"
			)
			assert(
				text(capability.hostOwnership) and text(capability.mode) and text(capability.namespace),
				"REJOIN_BACKEND_CONTEXT_REQUIRED"
			)
			assert(capability.token == nil and capability.port == nil, "REJOIN_PRIVATE_CONTEXT_FORBIDDEN")
			assert(
				Validation.dense(document.epochs, 128)
					and #document.epochs >= 2
					and Validation.dense(document.transitions, 16384)
					and #document.transitions > 0,
				"REJOIN_EPOCHS_REQUIRED"
			)
			local epochs, elapsed = {}, -math.huge
			for index, epoch in document.epochs do
				assert(
					epoch.epoch == index
						and Validation.finite(epoch.startedSeconds)
						and Validation.finite(epoch.endedSeconds)
						and epoch.startedSeconds >= elapsed
						and epoch.endedSeconds >= epoch.startedSeconds,
					"REJOIN_EPOCH_TIME"
				)
				assert(
					buildidentity.validateLoaded(receipt.buildIdentity, epoch.runtime.server, epoch.runtime.clients),
					"REJOIN_LOADED_IDENTITY"
				)
				local backend = proof(epoch.backendEvidence)
				assert(
					backend.observed == true
						and backend.backendIdentity == capability.backendIdentity
						and backend.hostOwnership == capability.hostOwnership
						and backend.mode == capability.mode
						and backend.namespace == capability.namespace
						and backend.sessionId == epoch.runtime.server.sessionId
						and text(backend.sessionOwnership)
						and backend.configConsumed == true,
					"REJOIN_RUNTIME_BACKEND_MISMATCH"
				)
				assert(backend.token == nil and backend.port == nil, "REJOIN_PRIVATE_CONTEXT_FORBIDDEN")
				local ready, resource = proof(backend.hostReady), proof(backend.resourceOwnership)
				local snapshotProof, handshake = proof(backend.snapshot), proof(backend.loadedHandshake)
				local install, consumed = proof(backend.installation), proof(backend.consumedObservation)
				assert(
					ready.ready == true
						and ready.hostOwnership == backend.hostOwnership
						and ready.databaseIdentity == resource.databaseIdentity
						and text(ready.databaseIdentity)
						and ready.backendIdentity == backend.backendIdentity,
					"REJOIN_HOST_READY_BINDING"
				)
				assert(
					resource.owned == true
						and resource.exclusiveDatabase == true
						and resource.hostOwnership == backend.hostOwnership
						and resource.sessionOwnership == backend.sessionOwnership
						and text(resource.processIdentity),
					"REJOIN_RESOURCE_BINDING"
				)
				assert(M.digest(handshake) == M.digest(epoch.runtime), "REJOIN_HANDSHAKE_PROOF")
				assert(
					snapshotProof.identity.mode == backend.mode
						and snapshotProof.identity.namespace == backend.namespace
						and text(snapshotProof.identity.storeName)
						and text(snapshotProof.identity.epoch)
						and type(snapshotProof.identity.serverSessionId) == "string",
					"REJOIN_SNAPSHOT_CONTEXT"
				)
				assert(
					backend.backendEpoch == snapshotProof.identity.epoch
						and backend.backendServerSessionId == snapshotProof.identity.serverSessionId,
					"REJOIN_BACKEND_EPOCH_BINDING"
				)
				assert(
					install.succeeded == true
						and install.beforePlay == true
						and install.mode == backend.mode
						and install.namespace == backend.namespace
						and install.sessionOwnership == backend.sessionOwnership
						and install.hostOwnership == backend.hostOwnership
						and text(install.invocation),
					"REJOIN_INSTALLATION_PROOF"
				)
				assert(
					consumed.folderAbsent == true
						and consumed.snapshotObserved == true
						and consumed.sessionOwnership == backend.sessionOwnership
						and consumed.sessionId == backend.sessionId
						and consumed.buildIdentity == receipt.buildIdentity.id
						and consumed.snapshotSha256 == backend.snapshot.sha256
						and text(consumed.invocation),
					"REJOIN_CONSUMPTION_PROOF"
				)
				for _, raw in { ready, resource, snapshotProof.identity, install, consumed } do
					assert(raw.token == nil and raw.port == nil, "REJOIN_PRIVATE_CONTEXT_FORBIDDEN")
				end
				assert(
					Validation.dense(epoch.actorMappings, 128) and #epoch.actorMappings == #epoch.runtime.clients,
					"REJOIN_ACTOR_MAPPING"
				)
				local mappedActors = {}
				for clientIndex, client in epoch.runtime.clients do
					local mapped = epoch.actorMappings[clientIndex]
					assert(
						mapped.actor == client.actorId
							and not mappedActors[mapped.actor]
							and mapped.studio_id == client.studio_id
							and text(mapped.clientSessionId)
							and text(mapped.processIdentity),
						"REJOIN_ACTOR_MAPPING"
					)
					mappedActors[mapped.actor] = true
				end
				epochs[index], elapsed = epoch, epoch.endedSeconds
			end
			local edges = {}
			for _, transition in document.transitions do
				local index = transition.fromEpoch
				assert(
					Validation.finite(index)
						and index % 1 == 0
						and index >= 1
						and index < #document.epochs
						and transition.toEpoch == index + 1
						and transition.backendIdentity == capability.backendIdentity
						and text(transition.profileKey),
					"REJOIN_TRANSITION"
				)
				edges[index] = edges[index] or {}
				assert(
					text(transition.actor) and not edges[index][transition.actor],
					"REJOIN_DUPLICATE_ACTOR_TRANSITION"
				)
				edges[index][transition.actor] = true
				local before, after
				for _, mapped in epochs[index].actorMappings do
					if mapped.actor == transition.actor then
						before = mapped
					end
				end
				for _, mapped in epochs[index + 1].actorMappings do
					if mapped.actor == transition.actor then
						after = mapped
					end
				end
				assert(
					before
						and after
						and before.clientSessionId == transition.oldClientSessionId
						and after.clientSessionId == transition.newClientSessionId
						and before.clientSessionId ~= after.clientSessionId
						and before.processIdentity ~= after.processIdentity
						and before.studio_id ~= after.studio_id,
					"REJOIN_REPLACEMENT_REQUIRED"
				)
				local closed, loaded = proof(transition.closeEvidence), proof(transition.loadEvidence)
				assert(
					closed.exited == true
						and closed.processIdentity == before.processIdentity
						and closed.clientSessionId == before.clientSessionId
						and Validation.finite(closed.elapsedSeconds)
						and closed.elapsedSeconds >= epochs[index].endedSeconds
						and closed.elapsedSeconds <= epochs[index + 1].startedSeconds,
					"REJOIN_CLOSE_REQUIRED"
				)
				assert(
					loaded.physicalReconnect == true
						and loaded.shortcut == false
						and loaded.restore == false
						and loaded.actor == transition.actor
						and loaded.profileKey == transition.profileKey
						and loaded.backendIdentity == transition.backendIdentity
						and loaded.clientSessionId == after.clientSessionId
						and loaded.processIdentity == after.processIdentity,
					"REJOIN_LOAD_REQUIRED"
				)
				assert(
					Validation.finite(loaded.elapsedSeconds)
						and loaded.elapsedSeconds >= epochs[index + 1].startedSeconds
						and loaded.elapsedSeconds <= epochs[index + 1].endedSeconds
						and loaded.elapsedSeconds >= closed.elapsedSeconds,
					"REJOIN_LOAD_TIME"
				)
				local oldBackend, newBackend =
					proof(epochs[index].backendEvidence), proof(epochs[index + 1].backendEvidence)
				assert(
					loaded.hostOwnership == newBackend.hostOwnership
						and loaded.sessionOwnership == newBackend.sessionOwnership
						and loaded.mode == newBackend.mode
						and loaded.namespace == newBackend.namespace
						and loaded.observedPersistedWrapper == true,
					"REJOIN_LOADED_BACKEND_CONTEXT"
				)
				assert(loaded.token == nil and loaded.port == nil, "REJOIN_PRIVATE_CONTEXT_FORBIDDEN")
				assert(
					Validation.finite(transition.committedRevision)
						and transition.committedRevision % 1 == 0
						and transition.committedRevision >= 0
						and Validation.finite(transition.loadedRevision)
						and transition.loadedRevision % 1 == 0
						and transition.loadedRevision >= transition.committedRevision
						and loaded.revision == transition.loadedRevision,
					"REJOIN_REVISION"
				)
				local commit = proof(transition.commitEvidence)
				assert(
					commit.durable == true
						and commit.actor == transition.actor
						and commit.profileKey == transition.profileKey
						and commit.backendIdentity == transition.backendIdentity
						and commit.revision == transition.committedRevision
						and Validation.finite(commit.elapsedSeconds)
						and commit.elapsedSeconds >= epochs[index].startedSeconds
						and commit.elapsedSeconds <= epochs[index].endedSeconds
						and commit.elapsedSeconds <= closed.elapsedSeconds,
					"REJOIN_DURABLE_COMMIT"
				)
				assert(
					commit.hostOwnership == oldBackend.hostOwnership
						and commit.sessionOwnership == oldBackend.sessionOwnership
						and commit.mode == oldBackend.mode
						and commit.namespace == oldBackend.namespace
						and commit.observedPersistedWrapper == true
						and commit.updateAsyncReturned == true,
					"REJOIN_COMMIT_OBSERVATION_REQUIRED"
				)
				if commit.barrier ~= nil then
					local barrier = commit.barrier
					assert(
						Validation.finite(barrier.expiresAtMs)
							and Validation.finite(barrier.observedAtMs)
							and barrier.observedAtMs < barrier.expiresAtMs
							and barrier.ackState ~= "expired",
						"REJOIN_BARRIER_EXPIRED"
					)
					assert(
						(barrier.held == true and barrier.ackState == "held")
							or (barrier.held == false and barrier.ackState == "released"),
						"REJOIN_BARRIER_STATE"
					)
				end
				assert(commit.token == nil and commit.port == nil, "REJOIN_PRIVATE_CONTEXT_FORBIDDEN")
				local commitRaw, loadRaw = proof(commit.wrapperEvidence), proof(loaded.wrapperEvidence)
				local function wrapperContext(raw: any, backend: any)
					local snapshotProof = proof(backend.snapshot)
					assert(
						raw.key == transition.profileKey
							and M.digest(raw.identity) == M.digest(snapshotProof.identity)
							and raw.hostOwnership == backend.hostOwnership
							and raw.sessionOwnership == backend.sessionOwnership
							and raw.buildIdentity == receipt.buildIdentity.id
							and raw.handshakeSessionId == backend.sessionId,
						"REJOIN_WRAPPER_CONTEXT"
					)
					assert(
						raw.token == nil and raw.port == nil and raw.identity.token == nil and raw.identity.port == nil,
						"REJOIN_PRIVATE_CONTEXT_FORBIDDEN"
					)
				end
				wrapperContext(commitRaw, oldBackend)
				wrapperContext(loadRaw, newBackend)
				assert(
					commitRaw.updateAsyncReturned == true
						and type(commitRaw.serialized) == "string"
						and type(loadRaw.previousSerialized) == "string",
					"REJOIN_RAW_WRAPPER_REQUIRED"
				)
				local committedWrapper = serde.decode("json", commitRaw.serialized)
				local loadedWrapper = serde.decode("json", loadRaw.previousSerialized)
				assert(
					committedWrapper.revision == transition.committedRevision
						and loadedWrapper.revision == transition.loadedRevision
						and M.digest(committedWrapper.data) == M.digest(loadedWrapper.data),
					"REJOIN_PERSISTED_DATA_MISMATCH"
				)
				local data = committedWrapper.data.envelope or committedWrapper.data
				local bag = data.genres["survival-coop"].data.inventory.bag.items
				local quantities = {}
				for item, entry in bag do
					quantities[item] = entry.quantity
				end
				assert(M.digest(quantities) == M.digest(commit.items), "REJOIN_RAW_ITEMS_MISMATCH")
				assert(
					type(commit.items) == "table"
						and M.digest(commit.items) == M.digest(loaded.items)
						and M.digest(transition.retainedItems) == M.digest(commit.items),
					"REJOIN_ITEMS_MISMATCH"
				)
				for item, quantity in commit.items do
					assert(
						text(item) and Validation.finite(quantity) and quantity >= 0 and quantity % 1 == 0,
						"REJOIN_ITEM_QUANTITY"
					)
				end
			end
			for index = 1, #document.epochs - 1 do
				assert(#epochs[index].actorMappings == #epochs[index + 1].actorMappings, "REJOIN_ACTOR_SET_CHANGED")
				for _, actor in epochs[index].actorMappings do
					assert(edges[index] and edges[index][actor.actor], "REJOIN_ACTOR_TRANSITION_REQUIRED")
				end
			end
			local previous = -math.huge
			assert(
				Validation.dense(document.actions, 100000)
					and #document.actions > 0
					and Validation.dense(document.captures, 4096)
					and #document.captures > 0,
				"REJOIN_ACTIONS_REQUIRED"
			)
			for _, action in document.actions do
				local epoch = epochs[action.epoch]
				assert(
					epoch
						and action.sessionId == epoch.runtime.server.sessionId
						and action.shortcut == false
						and not table.find({
							"restore",
							"dispatch",
							"server_command",
							"advance_to",
							"advance_elapsed",
							"command",
							"begin_clock",
							"obstacle",
						}, action.op),
					"REJOIN_ACTION_EPOCH"
				)
				local mapped = false
				for _, actor in epoch.actorMappings do
					if actor.actor == action.actor and actor.studio_id == action.studio_id then
						mapped = true
					end
				end
				assert(mapped, "REJOIN_ACTION_ACTOR")
				assert(
					Validation.finite(action.startedSeconds)
						and Validation.finite(action.elapsedSeconds)
						and action.startedSeconds >= previous
						and action.startedSeconds >= epoch.startedSeconds
						and action.elapsedSeconds <= epoch.endedSeconds
						and action.elapsedSeconds >= action.startedSeconds,
					"REJOIN_ACTION_TIME"
				)
				previous = action.elapsedSeconds
			end
			for _, capture in document.captures do
				local epoch = epochs[capture.epoch]
				assert(
					epoch
						and capture.sessionId == epoch.runtime.server.sessionId
						and capture.buildIdentity == receipt.buildIdentity.id
						and capture.elapsedSeconds >= epoch.startedSeconds
						and capture.elapsedSeconds <= epoch.endedSeconds,
					"REJOIN_CAPTURE_EPOCH"
				)
				local mapped = false
				for _, actor in epoch.actorMappings do
					if actor.actor == capture.actor and actor.studio_id == capture.studio_id then
						mapped = true
					end
				end
				assert(
					mapped
						and table.find(artifacts, capture.path)
						and relative(capture.path)
						and inside(capture.path, input.evidenceDir),
					"REJOIN_CAPTURE_UNBOUND"
				)
				local bytes = fs.readFile(input.root .. "/" .. capture.path)
				assert(
					capture.sha256 == serde.hash("sha256", bytes)
						and qastudio.validateCapture(capture, bytes, capture.device.surface),
					"REJOIN_CAPTURE_INVALID"
				)
			end
		end
	end)
	return ok, if ok then nil else tostring(reason)
end

function M.validateReference(profile: qualityprofile.Profile, input: Inputs, receipt: any): (boolean, string?)
	local ok, reason = pcall(function()
		local paths, artifacts = input.evidence.reference, input.evidence.referenceArtifacts
		assert(
			paths ~= nil
				and artifacts ~= nil
				and Validation.dense(paths, 1)
				and #paths == 1
				and Validation.dense(artifacts, 4096),
			"REFERENCE_EVIDENCE_REQUIRED"
		)
		local function bytes(entry: any): string
			assert(
				type(entry) == "table"
					and type(entry.path) == "string"
					and relative(entry.path)
					and inside(entry.path, input.evidenceDir)
					and table.find(artifacts, entry.path),
				"REFERENCE_UNBOUND_ARTIFACT"
			)
			assert(
				type(entry.sha256) == "string" and #entry.sha256 == 64 and string.match(entry.sha256, "^[a-f0-9]+$"),
				"REFERENCE_HASH_REQUIRED"
			)
			local value = fs.readFile(input.root .. "/" .. entry.path)
			assert(serde.hash("sha256", value) == entry.sha256, "REFERENCE_STALE_ARTIFACT")
			return value
		end
		local function utc(value: any): string
			assert(
				type(value) == "string" and string.match(value, "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"),
				"REFERENCE_UTC_REQUIRED"
			)
			local year, month, day, hour, minute, second =
				string.match(value, "^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)Z$")
			local y, m, d = tonumber(year), tonumber(month), tonumber(day)
			local h, n, s = tonumber(hour), tonumber(minute), tonumber(second)
			assert(
				y and m and d and h and n and s and m >= 1 and m <= 12 and h < 24 and n < 60 and s < 60,
				"REFERENCE_UTC_INVALID"
			)
			local days = {
				31,
				if y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then 29 else 28,
				31,
				30,
				31,
				30,
				31,
				31,
				30,
				31,
				30,
				31,
			}
			assert(d >= 1 and d <= days[m], "REFERENCE_UTC_INVALID")
			return value
		end
		assert(relative(paths[1]) and inside(paths[1], input.evidenceDir), "REFERENCE_PATH")
		local reference = serde.decode("json", fs.readFile(input.root .. "/" .. paths[1]))
		assert(reference.schemaVersion == 1 and reference.kind == "independent-reference", "REFERENCE_SCHEMA")
		assert(receipt.review.referenceDigest == M.digest(reference), "REFERENCE_DIGEST_MISMATCH")
		local source, rights, session = reference.source, reference.rights, reference.session
		assert(
			source.independentOfPack == profile.pack
				and text(source.owner)
				and text(source.name)
				and text(source.url)
				and text(source.revision),
			"REFERENCE_SOURCE_REQUIRED"
		)
		local independence = serde.decode("json", bytes(source.independenceEvidence))
		assert(
			independence.verified == true
				and independence.forgeGenerated == false
				and independence.sourceSha256 == source.sourceSha256
				and independence.independentOfPack == profile.pack
				and text(independence.reviewedBy),
			"REFERENCE_NOT_INDEPENDENT"
		)
		assert(
			independence.archive.sha256 == source.sourceSha256 and #bytes(independence.archive) > 0,
			"REFERENCE_SOURCE_ARCHIVE"
		)
		assert(
			rights.basis == "explicit-owner-permission" or rights.basis == "permissive-sample-license",
			"REFERENCE_RIGHTS_BASIS"
		)
		assert(
			rights.scope.localCapture == true
				and rights.scope.localEvaluation == true
				and type(rights.scope.redistribution) == "boolean"
				and text(rights.holder)
				and text(rights.reviewedBy),
			"REFERENCE_RIGHTS_SCOPE"
		)
		utc(rights.reviewedAt)
		assert(Validation.dense(rights.documents, 4096) and #rights.documents > 0, "REFERENCE_RIGHTS_DOCUMENTS")
		for _, entry in rights.documents do
			assert(text(entry.url) and text(entry.version) and #bytes(entry) > 0, "REFERENCE_RIGHTS_DOCUMENT")
		end
		local inventory = serde.decode("json", bytes(rights.inventory))
		assert(
			inventory.complete == true
				and inventory.sourceSha256 == source.sourceSha256
				and Validation.dense(inventory.components, 100000)
				and #inventory.components > 0,
			"REFERENCE_RIGHTS_INVENTORY"
		)
		for _, component in inventory.components do
			assert(
				text(component.name)
					and text(component.holder)
					and text(component.license)
					and component.localCapture == true
					and component.localEvaluation == true
					and text(component.documentPath),
				"REFERENCE_COMPONENT_RIGHTS"
			)
			local found = false
			for _, entry in rights.documents do
				if entry.path == component.documentPath then
					found = true
				end
			end
			assert(found, "REFERENCE_COMPONENT_DOCUMENT")
		end
		assert(
			reference.rubric.version == "primal-independent-1"
				and reference.rubric.version == profile.reference.rubricVersion,
			"REFERENCE_RUBRIC_VERSION"
		)
		local rubric = serde.decode("json", bytes(reference.rubric))
		local serializedCriteria = serde.decode("json", serde.encode("json", profile.criteria))
		assert(M.digest(rubric.criteria) == M.digest(serializedCriteria), "REFERENCE_RUBRIC_MISMATCH")
		assert(utc(reference.rubric.frozenAt) < utc(receipt.review.assessedAt), "REFERENCE_RUBRIC_NOT_FROZEN")
		assert(
			utc(session.startedAt) < utc(session.endedAt)
				and session.loadedSourceSha256 == source.sourceSha256
				and text(session.id),
			"REFERENCE_LOADED_SOURCE"
		)
		assert(
			reference.rubric.frozenAt <= session.startedAt
				and rights.reviewedAt <= session.startedAt
				and session.endedAt <= receipt.review.assessedAt,
			"REFERENCE_ACQUISITION_ORDER"
		)
		local invocations = serde.decode("json", bytes(session.invocations))
		assert(
			invocations.loadedSourceSha256 == source.sourceSha256
				and invocations.sessionId == session.id
				and invocations.loadVerified == true
				and Validation.dense(invocations.calls, 100000)
				and #invocations.calls > 0,
			"REFERENCE_LOAD_ATTESTATION"
		)
		assert(
			Validation.dense(session.actors, 128)
				and #session.actors >= 2
				and Validation.dense(reference.captures, 4096)
				and Validation.dense(reference.intervals, 4096),
			"REFERENCE_COLLECTIONS"
		)
		local actors, studios = {}, {}
		for _, actor in session.actors do
			assert(
				text(actor.actor)
					and text(actor.studio_id)
					and not actors[actor.actor]
					and not studios[actor.studio_id]
					and (actor.inputMode == "touch" or actor.inputMode == "keyboard-mouse"),
				"REFERENCE_ACTOR"
			)
			actors[actor.actor], studios[actor.studio_id] = actor, true
		end
		local surfaces, originals, views = {}, {}, {}
		for _, row in reference.captures do
			local capture = row.capture
			local value = bytes(capture)
			assert(
				utc(row.capturedAt) >= session.startedAt and row.capturedAt <= session.endedAt,
				"REFERENCE_CAPTURE_TIME"
			)
			assert(
				capture.sessionId == session.id
					and capture.buildIdentity == source.sourceSha256
					and actors[capture.actor]
					and actors[capture.actor].studio_id == capture.studio_id,
				"REFERENCE_CAPTURE_IDENTITY"
			)
			assert(row.surface ~= "mobile" or actors[capture.actor].inputMode == "touch", "REFERENCE_TOUCH_REQUIRED")
			assert(qastudio.validateCapture(capture, value, row.surface), "REFERENCE_CAPTURE_GEOMETRY")
			assert(row.geometryDigest == M.digest({
				device = capture.device,
				logical = capture.logical,
				raster = capture.raster,
				logicalToRaster = capture.logicalToRaster,
				criticalUI = capture.criticalUI,
			}), "REFERENCE_GEOMETRY_DIGEST")
			assert(
				(row.mimeType == "image/png" and string.sub(value, 1, 8) == "\137PNG\r\n\26\n")
					or (row.mimeType == "image/jpeg" and string.sub(value, 1, 2) == "\255\216"),
				"REFERENCE_MIME"
			)
			for _, path in input.evidence.captures do
				assert(
					serde.hash("sha256", fs.readFile(input.root .. "/" .. path)) ~= capture.sha256,
					"REFERENCE_SELF_CAPTURE"
				)
			end
			assert(
				text(row.checkpoint) and table.find({ "forward", "oblique", "elevated-back" }, row.view),
				"REFERENCE_EXEMPLAR_VIEW"
			)
			surfaces[row.surface], originals[capture.path], views[row.surface .. ":" .. row.view] = true, row, true
		end
		assert(surfaces.desktop and surfaces.mobile, "REFERENCE_SURFACES_REQUIRED")
		for _, entry in profile.reference.exemplars do
			assert(
				originals[entry.path] and originals[entry.path].surface == entry.surface,
				"REFERENCE_EXEMPLAR_REQUIRED"
			)
		end
		for _, surface in { "desktop", "mobile" } do
			for _, view in { "forward", "oblique", "elevated-back" } do
				assert(views[surface .. ":" .. view], "REFERENCE_VIEW_REQUIRED")
			end
		end
		local coverage, intervals = {}, {}
		for _, interval in reference.intervals do
			bytes(interval)
			assert(
				interval.sessionId == session.id
					and actors[interval.actor]
					and utc(interval.startedAt) >= session.startedAt
					and utc(interval.endedAt) <= session.endedAt
					and interval.startedAt < interval.endedAt,
				"REFERENCE_INTERVAL_IDENTITY"
			)
			local trace = serde.decode("json", bytes(interval.actionTrace))
			assert(
				trace.sessionId == session.id
					and trace.shortcut == false
					and trace.coached == false
					and trace.startedAt == interval.startedAt
					and trace.endedAt == interval.endedAt,
				"REFERENCE_ACTION_TRACE"
			)
			assert(
				text(interval.mimeType)
					and Validation.dense(interval.coverage, 128)
					and #interval.coverage > 0
					and Validation.dense(trace.coverage, 128),
				"REFERENCE_INTERVAL_COVERAGE"
			)
			for _, action in interval.coverage do
				assert(table.find(trace.coverage, action), "REFERENCE_TRACE_COVERAGE")
				coverage[action] = true
			end
			intervals[interval.path] = interval
		end
		for _, action in
			{ "gather", "craft", "eat", "rest", "build", "combat", "shared-facility", "objective-identified" }
		do
			assert(coverage[action], "REFERENCE_LOOP_INCOMPLETE: " .. action)
		end
		local cleanup =
			serde.decode("json", bytes({ path = reference.cleanup.receiptPath, sha256 = reference.cleanup.sha256 }))
		assert(
			cleanup.ok == true and Validation.dense(cleanup.residuals, 4096) and #cleanup.residuals == 0,
			"REFERENCE_CLEANUP_UNPROVEN"
		)
		assert(Validation.dense(cleanup.resources, 4096) and #cleanup.resources > 0, "REFERENCE_CLEANUP_RESOURCES")
		for _, resource in cleanup.resources do
			assert(resource.cleanup == "released" and type(resource.evidence) == "table", "REFERENCE_CLEANUP_RESOURCE")
		end
		for _, criterion in profile.criteria do
			local compared = {}
			for _, pair in receipt.review.criteria[criterion.id].comparisons do
				assert(
					pair.referenceDigest == M.digest(reference)
						and originals[pair.reference]
						and originals[pair.reference].surface == pair.surface
						and intervals[pair.referenceInterval]
						and text(pair.observedDifference)
						and text(pair.anchorRationale),
					"REFERENCE_COMPARISON_REQUIRED"
				)
				assert(
					utc(pair.referenceAt) >= intervals[pair.referenceInterval].startedAt
						and pair.referenceAt <= intervals[pair.referenceInterval].endedAt
						and table.find(input.evidence.captures, pair.capture)
						and table.find(input.evidence.actions, pair.candidateInterval)
						and Validation.finite(pair.candidateSeconds),
					"REFERENCE_COMPARISON_TIME"
				)
				local action = serde.decode("json", fs.readFile(input.root .. "/" .. pair.candidateInterval))
				local linked = false
				for _, step in action.steps do
					if
						pair.candidateSeconds >= step.startedSeconds
						and pair.candidateSeconds <= step.elapsedSeconds
					then
						linked = true
					end
				end
				assert(linked, "REFERENCE_CANDIDATE_TIME")
				compared[pair.surface] = true
			end
			assert(compared.desktop and compared.mobile, "REFERENCE_COMPARISON_SURFACES")
		end
	end)
	return ok, if ok then nil else tostring(reason)
end

-- Independent evaluator attestation remains the trust boundary for listening.
-- Every underlying byte and acquisition record must also be in the snapshot.
-- Registration evidence binds the rendered nonce proof to this source; a
-- boolean, bare filename or unbound artifact never reaches digest trust.
function M.validateRegistration(
	input: Inputs,
	receipt: any,
	scenario: any,
	source: any,
	artifacts: { string }
): (boolean, string?)
	return qualityregistration.admit({
		root = input.root,
		evidenceDir = input.evidenceDir,
		artifacts = artifacts,
		scenario = scenario,
		source = source,
		buildIdentity = receipt.buildIdentity.id,
		digest = M.digest,
	})
end

function M.validateAudiovisual(input: Inputs, receipt: any): (boolean, string?)
	local ok, reason = pcall(function()
		local manifests, artifacts = input.evidence.audiovisual, input.evidence.avArtifacts
		assert(
			manifests ~= nil
				and artifacts ~= nil
				and Validation.dense(manifests, 128)
				and #manifests > 0
				and Validation.dense(artifacts, 4096),
			"AV_EVIDENCE_REQUIRED"
		)
		local review = receipt.review.audiovisual
		assert(
			type(review) == "table" and review.verdict == "approved" and Validation.dense(review.observations, 4096),
			"AV_LISTENING_REQUIRED"
		)
		local function document(path: any): any
			assert(
				type(path) == "string"
					and relative(path)
					and inside(path, input.evidenceDir)
					and table.find(artifacts, path),
				"AV_UNBOUND_ARTIFACT"
			)
			return serde.decode("json", fs.readFile(input.root .. "/" .. path))
		end
		for _, path in manifests do
			assert(relative(path) and inside(path, input.evidenceDir), "AV_MANIFEST_PATH")
			local av = serde.decode("json", fs.readFile(input.root .. "/" .. path))
			assert(av.schemaVersion == 1 and table.find(input.evidence.scenarios, av.scenario), "AV_SCENARIO_REQUIRED")
			local scenario = serde.decode("json", fs.readFile(input.root .. "/" .. av.scenario)).outcome
			local source = document(av.sourceReceipt)
			local decoded = document(av.decodeReport)
			local capability = document(av.listeningCapability)
			local listening = document(av.listeningReport)
			local original = av.original
			assert(
				type(original) == "table"
					and type(original.path) == "string"
					and relative(original.path)
					and inside(original.path, input.evidenceDir)
					and table.find(artifacts, original.path),
				"AV_ORIGINAL_REQUIRED"
			)
			local bytes = fs.readFile(input.root .. "/" .. original.path)
			assert(
				original.sha256 == serde.hash("sha256", bytes) and original.byteLength == #bytes,
				"AV_ORIGINAL_MISMATCH"
			)
			assert(
				av.sessionId == scenario.runtime.server.sessionId and av.buildIdentity == receipt.buildIdentity.id,
				"AV_RUNTIME_MISMATCH"
			)
			local actor = false
			for _, client in scenario.runtime.clients do
				if client.actorId == av.actorId and client.studio_id == av.studioId then
					actor = true
				end
			end
			assert(
				actor
					and source.finalized == true
					and text(source.startAcknowledgement)
					and text(source.finalizeAcknowledgement),
				"AV_ACQUISITION_REQUIRED"
			)
			local registered, registrationReason = M.validateRegistration(input, receipt, scenario, source, artifacts)
			assert(registered, "AV_REGISTRATION_REQUIRED: " .. tostring(registrationReason))
			assert(
				type(scenario.audiovisualSources) == "table" and scenario.audiovisualSources[path] == M.digest(source),
				"AV_SOURCE_NOT_RECORDED"
			)
			for _, key in
				{
					"sessionId",
					"actorId",
					"studioId",
					"buildIdentity",
					"processIdentity",
					"recorderId",
					"audioEndpoint",
					"videoSource",
					"acquisitionDigest",
					"runSha256",
				}
			do
				assert(text(av[key]) and av[key] == source[key], "AV_SOURCE_MISMATCH: " .. key)
			end
			assert(
				M.digest(av.tracks) == M.digest(source.tracks) and M.digest(av.clock) == M.digest(source.clock),
				"AV_TRACK_CLOCK_MISMATCH"
			)
			assert(
				Validation.finite(av.tracks.audio)
					and av.tracks.audio >= 0
					and av.tracks.audio % 1 == 0
					and Validation.finite(av.tracks.video)
					and av.tracks.video >= 0
					and av.tracks.video % 1 == 0
					and av.tracks.audio ~= av.tracks.video,
				"AV_TRACK_IDS"
			)
			assert(
				Validation.finite(av.clock.offsetSeconds)
					and Validation.finite(av.clock.rate)
					and av.clock.rate > 0
					and Validation.dense(av.clock.anchors, 2)
					and #av.clock.anchors == 2,
				"AV_CLOCK_ANCHORS"
			)
			assert(M.digest(av.policy) == source.policyDigest, "AV_POLICY_MISMATCH")
			assert(
				source.acquisition == "owned-process-loopback"
					or source.acquisition == "isolated-owned-session-loopback",
				"AV_SOURCE_KIND"
			)
			if source.acquisition == "isolated-owned-session-loopback" then
				local isolation = source.isolation
				assert(
					type(isolation) == "table"
						and isolation.verified == true
						and isolation.unrelatedAudioExcluded == true
						and text(isolation.receipt)
						and Validation.dense(isolation.producers, 128)
						and #isolation.producers > 0,
					"AV_MIX_UNPROVEN"
				)
				for _, producer in isolation.producers do
					assert(
						producer.owned == true and producer.sessionId == av.sessionId and text(producer.processIdentity),
						"AV_MIX_SOURCE"
					)
					local mapped = false
					for _, client in scenario.runtime.clients do
						if client.actorId == producer.actorId then
							mapped = true
						end
					end
					assert(mapped, "AV_MIX_ACTOR")
				end
			end
			assert(
				decoded.schemaVersion == 1
					and M.digest(decoded.provenance) == M.digest(av)
					and decoded.original.sha256 == original.sha256,
				"AV_DECODE_BINDING"
			)
			assert(
				Validation.dense(decoded.runs, 32) and #decoded.runs >= 5 and type(decoded.versions) == "table",
				"AV_DECODE_REQUIRED"
			)
			for _, run in decoded.runs do
				assert(run.exitCode == 0 and run.cleanup.ok == true and text(run.stdoutSha256), "AV_DECODE_FAILED")
			end
			assert(
				type(decoded.audio) == "table"
					and decoded.audio.parentSha256 == original.sha256
					and decoded.audio.streamIndex == av.tracks.audio
					and decoded.audio.nonzero > 0
					and decoded.audio.samples > 0,
				"AV_AUDIO_DECODE_REQUIRED"
			)
			assert(
				Validation.dense(decoded.frameHashes, 1000000) and #decoded.frameHashes == #decoded.coverage.video,
				"AV_FRAME_HASHES_REQUIRED"
			)
			assert(
				capability.schemaVersion == 1
					and capability.evaluator == receipt.evaluator
					and capability.audioInput == true
					and capability.temporalVideoInput == true
					and capability.commercialUse == true
					and text(capability.api)
					and text(capability.probeEvidence)
					and text(capability.licenseBasis),
				"AV_CAPABILITY_UNPROVEN"
			)
			local probe = document(capability.probeEvidence)
			assert(
				probe.ok == true
					and probe.audioDelivered == true
					and probe.videoDelivered == true
					and probe.api == capability.api,
				"AV_CAPABILITY_PROBE"
			)
			assert(
				listening.evaluator == receipt.evaluator
					and listening.originalSha256 == original.sha256
					and M.digest(listening.tracks) == M.digest(av.tracks)
					and listening.verdict == "approved"
					and text(listening.deliveryEvidence),
				"AV_LISTENING_BINDING"
			)
			local delivery = document(listening.deliveryEvidence)
			assert(
				delivery.audioDelivered == true
					and delivery.videoDelivered == true
					and delivery.originalSha256 == original.sha256
					and delivery.api == capability.api
					and M.digest(delivery.tracks) == M.digest(av.tracks),
				"AV_MEDIA_DELIVERY"
			)
			assert(Validation.dense(av.policy.intervals, 4096) and #av.policy.intervals > 0, "AV_INTERVALS_REQUIRED")
			local cueCoverage = {}
			for _, interval in av.policy.intervals do
				local step = scenario.steps[interval.step]
				assert(
					step
						and step.sessionId == av.sessionId
						and step.actor == av.actorId
						and Validation.finite(interval.start)
						and Validation.finite(interval["end"])
						and interval.start >= step.startedSeconds
						and interval["end"] <= step.elapsedSeconds
						and interval["end"] > interval.start,
					"AV_ACTION_INTERVAL"
				)
				assert(
					Validation.finite(av.policy.maxGapSeconds)
						and av.policy.maxGapSeconds >= 0
						and Validation.finite(av.policy.maxClockErrorSeconds)
						and av.policy.maxClockErrorSeconds >= 0,
					"AV_POLICY_LIMITS"
				)
				assert(
					Validation.finite(av.clock.uncertaintySeconds)
						and av.clock.uncertaintySeconds >= 0
						and Validation.finite(av.clock.driftSeconds)
						and av.clock.driftSeconds >= 0
						and av.clock.uncertaintySeconds + av.clock.driftSeconds <= av.policy.maxClockErrorSeconds,
					"AV_CLOCK_ERROR"
				)
				for _, anchor in av.clock.anchors do
					assert(
						Validation.finite(anchor.ptsSeconds)
							and Validation.finite(anchor.actionSeconds)
							and math.abs(
									av.clock.offsetSeconds + anchor.ptsSeconds * av.clock.rate - anchor.actionSeconds
								)
								<= av.policy.maxClockErrorSeconds,
						"AV_CLOCK_ANCHOR_MISMATCH"
					)
				end
				assert(
					av.clock.anchors[1].actionSeconds <= interval.start
						and av.clock.anchors[2].actionSeconds >= interval["end"]
						and av.clock.anchors[2].ptsSeconds > av.clock.anchors[1].ptsSeconds,
					"AV_CLOCK_COVERAGE"
				)
				assert(
					table.find({ "gather", "craft", "hit", "ambient" }, interval.cue) and interval.audioRequired == true,
					"AV_CUE_REQUIRED"
				)
				cueCoverage[interval.cue] = true
				for _, kind in { "audio", "video" } do
					local frames = decoded.coverage[kind]
					assert(Validation.dense(frames, 1000000) and #frames > 0, "AV_DECODE_COVERAGE")
					local finish, started, previous = interval.start, false, -math.huge
					for _, frame in frames do
						assert(
							Validation.finite(frame.start)
								and Validation.finite(frame["end"])
								and frame["end"] > frame.start,
							"AV_FRAME_TIME"
						)
						assert(frame.start > previous, "AV_FRAME_ORDER")
						previous = frame.start
						if frame["end"] > interval.start and frame.start < interval["end"] then
							assert(
								frame.start <= finish + (if started then av.policy.maxGapSeconds else 0),
								"AV_FRAME_GAP"
							)
							finish, started = frame["end"], true
						end
					end
					assert(started and finish >= interval["end"], "AV_TRUNCATED")
				end
				if interval.motion == true then
					local first, changed = nil, false
					for index, frame in decoded.coverage.video do
						if frame["end"] > interval.start and frame.start < interval["end"] then
							local hash = decoded.frameHashes[index]
							assert(text(hash), "AV_FRAME_HASH_REQUIRED")
							if first and hash ~= first then
								changed = true
							end
							first = first or hash
						end
					end
					assert(changed, "AV_STATIC_MOTION")
				end
				local found = false
				for _, observed in review.observations do
					if observed.manifest == path and observed.interval == interval.id then
						assert(
							observed.listeningReportDigest == M.digest(listening)
								and observed.originalSha256 == original.sha256,
							"AV_OBSERVATION_BINDING"
						)
						local heard = listening.intervals[interval.id]
						assert(
							type(heard) == "table"
								and heard.start <= interval.start
								and heard.finish >= interval["end"]
								and heard.heard == true
								and text(heard.audioObservation)
								and text(heard.motionObservation)
								and heard.frames > 1
								and heard.samples > 0,
							"AV_LISTENING_COVERAGE"
						)
						found = true
					end
				end
				assert(found, "AV_OBSERVATION_REQUIRED")
			end
			for _, cue in { "gather", "craft", "hit", "ambient" } do
				assert(cueCoverage[cue], "AV_MISSING_CUE: " .. cue)
			end
		end
	end)
	return ok, if ok then nil else tostring(reason)
end

-- This runs at the global approval boundary, not only at supplement attachment.
function M.validateRuntime(profile: qualityprofile.Profile, input: Inputs, receipt: any): (boolean, string?)
	local ok, reason = pcall(function()
		assert(receipt.captureSchemaVersion == 2, "CAPTURE_SCHEMA_REQUIRED")
		assert(
			M.digest(receipt.inputs)
				== M.digest({ buildPath = input.buildPath, evidenceDir = input.evidenceDir, evidence = input.evidence }),
			"INPUT_BINDING_MISMATCH"
		)
		local sidecar = serde.decode("json", fs.readFile(input.root .. "/" .. input.buildPath .. ".identity.json"))
		local current = buildidentity.snapshot(
			input.root .. "/" .. input.packDir .. "/default.project.json",
			input.root .. "/" .. input.packDir,
			input.root .. "/" .. input.buildPath
		)
		assert(sidecar.schemaVersion == 1 and M.digest(sidecar.identity) == M.digest(current), "STALE_BUILD_IDENTITY")
		local ownedQaToken = sidecar.ownedQaToken
		assert(
			ownedQaToken == nil
				or (
					type(ownedQaToken) == "string"
					and #ownedQaToken >= 16
					and #ownedQaToken <= 128
					and string.match(ownedQaToken, "^[%w%-]+$") ~= nil
				),
			"INVALID_OWNED_QA_TOKEN"
		)
		assert(
			sidecar.build == "sha256:" .. serde.hash("sha256", fs.readFile(input.root .. "/" .. input.buildPath)),
			"IDENTITY_BUILD_MISMATCH"
		)
		assert(
			buildidentity.inspectArtifact(fs.readFile(input.root .. "/" .. input.buildPath), current, ownedQaToken),
			"EMBEDDED_IDENTITY_MISMATCH"
		)
		assert(M.digest(receipt.buildIdentity) == M.digest(current), "RECEIPT_IDENTITY_MISMATCH")
		local scenarios = {}
		local forbidden = {
			advance_to = true,
			advance_elapsed = true,
			begin_clock = true,
			restore = true,
			server_command = true,
			dispatch = true,
			command = true,
			obstacle = true,
		}
		for _, path in input.evidence.scenarios do
			local document = serde.decode("json", fs.readFile(input.root .. "/" .. path))
			local outcome = document.outcome
			assert(
				document.mode == "studio"
					and type(outcome) == "table"
					and outcome.ok == true
					and outcome.kind == "studio",
				"INVALID_RUNTIME_SCENARIO"
			)
			assert(type(outcome.blockers) == "table" and next(outcome.blockers) == nil, "RUNTIME_BLOCKERS")
			local runtime = outcome.runtime
			assert(
				type(runtime) == "table" and buildidentity.validateLoaded(current, runtime.server, runtime.clients),
				"LOADED_IDENTITY_MISMATCH"
			)
			assert(text(runtime.server.studio_id), "MISSING_SERVER_PROCESS")
			local function checkOwner(handshake: any)
				assert(handshake.ownedQaToken == ownedQaToken, "LOADED_OWNERSHIP_MISMATCH")
				assert(
					if ownedQaToken ~= nil
						then handshake.placeId == 0
						else handshake.placeId == nil or handshake.placeId == 0,
					"LOADED_PLACE_MISMATCH"
				)
			end
			checkOwner(runtime.server)
			assert(
				Validation.dense(outcome.clients, 128) and #outcome.clients == #runtime.clients,
				"ACTOR_MAPPING_MISMATCH"
			)
			local actors, processes = {}, { [runtime.server.studio_id] = true }
			for index, client in runtime.clients do
				checkOwner(client)
				local mapped = outcome.clients[index]
				assert(
					text(client.studio_id)
						and not processes[client.studio_id]
						and mapped.studio_id == client.studio_id
						and mapped.actor == client.actorId,
					"ACTOR_MAPPING_MISMATCH"
				)
				actors[client.actorId], processes[client.studio_id] = client.studio_id, true
			end
			assert(Validation.dense(outcome.steps, 10000) and #outcome.steps > 0, "MISSING_ACTIONS")
			local elapsed, revision = 0, 0
			for index, step in outcome.steps do
				assert(
					type(step) == "table"
						and step.index == index
						and text(step.op)
						and not forbidden[step.op]
						and step.shortcut == false,
					"INVALID_ACTION_ORDER_OR_SHORTCUT"
				)
				assert(
					step.sessionId == runtime.server.sessionId and actors[step.actor] == step.studio_id,
					"ACTION_ACTOR_SESSION_MISMATCH"
				)
				assert(
					Validation.finite(step.startedSeconds)
						and Validation.finite(step.elapsedSeconds)
						and step.startedSeconds >= elapsed
						and step.elapsedSeconds >= step.startedSeconds,
					"INVALID_ACTION_TIME"
				)
				assert(
					Validation.finite(step.revisionBefore)
						and Validation.finite(step.revisionAfter)
						and step.revisionBefore % 1 == 0
						and step.revisionAfter % 1 == 0
						and step.revisionBefore >= revision
						and step.revisionAfter >= step.revisionBefore,
					"INVALID_REVISION_PROGRESSION"
				)
				elapsed, revision = step.elapsedSeconds, step.revisionAfter
			end
			assert(Validation.dense(outcome.captures, 4096) and #outcome.captures > 0, "MISSING_RUNTIME_CAPTURES")
			for _, capture in outcome.captures do
				assert(
					capture.schemaVersion == 2
						and actors[capture.actor] == capture.studio_id
						and capture.sessionId == runtime.server.sessionId
						and capture.buildIdentity == current.id,
					"CAPTURE_RUNTIME_MISMATCH"
				)
				assert(table.find(input.evidence.captures, capture.path), "UNBOUND_CAPTURE")
				assert(
					capture.sha256 == serde.hash("sha256", fs.readFile(input.root .. "/" .. capture.path)),
					"STALE_CAPTURE"
				)
				assert(
					qastudio.validateCapture(
						capture,
						fs.readFile(input.root .. "/" .. capture.path),
						capture.device.surface
					),
					"INVALID_CAPTURE_GEOMETRY"
				)
				local step = outcome.steps[capture.step]
				assert(
					step
						and step.op == "capture"
						and Validation.finite(capture.elapsedSeconds)
						and capture.elapsedSeconds >= step.startedSeconds
						and capture.elapsedSeconds <= step.elapsedSeconds,
					"CAPTURE_TIME_MISMATCH"
				)
				local bound = false
				for _, observed in receipt.review.surfaces or {} do
					if
						observed.scenario == path
						and observed.capture == capture.path
						and observed.actor == capture.actor
						and observed.studio_id == capture.studio_id
					then
						bound = observed.captureSchemaVersion == 2
							and observed.surface == capture.device.surface
							and observed.geometryDigest
								== M.digest({
									device = capture.device,
									logical = capture.logical,
									raster = capture.raster,
									logicalToRaster = capture.logicalToRaster,
									criticalUI = capture.criticalUI,
								})
					end
				end
				assert(bound, "GEOMETRY_OBSERVATION_MISMATCH")
			end
			local actionPath = outcome.actionEvidence
			assert(table.find(input.evidence.actions, actionPath), "UNBOUND_ACTION_TRACE")
			local actions = serde.decode("json", fs.readFile(input.root .. "/" .. actionPath))
			assert(
				M.digest(actions) == M.digest({ runtime = runtime, clients = outcome.clients, steps = outcome.steps }),
				"ACTION_TRACE_MISMATCH"
			)
			scenarios[path] = outcome
		end
		for _, goal in profile.firstPlayGoals do
			local observed = receipt.review.goals[goal.id]
			local outcome = scenarios[observed.evidence]
			local recorded = outcome
				and outcome.firstPlay
				and outcome.firstPlay.goals
				and outcome.firstPlay.goals[goal.id]
			assert(type(recorded) == "table", "MISSING_RECORDED_GOAL")
			assert(M.digest(recorded) == M.digest({
				goalDigest = observed.goalDigest,
				actors = observed.actors,
				step = observed.step,
				elapsedSeconds = observed.elapsedSeconds,
				observation = observed.observation,
				unprompted = observed.unprompted,
				shortcut = observed.shortcut,
			}), "GOAL_CAPTURE_MISMATCH")
			assert(
				observed.goalDigest == M.digest(goal)
					and observed.shortcut == false
					and observed.unprompted == true
					and text(observed.observation),
				"INVALID_GOAL_OBSERVATION"
			)
			assert(Validation.finite(observed.step) and observed.step % 1 == 0, "INVALID_GOAL_STEP")
			local step = outcome.steps[observed.step]
			assert(
				step
					and Validation.finite(observed.elapsedSeconds)
					and observed.elapsedSeconds >= step.startedSeconds
					and observed.elapsedSeconds <= step.elapsedSeconds
					and observed.minutes == observed.elapsedSeconds / 60,
				"GOAL_TIME_MISMATCH"
			)
			assert(Validation.dense(observed.actors, 128) and #observed.actors == observed.players, "GOAL_ACTOR_COUNT")
			local seen = {}
			for _, actor in observed.actors do
				assert(not seen[actor], "DUPLICATE_GOAL_ACTOR")
				seen[actor] = true
				local found = false
				for _, capture in outcome.captures do
					if capture.actor == actor then
						found = true
					end
				end
				assert(found, "GOAL_ACTOR_MISMATCH")
			end
		end
	end)
	return ok, if ok then nil else tostring(reason)
end

function M.check(
	profile: qualityprofile.Profile,
	input: Inputs,
	receipt: any,
	authority: Authority,
	target: qualityprofile.Tier?
): Result
	if type(receipt) ~= "table" or receipt.schemaVersion ~= M.SCHEMA_VERSION then
		return fail("INVALID_RECEIPT")
	end
	if not text(authority.identity) or not text(authority.attestationPath) then
		return fail("MISSING_EVALUATOR")
	end
	if receipt.evaluator ~= authority.identity then
		return fail("UNAUTHORIZED_EVALUATOR")
	end
	if receipt.pack ~= profile.pack or not qualityprofile.tierWithin(target or profile.tier, receipt.scope) then
		return fail("INVALID_SCOPE")
	end
	if receipt.verdict ~= "approved" and receipt.verdict ~= "failed" and receipt.verdict ~= "inconclusive" then
		return fail("INVALID_VERDICT")
	end
	if receipt.verdict ~= "approved" then
		return fail(string.upper(receipt.verdict))
	end
	local ok, attestation = pcall(function()
		return serde.decode("json", fs.readFile(authority.attestationPath))
	end)
	if
		not ok
		or type(attestation) ~= "table"
		or attestation.schemaVersion ~= M.SCHEMA_VERSION
		or attestation.evaluator ~= authority.identity
		or attestation.receiptDigest ~= M.digest(receipt)
	then
		return fail("INVALID_ATTESTATION")
	end
	local current, reason = M.snapshot(profile, input)
	if current == nil then
		return fail("MISSING_INPUT", reason)
	end
	if type(receipt.snapshot) ~= "table" then
		return fail("MISSING_DIGEST")
	end
	-- Specific categories precede source because shipped assets also belong to source.
	for _, key in { "asset", "rubric", "evidence", "build", "config", "source", "tree" } do
		if receipt.snapshot[key] ~= current[key] then
			return fail("STALE_" .. string.upper(key))
		end
	end
	local review = receipt.review
	if
		type(review) ~= "table"
		or type(review.criteria) ~= "table"
		or type(review.blockers) ~= "table"
		or next(review.blockers) ~= nil
	then
		return fail("INVALID_REVIEW")
	end
	for _, criterion in profile.criteria do
		local score = review.criteria[criterion.id]
		if
			type(score) ~= "table"
			or type(score.score) ~= "number"
			or score.score ~= score.score
			or score.score % 1 ~= 0
			or score.score < criterion.target
			or score.score > qualityprofile.MAX_CRITERION_SCORE
			or not text(score.rationale)
		then
			return fail("CRITERION_FAILED", criterion.id)
		end
	end
	local fun = review.fun
	if type(fun) ~= "table" or fun.verdict ~= "approved" or not text(fun.rationale) or not text(fun.confidence) then
		return fail("FUN_NOT_APPROVED")
	end
	if type(review.goals) ~= "table" then
		return fail("MISSING_GOALS")
	end
	local scenarioPaths: { [string]: boolean } = {}
	for _, path in input.evidence.scenarios do
		scenarioPaths[path] = true
	end
	for _, goal in profile.firstPlayGoals do
		local observed = review.goals[goal.id]
		if
			type(observed) ~= "table"
			or observed.completed ~= true
			or not text(observed.evidence)
			or not scenarioPaths[observed.evidence]
			or type(observed.minutes) ~= "number"
			or observed.minutes ~= observed.minutes
			or observed.minutes < 0
			or (goal.withinMinutes ~= nil and observed.minutes > goal.withinMinutes)
			or type(observed.players) ~= "number"
			or observed.players % 1 ~= 0
			or observed.players < (goal.players or 1)
		then
			return fail("GOAL_FAILED", goal.id)
		end
	end
	local admitted, admissionReason = M.validateRuntime(profile, input, receipt)
	if not admitted then
		return fail("INVALID_RUNTIME_EVIDENCE", admissionReason)
	end
	local av, avReason = M.validateAudiovisual(input, receipt)
	if not av then
		return fail("INCONCLUSIVE", avReason)
	end
	local reference, referenceReason = M.validateReference(profile, input, receipt)
	if not reference then
		return fail("INCONCLUSIVE", referenceReason)
	end
	if input.evidence.rejoin ~= nil or receipt.review.rejoinDigests ~= nil then
		local rejoin, rejoinReason = M.validateRejoin(input, receipt)
		if not rejoin then
			return fail("INCONCLUSIVE", rejoinReason)
		end
	end
	return { ok = true, code = "APPROVED", errors = {} }
end

return M
