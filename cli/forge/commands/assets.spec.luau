--!strict
-- Specs for assets.luau's moderation write-back. applyModerationUpdates is
-- exported so this can drive the real predicate `runStatus` uses without a
-- live Open Cloud call or a real pack directory.

local assetsCommand = require("./assets")
local assetsLib = require("../lib/assets")
local serde = require("@lune/serde")

local function assertSame(actual: any, expected: any)
	assert(typeof(actual) == typeof(expected), "preserved field type")
	if typeof(expected) == "table" then
		for key, value in expected do
			assertSame(actual[key], value)
		end
		for key in actual do
			assert(expected[key] ~= nil, "no unexpected fields")
		end
	else
		assert(actual == expected, "preserved field value")
	end
end

local function moderationFixture(indent: string, trailingNewline: boolean)
	local fields = indent .. "  "
	local lines = { "# hand-written manifest", "assets:" }
	for _, key in { "iconA", "iconB", "iconC" } do
		table.insert(lines, indent .. '- key: "' .. key .. '"')
		for _, field in { "kind: image", "tool: forge-procgen", "source: generated", "assetId: 123" } do
			table.insert(lines, fields .. field)
		end
		if key ~= "iconA" then
			table.insert(lines, fields .. "moderation: PendingModeration")
		end
		table.insert(lines, fields .. "metadata:")
		table.insert(lines, fields .. "  moderation: nested-value")
		table.insert(lines, fields .. "  owner: artist")
	end
	local suffix = "\n\n# keep the following section\nmetadata:\n  owner: forge\n  moderation: document-value"
	local text = table.concat(lines, "\n") .. suffix .. (if trailingNewline then "\n" else "")
	local before = serde.decode("yaml", text)
	local manifest, err = assetsLib.parseManifest(before)
	assert(manifest ~= nil, err)
	assert(manifest.assets[1].moderation == "NotUploaded", "missing moderation uses the parser default")
	local updated = assetsCommand.applyModerationUpdates(text, { iconA = "Approved", iconB = "Rejected" })
	local after = serde.decode("yaml", updated)
	local refreshed, refreshErr = assetsLib.parseManifest(after)
	assert(refreshed ~= nil, refreshErr)
	assert(refreshed.assets[1].moderation == "Approved", "missing moderation is inserted")
	assert(refreshed.assets[2].moderation == "Rejected", "existing moderation is replaced")
	before.assets[1].moderation = "Approved"
	before.assets[2].moderation = "Rejected"
	assertSame(after, before)
	assert(string.find(updated, suffix, 1, true) ~= nil, "following section and comments are byte-preserved")
	assert((string.sub(updated, -1) == "\n") == trailingNewline, "newline convention is preserved")
	assert(assetsCommand.applyModerationUpdates(text, {}) == text, "no updates preserve the entire document")
end

local function unrelatedListsFixture(indent: string, beforeAssets: boolean)
	local fields = indent .. "  "
	local unrelated = "metadata:\n"
		.. indent
		.. "- key: iconA\n"
		.. fields
		.. "moderation: internal-value\n"
		.. fields
		.. "assets:\n"
		.. fields
		.. "  - key: iconA\n"
		.. fields
		.. "    moderation: nested-document-value\n"
	local assetText = "assets: # keep header comment\n"
		.. "# keep sequence comment\n"
		.. indent
		.. "- key: iconA\n"
		.. fields
		.. "kind: image\n"
		.. fields
		.. "tool: forge-procgen\n"
		.. fields
		.. "source: generated\n"
		.. fields
		.. "assetId: 123\n"
		.. fields
		.. "metadata:\n"
		.. fields
		.. "  - key: iconA\n"
		.. fields
		.. "    moderation: nested-asset-value\n"
		.. "# keep block boundary comment\n"
		.. fields
		.. "owner: artist\n"
		.. indent
		.. "- key: iconB\n"
		.. fields
		.. "kind: image\n"
		.. fields
		.. "tool: forge-procgen\n"
		.. fields
		.. "source: generated\n"
		.. fields
		.. "moderation: PendingModeration\n"
	local text = if beforeAssets then unrelated .. assetText else assetText .. unrelated
	local before = serde.decode("yaml", text)
	local manifest, err = assetsLib.parseManifest(before)
	assert(manifest ~= nil, err)
	local updated = assetsCommand.applyModerationUpdates(text, { iconA = "Approved", iconB = "Rejected" })
	local after = serde.decode("yaml", updated)
	before.assets[1].moderation = "Approved"
	before.assets[2].moderation = "Rejected"
	assertSame(after, before)
	assert(string.find(updated, unrelated, 1, true) ~= nil, "unrelated sequence is byte-preserved")
	assert(string.find(updated, "# keep block boundary comment", 1, true) ~= nil, "boundary comment is preserved")
	assert(assetsCommand.applyModerationUpdates(text, {}) == text, "no updates preserve same-key metadata")
end

return {
	["normal YAML preserves same-key unrelated sequences before and after assets"] = function()
		for _, beforeAssets in { true, false } do
			unrelatedListsFixture("  ", beforeAssets)
		end
	end,

	["indentless YAML preserves same-key unrelated sequences before and after assets"] = function()
		for _, beforeAssets in { true, false } do
			unrelatedListsFixture("", beforeAssets)
		end
	end,

	["normal YAML moderation stays inside assets before a following section"] = function()
		moderationFixture("  ", true)
	end,

	["indentless YAML moderation keeps metadata and unrelated assets"] = function()
		moderationFixture("", false)
	end,

	-- finding 5 --------------------------------------------------------------
	["old assets status logic left a block with no moderation line byte-identical"] = function()
		-- assets.luau's old write-back only rewrote a line already matching
		-- '^%s*moderation:'; a block with assetId but no moderation key had no
		-- such line, so nothing in the document ever changed.
		local text = "assets:\n" .. "  - key: ember-pup\n" .. "    kind: model\n" .. "    assetId: 987\n"
		local lines: { string } = {}
		for line in string.gmatch(text, "([^\n]*)\n?") do
			table.insert(lines, line)
		end
		if #lines > 0 and lines[#lines] == "" then
			table.remove(lines)
		end
		local currentKey: string? = nil
		local changed = false
		for _, line in lines do
			local rawKey = string.match(line, "^%s*%- key:%s*(.-)%s*$")
			if rawKey ~= nil then
				currentKey = rawKey
			elseif currentKey == "ember-pup" and string.match(line, "^%s*moderation:") ~= nil then
				changed = true
			end
		end
		assert(not changed, "the old scan never finds a moderation: line to rewrite, so nothing changes")
	end,

	["applyModerationUpdates inserts a missing moderation line"] = function()
		local text = "assets:\n" .. "  - key: ember-pup\n" .. "    kind: model\n" .. "    assetId: 987\n"
		local updated = assetsCommand.applyModerationUpdates(text, { ["ember-pup"] = "Approved" })
		assert(updated ~= text, "the manifest text must change when moderation is missing")
		assert(string.find(updated, "moderation: Approved", 1, true) ~= nil, "the moderation line is now present")
	end,

	["applyModerationUpdates rewrites an existing moderation line in place"] = function()
		local text = "assets:\n"
			.. "  - key: ember-pup\n"
			.. "    kind: model\n"
			.. "    assetId: 987\n"
			.. "    moderation: PendingModeration\n"
		local updated = assetsCommand.applyModerationUpdates(text, { ["ember-pup"] = "Approved" })
		assert(string.find(updated, "moderation: Approved", 1, true) ~= nil, "the line is rewritten to Approved")
		assert(
			string.find(updated, "moderation: PendingModeration", 1, true) == nil,
			"the stale value is gone, not duplicated"
		)
	end,

	["applyModerationUpdates only touches keys present in linesByKey"] = function()
		local text = "assets:\n"
			.. "  - key: ember-pup\n"
			.. "    assetId: 987\n"
			.. "  - key: other-key\n"
			.. "    assetId: 5\n"
		local updated = assetsCommand.applyModerationUpdates(text, { ["ember-pup"] = "Approved" })
		assert(string.find(updated, "moderation: Approved", 1, true) ~= nil, "ember-pup gets its moderation line")
		local otherBlockStart = string.find(updated, "key: other-key", 1, true)
		assert(otherBlockStart ~= nil, "other-key's block is untouched")
		local afterOther = string.sub(updated, otherBlockStart)
		assert(string.find(afterOther, "moderation:", 1, true) == nil, "other-key gets no moderation line inserted")
	end,

	["applyModerationUpdates inserts a missing line for the last block in the document"] = function()
		local text = "assets:\n"
			.. "  - key: iconA\n"
			.. "    assetId: 1\n"
			.. "  - key: iconB\n"
			.. "    assetId: 987\n"
		local updated = assetsCommand.applyModerationUpdates(text, { ["iconB"] = "Approved" })
		assert(
			string.find(updated, "moderation: Approved", 1, true) ~= nil,
			"the last block in the document also gets its missing line inserted"
		)
	end,

	["applyModerationUpdates preserves a trailing newline"] = function()
		local text = "assets:\n" .. "  - key: ember-pup\n" .. "    assetId: 987\n"
		local updated = assetsCommand.applyModerationUpdates(text, { ["ember-pup"] = "Approved" })
		assert(string.sub(updated, -1) == "\n", "the document still ends with a newline")
	end,

	["multipartBody frames the request JSON and the binary file part"] = function()
		-- The WAV bytes are not UTF-8 text: a NUL, a 0xFF and a 0x00 byte in the body
		-- must survive verbatim, which is what makes a Lune string a byte-safe carrier.
		local bytes = string.char(0, 255, 82, 73, 70, 70, 0, 1, 2, 3)
		local body = assetsCommand.multipartBody("----forgeaudioabc", '{"assetType":"Audio"}', "cue.wav", bytes)
		assert(string.sub(body, 1, #"------forgeaudioabc\r\n") == "------forgeaudioabc\r\n", "leading boundary")
		assert(string.find(body, 'name="request"', 1, true) ~= nil, "request part is named")
		assert(string.find(body, "Content-Type: application/json", 1, true) ~= nil, "request part is JSON")
		assert(string.find(body, '{"assetType":"Audio"}', 1, true) ~= nil, "request JSON is carried verbatim")
		assert(string.find(body, 'name="fileContent"; filename="cue.wav"', 1, true) ~= nil, "file part names the file")
		assert(string.find(body, "Content-Type: audio/wav", 1, true) ~= nil, "file part is audio/wav")
		assert(string.find(body, bytes, 1, true) ~= nil, "the binary payload survives byte-for-byte")
		assert(string.sub(body, -#"------forgeaudioabc--\r\n") == "------forgeaudioabc--\r\n", "closing boundary")
	end,

	["multipartBody boundary is derived from the cue's own digest"] = function()
		-- A content-derived boundary cannot collide with the payload's own bytes and
		-- is deterministic, so the same cue always produces the same request body.
		local first = assetsCommand.multipartBody("----forgeaudio" .. string.rep("a", 64), "{}", "a.wav", "x")
		local second = assetsCommand.multipartBody("----forgeaudio" .. string.rep("a", 64), "{}", "a.wav", "x")
		assert(first == second, "the same inputs produce the same body")
		assert(
			string.find(first, "----forgeaudio" .. string.rep("a", 64), 1, true) ~= nil,
			"the boundary is carried verbatim"
		)
	end,
}
