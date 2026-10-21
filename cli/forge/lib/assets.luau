--!strict
-- assets: pure parsing, gating, and code generation for a pack's
-- games/<pack>/assets/manifest.yml. Nothing here touches the network or the
-- filesystem, so the check [assets] stage, the `assets` command, and the specs
-- all share the exact same logic.
--
-- The manifest is versioned (see MANIFEST_VERSION):
--   v1 (legacy, the default when `version:` is absent) - key/kind/tool/source/
--      path/assetId/moderation only. It still parses, still gates, and still
--      generates code, but it carries no provenance, so it can never be
--      granted a quality approval: migration must not invent one.
--   v2 - every asset additionally carries `provenance`: the content digest of
--      the artifact, the generation/import recipe and its input version, the
--      provider/tool and its version, where the commercial rights come from,
--      who owns the artifact, and optionally which quality reference it is
--      evaluated against.
-- An unknown newer version is refused rather than read as v2.
--
-- Three separate verdicts, deliberately never folded together:
--   * lawfulness/reproducibility - `checkProvenance` (a licensed import can
--     pass it; passing says nothing about how the asset looks),
--   * platform moderation - the manifest's `moderation` field, reported on its
--     own and refreshed from Open Cloud, never a local quality signal,
--   * appearance/quality - `checkQuality`, which only ever approves an asset
--     through a quality report bound to that exact content digest.

local licenses = require("./licenses")
local qualityprofile = require("./qualityprofile")
local qualityreceipt = require("./qualityreceipt")

local M = {}

export type Kind = "mesh" | "image" | "sfx" | "bgm" | "model"
export type Moderation = "Approved" | "PendingModeration" | "Rejected" | "NotUploaded"

export type Recipe = {
	id: string,
	version: string,
	input: string?,
	inputVersion: string?,
}

export type Provider = {
	name: string,
	version: string,
}

export type RightsDecl = {
	source: string,
	ownership: licenses.Ownership,
	-- Evidence that the commercial rights actually exist, required whenever the
	-- tool is not one this repo's registry already records. `document` names the
	-- licence/agreement (a path or URI, never fetched here), `version` pins the
	-- exact revision agreed to, and `verifiedBy` records who checked it. A
	-- registered tool may omit the block: the registry is its evidence.
	evidence: RightsEvidence?,
}

export type RightsEvidence = {
	document: string,
	version: string,
	verifiedBy: string,
}

export type QualityRef = {
	reference: string,
	referenceVersion: string,
}

export type Provenance = {
	digest: string,
	recipe: Recipe,
	provider: Provider,
	rights: RightsDecl,
	quality: QualityRef?,
}

export type Asset = {
	key: string,
	kind: Kind,
	tool: string,
	source: string,
	path: string?,
	assetId: number,
	moderation: Moderation,
	provenance: Provenance?,
}

export type Manifest = { version: number, assets: { Asset } }

-- What the code generators need: only the asset list. Declaring it separately
-- keeps `renderLuau`/`asphaltConfig` callable with a hand-built asset list (the
-- genre scaffolds render a starter Assets.luau before any manifest exists)
-- without those callers having to pick a schema version.
export type RenderableManifest = { version: number?, assets: { Asset } }

export type CheckResult = { ok: boolean, errors: { string } }

-- A provenance/quality verdict. `errors` is the flat list every caller prints
-- (it includes the moderation findings), while `moderation`, `pending` and
-- `approved` keep the three verdicts separable for callers that report them.
export type GateResult = {
	ok: boolean,
	errors: { string },
	moderation: { string },
	pending: { string },
	approved: { string },
}

export type QualityVerdict = "approved" | "failed" | "inconclusive"

export type QualityReport = {
	key: string,
	digest: string,
	verdict: QualityVerdict,
	evaluator: string,
	report: string,
	reference: string?,
	referenceVersion: string?,
}

export type QualityProfile = {
	reference: string,
	referenceVersion: string,
	reports: { QualityReport },
}

-- The manifest version this CLI writes. v1 documents (no `version:` key) are
-- still read; anything newer than MANIFEST_VERSION is refused.
M.MANIFEST_VERSION = 2
M.LEGACY_MANIFEST_VERSION = 1

local KINDS: { [string]: boolean } = {
	mesh = true,
	image = true,
	sfx = true,
	bgm = true,
	model = true,
}

local MODERATIONS: { [string]: boolean } = {
	Approved = true,
	PendingModeration = true,
	Rejected = true,
	NotUploaded = true,
}

local VERDICTS: { [string]: boolean } = {
	approved = true,
	failed = true,
	inconclusive = true,
}

-- Kinds Asphalt can upload; it deliberately does not upload meshes or models
-- (see the Asphalt README and the architecture review), so they are excluded
-- from asphalt.toml.
local ASPHALT_KINDS: { [string]: boolean } = {
	image = true,
	sfx = true,
	bgm = true,
}

-- Keys match asset ids, which include hyphenated kaiju/egg ids (pyro-pup).
local KEY_PATTERN = "^[%a][%w_%-]*$"

local function isNonEmptyString(value: any): boolean
	return type(value) == "string" and value ~= ""
end

--- True when `value` is a `sha256:<64 lowercase hex>` content digest.
function M.isDigest(value: any): boolean
	if not isNonEmptyString(value) then
		return false
	end
	local hex = string.match(value, "^sha256:([0-9a-f]+)$")
	return hex ~= nil and #hex == 64
end

--- Renders the canonical digest string for an already-hex sha256 sum.
function M.digestOf(hex: string): string
	return "sha256:" .. string.lower(hex)
end

local function requireString(container: any, field: string, label: string): (string?, string?)
	local value = container[field]
	if not isNonEmptyString(value) then
		return nil, label .. "." .. field .. " is missing"
	end
	return value, nil
end

-- Version fields are written as plain scalars (`version: 1`, `version: 2026-01`)
-- and a YAML decoder hands those back as numbers, so they are read as scalars
-- and normalised to their text form rather than rejected for not being a
-- string. A boolean or a table is still not a version.
local function requireScalar(container: any, field: string, label: string): (string?, string?)
	local value = container[field]
	if type(value) == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return nil, label .. "." .. field .. " is not a finite version"
		end
		if value == math.floor(value) then
			return string.format("%d", value), nil
		end
		return tostring(value), nil
	end
	if not isNonEmptyString(value) then
		return nil, label .. "." .. field .. " is missing"
	end
	return value, nil
end

-- Parses one asset's `provenance` block. Every field the gate later reasons
-- about is required here, so a half-filled provenance can never reach a gate
-- and read as "nothing to check".
local function parseProvenance(raw: any, label: string): (Provenance?, string?)
	if type(raw) ~= "table" then
		return nil, label .. " must be a table"
	end

	local digest = raw.digest
	if not isNonEmptyString(digest) then
		return nil, label .. ".digest is missing"
	end
	if not M.isDigest(digest) then
		return nil, label .. ".digest must be sha256:<64 hex> (got '" .. tostring(digest) .. "')"
	end

	if type(raw.recipe) ~= "table" then
		return nil, label .. ".recipe is missing"
	end
	local recipeId, recipeIdErr = requireString(raw.recipe, "id", label .. ".recipe")
	if recipeId == nil then
		return nil, recipeIdErr
	end
	local recipeVersion, recipeVersionErr = requireScalar(raw.recipe, "version", label .. ".recipe")
	if recipeVersion == nil then
		return nil, recipeVersionErr
	end
	local input = raw.recipe.input
	local rawInputVersion = raw.recipe.inputVersion
	local inputVersion: string? = nil
	if input ~= nil and not isNonEmptyString(input) then
		return nil, label .. ".recipe.input must be a non-empty string when present"
	end
	-- An input without its version cannot be reproduced, so the pair is
	-- all-or-nothing rather than silently half-recorded.
	if input ~= nil then
		local parsedInputVersion, inputVersionErr = requireScalar(raw.recipe, "inputVersion", label .. ".recipe")
		if parsedInputVersion == nil then
			return nil,
				if string.find(tostring(inputVersionErr), "is missing", 1, true) ~= nil
					then label .. ".recipe.inputVersion is missing for input '" .. input .. "'"
					else inputVersionErr
		end
		inputVersion = parsedInputVersion
	end
	if input == nil and rawInputVersion ~= nil then
		return nil, label .. ".recipe.inputVersion is set without an input"
	end

	if type(raw.provider) ~= "table" then
		return nil, label .. ".provider is missing"
	end
	local providerName, providerNameErr = requireString(raw.provider, "name", label .. ".provider")
	if providerName == nil then
		return nil, providerNameErr
	end
	local providerVersion, providerVersionErr = requireScalar(raw.provider, "version", label .. ".provider")
	if providerVersion == nil then
		return nil, providerVersionErr
	end

	if type(raw.rights) ~= "table" then
		return nil, label .. ".rights is missing"
	end
	local rightsSource, rightsSourceErr = requireString(raw.rights, "source", label .. ".rights")
	if rightsSource == nil then
		return nil, rightsSourceErr
	end
	local ownership, ownershipErr = requireString(raw.rights, "ownership", label .. ".rights")
	if ownership == nil then
		return nil, ownershipErr
	end
	if not licenses.isOwnership(ownership) then
		return nil, label .. ".rights.ownership '" .. ownership .. "' is not a known ownership class"
	end

	local evidence: RightsEvidence? = nil
	if raw.rights.evidence ~= nil then
		if type(raw.rights.evidence) ~= "table" then
			return nil, label .. ".rights.evidence must be a table"
		end
		local evidenceLabel = label .. ".rights.evidence"
		local document, documentErr = requireString(raw.rights.evidence, "document", evidenceLabel)
		if document == nil then
			return nil, documentErr
		end
		local evidenceVersion, evidenceVersionErr = requireScalar(raw.rights.evidence, "version", evidenceLabel)
		if evidenceVersion == nil then
			return nil, evidenceVersionErr
		end
		local verifiedBy, verifiedByErr = requireString(raw.rights.evidence, "verifiedBy", evidenceLabel)
		if verifiedBy == nil then
			return nil, verifiedByErr
		end
		evidence = { document = document, version = evidenceVersion, verifiedBy = verifiedBy }
	end

	local quality: QualityRef? = nil
	if raw.quality ~= nil then
		if type(raw.quality) ~= "table" then
			return nil, label .. ".quality must be a table"
		end
		local reference, referenceErr = requireString(raw.quality, "reference", label .. ".quality")
		if reference == nil then
			return nil, referenceErr
		end
		local referenceVersion, referenceVersionErr =
			requireScalar(raw.quality, "referenceVersion", label .. ".quality")
		if referenceVersion == nil then
			return nil, referenceVersionErr
		end
		quality = { reference = reference, referenceVersion = referenceVersion }
	end

	return {
		digest = digest,
		recipe = {
			id = recipeId,
			version = recipeVersion,
			input = input,
			inputVersion = inputVersion,
		},
		provider = { name = providerName, version = providerVersion },
		rights = {
			source = rightsSource,
			ownership = ownership :: licenses.Ownership,
			evidence = evidence,
		},
		quality = quality,
	},
		nil
end

--- Parses and schema-validates a decoded manifest.yml. Returns the typed
--- manifest or (nil, reason). Duplicate keys are a gate concern (see check), so
--- they are not rejected here. A document with no `version:` is read as the
--- legacy v1 schema, where `provenance` is optional; v2 requires it on every
--- asset. A version newer than this CLI understands is refused outright.
function M.parseManifest(yamlTable: any): (Manifest?, string?)
	if type(yamlTable) ~= "table" then
		return nil, "manifest: expected a table with an 'assets' list"
	end
	local rawAssets = yamlTable.assets
	if type(rawAssets) ~= "table" then
		return nil, "manifest: 'assets' must be a list"
	end

	local version = yamlTable.version
	if version == nil then
		version = M.LEGACY_MANIFEST_VERSION
	end
	if type(version) ~= "number" or version ~= math.floor(version) or version < 1 then
		return nil, "manifest: 'version' must be a positive integer (got " .. tostring(yamlTable.version) .. ")"
	end
	if version > M.MANIFEST_VERSION then
		return nil,
			string.format(
				"manifest: version %d is newer than this CLI supports (max %d); upgrade the toolchain",
				version,
				M.MANIFEST_VERSION
			)
	end

	local assets: { Asset } = {}
	for index, entry in rawAssets do
		if type(entry) ~= "table" then
			return nil, string.format("manifest: asset %d is not a table", index)
		end

		local key = entry.key
		if not isNonEmptyString(key) then
			return nil, string.format("manifest: asset %d is missing a key", index)
		end
		if string.match(key, KEY_PATTERN) == nil then
			return nil, "manifest: invalid key '" .. key .. "' (must match [a-zA-Z][a-zA-Z0-9_]*)"
		end

		local kind = entry.kind
		if not isNonEmptyString(kind) or not KINDS[kind] then
			return nil, "manifest: asset " .. key .. " has invalid kind '" .. tostring(kind) .. "'"
		end

		local tool = entry.tool
		if not isNonEmptyString(tool) then
			return nil, "manifest: asset " .. key .. " is missing a tool"
		end

		local source = entry.source
		if not isNonEmptyString(source) then
			return nil, "manifest: asset " .. key .. " is missing a source"
		end

		local path = entry.path
		if path ~= nil and not isNonEmptyString(path) then
			return nil, "manifest: asset " .. key .. " has an invalid path"
		end

		local assetId = entry.assetId
		if assetId == nil then
			assetId = 0
		end
		if type(assetId) ~= "number" or assetId < 0 or assetId ~= math.floor(assetId) then
			return nil, "manifest: asset " .. key .. " has an invalid assetId (expected a non-negative integer)"
		end

		local moderation = entry.moderation
		if moderation == nil then
			moderation = "NotUploaded"
		end
		if not isNonEmptyString(moderation) or not MODERATIONS[moderation] then
			return nil, "manifest: asset " .. key .. " has invalid moderation '" .. tostring(moderation) .. "'"
		end

		local provenanceRaw = entry.provenance
		local provenance: Provenance? = nil
		if provenanceRaw ~= nil then
			local parsed, provenanceErr = parseProvenance(provenanceRaw, "manifest: asset " .. key .. " provenance")
			if parsed == nil then
				return nil, provenanceErr
			end
			provenance = parsed
		elseif version >= 2 then
			return nil, "manifest: asset " .. key .. " is missing provenance (required from manifest version 2)"
		end

		table.insert(assets, {
			key = key,
			kind = kind :: Kind,
			tool = tool,
			source = source,
			path = path,
			assetId = assetId,
			moderation = moderation :: Moderation,
			provenance = provenance,
		})
	end

	return { version = version, assets = assets }, nil
end

--- Parses the subset of a quality profile the asset gate consumes: the active
--- reference and its version, plus one report per evaluated asset. The full
--- quality.yml schema (tiers, rubric, first-play goals) is owned by the quality
--- command; this reads only what binds a verdict to a content digest, and
--- refuses anything it cannot bind.
function M.parseQualityProfile(yamlTable: any): (QualityProfile?, string?)
	if type(yamlTable) ~= "table" then
		return nil, "quality profile: expected a table"
	end
	if type(yamlTable.reference) ~= "table" then
		return nil, "quality profile: 'reference' is missing"
	end
	local reference, referenceErr = requireString(yamlTable.reference, "id", "quality profile: reference")
	if reference == nil then
		return nil, referenceErr
	end
	local referenceVersion, referenceVersionErr =
		requireScalar(yamlTable.reference, "version", "quality profile: reference")
	if referenceVersion == nil then
		return nil, referenceVersionErr
	end

	local rawReports = yamlTable.reports
	if rawReports == nil then
		rawReports = {}
	end
	if type(rawReports) ~= "table" then
		return nil, "quality profile: 'reports' must be a list"
	end

	local reports: { QualityReport } = {}
	for index, raw in rawReports do
		local label = string.format("quality profile: report %d", index)
		if type(raw) ~= "table" then
			return nil, label .. " is not a table"
		end
		local key, keyErr = requireString(raw, "key", label)
		if key == nil then
			return nil, keyErr
		end
		label = "quality profile: report " .. key
		if not M.isDigest(raw.digest) then
			return nil, label .. ".digest must be sha256:<64 hex> (got '" .. tostring(raw.digest) .. "')"
		end
		local verdict, verdictErr = requireString(raw, "verdict", label)
		if verdict == nil then
			return nil, verdictErr
		end
		if not VERDICTS[verdict] then
			return nil, label .. ".verdict '" .. verdict .. "' must be approved|failed|inconclusive"
		end
		local evaluator, evaluatorErr = requireString(raw, "evaluator", label)
		if evaluator == nil then
			return nil, evaluatorErr
		end
		local report, reportErr = requireString(raw, "report", label)
		if report == nil then
			return nil, reportErr
		end
		local reportReference = raw.reference
		if reportReference ~= nil and not isNonEmptyString(reportReference) then
			return nil, label .. ".reference must be a non-empty string when present"
		end
		local reportReferenceVersion: string? = nil
		if raw.referenceVersion ~= nil then
			local parsedVersion, parsedVersionErr = requireScalar(raw, "referenceVersion", label)
			if parsedVersion == nil then
				return nil, parsedVersionErr
			end
			reportReferenceVersion = parsedVersion
		end
		table.insert(reports, {
			key = key,
			digest = raw.digest,
			verdict = verdict :: QualityVerdict,
			evaluator = evaluator,
			report = report,
			reference = reportReference,
			referenceVersion = reportReferenceVersion,
		})
	end

	return { reference = reference, referenceVersion = referenceVersion, reports = reports }, nil
end

--- Gates a parsed manifest for one environment: keys must be unique, banned
--- tools are refused outright, production requires every asset to be Approved
--- with an uploaded id, and staging forbids Rejected assets.
---
--- Lawfulness of a non-banned tool is NOT decided here. A v2 asset proves it
--- through recorded rights (see checkProvenance); a legacy v1 asset, which has
--- no rights to record, is still held to the old registry verdict so an
--- unvetted tool cannot slip in through an unversioned manifest.
function M.check(manifest: Manifest, env: string): CheckResult
	local errors: { string } = {}
	if env ~= "staging" and env ~= "production" then
		table.insert(errors, "unknown env '" .. tostring(env) .. "' (expected staging|production)")
	end

	local seen: { [string]: boolean } = {}
	for _, asset in manifest.assets do
		if seen[asset.key] then
			table.insert(errors, "asset " .. asset.key .. ": duplicate key")
		end
		seen[asset.key] = true

		local denial = licenses.denialReason(asset.tool)
		if denial ~= nil then
			table.insert(errors, "asset " .. asset.key .. ": " .. denial)
		elseif asset.provenance == nil then
			local allowed, licenseOrReason = licenses.resolve(asset.tool)
			if not allowed then
				table.insert(errors, "asset " .. asset.key .. ": " .. licenseOrReason)
			end
		end

		if env == "production" then
			if asset.moderation ~= "Approved" or asset.assetId <= 0 then
				table.insert(errors, "asset " .. asset.key .. ": not approved (" .. asset.moderation .. ")")
			end
		elseif env == "staging" then
			if asset.moderation == "Rejected" then
				table.insert(errors, "asset " .. asset.key .. ": rejected")
			end
		end
	end

	return { ok = #errors == 0, errors = errors }
end

local PLACEHOLDER_MARKERS = { "tbd", "placeholder" }

local function isPlaceholder(value: string): boolean
	local lower = string.lower(value)
	for _, marker in PLACEHOLDER_MARKERS do
		if string.find(lower, marker, 1, true) ~= nil then
			return true
		end
	end
	return false
end

export type ProvenanceOptions = {
	-- key -> the digest actually computed from the artifact's bytes on disk. A
	-- key present here with a different digest than the manifest declares is a
	-- mutated artifact; a key with no entry simply had no bytes to hash, and a
	-- key whose artifact could not be read belongs in `unreadable` so the gate
	-- refuses it rather than passing it silently.
	digests: { [string]: string }?,
	-- Keys whose artifact the caller tried and failed to read.
	unreadable: { [string]: boolean }?,
	-- Require provenance on every asset even in a legacy v1 manifest.
	requireProvenance: boolean?,
}

local function emptyGate(): GateResult
	return { ok = true, errors = {}, moderation = {}, pending = {}, approved = {} }
end

--- Gates a manifest's provenance.
---
--- Lawfulness is decided by recorded commercial rights, not by a tool-name
--- whitelist. For each asset:
---   * a banned tool or provider (audiocraft, roblox-cube, hunyuan3d-2) fails
---     outright, whatever rights the manifest claims for it - the weights are
---     not licensed for commercial use here, so no evidence can authorize them;
---   * a tool the registry records is authorized by that record, and a
---     first-party ownership claim must match it;
---   * any other tool - an unregistered provider, a commissioned artist, a
---     licensed import - is authorized by versioned rights evidence on the
---     asset itself (document, version, verifiedBy). Without that evidence it
---     fails for lack of recorded rights, not for being unknown.
---
--- This is a lawfulness and reproducibility verdict only. A licensed import
--- passes it with no quality approval whatsoever: `result.pending` lists every
--- asset that is lawful but still awaiting a quality report, and `moderation`
--- separately reports platform moderation state, which this gate never treats
--- as a quality signal.
---
--- Legacy v1 assets carry no provenance: their tool is held to the old registry
--- verdict (`licenses.resolve`), and they are reported as pending - never
--- approved - instead of failing, so an old manifest keeps building.
function M.checkProvenance(manifest: Manifest, options: ProvenanceOptions?): GateResult
	local result = emptyGate()
	local digests = if options ~= nil then options.digests else nil
	local unreadable = if options ~= nil then options.unreadable else nil
	local requireProvenance = if options ~= nil and options.requireProvenance == true
		then true
		else manifest.version >= 2

	for _, asset in manifest.assets do
		local label = "asset " .. asset.key .. ": "

		-- A denial is absolute and is checked before anything else, so a forged
		-- rights block on a banned tool cannot buy its way in.
		local toolDenial = licenses.denialReason(asset.tool)
		if toolDenial ~= nil then
			table.insert(result.errors, label .. toolDenial)
		end

		if isPlaceholder(asset.source) then
			table.insert(result.errors, label .. "source is a placeholder (" .. asset.source .. ")")
		end
		local path = asset.path
		if path ~= nil and isPlaceholder(path) then
			table.insert(result.errors, label .. "path is a placeholder (" .. path .. ")")
		end

		table.insert(result.moderation, asset.key .. ": " .. asset.moderation)

		local provenance = asset.provenance
		if provenance == nil then
			if requireProvenance then
				table.insert(result.errors, label .. "missing provenance (digest, recipe, provider, rights)")
			else
				-- A legacy entry has no rights evidence to reason about, so it stays
				-- on the old registry verdict rather than being newly accepted.
				local allowed, reason = licenses.resolve(asset.tool)
				if not allowed and toolDenial == nil then
					table.insert(result.errors, label .. reason)
				end
				table.insert(result.pending, asset.key .. ": legacy entry, no provenance recorded")
			end
		else
			local typed = provenance :: Provenance
			local providerName = typed.provider.name

			-- Reported only when it differs from the tool's own denial above, so a
			-- banned tool recorded as its own provider is named once.
			local providerDenial = licenses.denialReason(providerName)
			if providerDenial ~= nil and providerName ~= asset.tool then
				table.insert(result.errors, label .. "provider " .. providerDenial)
			end

			local evidence = typed.rights.evidence
			local toolRights = licenses.rights(providerName)
			if toolRights ~= nil then
				-- A registered provider carries its own rights record; the artifact's
				-- ownership claim has to survive it, so a licensed or platform
				-- generator's output is not first-party work.
				if typed.rights.ownership == "first-party" and toolRights.ownership ~= "first-party" then
					table.insert(
						result.errors,
						label
							.. "claims first-party ownership but provider '"
							.. providerName
							.. "' is "
							.. toolRights.ownership
					)
				end
			elseif providerDenial == nil then
				-- Unregistered provider: lawful only on recorded rights evidence.
				if evidence == nil then
					table.insert(
						result.errors,
						label
							.. "provider '"
							.. providerName
							.. "' is not in the license registry and records no rights evidence "
							.. "(rights.evidence needs document, version, verifiedBy)"
					)
				else
					local typedEvidence = evidence :: RightsEvidence
					local evidenceFields: { [string]: string } = {
						["rights.evidence.document"] = typedEvidence.document,
						["rights.evidence.version"] = typedEvidence.version,
						["rights.evidence.verifiedBy"] = typedEvidence.verifiedBy,
					}
					for field, value in evidenceFields do
						if isPlaceholder(value) then
							table.insert(result.errors, label .. field .. " is a placeholder (" .. value .. ")")
						end
					end
				end
			end

			-- A tool/provider disagreement would let a lawful provider launder an
			-- entry whose `tool` is something else entirely.
			if asset.tool ~= providerName then
				table.insert(
					result.errors,
					label .. "tool '" .. asset.tool .. "' does not match recorded provider '" .. providerName .. "'"
				)
			end

			local provenanceFields: { [string]: string } = {
				["rights.source"] = typed.rights.source,
				["recipe.id"] = typed.recipe.id,
				["recipe.version"] = typed.recipe.version,
				["provider.version"] = typed.provider.version,
			}
			for field, value in provenanceFields do
				if isPlaceholder(value) then
					table.insert(result.errors, label .. field .. " is a placeholder (" .. value .. ")")
				end
			end

			if unreadable ~= nil and unreadable[asset.key] then
				table.insert(result.errors, label .. "artifact could not be read to verify its digest")
			elseif digests ~= nil then
				-- Only keys the caller actually hashed are compared: an asset with no
				-- local file (a generated model that lives in ProcAssets.luau) has no
				-- bytes to read here, and a file that exists but could not be read is
				-- reported through `unreadable` above rather than passing silently.
				local actual = digests[asset.key]
				if actual ~= nil and actual ~= typed.digest then
					table.insert(
						result.errors,
						label .. "digest mismatch: manifest has " .. typed.digest .. ", artifact is " .. actual
					)
				end
			end

			table.insert(result.pending, asset.key .. ": provenance recorded, quality not evaluated here")
		end
	end

	result.ok = #result.errors == 0
	return result
end

--- Legacy entry point kept for callers outside this task's ownership (the
--- check command's [assets] stage). The framework tool whitelist it used to
--- apply is gone: lawfulness now comes from the license registry plus recorded
--- provenance, and appearance is never decided here.
function M.checkFramework(manifest: Manifest): CheckResult
	local gate = M.checkProvenance(manifest)
	return { ok = gate.ok, errors = gate.errors }
end

--- Asset reports are accepted only inside the canonical attested receipt.
function M.checkQuality(
	manifest: Manifest,
	profile: qualityprofile.Profile,
	input: qualityreceipt.Inputs,
	receipt: any,
	authority: qualityreceipt.Authority
): GateResult
	local result = emptyGate()
	local gate = qualityreceipt.check(profile, input, receipt, authority)
	if not gate.ok then
		result.ok = false
		result.errors = { gate.code }
		return result
	end
	local reports, reason = M.parseQualityProfile({
		reference = { id = profile.reference.name, version = profile.reference.rubricVersion },
		reports = receipt.review.assets,
	})
	if reports == nil then
		result.ok = false
		result.errors = { tostring(reason) }
		return result
	end
	local byKey: { [string]: QualityReport } = {}
	for _, report in reports.reports do
		byKey[report.key] = report
	end

	for _, asset in manifest.assets do
		local label = "asset " .. asset.key .. ": "
		table.insert(result.moderation, asset.key .. ": " .. asset.moderation)

		local provenance = asset.provenance
		if provenance == nil then
			table.insert(
				result.errors,
				label .. "no provenance digest, so no quality report can be bound to it (legacy entry)"
			)
			continue
		end
		local typed = provenance :: Provenance

		local report = byKey[asset.key]
		if report == nil then
			table.insert(result.errors, label .. "no quality report for digest " .. typed.digest)
			continue
		end
		if report.digest ~= typed.digest then
			table.insert(
				result.errors,
				label .. "stale quality report: evaluated " .. report.digest .. ", manifest has " .. typed.digest
			)
			continue
		end

		if report.evaluator ~= authority.identity then
			table.insert(result.errors, label .. "report evaluator differs from attested evaluator")
			continue
		end
		if
			report.reference ~= nil and report.reference ~= profile.reference.name
			or report.referenceVersion ~= nil and report.referenceVersion ~= profile.reference.rubricVersion
		then
			table.insert(result.errors, label .. "report reference differs from canonical profile")
			continue
		end
		local bound = false
		for _, path in input.evidence.captures do
			if path == report.report then
				bound = true
			end
		end
		for _, path in input.evidence.audio do
			if path == report.report then
				bound = true
			end
		end
		if not bound then
			table.insert(result.errors, label .. "report evidence is not bound")
			continue
		end

		-- A report evaluated against a different reference (or an older version of
		-- it) did not judge this pack's current bar.
		local reference = report.reference or profile.reference.name
		local referenceVersion = report.referenceVersion or profile.reference.rubricVersion
		local declared = typed.quality
		if declared ~= nil and (declared.reference ~= reference or declared.referenceVersion ~= referenceVersion) then
			table.insert(
				result.errors,
				label
					.. "quality reference mismatch: manifest expects "
					.. declared.reference
					.. "@"
					.. declared.referenceVersion
					.. ", report used "
					.. reference
					.. "@"
					.. referenceVersion
			)
			continue
		end

		if report.verdict == "approved" then
			table.insert(
				result.approved,
				asset.key .. ": approved by " .. report.evaluator .. " (" .. report.report .. ")"
			)
		else
			table.insert(
				result.errors,
				label .. "quality verdict is " .. report.verdict .. " (" .. report.report .. ")"
			)
		end
	end

	result.ok = #result.errors == 0
	return result
end

-- Renders a quoted Luau string literal.
local function quote(value: string): string
	local escaped = string.gsub(value, "\\", "\\\\")
	escaped = string.gsub(escaped, '"', '\\"')
	escaped = string.gsub(escaped, "\n", "\\n")
	return '"' .. escaped .. '"'
end

--- Maps a locally generated sound file to its Studio asset URL. `forge gen audio
--- --install` copies games/<pack>/assets/audio/<cue>.wav into
--- <Studio content>/forge/<pack>/, which Roblox resolves as
--- rbxasset://forge/<pack>/<cue>.wav. Returns nil for non-wav paths.
function M.soundUrl(pack: string, path: string): string?
	local base = string.match(path, "[^/]+$")
	if base == nil or string.match(base, "%.wav$") == nil then
		return nil
	end
	return "rbxasset://forge/" .. pack .. "/" .. base
end

--- Renders sorted published IDs and local WAV URLs. Unpublished/unknown keys
--- resolve to "" without storing placeholder rows in every built place.
function M.renderLuau(manifest: RenderableManifest, pack: string?): string
	local keys: { string } = {}
	local byKey: { [string]: Asset } = {}
	for _, asset in manifest.assets do
		if byKey[asset.key] == nil then
			table.insert(keys, asset.key)
		end
		byKey[asset.key] = asset
	end
	table.sort(keys)

	local lines: { string } = {
		"--!strict",
		"-- Generated by forge assets codegen from assets/manifest.yml. Do not edit.",
		"",
	}
	table.insert(lines, "local ids: { [string]: number | string } = {")
	for _, key in keys do
		local asset = byKey[key]
		local value: string? = nil
		local path = asset.path
		if asset.assetId > 0 then
			if asset.kind ~= "image" or asset.moderation == "Approved" then
				value = string.format("%.0f", asset.assetId)
			end
		elseif pack ~= nil and path ~= nil and (asset.kind == "sfx" or asset.kind == "bgm") then
			local url = M.soundUrl(pack, path)
			if url ~= nil then
				value = quote(url)
			end
		end
		if value ~= nil then
			table.insert(lines, "\t[" .. quote(key) .. "] = " .. value .. ",")
		end
	end
	table.insert(lines, "}")
	if lines[#lines - 1] == "local ids: { [string]: number | string } = {" then
		table.remove(lines)
		lines[#lines] = "local ids: { [string]: number | string } = {}"
	end
	table.insert(lines, "local Assets: { [string]: string } = {}")
	table.insert(lines, "for key, id in ids do")
	table.insert(
		lines,
		'\tAssets[key] = if type(id) == "number" then "rbxassetid://" .. string.format("%.0f", id) else id'
	)
	table.insert(lines, "end")
	table.insert(lines, "local function defaultEmpty(values: { [string]: string }): ()")
	table.insert(lines, "\tsetmetatable(values, {")
	table.insert(lines, "\t\t__index = function(): string")
	table.insert(lines, '\t\t\treturn ""')
	table.insert(lines, "\t\tend,")
	table.insert(lines, "\t})")
	table.insert(lines, "end")
	table.insert(lines, "defaultEmpty(Assets)")
	table.insert(lines, "")
	table.insert(lines, "return Assets")
	return table.concat(lines, "\n") .. "\n"
end

--- Renders an asphalt.toml for the manifest's image/sfx/bgm entries. Meshes and
--- models are excluded: Asphalt does not upload them via the web API.
function M.asphaltConfig(pack: string, manifest: RenderableManifest): string
	local lines: { string } = {
		"#:schema https://raw.githubusercontent.com/jackTabsCode/asphalt/refs/heads/main/schema.json",
		"# Generated by forge assets codegen from assets/manifest.yml. Do not edit.",
		"",
		"[creator]",
		'type = "user"',
		"id = 0",
		"",
		"[codegen]",
		'style = "flat"',
	}

	local chosen: { Asset } = {}
	for _, asset in manifest.assets do
		if ASPHALT_KINDS[asset.kind] and asset.path ~= nil then
			table.insert(chosen, asset)
		end
	end
	table.sort(chosen, function(a, b)
		return a.key < b.key
	end)

	for _, asset in chosen do
		local path = asset.path or ""
		table.insert(lines, "")
		table.insert(lines, "[inputs." .. asset.key .. "]")
		table.insert(lines, "path = " .. quote(path))
		table.insert(lines, "output_path = " .. quote("games/" .. pack .. "/src/shared"))
		if asset.assetId > 0 then
			local base = string.match(path, "[^/]+$") or path
			table.insert(lines, "")
			table.insert(lines, "[inputs." .. asset.key .. ".web]")
			table.insert(lines, quote(base) .. " = { id = " .. tostring(asset.assetId) .. " }")
		end
	end

	return table.concat(lines, "\n") .. "\n"
end

return M
