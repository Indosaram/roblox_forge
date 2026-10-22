--!strict
-- provenance: pure release-provenance gate (QA-PROV-01 / QA-NAME-01, ADR-06).
--
-- A pack opts in with games/<pack>/provenance/policy.yml. This module only
-- parses and judges: the caller reads files and hands them over as text, so
-- the gate never touches the filesystem or the clock. Matched banned names and
-- reference grams are never echoed back in plain text; findings name a list
-- index or a hash so logs cannot re-accumulate the original wording.

local serde = require("@lune/serde")
local licenses = require("./licenses")
local localesync = require("./localesync")

local M = {}

export type Finding = { rule: string, file: string, locator: string, detail: string }

export type Report = {
	ok: boolean,
	pack: string,
	findings: { Finding },
	strings: number,
	entries: number,
	assets: number,
	sets: { string },
}

-- Raw fingerprint files for one set id; nil fields mean the file is missing.
export type SetFiles = { fp: string?, meta: string? }

M.N = 8
M.ALGO = "sha256-48"
M.NORMALIZATION = "skeleton-v1"
M.GENERATOR = "forge provenance fingerprint v1"
M.BOILERPLATE_FRACTION = 0.5
-- Boilerplate exclusion needs enough documents to tell site chrome from text.
M.BOILERPLATE_MIN_DOCS = 4

M.RULES = {
	"PROV-POLICY",
	"PROV-FP",
	"PROV-MISSING",
	"PROV-STALE",
	"PROV-FIELD",
	"PROV-NGRAM",
	"NAME-TERM",
	"NAME-STEM",
	"NAME-LETTER",
	"NAME-HASHED",
	"NAME-ENCODING",
	"ASSET-TOOL",
	"ASSET-PROV",
}

-- Files the gate reads, relative to the pack directory.
local FILES: { [string]: string } = {
	policy = "provenance/policy.yml",
	banned = "provenance/banned-names.yml",
	allow = "provenance/allow.yml",
	game = "game.yml",
	econ = "econ.yml",
	econProv = "econ.provenance.yml",
	content = "content.yml",
	contentProv = "content.provenance.yml",
	deploy = "deploy.yml",
	locale = "locale/strings.csv",
	localeProv = "locale/provenance.csv",
	manifest = "assets/manifest.yml",
}
M.FILES = FILES

local CONTENT_CATALOGS = { "items", "recipes", "nodes", "structures", "wildlife" }
local CONTENT_SCALARS = {
	"rules",
	"limits",
	"vitals",
	"tags",
	"homePolicy",
	"harborPolicy",
	"buildingPolicy",
	"brawlPolicy",
	"clanPolicy",
	"outpostPolicy",
	"music",
}
local LOCALE_PROV_HEADER = { "Key", "source", "author", "created" }

local ZERO_WIDTH: { [number]: boolean } = {
	[0x200B] = true,
	[0x200C] = true,
	[0x200D] = true,
	[0x2060] = true,
	[0xFEFF] = true,
	[0x00AD] = true,
}

local function isDecomposedJamo(cp: number): boolean
	return (cp >= 0x1100 and cp <= 0x11FF) or (cp >= 0xA960 and cp <= 0xA97F) or (cp >= 0xD7B0 and cp <= 0xD7FF)
end

local function isKept(cp: number): boolean
	return (cp >= 0x30 and cp <= 0x39)
		or (cp >= 0x61 and cp <= 0x7A)
		or (cp >= 0xAC00 and cp <= 0xD7A3)
		or (cp >= 0x4E00 and cp <= 0x9FFF)
		or (cp >= 0x3040 and cp <= 0x30FF)
		or (cp >= 0xC0 and cp <= 0xFF and cp ~= 0xD7 and cp ~= 0xF7)
end

--- Normalized skeleton (skeleton-v1) as a list of code points (UTF-8 strings).
--- Spaces, punctuation, symbols and zero-width characters vanish, full-width
--- Latin folds to ASCII and ASCII is lower-cased, so spacing or punctuation
--- tricks cannot dodge a match. Invalid UTF-8 and decomposed Hangul jamo are
--- refused (Luau has no NFC normalization, so refusing is the safe choice).
function M.skeleton(text: string): ({ string }?, string?)
	if utf8.len(text) == nil then
		return nil, "invalid UTF-8"
	end
	local out: { string } = {}
	for _, code in utf8.codes(text) do
		local cp = code
		if ZERO_WIDTH[cp] then
			continue
		end
		if cp >= 0xFF01 and cp <= 0xFF5E then
			cp -= 0xFEE0
		end
		if isDecomposedJamo(cp) then
			return nil, "decomposed Hangul jamo"
		end
		if cp >= 0x41 and cp <= 0x5A then
			cp += 32
		end
		if isKept(cp) then
			table.insert(out, utf8.char(cp))
		end
	end
	return out, nil
end

--- sha256-48: the first 12 hex digits of sha256(salt .. text).
function M.hash12(salt: string, text: string): string
	return string.sub(serde.hash("sha256", salt .. text), 1, 12)
end

local function digitsOnly(chars: { string }, first: number, last: number): boolean
	for index = first, last do
		local char = chars[index]
		if #char ~= 1 or char < "0" or char > "9" then
			return false
		end
	end
	return true
end

--- Unique n-grams of a skeleton, skipping digit-only grams, in first-seen order.
function M.grams(chars: { string }, n: number): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for first = 1, #chars - n + 1 do
		local last = first + n - 1
		if not digitsOnly(chars, first, last) then
			local gram = table.concat(chars, "", first, last)
			if not seen[gram] then
				seen[gram] = true
				table.insert(out, gram)
			end
		end
	end
	return out
end

--- True when the upper-case ASCII `letter` occurs in `text` with no ASCII
--- letter or digit on either side ("K가 돌아왔다" matches, "OK" does not).
function M.standaloneLetter(text: string, letter: string): boolean
	local from = 1
	while true do
		local at = string.find(text, letter, from, true)
		if at == nil then
			return false
		end
		local before = if at > 1 then string.sub(text, at - 1, at - 1) else ""
		local after = string.sub(text, at + 1, at + 1)
		if not string.match(before, "^%w$") and not string.match(after, "^%w$") then
			return true
		end
		from = at + 1
	end
end

local function isMapping(value: any): boolean
	return type(value) == "table"
end

local function isList(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for _ in value do
		count += 1
	end
	return count == #value
end

local function unknownKeys(value: any, allowed: { string }): { string }
	local set: { [string]: boolean } = {}
	for _, key in allowed do
		set[key] = true
	end
	local out: { string } = {}
	for key in value do
		if type(key) ~= "string" or not set[key] then
			table.insert(out, tostring(key))
		end
	end
	table.sort(out)
	return out
end

local function sortedKeys(value: any): { string }
	local keys: { string } = {}
	for key in value do
		if type(key) == "string" then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	return keys
end

local function stringList(value: any): boolean
	if not isList(value) then
		return false
	end
	for _, item in value do
		if type(item) ~= "string" or item == "" then
			return false
		end
	end
	return true
end

local function decodeYaml(text: string): (any, string?)
	local ok, decoded = pcall(function()
		return serde.decode("yaml", text)
	end)
	if not ok then
		return nil, tostring(decoded)
	end
	return decoded, nil
end

local function stripCsvBom(text: string): string
	if string.sub(text, 1, 3) == "\239\187\191" then
		return string.sub(text, 4)
	end
	return text
end

local function trim(value: string): string
	return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

local function blankRow(row: { string }): boolean
	for _, cell in row do
		if trim(cell) ~= "" then
			return false
		end
	end
	return true
end

-- Fingerprints --------------------------------------------------------------

export type CorpusDoc = { name: string, text: string }
export type FingerprintOptions = { set: string, salt: string?, boilerplateDocFraction: number? }

local function stripHeader(text: string): (string, string?)
	local fetched: string? = nil
	local lines: { string } = {}
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		if string.sub(line, 1, 8) == "FETCHED:" then
			fetched = string.match(line, "^FETCHED:%s*(%d%d%d%d%-%d%d%-%d%d)")
		elseif string.sub(line, 1, 7) ~= "SOURCE:" then
			table.insert(lines, line)
		end
	end
	return table.concat(lines, "\n"), fetched
end

--- Builds a fingerprint set from corpus documents. Deterministic: documents
--- are processed in name order and the output is a sorted, de-duplicated list
--- of 12-hex hashes, so identical input always yields identical bytes. Only
--- hashes and per-document sha256 digests leave this function.
function M.fingerprint(docs: { CorpusDoc }, options: FingerprintOptions): (string?, string?, string?)
	local salt = options.salt or options.set
	local fraction = options.boilerplateDocFraction or M.BOILERPLATE_FRACTION
	local ordered = table.clone(docs)
	table.sort(ordered, function(a, b)
		return a.name < b.name
	end)
	local perDoc: { { string } } = {}
	local fetchedByDoc: { string? } = {}
	local docFreq: { [string]: number } = {}
	for index, doc in ordered do
		local body, fetched = stripHeader(doc.text)
		local chars, err = M.skeleton(body)
		if chars == nil then
			return nil, nil, doc.name .. ": " .. tostring(err)
		end
		local grams = M.grams(chars, M.N)
		perDoc[index] = grams
		fetchedByDoc[index] = fetched
		for _, gram in grams do
			docFreq[gram] = (docFreq[gram] or 0) + 1
		end
	end
	local excludeBoilerplate = #ordered >= M.BOILERPLATE_MIN_DOCS
	local hashes: { [string]: boolean } = {}
	local sources: { string } = {}
	for index, doc in ordered do
		local kept = 0
		for _, gram in perDoc[index] do
			if excludeBoilerplate and docFreq[gram] / #ordered >= fraction then
				continue
			end
			kept += 1
			hashes[M.hash12(salt, gram)] = true
		end
		local fetched = fetchedByDoc[index]
		table.insert(
			sources,
			string.format(
				'  - { sha256: "%s", grams: %d%s }',
				serde.hash("sha256", doc.text),
				kept,
				if fetched then ", fetched: " .. fetched else ""
			)
		)
	end
	local list: { string } = {}
	for hash in hashes do
		table.insert(list, hash)
	end
	table.sort(list)
	local fp = if #list > 0 then table.concat(list, "\n") .. "\n" else ""
	local meta = table.concat({
		"version: 1",
		"set: " .. options.set,
		"n: " .. M.N,
		"algo: " .. M.ALGO,
		'salt: "' .. salt .. '"',
		"normalization: " .. M.NORMALIZATION,
		"boilerplateDocFraction: " .. tostring(fraction),
		'generator: "' .. M.GENERATOR .. '"',
		"sources:",
		table.concat(sources, "\n"),
		"count: " .. #list,
		'fpSha256: "' .. serde.hash("sha256", fp) .. '"',
	}, "\n") .. "\n"
	return fp, meta, nil
end

--- Hashes a reviewed list of proper names into banned-names `hashedNames`
--- entries ({ code points, hash }), sorted and de-duplicated.
function M.hashNames(names: { string }, salt: string): ({ { any } }?, string?)
	local seen: { [string]: boolean } = {}
	local out: { { any } } = {}
	for index, name in names do
		local chars, err = M.skeleton(name)
		if chars == nil then
			return nil, "name #" .. tostring(index) .. ": " .. tostring(err)
		end
		if #chars == 0 then
			continue
		end
		local hash: string = M.hash12(salt, table.concat(chars))
		local id = tostring(#chars) .. ":" .. hash
		if not seen[id] then
			seen[id] = true
			local entry: { any } = { #chars, hash }
			table.insert(out, entry)
		end
	end
	table.sort(out, function(a, b)
		if a[1] ~= b[1] then
			return a[1] < b[1]
		end
		return a[2] < b[2]
	end)
	return out, nil
end

export type FingerprintSet = { id: string, salt: string, n: number, hashes: { [string]: boolean }, count: number }

--- Validates a .fp/.meta.yml pair and returns the loaded set, or the reason
--- it is refused (format violation, tampering or a parameter mismatch).
function M.loadSet(id: string, files: SetFiles, n: number): (FingerprintSet?, string?)
	if files.fp == nil or files.meta == nil then
		return nil, "fingerprint set " .. id .. " is missing (.fp and .meta.yml required)"
	end
	local fp = files.fp :: string
	local meta, decodeErr = decodeYaml(files.meta :: string)
	if not isMapping(meta) then
		return nil, id .. ".meta.yml does not decode: " .. tostring(decodeErr)
	end
	local unknown = unknownKeys(meta, {
		"version",
		"set",
		"n",
		"algo",
		"salt",
		"normalization",
		"boilerplateDocFraction",
		"generator",
		"sources",
		"count",
		"fpSha256",
	})
	if #unknown > 0 then
		return nil, id .. ".meta.yml has unknown keys: " .. table.concat(unknown, ", ")
	end
	if meta.version ~= 1 or meta.set ~= id then
		return nil, id .. ".meta.yml: version must be 1 and set must be " .. id
	end
	if meta.n ~= n or meta.algo ~= M.ALGO or meta.normalization ~= M.NORMALIZATION then
		return nil, string.format("%s.meta.yml: n/algo/normalization must be %d/%s/%s", id, n, M.ALGO, M.NORMALIZATION)
	end
	if type(meta.salt) ~= "string" or meta.salt == "" then
		return nil, id .. ".meta.yml: salt must be a non-empty string"
	end
	if meta.fpSha256 ~= serde.hash("sha256", fp) then
		return nil, id .. ".fp does not match fpSha256 in its meta (tampered or stale)"
	end
	local hashes: { [string]: boolean } = {}
	local count = 0
	local previous = ""
	local lineNo = 0
	for line in string.gmatch(fp, "([^\n]*)\n") do
		lineNo += 1
		if #line ~= 12 or not string.match(line, "^[0-9a-f]+$") then
			return nil, string.format("%s.fp line %d is not a 12-hex hash", id, lineNo)
		end
		if line <= previous then
			return nil, string.format("%s.fp line %d is not sorted and unique", id, lineNo)
		end
		previous = line
		hashes[line] = true
		count += 1
	end
	if #fp > 0 and string.sub(fp, -1) ~= "\n" then
		return nil, id .. ".fp must end with a newline"
	end
	if meta.count ~= count then
		return nil, string.format("%s.meta.yml count %s does not match %d lines", id, tostring(meta.count), count)
	end
	return { id = id, salt = meta.salt, n = n, hashes = hashes, count = count }, nil
end

-- Policy and name lists ------------------------------------------------------

export type Policy = {
	track: string,
	allowedSources: { [string]: boolean },
	n: number,
	sets: { string },
	dialogueKeyPrefixes: { string },
	allowTools: { [string]: boolean },
	allowRecipes: { [string]: { [string]: boolean } },
	licensedKinds: { [string]: boolean },
	denyTools: { [string]: boolean },
}

local function toSet(list: { string }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, item in list do
		set[item] = true
	end
	return set
end

--- Parses provenance/policy.yml. Any unknown key, a version other than 1 or
--- an n other than 8 is refused so a policy can never silently weaken.
function M.parsePolicy(raw: any): (Policy?, { string })
	local errors: { string } = {}
	if not isMapping(raw) then
		return nil, { "policy: expected mapping" }
	end
	for _, key in unknownKeys(raw, { "version", "track", "allowedSources", "ngram", "dialogueKeyPrefixes", "assets" }) do
		table.insert(errors, "policy: unknown key " .. key)
	end
	if raw.version ~= 1 then
		table.insert(errors, "policy.version must be 1")
	end
	if raw.track ~= "original" and raw.track ~= "license" then
		table.insert(errors, "policy.track must be original or license")
	end
	if not stringList(raw.allowedSources) or #raw.allowedSources == 0 then
		table.insert(errors, "policy.allowedSources must be a non-empty list of strings")
	else
		for _, source in raw.allowedSources do
			local licensed = string.match(source, "^licensed:[%w%._%-]+$") ~= nil
			if source ~= "original" and not (raw.track == "license" and licensed) then
				table.insert(
					errors,
					"policy.allowedSources: " .. source .. " is not allowed on track " .. tostring(raw.track)
				)
			end
		end
	end
	local ngram = raw.ngram
	if not isMapping(ngram) then
		table.insert(errors, "policy.ngram must be a mapping")
	else
		for _, key in unknownKeys(ngram, { "n", "sets" }) do
			table.insert(errors, "policy.ngram: unknown key " .. key)
		end
		if ngram.n ~= M.N then
			table.insert(errors, "policy.ngram.n must be " .. M.N)
		end
		if not stringList(ngram.sets) or #ngram.sets == 0 then
			table.insert(errors, "policy.ngram.sets must be a non-empty list of set ids")
		else
			for _, id in ngram.sets do
				if not string.match(id, "^[%w%._%-]+$") then
					table.insert(errors, "policy.ngram.sets: invalid set id")
				end
			end
		end
	end
	if not stringList(raw.dialogueKeyPrefixes) then
		table.insert(errors, "policy.dialogueKeyPrefixes must be a list of strings")
	end
	local assets = raw.assets
	if not isMapping(assets) then
		table.insert(errors, "policy.assets must be a mapping")
	else
		for _, key in unknownKeys(assets, { "allowTools", "allowRecipes", "licensedKinds", "denyTools" }) do
			table.insert(errors, "policy.assets: unknown key " .. key)
		end
		for _, key in { "allowTools", "licensedKinds", "denyTools" } do
			if not stringList(assets[key]) then
				table.insert(errors, "policy.assets." .. key .. " must be a list of strings")
			end
		end
		if stringList(assets.allowTools) then
			for _, tool in assets.allowTools do
				if licenses.denialReason(tool) ~= nil then
					table.insert(errors, "policy.assets.allowTools: " .. tool .. " is denied by the license registry")
				end
			end
		end
		if assets.allowRecipes ~= nil then
			if not isMapping(assets.allowRecipes) then
				table.insert(errors, "policy.assets.allowRecipes must be a mapping")
			else
				local allowTools = if stringList(assets.allowTools) then toSet(assets.allowTools) else {}
				for tool, recipes in assets.allowRecipes do
					if not allowTools[tool] then
						table.insert(
							errors,
							"policy.assets.allowRecipes: " .. tostring(tool) .. " is not in allowTools"
						)
					end
					if not stringList(recipes) then
						table.insert(errors, "policy.assets.allowRecipes." .. tostring(tool) .. " must be a list")
					end
				end
			end
		end
	end
	if #errors > 0 then
		table.sort(errors)
		return nil, errors
	end
	local allowRecipes: { [string]: { [string]: boolean } } = {}
	for tool, recipes in assets.allowRecipes or {} do
		allowRecipes[tool] = toSet(recipes)
	end
	return {
		track = raw.track,
		allowedSources = toSet(raw.allowedSources),
		n = ngram.n,
		sets = table.clone(ngram.sets),
		dialogueKeyPrefixes = table.clone(raw.dialogueKeyPrefixes),
		allowTools = toSet(assets.allowTools),
		allowRecipes = allowRecipes,
		licensedKinds = toSet(assets.licensedKinds),
		denyTools = toSet(assets.denyTools),
	}, {}
end

export type Names = {
	terms: { string },
	stems: { string },
	letters: { string },
	salt: string,
	hashedByLength: { [number]: { [string]: boolean } },
}

local function skeletonList(errors: { string }, label: string, raw: any): { string }
	local out: { string } = {}
	if raw == nil then
		return out
	end
	if not stringList(raw) then
		table.insert(errors, "banned-names." .. label .. " must be a list of strings")
		return out
	end
	for index, value in raw do
		local chars, err = M.skeleton(value)
		if chars == nil or #chars == 0 then
			table.insert(
				errors,
				string.format("banned-names.%s[%d]: %s", label, index, err or "normalizes to an empty string")
			)
		else
			table.insert(out, table.concat(chars))
		end
	end
	return out
end

--- Parses provenance/banned-names.yml into normalized matchers.
function M.parseNames(raw: any): (Names?, { string })
	if not isMapping(raw) then
		return nil, { "banned-names: expected mapping" }
	end
	local errors: { string } = {}
	for _, key in unknownKeys(raw, { "version", "terms", "stems", "singleLetter", "hashedNames" }) do
		table.insert(errors, "banned-names: unknown key " .. key)
	end
	if raw.version ~= 1 then
		table.insert(errors, "banned-names.version must be 1")
	end
	local terms = skeletonList(errors, "terms", raw.terms)
	local stems = skeletonList(errors, "stems", raw.stems)
	local letters: { string } = {}
	if raw.singleLetter ~= nil then
		if not stringList(raw.singleLetter) then
			table.insert(errors, "banned-names.singleLetter must be a list of strings")
		else
			for index, letter in raw.singleLetter do
				if not string.match(letter, "^%u$") then
					table.insert(errors, string.format("banned-names.singleLetter[%d] must be one A-Z letter", index))
				else
					table.insert(letters, letter)
				end
			end
		end
	end
	local salt = ""
	local hashedByLength: { [number]: { [string]: boolean } } = {}
	local hashed = raw.hashedNames
	if hashed ~= nil then
		if not isMapping(hashed) then
			table.insert(errors, "banned-names.hashedNames must be a mapping")
		else
			for _, key in unknownKeys(hashed, { "algo", "salt", "entries" }) do
				table.insert(errors, "banned-names.hashedNames: unknown key " .. key)
			end
			if hashed.algo ~= M.ALGO then
				table.insert(errors, "banned-names.hashedNames.algo must be " .. M.ALGO)
			end
			if type(hashed.salt) ~= "string" or hashed.salt == "" then
				table.insert(errors, "banned-names.hashedNames.salt must be a non-empty string")
			else
				salt = hashed.salt
			end
			if not isList(hashed.entries) then
				table.insert(errors, "banned-names.hashedNames.entries must be a list")
			else
				for index, entry in hashed.entries do
					local length = if type(entry) == "table" then entry[1] else nil
					local hash = if type(entry) == "table" then entry[2] else nil
					if
						type(length) ~= "number"
						or length < 1
						or length ~= math.floor(length)
						or type(hash) ~= "string"
						or #hash ~= 12
						or not string.match(hash, "^[0-9a-f]+$")
					then
						table.insert(
							errors,
							string.format("banned-names.hashedNames.entries[%d] must be [length, 12-hex]", index)
						)
					else
						hashedByLength[length] = hashedByLength[length] or {}
						hashedByLength[length][hash] = true
					end
				end
			end
		end
	end
	if #errors > 0 then
		table.sort(errors)
		return nil, errors
	end
	return { terms = terms, stems = stems, letters = letters, salt = salt, hashedByLength = hashedByLength }, {}
end

-- Pack check -----------------------------------------------------------------

type Ctx = {
	pack: string,
	findings: { Finding },
	names: Names,
	sets: { FingerprintSet },
	allow: { [string]: boolean },
	strings: number,
	entries: number,
	assets: number,
}

type ScanRules = { ngram: boolean, letter: boolean }

local function add(findings: { Finding }, rule: string, file: string, locator: string, detail: string)
	table.insert(findings, { rule = rule, file = file, locator = locator, detail = detail })
end

local function scanText(ctx: Ctx, file: string, locator: string, text: string, rules: ScanRules)
	ctx.strings += 1
	local chars, err = M.skeleton(text)
	if chars == nil then
		add(ctx.findings, "NAME-ENCODING", file, locator, tostring(err))
		return
	end
	local skeleton = table.concat(chars)
	for index, term in ctx.names.terms do
		if string.find(skeleton, term, 1, true) then
			add(ctx.findings, "NAME-TERM", file, locator, "matched banned term #" .. index)
		end
	end
	for index, stem in ctx.names.stems do
		if string.find(skeleton, stem, 1, true) then
			add(ctx.findings, "NAME-STEM", file, locator, "matched banned stem #" .. index)
		end
	end
	local lengths: { number } = {}
	for length in ctx.names.hashedByLength do
		table.insert(lengths, length)
	end
	table.sort(lengths)
	for _, length in lengths do
		local hashes = ctx.names.hashedByLength[length]
		for first = 1, #chars - length + 1 do
			local hash = M.hash12(ctx.names.salt, table.concat(chars, "", first, first + length - 1))
			if hashes[hash] then
				add(ctx.findings, "NAME-HASHED", file, locator, "matched hashed name " .. hash)
				break
			end
		end
	end
	if rules.letter then
		for index, letter in ctx.names.letters do
			if M.standaloneLetter(text, letter) then
				add(ctx.findings, "NAME-LETTER", file, locator, "standalone single-letter name #" .. index)
			end
		end
	end
	if rules.ngram then
		for _, set in ctx.sets do
			if #chars < set.n then
				continue
			end
			local matched = 0
			for _, gram in M.grams(chars, set.n) do
				local hash = M.hash12(set.salt, gram)
				if set.hashes[hash] and not ctx.allow[file .. "|" .. locator .. "|" .. hash] then
					matched += 1
				end
			end
			if matched > 0 then
				add(
					ctx.findings,
					"PROV-NGRAM",
					file,
					locator,
					string.format("%d reference %d-grams matched (set %s)", matched, set.n, set.id)
				)
			end
		end
	end
end

type Leaf = { locator: string, text: string, key: string? }

local function collectStrings(value: any, path: string, key: string?, out: { Leaf })
	if type(value) == "string" then
		table.insert(out, { locator = path, text = value, key = key })
	elseif type(value) == "table" then
		if isList(value) then
			for index, item in value do
				collectStrings(item, path .. "[" .. index .. "]", key, out)
			end
		else
			for _, name in sortedKeys(value) do
				collectStrings(value[name], if path == "" then name else path .. "." .. name, name, out)
			end
		end
	end
end

local function scanYaml(ctx: Ctx, file: string, decoded: any, ngram: boolean, letterKey: string?)
	local leaves: { Leaf } = {}
	collectStrings(decoded, "", nil, leaves)
	for _, leaf in leaves do
		scanText(ctx, file, leaf.locator, leaf.text, {
			ngram = ngram,
			letter = letterKey ~= nil and leaf.key == letterKey,
		})
	end
end

local function validDate(value: any): boolean
	if type(value) ~= "string" then
		return false
	end
	local y, m, d = string.match(value, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if y == nil then
		return false
	end
	local year, month, day = tonumber(y) :: number, tonumber(m) :: number, tonumber(d) :: number
	if month < 1 or month > 12 or day < 1 then
		return false
	end
	local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	local leap = (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
	local limit = if month == 2 and leap then 29 else days[month]
	return day <= limit
end

local function validAuthor(value: any): boolean
	if type(value) ~= "string" then
		return false
	end
	local body = string.match(value, "^human:(.+)$") or string.match(value, "^agent:(.+)$")
	return body ~= nil and #body <= 64 and string.match(body, "^[%w%._/@%-]+$") ~= nil
end

local function checkRecord(ctx: Ctx, policy: Policy, file: string, locator: string, record: any, defaults: any)
	ctx.entries += 1
	if not isMapping(record) then
		add(ctx.findings, "PROV-FIELD", file, locator, "entry must be a mapping")
		return
	end
	for _, key in unknownKeys(record, { "source", "author", "created", "note" }) do
		add(ctx.findings, "PROV-FIELD", file, locator, "unknown field " .. key)
	end
	local source = if record.source ~= nil then record.source else defaults.source
	local author = if record.author ~= nil then record.author else defaults.author
	if type(source) ~= "string" or not policy.allowedSources[source] then
		add(ctx.findings, "PROV-FIELD", file, locator, "source must be one of policy.allowedSources")
	end
	if not validAuthor(author) then
		add(ctx.findings, "PROV-FIELD", file, locator, "author must be human:<handle> or agent:<model>/<run>")
	end
	if not validDate(record.created) then
		add(ctx.findings, "PROV-FIELD", file, locator, "created must be a valid YYYY-MM-DD date")
	end
	if record.note ~= nil and (type(record.note) ~= "string" or #record.note > 256) then
		add(ctx.findings, "PROV-FIELD", file, locator, "note must be a string of at most 256 bytes")
	end
end

-- Parses a yaml sidecar (version/defaults/entries) and returns its entries.
local function readSidecar(ctx: Ctx, file: string, text: string?): ({ [string]: any }?, any)
	if text == nil then
		add(ctx.findings, "PROV-MISSING", file, "file", "sidecar file is missing")
		return nil, nil
	end
	local decoded, err = decodeYaml(text)
	if not isMapping(decoded) then
		add(ctx.findings, "PROV-FIELD", file, "file", "does not decode: " .. tostring(err))
		return nil, nil
	end
	for _, key in unknownKeys(decoded, { "version", "defaults", "entries" }) do
		add(ctx.findings, "PROV-FIELD", file, key, "unknown key")
	end
	if decoded.version ~= 1 then
		add(ctx.findings, "PROV-FIELD", file, "version", "version must be 1")
	end
	local defaults = decoded.defaults or {}
	if not isMapping(defaults) then
		add(ctx.findings, "PROV-FIELD", file, "defaults", "defaults must be a mapping")
		defaults = {}
	else
		for _, key in unknownKeys(defaults, { "source", "author" }) do
			add(ctx.findings, "PROV-FIELD", file, "defaults." .. key, "only source and author may have defaults")
		end
	end
	local entries = decoded.entries or {}
	if not isMapping(entries) or (next(entries) ~= nil and isList(entries)) then
		add(ctx.findings, "PROV-FIELD", file, "entries", "entries must be a mapping")
		return nil, nil
	end
	return entries, defaults
end

local function coverage(
	ctx: Ctx,
	policy: Policy,
	file: string,
	sourceFile: string,
	expected: { string },
	entries: { [string]: any },
	defaults: any
)
	local expectedSet = toSet(expected)
	for _, key in expected do
		if entries[key] == nil then
			add(ctx.findings, "PROV-MISSING", file, key, "no provenance entry for " .. sourceFile .. " " .. key)
		end
	end
	for _, key in sortedKeys(entries) do
		if not expectedSet[key] then
			add(ctx.findings, "PROV-STALE", file, key, "entry points at nothing in " .. sourceFile)
		else
			checkRecord(ctx, policy, file, key, entries[key], defaults)
		end
	end
end

local function contentUnits(content: any): { string }
	local units: { string } = {}
	for _, section in CONTENT_CATALOGS do
		local list = content[section]
		if isList(list) then
			for _, entry in list do
				if isMapping(entry) and type(entry.id) == "string" then
					table.insert(units, section .. "/" .. entry.id)
				end
			end
		end
	end
	for _, section in CONTENT_SCALARS do
		if content[section] ~= nil then
			table.insert(units, "sections/" .. section)
		end
	end
	return units
end

local function econUnits(econ: any): { string }
	local units: { string } = {}
	for _, key in sortedKeys(econ) do
		if key == "genre_contract" then
			local configs = if isMapping(econ.genre_contract) then econ.genre_contract.configs else nil
			if isMapping(configs) then
				for _, genre in sortedKeys(configs) do
					if isMapping(configs[genre]) then
						for _, field in sortedKeys(configs[genre]) do
							table.insert(units, "genre_contract.configs." .. genre .. "." .. field)
						end
					end
				end
			end
		elseif key == "monetization" then
			local monetization = econ.monetization
			if isMapping(monetization) then
				for _, category in sortedKeys(monetization) do
					local list = monetization[category]
					if isList(list) then
						for _, product in list do
							local id = if isMapping(product) then product.key or product.id else nil
							if id ~= nil then
								table.insert(units, "monetization." .. category .. "." .. tostring(id))
							end
						end
					end
				end
			end
		else
			table.insert(units, key)
		end
	end
	return units
end

local function checkLocale(ctx: Ctx, policy: Policy, files: { [string]: string })
	local stringsText = files[M.FILES.locale]
	if stringsText == nil then
		return
	end
	local file = M.FILES.locale
	local rows = localesync.parseCsv(stripCsvBom(stringsText))
	local header: { string } = rows[1] or {}
	local keyIndex: number? = nil
	local scanColumns: { { index: number, name: string } } = {}
	for index, name in header do
		local column = trim(name)
		if column == "Key" then
			keyIndex = index
		elseif column ~= "Context" then
			table.insert(scanColumns, { index = index, name = column })
		end
	end
	if keyIndex == nil then
		add(ctx.findings, "PROV-FIELD", file, "header", "missing Key column")
		return
	end
	local keys: { string } = {}
	for rowIndex = 2, #rows do
		local row = rows[rowIndex]
		if blankRow(row) then
			continue
		end
		local key = trim(row[keyIndex :: number] or "")
		if key == "" then
			continue
		end
		table.insert(keys, key)
		local dialogue = false
		for _, prefix in policy.dialogueKeyPrefixes do
			if string.sub(key, 1, #prefix) == prefix then
				dialogue = true
			end
		end
		for _, column in scanColumns do
			local cell = row[column.index] or ""
			if trim(cell) ~= "" then
				scanText(
					ctx,
					file,
					"Key=" .. key .. "[" .. column.name .. "]",
					cell,
					{ ngram = true, letter = dialogue }
				)
			end
		end
	end

	local provFile = M.FILES.localeProv
	local provText = files[provFile]
	if provText == nil then
		add(ctx.findings, "PROV-MISSING", provFile, "file", "sidecar file is missing")
		return
	end
	local provRows = localesync.parseCsv(stripCsvBom(provText))
	local provHeader = provRows[1] or {}
	for index, name in LOCALE_PROV_HEADER do
		if trim(provHeader[index] or "") ~= name then
			add(
				ctx.findings,
				"PROV-FIELD",
				provFile,
				"header",
				"header must be " .. table.concat(LOCALE_PROV_HEADER, ",")
			)
			return
		end
	end
	if #provHeader ~= #LOCALE_PROV_HEADER then
		add(ctx.findings, "PROV-FIELD", provFile, "header", "header must be " .. table.concat(LOCALE_PROV_HEADER, ","))
		return
	end
	local entries: { [string]: any } = {}
	for rowIndex = 2, #provRows do
		local row = provRows[rowIndex]
		if blankRow(row) then
			continue
		end
		local key = trim(row[1] or "")
		if entries[key] ~= nil then
			add(ctx.findings, "PROV-FIELD", provFile, "Key=" .. key, "duplicate Key")
		else
			entries[key] = { source = trim(row[2] or ""), author = trim(row[3] or ""), created = trim(row[4] or "") }
		end
	end
	coverage(ctx, policy, provFile, file, keys, entries, {})
end

local function checkAssets(ctx: Ctx, policy: Policy, manifest: any)
	local file = M.FILES.manifest
	local assets = if isMapping(manifest) then manifest.assets else nil
	if assets == nil then
		return
	end
	if not isList(assets) then
		add(ctx.findings, "ASSET-PROV", file, "assets", "assets must be a list")
		return
	end
	for index, asset in assets do
		ctx.assets += 1
		if not isMapping(asset) then
			add(ctx.findings, "ASSET-PROV", file, "assets[" .. index .. "]", "asset must be a mapping")
			continue
		end
		local key = if type(asset.key) == "string" then asset.key else "assets[" .. index .. "]"
		local locator = "key=" .. key
		for _, field in { "key", "source" } do
			if type(asset[field]) == "string" then
				scanText(ctx, file, locator .. "." .. field, asset[field], { ngram = false, letter = false })
			end
		end
		local tool = if type(asset.tool) == "string" then asset.tool else ""
		local provenance = asset.provenance
		local recipe = if isMapping(provenance) and isMapping(provenance.recipe) then provenance.recipe else {}
		local provider = if isMapping(provenance) and isMapping(provenance.provider) then provenance.provider else {}
		local rights = if isMapping(provenance) and isMapping(provenance.rights) then provenance.rights else {}

		if policy.denyTools[tool] or licenses.denialReason(tool) ~= nil then
			add(ctx.findings, "ASSET-TOOL", file, locator, "tool " .. tool .. " is denied")
		elseif policy.allowTools[tool] then
			if provider.name ~= tool then
				add(ctx.findings, "ASSET-TOOL", file, locator, "provenance.provider.name must equal tool " .. tool)
			end
			local recipes = policy.allowRecipes[tool]
			if recipes ~= nil and not recipes[recipe.id] then
				add(
					ctx.findings,
					"ASSET-TOOL",
					file,
					locator,
					"recipe.id " .. tostring(recipe.id) .. " is not allowed for " .. tool
				)
			end
		else
			local licensedKind = type(asset.kind) == "string" and policy.licensedKinds[asset.kind] == true
			local evidenced = licenses.rights(tool) ~= nil or isMapping(rights.evidence)
			if not (licensedKind and rights.ownership == "licensed" and evidenced) then
				add(
					ctx.findings,
					"ASSET-TOOL",
					file,
					locator,
					"tool "
						.. tool
						.. " is not in policy.allowTools and is not a licensed "
						.. "provider for a licensedKinds asset with rights evidence"
				)
			end
		end

		if not isMapping(provenance) then
			add(ctx.findings, "ASSET-PROV", file, locator, "missing provenance block")
		else
			if not validAuthor(provenance.author) then
				add(ctx.findings, "ASSET-PROV", file, locator, "provenance.author must be human:/agent:")
			end
			if not validDate(provenance.created) then
				add(ctx.findings, "ASSET-PROV", file, locator, "provenance.created must be YYYY-MM-DD")
			end
		end
	end
end

local function parseAllow(ctx: Ctx, text: string?)
	if text == nil then
		return
	end
	local file = M.FILES.allow
	local decoded, err = decodeYaml(text)
	if not isMapping(decoded) then
		add(ctx.findings, "PROV-POLICY", file, "file", "does not decode: " .. tostring(err))
		return
	end
	for _, key in unknownKeys(decoded, { "version", "entries" }) do
		add(ctx.findings, "PROV-POLICY", file, key, "unknown key")
	end
	if decoded.version ~= 1 then
		add(ctx.findings, "PROV-POLICY", file, "version", "version must be 1")
	end
	local entries = decoded.entries or {}
	if not isList(entries) then
		add(ctx.findings, "PROV-POLICY", file, "entries", "entries must be a list")
		return
	end
	for index, entry in entries do
		local locator = "entries[" .. index .. "]"
		if
			not isMapping(entry)
			or #unknownKeys(entry, { "file", "locator", "gramHash", "reason", "reviewer" }) > 0
			or type(entry.file) ~= "string"
			or type(entry.locator) ~= "string"
			or type(entry.gramHash) ~= "string"
			or type(entry.reason) ~= "string"
			or entry.reason == ""
		then
			add(ctx.findings, "PROV-POLICY", file, locator, "entry needs file, locator, gramHash, reason, reviewer")
		elseif type(entry.reviewer) ~= "string" or string.match(entry.reviewer, "^human:[%w%._/@%-]+$") == nil then
			add(ctx.findings, "PROV-POLICY", file, locator, "ignored: reviewer must be human:<handle>")
		else
			ctx.allow[entry.file .. "|" .. entry.locator .. "|" .. entry.gramHash] = true
		end
	end
end

local function compareFindings(a: Finding, b: Finding): boolean
	if a.file ~= b.file then
		return a.file < b.file
	end
	if a.locator ~= b.locator then
		return a.locator < b.locator
	end
	if a.rule ~= b.rule then
		return a.rule < b.rule
	end
	return a.detail < b.detail
end

--- Judges one opted-in pack. `files` maps pack-relative paths (M.FILES) to
--- raw text for the files that exist; `sets` maps policy set ids to their
--- fingerprint files. Findings are sorted, so the report is deterministic.
function M.checkPack(pack: string, files: { [string]: string }, sets: { [string]: SetFiles }): Report
	local findings: { Finding } = {}
	local report: Report = {
		ok = false,
		pack = pack,
		findings = findings,
		strings = 0,
		entries = 0,
		assets = 0,
		sets = {},
	}
	local policyText = files[M.FILES.policy]
	if policyText == nil then
		add(findings, "PROV-POLICY", M.FILES.policy, "file", "policy file is missing")
		return report
	end
	local decodedPolicy, policyErr = decodeYaml(policyText)
	local policy, policyErrors = M.parsePolicy(decodedPolicy)
	if policy == nil then
		if policyErr then
			add(findings, "PROV-POLICY", M.FILES.policy, "file", "does not decode: " .. policyErr)
		end
		for _, err in policyErrors do
			add(findings, "PROV-POLICY", M.FILES.policy, "policy", err)
		end
		table.sort(findings, compareFindings)
		return report
	end
	local bannedText = files[M.FILES.banned]
	local names: Names? = nil
	if bannedText == nil then
		add(findings, "PROV-POLICY", M.FILES.banned, "file", "banned-names file is missing")
	else
		local decodedNames, namesErr = decodeYaml(bannedText)
		local parsed, nameErrors = M.parseNames(decodedNames)
		if namesErr then
			add(findings, "PROV-POLICY", M.FILES.banned, "file", "does not decode: " .. namesErr)
		end
		for _, err in nameErrors do
			add(findings, "PROV-POLICY", M.FILES.banned, "names", err)
		end
		names = parsed
	end
	local loaded: { FingerprintSet } = {}
	for _, id in policy.sets do
		local set, setErr = M.loadSet(id, sets[id] or {}, policy.n)
		if set == nil then
			add(findings, "PROV-FP", "provenance/fingerprints/" .. id, "set", tostring(setErr))
		else
			table.insert(loaded, set)
			table.insert(report.sets, id)
		end
	end
	if names == nil or #loaded ~= #policy.sets then
		-- Without every matcher a pass would be meaningless: stop here.
		table.sort(findings, compareFindings)
		return report
	end

	local ctx: Ctx = {
		pack = pack,
		findings = findings,
		names = names,
		sets = loaded,
		allow = {},
		strings = 0,
		entries = 0,
		assets = 0,
	}
	parseAllow(ctx, files[M.FILES.allow])

	local function decodeSurface(file: string): any
		local text = files[file]
		if text == nil then
			return nil
		end
		local decoded, err = decodeYaml(text)
		if decoded == nil and err ~= nil then
			if utf8.len(text) == nil then
				add(findings, "NAME-ENCODING", file, "file", "invalid UTF-8")
			else
				add(findings, "PROV-FIELD", file, "file", "does not decode: " .. err)
			end
		end
		return decoded
	end

	for _, file in { M.FILES.game, M.FILES.econ, M.FILES.deploy } do
		local decoded = decodeSurface(file)
		if decoded ~= nil then
			scanYaml(ctx, file, decoded, true, nil)
		end
	end
	local content = decodeSurface(M.FILES.content)
	if content ~= nil then
		scanYaml(ctx, M.FILES.content, content, true, "speaker")
		local entries, defaults = readSidecar(ctx, M.FILES.contentProv, files[M.FILES.contentProv])
		if entries ~= nil then
			coverage(ctx, policy, M.FILES.contentProv, M.FILES.content, contentUnits(content), entries, defaults)
		end
	end
	local econText = files[M.FILES.econ]
	local econ = if econText ~= nil then decodeYaml(econText) else nil
	if isMapping(econ) then
		local entries, defaults = readSidecar(ctx, M.FILES.econProv, files[M.FILES.econProv])
		if entries ~= nil then
			coverage(ctx, policy, M.FILES.econProv, M.FILES.econ, econUnits(econ), entries, defaults)
		end
	end
	checkLocale(ctx, policy, files)
	local manifest = decodeSurface(M.FILES.manifest)
	if manifest ~= nil then
		checkAssets(ctx, policy, manifest)
	end

	report.strings = ctx.strings
	report.entries = ctx.entries
	report.assets = ctx.assets
	table.sort(findings, compareFindings)
	report.ok = #findings == 0
	return report
end

--- One finding per line: `<pack>: <file>:<locator>: <RULE> <detail>`.
function M.formatFinding(pack: string, finding: Finding): string
	return string.format("%s: %s:%s: %s %s", pack, finding.file, finding.locator, finding.rule, finding.detail)
end

return M
