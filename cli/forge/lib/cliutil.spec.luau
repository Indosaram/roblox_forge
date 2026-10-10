--!strict
-- Specs for cliutil: each case first reproduces the old command's inline
-- logic (as it stood before this change) to show it accepts/loses the bad
-- input, then asserts cliutil's version rejects/preserves it correctly.

local cliutil = require("./cliutil")
local serde = require("@lune/serde")

return {
	["preservation roundtrip ignores unrelated lists and nested asset fields"] = function()
		for _, indent in { "  ", "" } do
			local field = indent .. "  "
			local unrelated = "before:\n  - key: same\n    assetId: 11\n    moderation: Rejected\n"
			local trailing = "after:\n  - key: same\n    assetId: 0\n    moderation: Rejected\n"
			local asset = indent
				.. "- key: same\n"
				.. field
				.. "assetId: 123\n"
				.. field
				.. "moderation: PendingModeration\n"
				.. field
				.. "metadata:\n"
				.. field
				.. "  - key: same\n"
				.. field
				.. "    assetId: 999\n"
				.. field
				.. "    moderation: Rejected\n"
			local text = unrelated .. "assets:\n" .. asset .. trailing
			local fields = cliutil.readAssetFields(text, { same = true })
			assert(
				fields.same.assetId == "123" and fields.same.moderation == "PendingModeration",
				"direct fields captured"
			)
			local kept = cliutil.survivingBlocks(text, { same = true })
			assert(#kept == 1 and kept[1] == asset, "only actual asset block survives")
			local fragmentFields = cliutil.readAssetFields(table.concat(kept), { same = true })
			assert(fragmentFields.same.assetId == "123", "headerless fragment contract preserved")
			local fresh = unrelated .. "assets:\n" .. string.gsub(asset, "assetId: 123", "assetId: 0") .. trailing
			local restored = serde.decode("yaml", cliutil.applyAssetFields(fresh, fields))
			assert(
				restored.assets[1].assetId == 123 and restored.assets[1].moderation == "PendingModeration",
				"direct fields restored"
			)
			assert(
				restored.assets[1].metadata[1].assetId == 999
					and restored.assets[1].metadata[1].moderation == "Rejected",
				"nested fields preserved"
			)
			assert(restored.before[1].assetId == 11 and restored.after[1].assetId == 0, "unrelated IDs preserved")
			assert(
				restored.before[1].moderation == "Rejected" and restored.after[1].moderation == "Rejected",
				"unrelated moderation preserved"
			)
		end
	end,
	["preservation helpers do not treat metadata-only manifests as fragments"] = function()
		local text = "metadata:\n  - key: same\n    assetId: 0\n"
		assert(next(cliutil.readAssetFields(text, { same = true })) == nil, "no asset fields in metadata")
		assert(#cliutil.survivingBlocks(text, { same = true }) == 0, "no asset blocks in metadata")
		assert(
			cliutil.applyAssetFields(text, { same = { assetId = "123" } }) == text,
			"metadata-only document unchanged"
		)
	end,
	-- F3 -----------------------------------------------------------------
	["old econ.luau logic let --players inf through"] = function()
		-- econ.luau's old check: `local number = tonumber(value); ...
		-- players = math.floor(number)` then `if players < 1 ... refuse`.
		local old = tonumber("inf")
		assert(old ~= nil, "tonumber parses 'inf'")
		assert(not (math.floor(old :: number) < 1), "the old '< 1' guard does not catch inf")
	end,

	["parseFiniteInt rejects inf"] = function()
		local value, reason = cliutil.parseFiniteInt("inf")
		assert(value == nil, "inf must not parse")
		assert(reason ~= nil and string.find(reason, "inf", 1, true) ~= nil, "reason names inf")
	end,

	["old econ.luau logic let --players nan through"] = function()
		local old = tonumber("nan")
		assert(old ~= nil, "tonumber parses 'nan'")
		assert(not ((old :: number) < 1), "nan < 1 is false, so the old guard exits 0")
	end,

	["parseFiniteInt rejects nan"] = function()
		local value, reason = cliutil.parseFiniteInt("nan")
		assert(value == nil, "nan must not parse")
		assert(reason ~= nil and string.find(reason, "nan", 1, true) ~= nil, "reason names nan")
	end,

	["parseFiniteInt rejects a fractional value"] = function()
		local value = cliutil.parseFiniteInt("1.5")
		assert(value == nil, "a fractional value is not an integer")
	end,

	["parseFiniteInt accepts a normal integer"] = function()
		local value, reason = cliutil.parseFiniteInt("20")
		assert(value == 20, "20 parses to 20: " .. tostring(reason))
	end,

	-- F9 -------------------------------------------------------------------
	["old gen.luau KEY_PATTERN rejected a hyphenated key"] = function()
		local oldPattern = "^[%a][%w_]*$"
		assert(string.match("ember-pup", oldPattern) == nil, "the old pattern rejects hyphens")
	end,

	["isValidKey accepts a hyphenated key matching lib/assets.luau"] = function()
		assert(cliutil.isValidKey("ember-pup"), "ember-pup must be a valid key")
		assert(cliutil.isValidKey("tidal-serpent"), "tidal-serpent must be a valid key")
	end,

	["isValidKey still rejects a leading digit or embedded space"] = function()
		assert(not cliutil.isValidKey("9bad"), "a leading digit is invalid")
		assert(not cliutil.isValidKey("a b"), "an embedded space is invalid")
	end,

	-- F4 -------------------------------------------------------------------
	["isSafeYamlScalar rejects an embedded newline"] = function()
		assert(
			not cliutil.isSafeYamlScalar("trellis\n    moderation: Approved"),
			"a newline must not be a safe scalar (YAML field injection)"
		)
	end,

	["isSafeYamlScalar rejects an embedded ': ' sequence"] = function()
		assert(not cliutil.isSafeYamlScalar("a: b"), "a colon-space sequence can start a new mapping key")
	end,

	["isSafeYamlScalar accepts an ordinary tool name"] = function()
		assert(cliutil.isSafeYamlScalar("trellis"), "trellis is a safe scalar")
	end,

	-- F10 --------------------------------------------------------------------
	["old locale.luau header lookup failed on a BOM-prefixed CSV"] = function()
		local bomText = "\239\187\191Key,Source,Context,en-us,ko-kr\n"
		local firstHeader = string.match(bomText, "^([^,]*)")
		assert(firstHeader ~= "Key", "the BOM merges into the first header before stripping")
	end,

	["stripBom removes a leading UTF-8 BOM"] = function()
		local bomText = "\239\187\191Key,Source,Context,en-us,ko-kr\n"
		local stripped = cliutil.stripBom(bomText)
		local firstHeader = string.match(stripped, "^([^,]*)")
		assert(firstHeader == "Key", "after stripBom the first header reads 'Key'")
	end,

	["stripBom is a no-op without a BOM"] = function()
		local text = "Key,Source\n"
		assert(cliutil.stripBom(text) == text, "text without a BOM is unchanged")
	end,

	-- F5 -------------------------------------------------------------------
	["unquoteYamlKey strips double quotes"] = function()
		assert(cliutil.unquoteYamlKey('"ember-pup"') == "ember-pup", "double quotes are stripped")
	end,

	["unquoteYamlKey strips single quotes"] = function()
		assert(cliutil.unquoteYamlKey("'ember-pup'") == "ember-pup", "single quotes are stripped")
	end,

	["unquoteYamlKey passes through an unquoted key"] = function()
		assert(cliutil.unquoteYamlKey("ember-pup") == "ember-pup", "an unquoted key is unchanged")
	end,

	["old gen.luau raw string compare missed a quoted key"] = function()
		local line = '  - key: "ember-pup"'
		local matched = string.match(line, "^%s*%- key:%s*(.-)%s*$")
		assert(matched ~= "ember-pup", "the raw match still carries the quotes")
	end,

	["findKeyLine matches a quoted key against an unquoted lookup"] = function()
		local lines = { "assets:", '  - key: "ember-pup"', "    kind: mesh" }
		local found = cliutil.findKeyLine(lines, "ember-pup")
		assert(found == 2, "the quoted key line must be found")
	end,

	["old gen.luau block-end scan swallowed trailing content after the last block"] = function()
		local lines = {
			"assets:",
			"  - key: iconB",
			"    kind: image",
			"    tool: forge-procgen",
			"# notes: keep these",
			"# more notes",
		}
		-- old loop: `for i = startIndex+1, #lines do if matches '- key:' then break end;
		-- lastIndex = i end` -- with no other `- key:` line, it always runs to #lines.
		local lastIndex = 2
		for i = 3, #lines do
			if string.match(lines[i], "^%s*%- key:") then
				break
			end
			lastIndex = i
		end
		assert(lastIndex == #lines, "the old scan consumes the trailing comment block")
	end,

	["findBlockEnd stops before trailing top-level content"] = function()
		local lines = {
			"assets:",
			"  - key: iconB",
			"    kind: image",
			"    tool: forge-procgen",
			"# notes: keep these",
			"# more notes",
		}
		local lastIndex = cliutil.findBlockEnd(lines, 2)
		assert(lastIndex == 4, "the block ends at the last indented line, index 4, got " .. tostring(lastIndex))
	end,

	["findBlockEnd stops at the next list item"] = function()
		local lines = {
			"assets:",
			"  - key: iconA",
			"    kind: image",
			"  - key: iconB",
			"    kind: image",
		}
		local lastIndex = cliutil.findBlockEnd(lines, 2)
		assert(lastIndex == 3, "the block ends right before the next '- key:' line")
	end,

	["findBlockEnd treats an interior blank line as part of the block"] = function()
		local lines = {
			"assets:",
			"  - key: iconA",
			"    kind: image",
			"",
			"    tool: forge-procgen",
			"  - key: iconB",
		}
		local lastIndex = cliutil.findBlockEnd(lines, 2)
		assert(lastIndex == 5, "a blank line followed by more indented content stays in the block")
	end,

	-- F7 / H1 -------------------------------------------------------------
	["old plan.luau + gen procedural sequence lost an uploaded asset id"] = function()
		-- Reproduces the exact defect: survivingBlocks correctly keeps the block,
		-- but plan.luau's old code wrote it straight back with no snapshot, then
		-- gen procedural's upsertAsset (replace-the-whole-block) overwrote it with
		-- a fresh assetId: 0 block, same as gen.luau:128-147 against the
		-- "gen procedural" replacement block.
		local oldManifest = "assets:\n"
			.. "  - key: pyro-pup\n"
			.. "    kind: model\n"
			.. "    tool: studio-mcp\n"
			.. '    source: "hand upload"\n'
			.. "    assetId: 987\n"
			.. "    moderation: Approved\n"
		local kept = cliutil.survivingBlocks(oldManifest, { ["pyro-pup"] = true })
		local afterTruncation = "assets:\n" .. table.concat(kept, "")
		assert(string.find(afterTruncation, "assetId: 987", 1, true) ~= nil, "the id survives the truncation alone")

		-- gen procedural's upsertAsset replaces the whole block for a matching key
		-- (gen.luau upsertAsset): simulate that replacement directly with
		-- findKeyLine/findBlockEnd, the same primitives it uses.
		local lines = cliutil.splitLines(afterTruncation)
		local startIndex = cliutil.findKeyLine(lines, "pyro-pup")
		assert(startIndex ~= nil, "pyro-pup must still be found before the regen overwrite")
		local lastIndex = cliutil.findBlockEnd(lines, startIndex :: number)
		local regenBlock = {
			"  - key: pyro-pup",
			"    kind: model",
			"    tool: forge-procgen",
			'    source: "procedural creature/pyro"',
			"    assetId: 0",
			"    moderation: Approved",
		}
		local merged: { string } = {}
		for i = 1, (startIndex :: number) - 1 do
			table.insert(merged, lines[i])
		end
		for _, line in regenBlock do
			table.insert(merged, line)
		end
		for i = lastIndex + 1, #lines do
			table.insert(merged, lines[i])
		end
		local afterRegen = table.concat(merged, "\n") .. "\n"
		assert(
			string.find(afterRegen, "assetId: 987", 1, true) == nil,
			"without the fix, gen procedural's upsert wipes the preserved id back to 0"
		)
	end,

	["readAssetFields + applyAssetFields restore an id gen procedural wiped to 0"] = function()
		-- The fix plan.luau now applies: snapshot the surviving block's fields
		-- before truncation, then after the gen steps have overwritten the block
		-- with assetId: 0, reapply the snapshot.
		local survivingBlockText = "  - key: pyro-pup\n"
			.. "    kind: model\n"
			.. "    tool: studio-mcp\n"
			.. '    source: "hand upload"\n'
			.. "    assetId: 987\n"
			.. "    moderation: Approved\n"
		local preserved = cliutil.readAssetFields(survivingBlockText, { ["pyro-pup"] = true })
		assert(preserved["pyro-pup"] ~= nil, "the surviving block's fields must be captured")
		assert(preserved["pyro-pup"].assetId == "987", "the captured assetId is 987")
		assert(preserved["pyro-pup"].moderation == "Approved", "the captured moderation is Approved")

		local afterGenSteps = "assets:\n"
			.. "  - key: pyro-pup\n"
			.. "    kind: model\n"
			.. "    tool: forge-procgen\n"
			.. '    source: "procedural creature/pyro"\n'
			.. "    assetId: 0\n"
			.. "    moderation: Approved\n"
		local restored = cliutil.applyAssetFields(afterGenSteps, preserved)
		assert(string.find(restored, "assetId: 987", 1, true) ~= nil, "applyAssetFields restores the wiped id")
		assert(
			string.find(restored, "tool: forge-procgen", 1, true) ~= nil,
			"the regenerated tool/source/kind lines are left alone"
		)
	end,

	["applyAssetFields leaves a non-zero regenerated assetId alone"] = function()
		-- A gen step can legitimately produce its own non-zero assetId for a key
		-- (e.g. a future provider that uploads inline); applyAssetFields must not
		-- clobber that with a stale preserved value.
		local preserved: { [string]: cliutil.AssetFields } =
			{ ["pyro-pup"] = { assetId = "987", moderation = "Approved" } }
		local manifest = "assets:\n" .. "  - key: pyro-pup\n" .. "    assetId: 42\n" .. "    moderation: Approved\n"
		local restored = cliutil.applyAssetFields(manifest, preserved)
		assert(string.find(restored, "assetId: 42", 1, true) ~= nil, "a non-zero regenerated id is preserved as-is")
		assert(string.find(restored, "assetId: 987", 1, true) == nil, "the stale snapshot must not overwrite it")
	end,

	["applyAssetFields also leaves moderation alone on a block whose assetId is non-zero"] = function()
		-- Same guarantee as the id: a block the gen step already stamped with its
		-- own non-zero assetId keeps its own moderation value too, even though
		-- `fields` carries a snapshot for that key (from before the gen steps ran).
		local preserved: { [string]: cliutil.AssetFields } =
			{ ["pyro-pup"] = { assetId = "987", moderation = "Approved" } }
		local manifest = "assets:\n"
			.. "  - key: pyro-pup\n"
			.. "    assetId: 42\n"
			.. "    moderation: PendingModeration\n"
		local restored = cliutil.applyAssetFields(manifest, preserved)
		assert(string.find(restored, "assetId: 42", 1, true) ~= nil, "the non-zero id is preserved as-is")
		assert(
			string.find(restored, "moderation: PendingModeration", 1, true) ~= nil,
			"a block whose assetId is untouched must also keep its own moderation value"
		)
		assert(
			string.find(restored, "moderation: Approved", 1, true) == nil,
			"the stale snapshot's moderation must not overwrite the untouched block's own value"
		)
	end,

	["readAssetFields ignores keys outside the requested set"] = function()
		local manifest = "assets:\n"
			.. "  - key: pyro-pup\n"
			.. "    assetId: 987\n"
			.. "  - key: other-key\n"
			.. "    assetId: 5\n"
		local fields = cliutil.readAssetFields(manifest, { ["pyro-pup"] = true })
		assert(fields["pyro-pup"] ~= nil, "the requested key is captured")
		assert(fields["other-key"] == nil, "a key outside the requested set is not captured")
	end,

	["survivingBlocks keeps an uploaded asset id for a key still in the new roster"] = function()
		local oldManifest = "assets:\n"
			.. "  - key: pyro-pup\n"
			.. "    kind: model\n"
			.. "    tool: studio-mcp\n"
			.. '    source: "hand upload"\n'
			.. "    assetId: 987\n"
			.. "    moderation: Approved\n"
		local kept = cliutil.survivingBlocks(oldManifest, { ["pyro-pup"] = true })
		assert(#kept == 1, "exactly one block must survive")
		assert(string.find(kept[1], "assetId: 987", 1, true) ~= nil, "the uploaded assetId must be preserved")
		assert(
			string.find(kept[1], "moderation: Approved", 1, true) ~= nil,
			"the Approved moderation must be preserved"
		)
	end,

	["survivingBlocks drops a key the new roster no longer has"] = function()
		local oldManifest = "assets:\n"
			.. "  - key: retired-creature\n"
			.. "    kind: model\n"
			.. "    tool: studio-mcp\n"
			.. '    source: "x"\n'
			.. "    assetId: 5\n"
			.. "    moderation: Approved\n"
		local kept = cliutil.survivingBlocks(oldManifest, { ["pyro-pup"] = true })
		assert(#kept == 0, "a key dropped from the roster must not survive (commit 87ef33c's intentional reset)")
	end,

	["survivingBlocks keeps multiple surviving blocks in document order and matches a quoted key"] = function()
		local oldManifest = "assets:\n"
			.. '  - key: "pyro-pup"\n'
			.. "    assetId: 1\n"
			.. "  - key: retired\n"
			.. "    assetId: 2\n"
			.. "  - key: tidal-serpent\n"
			.. "    assetId: 3\n"
		local kept = cliutil.survivingBlocks(oldManifest, { ["pyro-pup"] = true, ["tidal-serpent"] = true })
		assert(#kept == 2, "two of the three blocks survive")
		assert(string.find(kept[1], "assetId: 1", 1, true) ~= nil, "the quoted key pyro-pup still matches")
		assert(string.find(kept[2], "assetId: 3", 1, true) ~= nil, "tidal-serpent is the second surviving block")
	end,

	-- finding 4(a) -----------------------------------------------------------
	["old plan.luau logic recorded a saturated int64 for an out-of-range seed"] = function()
		-- plan.luau's old code only ran the parsed seed through parseFiniteInt
		-- (finite + integral) before handing it to string.format("%d", seed).
		local seed = tonumber("1e300")
		assert(
			seed ~= nil and seed % 1 == 0 and seed == seed and seed ~= math.huge,
			"parseFiniteInt would accept 1e300"
		)
		local recorded = string.format("%d", seed :: number)
		assert(
			recorded == "-9223372036854775808",
			"without a bound, %d silently saturates 1e300 to the int64 minimum, got " .. recorded
		)
	end,

	["isSafeInteger rejects a seed outside the 2^53 double-precision range"] = function()
		assert(not cliutil.isSafeInteger(1e300), "1e300 is far outside the safe range")
		assert(not cliutil.isSafeInteger(2 ^ 53), "2^53 itself is excluded (the boundary is exclusive)")
		assert(not cliutil.isSafeInteger(-(2 ^ 60)), "a large negative magnitude is also rejected")
	end,

	["isSafeInteger accepts an ordinary seed"] = function()
		assert(cliutil.isSafeInteger(7), "7 is a normal seed")
		assert(cliutil.isSafeInteger(0), "0 is the default seed")
		assert(cliutil.isSafeInteger(-1000), "a small negative seed is fine")
	end,

	["isSafeInteger rejects nan and inf"] = function()
		assert(not cliutil.isSafeInteger(0 / 0), "nan is not a safe integer")
		assert(not cliutil.isSafeInteger(math.huge), "inf is not a safe integer")
	end,

	-- finding 4(b) -----------------------------------------------------------
	["old plan.luau logic recorded --teams unquoted, splittable by a shell"] = function()
		-- plan.luau's old generatedBy used %s (raw, unquoted) for the joined teams
		-- list, so an embedded space in a team name reopens as a second shell arg.
		local teams = { "Red, Blue" }
		local recorded = string.format("--teams %s", table.concat(teams, ","))
		assert(
			string.find(recorded, " ", 1, true) ~= nil,
			"the recorded flag value still contains a bare space a shell would split on"
		)
	end,

	["isRecordableToken rejects a value with an embedded space"] = function()
		assert(not cliutil.isRecordableToken("Red, Blue"), "an embedded space/comma cannot round-trip through a shell")
	end,

	["isRecordableToken rejects a value with a comma, quote, or surrounding whitespace"] = function()
		assert(
			not cliutil.isRecordableToken("Red,Blue"),
			"a comma inside one team name is ambiguous with the separator"
		)
		assert(not cliutil.isRecordableToken('Red"Blue'), "a double quote is not a safe bare token")
		assert(not cliutil.isRecordableToken(" Red"), "leading whitespace is not a safe bare token")
		assert(not cliutil.isRecordableToken("Red "), "trailing whitespace is not a safe bare token")
		assert(not cliutil.isRecordableToken(""), "an empty token is not recordable")
	end,

	["isRecordableToken accepts an ordinary team or binding name"] = function()
		assert(cliutil.isRecordableToken("Red"), "Red is a safe token")
		assert(cliutil.isRecordableToken("PlanDemoDebug"), "a PascalCase binding name is a safe token")
	end,
}
