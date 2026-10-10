--!strict
-- cliutil: pure helpers shared by cli/forge/commands/* for input validation and
-- manifest text editing. Nothing here touches the network or the filesystem, so
-- every rule can be covered by a spec without a real command run.

local M = {}

export type CommandContext = { packsDir: string?, genresDir: string?, reportsDir: string? }

-- ---------------------------------------------------------------------------
-- F3: finite numeric flag parsing (econ.luau --players/--days/--seed,
-- plan.luau --seed). `tonumber("inf")` and `tonumber("nan")` both parse to a
-- non-integer float that back then compares false against `< 1`, so a naive
-- `tonumber` + `math.floor` check lets `inf`/`nan` slip past a positivity
-- check and hang or silently no-op the simulator.
-- ---------------------------------------------------------------------------

--- Parses `text` as a finite integer (rejects `inf`, `-inf`, `nan`, and any
--- fractional value). Returns (nil, reason) when it is not.
function M.parseFiniteInt(text: string): (number?, string?)
	local value = tonumber(text)
	if value == nil then
		return nil, "'" .. text .. "' is not a number"
	end
	if value ~= value then
		return nil, "'" .. text .. "' is not a finite number (nan)"
	end
	if value == math.huge or value == -math.huge then
		return nil, "'" .. text .. "' is not a finite number (inf)"
	end
	if value % 1 ~= 0 then
		return nil, "'" .. text .. "' must be an integer"
	end
	return value, nil
end

-- ---------------------------------------------------------------------------
-- F9: the asset key pattern must match lib/assets.luau's KEY_PATTERN, which
-- allows hyphens (existing keys like `ember-pup`, `tidal-serpent`).
-- ---------------------------------------------------------------------------

-- Kept identical to lib/assets.luau's KEY_PATTERN (not required from there:
-- commands may not reach into lib/assets for this, and the pattern is a
-- stable, documented manifest contract in its own right).
M.KEY_PATTERN = "^[%a][%w_%-]*$"

--- True when `key` matches the manifest key contract (leading letter, then
--- letters/digits/underscore/hyphen).
function M.isValidKey(key: string): boolean
	return string.match(key, M.KEY_PATTERN) ~= nil
end

-- ---------------------------------------------------------------------------
-- F4: gen fulfill writes `key`/`kind`/`tool` straight into a YAML block. Any
-- of the three can contain a newline or a `: ` sequence that breaks out of its
-- own field and injects a sibling YAML key (a gate field like `moderation:`).
-- ---------------------------------------------------------------------------

--- True when `value` is safe to emit as a bare (unquoted) YAML scalar on its
--- own manifest line: no newline, and no ": " that could start a new key.
function M.isSafeYamlScalar(value: string): boolean
	if string.find(value, "\n", 1, true) ~= nil then
		return false
	end
	if string.find(value, ": ", 1, true) ~= nil then
		return false
	end
	-- A trailing ":" (e.g. "tool:") also reopens mapping parsing on re-read.
	if string.sub(value, -1) == ":" then
		return false
	end
	return true
end

-- ---------------------------------------------------------------------------
-- F10: a leading UTF-8 BOM (which Excel writes when a CSV is edited there)
-- must be stripped before the header row is parsed, or it merges into the
-- first header name.
-- ---------------------------------------------------------------------------

local UTF8_BOM = "\239\187\191"

--- Strips a leading UTF-8 BOM from `text`, if present.
function M.stripBom(text: string): string
	if string.sub(text, 1, #UTF8_BOM) == UTF8_BOM then
		return string.sub(text, #UTF8_BOM + 1)
	end
	return text
end

-- ---------------------------------------------------------------------------
-- F5: upsertAsset-style manifest block replacement. When replacing an
-- existing `- key: <k>` block, the old implementation ran to the next line
-- matching `^%s*%- key:` (unconditionally), so a trailing top-level comment
-- or blank line after the *last* block was folded into the replaced block and
-- lost. It also compared the matched key as a raw string, so a quoted key
-- (`- key: "ember-pup"`) never matched an unquoted lookup key.
-- ---------------------------------------------------------------------------

--- Strips one layer of matching single or double quotes from a YAML scalar.
function M.unquoteYamlKey(raw: string): string
	local trimmed = string.match(raw, "^%s*(.-)%s*$") or raw
	local doubleQuoted = string.match(trimmed, '^"(.*)"$')
	if doubleQuoted ~= nil then
		return doubleQuoted
	end
	local singleQuoted = string.match(trimmed, "^'(.*)'$")
	if singleQuoted ~= nil then
		return singleQuoted
	end
	return trimmed
end

--- Returns the 1-based indent width (leading spaces) of `line`.
local function indentWidth(line: string): number
	local spaces = string.match(line, "^( *)")
	return if spaces ~= nil then #spaces else 0
end

export type AssetSequence = { header: number?, first: number, limit: number, indent: string }

--- Bounds the top-level assets sequence; comments/blanks do not close it.
--- Headerless fragments are accepted only by preservation helpers, not editors.
function M.assetSequence(lines: { string }, allowFragment: boolean?): AssetSequence?
	local header: number? = nil
	local limit = #lines + 1
	local hasMapping = false
	for i, line in lines do
		if string.match(line, "^[^%s#%-]") then
			hasMapping = true
			if header ~= nil then
				limit = i
				break
			elseif
				string.match(line, "^assets:%s*$")
				or string.match(line, "^assets:%s+#")
				or string.match(line, "^assets:%s*%[%]%s*$")
			then
				header = i
			end
		end
	end
	if header == nil and (not allowFragment or hasMapping) then
		return nil
	end
	local first = if header ~= nil then header + 1 else 1
	local indent = "  "
	for i = first, limit - 1 do
		local itemIndent = string.match(lines[i], "^( *)%-%s")
		if itemIndent ~= nil then
			indent = itemIndent
			break
		end
	end
	return { header = header, first = first, limit = limit, indent = indent }
end

local function assetKey(line: string, sequence: AssetSequence): string?
	local indent, rawKey = string.match(line, "^( *)%- key:%s*(.-)%s*$")
	return if indent == sequence.indent and rawKey ~= nil then M.unquoteYamlKey(rawKey) else nil
end

--- Finds only a direct item of the top-level assets sequence.
function M.findKeyLine(lines: { string }, key: string): number?
	local sequence = M.assetSequence(lines)
	if sequence == nil then
		return nil
	end
	for i = sequence.first, sequence.limit - 1 do
		if assetKey(lines[i], sequence) == key then
			return i
		end
	end
	return nil
end

--- Finds the last line index of the block that starts at `lines[startIndex]`
--- (a `- key:` line): every following line belongs to the same block only
--- while it is indented *more* than the `- key:` line itself. A line at or
--- below that indent - another list item, a top-level comment, or a blank
--- line followed by a dedented line - ends the block, so trailing content
--- after the last entry is preserved instead of being swallowed.
function M.findBlockEnd(lines: { string }, startIndex: number): number
	local itemIndent = indentWidth(lines[startIndex])
	local lastIndex = startIndex
	for i = startIndex + 1, #lines do
		local line = lines[i]
		if string.match(line, "^%s*$") ~= nil then
			-- A blank line only extends the block if a later, still-nested line
			-- follows; otherwise stop before it so trailing blank lines are kept
			-- as document content rather than swallowed into the block.
			local nextNonBlank: number? = nil
			for j = i + 1, #lines do
				if string.match(lines[j], "^%s*$") == nil then
					nextNonBlank = j
					break
				end
			end
			if nextNonBlank == nil or indentWidth(lines[nextNonBlank]) <= itemIndent then
				break
			end
			lastIndex = i
		elseif indentWidth(line) > itemIndent then
			lastIndex = i
		else
			break
		end
	end
	return lastIndex
end

-- ---------------------------------------------------------------------------
-- F7: `forge plan` regenerating a pack truncates assets/manifest.yml to
-- `assets:\n` and lets gen procedural/launchart/audio re-add only the entries
-- their own (possibly shrunk) roster still produces. Any manually uploaded
-- asset id for a key that is still in the new roster must survive that
-- truncation; a key the new roster dropped is correctly left out (commit
-- 87ef33c's intentional reset of stale roster entries).
-- ---------------------------------------------------------------------------

--- Splits a manifest document into lines (no trailing empty element), mirroring
--- gen.luau's own splitLines so line numbers line up with findKeyLine/findBlockEnd.
function M.splitLines(text: string): { string }
	local lines: { string } = {}
	local start = 1
	while true do
		local newline = string.find(text, "\n", start, true)
		if newline == nil then
			table.insert(lines, string.sub(text, start))
			break
		end
		table.insert(lines, string.sub(text, start, newline - 1))
		start = newline + 1
	end
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

--- Returns the `- key: <k>` blocks of `manifestText` whose key is in `keep`
--- (a set of keys), each block's raw source lines joined back with "\n" and a
--- trailing newline, in the order they appeared in the document. Keys not in
--- `keep`, and any non-block content (top-level comments, the `assets:`
--- header), are dropped: the caller re-adds its own header and lets the gen
--- steps re-add every current-roster block.
function M.survivingBlocks(manifestText: string, keep: { [string]: boolean }): { string }
	local lines = M.splitLines(manifestText)
	local blocks: { string } = {}
	local sequence = M.assetSequence(lines, true)
	if sequence == nil then
		return blocks
	end
	local i = sequence.first
	while i < sequence.limit do
		local key = assetKey(lines[i], sequence)
		if key ~= nil then
			local lastIndex = M.findBlockEnd(lines, i)
			if keep[key] then
				local blockLines: { string } = {}
				for j = i, lastIndex do
					table.insert(blockLines, lines[j])
				end
				table.insert(blocks, table.concat(blockLines, "\n") .. "\n")
			end
			i = lastIndex + 1
		else
			i += 1
		end
	end
	return blocks
end

-- ---------------------------------------------------------------------------
-- H1/finding 1: `forge plan` keeps a manifest block whose key survives into
-- the new roster (survivingBlocks above), but then calls `gen procedural` ->
-- `gen launchart` -> `gen audio`, and each of those upserts a fresh
-- `assetId: 0` / `moderation: Approved` block for every procgen key, wiping
-- the id survivingBlocks just preserved. plan.luau snapshots each surviving
-- key's assetId/moderation before the gen steps with readAssetFields, then
-- reapplies them after with applyAssetFields for any key whose regenerated
-- block still reads assetId: 0 (a key the gen steps did not touch keeps its
-- own freshly-generated id).
-- ---------------------------------------------------------------------------

export type AssetFields = { assetId: string, moderation: string? }

--- Reads the raw `assetId:`/`moderation:` line values for every key in `keys`
--- present in `manifestText`. Values are returned as the exact trailing text
--- of each line (untyped: the caller already knows these are manifest
--- scalars), so this stays a pure text operation with no YAML decoding.
function M.readAssetFields(manifestText: string, keys: { [string]: boolean }): { [string]: AssetFields }
	local lines = M.splitLines(manifestText)
	local result: { [string]: AssetFields } = {}
	local sequence = M.assetSequence(lines, true)
	if sequence == nil then
		return result
	end
	local i = sequence.first
	while i < sequence.limit do
		local key = assetKey(lines[i], sequence)
		if key ~= nil then
			local lastIndex = M.findBlockEnd(lines, i)
			if keys[key] then
				local assetId: string? = nil
				local moderation: string? = nil
				for j = i + 1, lastIndex do
					local idValue = string.match(lines[j], "^" .. sequence.indent .. "  assetId:%s*(.-)%s*$")
					if idValue ~= nil then
						assetId = idValue
					end
					local modValue = string.match(lines[j], "^" .. sequence.indent .. "  moderation:%s*(.-)%s*$")
					if modValue ~= nil then
						moderation = modValue
					end
				end
				if assetId ~= nil then
					result[key] = { assetId = assetId, moderation = moderation }
				end
			end
			i = lastIndex + 1
		else
			i += 1
		end
	end
	return result
end

--- Rewrites the `assetId:`/`moderation:` lines of every `- key: <k>` block in
--- `manifestText` whose key is in `fields` AND whose current `assetId:` line
--- reads `0` (a freshly regenerated, never-uploaded block): the preserved
--- assetId replaces the `0`, and moderation is set when `fields[key]` carries
--- one. A block whose regenerated assetId is already non-zero (the gen step
--- produced its own id) is left untouched.
function M.applyAssetFields(manifestText: string, fields: { [string]: AssetFields }): string
	local lines = M.splitLines(manifestText)
	local hadTrailingNewline = string.sub(manifestText, -1) == "\n"
	local sequence = M.assetSequence(lines, true)
	if sequence == nil then
		return manifestText
	end
	local i = sequence.first
	while i < sequence.limit do
		local key = assetKey(lines[i], sequence)
		if key ~= nil then
			local lastIndex = M.findBlockEnd(lines, i)
			local currentFields = fields[key]
			if currentFields ~= nil then
				-- Only touch this block when its regenerated assetId still reads 0:
				-- otherwise the gen step produced its own id and both lines are left
				-- alone, matching the docstring.
				local isZero = false
				for j = i + 1, lastIndex do
					local idValue = string.match(lines[j], "^" .. sequence.indent .. "  assetId:%s*(.-)%s*$")
					if idValue == "0" then
						isZero = true
						break
					end
				end
				if isZero then
					for j = i + 1, lastIndex do
						local indent, idValue =
							string.match(lines[j], "^(" .. sequence.indent .. "  )assetId:%s*(.-)%s*$")
						if indent ~= nil and idValue == "0" then
							lines[j] = indent .. "assetId: " .. currentFields.assetId
						else
							local modIndent = string.match(lines[j], "^(" .. sequence.indent .. "  )moderation:")
							if modIndent ~= nil and currentFields.moderation ~= nil then
								lines[j] = modIndent .. "moderation: " .. currentFields.moderation
							end
						end
					end
				end
			end
			i = lastIndex + 1
		else
			i += 1
		end
	end
	return table.concat(lines, "\n") .. (if hadTrailingNewline then "\n" else "")
end

-- ---------------------------------------------------------------------------
-- finding 4(a): `forge plan --seed` accepted any finite integral double
-- (e.g. `1e300`), and `generatedBy` formatted it with `string.format("%d", ...)`,
-- which silently saturates to `-9223372036854775808` for a value outside a
-- 64-bit integer's range -- and, well before that overflow, outside the range
-- a double can represent exactly (2^53), so the recorded seed is not even the
-- one `planner.buildRoster` actually used. Bound the accepted seed to a range
-- both `%d` and double-exact arithmetic can round-trip.
-- ---------------------------------------------------------------------------

-- 2^53: the largest magnitude a double still represents every integer up to,
-- exactly. `%d` on a value beyond this has already lost precision before the
-- int64 conversion even runs.
M.SAFE_INT_LIMIT = 2 ^ 53

--- True when `value` is a finite integer whose magnitude is small enough that
--- both double arithmetic and `string.format("%d", value)` represent it
--- exactly (no precision loss, no int64 saturation).
function M.isSafeInteger(value: number): boolean
	if value ~= value or value == math.huge or value == -math.huge then
		return false
	end
	if value % 1 ~= 0 then
		return false
	end
	return math.abs(value) < M.SAFE_INT_LIMIT
end

-- ---------------------------------------------------------------------------
-- finding 4(b): `forge plan --teams`/`--debug-name`/`--gui-name` are recorded
-- unquoted in `generatedBy` (`%q` escapes for a Luau string literal, not for a
-- shell), so a value with embedded whitespace records a command a shell
-- splits into extra arguments, and a value with a comma silently changes the
-- recorded team count. Values must be a single shell word to round-trip.
-- ---------------------------------------------------------------------------

--- True when `value` is safe to record as a single unquoted token in a shell
--- command line: non-empty, no leading/trailing space (trimming would change
--- it silently), no embedded whitespace, comma, or quote character.
function M.isRecordableToken(value: string): boolean
	if value == "" then
		return false
	end
	if string.match(value, "^%s") ~= nil or string.match(value, "%s$") ~= nil then
		return false
	end
	if string.find(value, "[%s,\"']") ~= nil then
		return false
	end
	return true
end

return M
