--!strict
-- Specs for assets.luau's moderation write-back. applyModerationUpdates is
-- exported so this can drive the real predicate `runStatus` uses without a
-- live Open Cloud call or a real pack directory.

local assetsCommand = require("./assets")
local assetsLib = require("../lib/assets")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local tempdir = require("../lib/tempdir")

-- upload-images batch fixture: a scratch pack with four PNG image entries and
-- one already-published sfx entry, driven through assets.run with a mocked
-- transport. No Open Cloud request ever leaves the process.
local IMAGE_KEYS = { "iconA", "iconB", "iconC", "iconD" }

local function uploadFixture(test: (root: string, packDir: string) -> ())
	local root = tempdir.root() .. "/forge-upload-batch-" .. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
	local packDir = root .. "/batchpack"
	local ok, reason = xpcall(function()
		fs.writeDir(packDir .. "/assets/icons")
		fs.writeDir(packDir .. "/src/shared")
		local lines = {
			"assets:",
			"  - key: cueA",
			"    kind: sfx",
			"    tool: forge-procgen",
			"    source: generated",
			"    assetId: 5",
			"    moderation: Approved",
		}
		for _, key in IMAGE_KEYS do
			fs.writeFile(packDir .. "/assets/icons/" .. key .. ".png", "\137PNG fixture " .. key)
			for _, line in
				{
					"  - key: " .. key,
					"    kind: image",
					"    tool: forge-procgen",
					"    source: generated",
					"    path: assets/icons/" .. key .. ".png",
				}
			do
				table.insert(lines, line)
			end
		end
		fs.writeFile(packDir .. "/assets/manifest.yml", table.concat(lines, "\n") .. "\n")
		test(root, packDir)
	end, debug.traceback)
	local cleaned, cleanupError = pcall(function()
		if fs.isDir(root) then
			fs.removeDir(root)
		end
	end)
	assert(cleaned, tostring(cleanupError))
	assert(ok, tostring(reason))
end

-- Mocked Open Cloud: each create returns a fresh operation that finishes at
-- once as an Approved Image asset, so no delivery round-trip is needed.
local function mockTransport(): (assetsCommand.UploadDeps, { creates: { string }, calls: number })
	local state = { creates = {} :: { string }, calls = 0 }
	local nextId = 1000
	return {
		request = function(params: any): any
			state.calls += 1
			if params.method == "POST" then
				nextId += 1
				table.insert(state.creates, string.match(params.body, '"displayName":"([^"]+)"') or "?")
				return {
					ok = true,
					statusCode = 200,
					body = serde.encode("json", { path = "operations/op" .. tostring(nextId) }),
				}
			end
			local op = string.match(params.url, "operations/op(%d+)$")
			assert(op ~= nil, "unexpected request " .. tostring(params.url))
			return {
				ok = true,
				statusCode = 200,
				body = serde.encode("json", {
					done = true,
					response = {
						assetId = op,
						assetType = "Image",
						moderationResult = { moderationState = "Approved" },
					},
				}),
			}
		end,
		wait = function(_seconds: number) end,
		env = { ROBLOX_API_KEY = "test-key" } :: { [string]: string? },
	},
		state
end

local function uploadArgs(root: string, packDir: string, extra: { string }): { string }
	local args = {
		"assets",
		"upload-images",
		"--pack-dir",
		packDir,
		"--cache",
		root .. "/image-upload-cache.json",
		"--creator-user",
		"1234567891",
	}
	for _, arg in extra do
		table.insert(args, arg)
	end
	return args
end

local function manifestIds(packDir: string): ({ [string]: number }, assetsLib.Manifest)
	local manifest, err = assetsLib.parseManifest(serde.decode("yaml", fs.readFile(packDir .. "/assets/manifest.yml")))
	assert(manifest ~= nil, err)
	local ids: { [string]: number } = {}
	for _, asset in manifest.assets do
		ids[asset.key] = asset.assetId
	end
	return ids, manifest
end

local function assertFullCodegen(packDir: string)
	local _, manifest = manifestIds(packDir)
	local expected = assetsLib.renderLuau(manifest, "batchpack")
	assert(fs.readFile(packDir .. "/src/shared/Assets.luau") == expected, "Assets.luau equals full-manifest codegen")
end

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

	["upload creator comes from flags or the environment, never a built-in id"] = function()
		-- Synthetic ids only: the framework must not carry a real group or user id.
		local flagGroup, flagErr = assetsCommand.resolveCreator(1234567890, nil, {})
		assert(flagErr == nil, tostring(flagErr))
		local group = flagGroup :: assetsCommand.Creator
		assert(group.kind == "group" and group.id == 1234567890, "--creator-group wins")

		local flagUser, userErr = assetsCommand.resolveCreator(nil, 1234567891, {})
		assert(userErr == nil, tostring(userErr))
		local user = flagUser :: assetsCommand.Creator
		assert(user.kind == "user" and user.id == 1234567891, "--creator-user wins")

		local fromEnv, envErr = assetsCommand.resolveCreator(nil, nil, { FORGE_ROBLOX_CREATOR_GROUP_ID = "1234567890" })
		assert(envErr == nil, tostring(envErr))
		assert((fromEnv :: assetsCommand.Creator).id == 1234567890, "FORGE_ROBLOX_CREATOR_GROUP_ID is used")

		local fromUserEnv, userEnvErr =
			assetsCommand.resolveCreator(nil, nil, { FORGE_ROBLOX_CREATOR_USER_ID = "1234567891" })
		assert(userEnvErr == nil, tostring(userEnvErr))
		local envUser = fromUserEnv :: assetsCommand.Creator
		assert(envUser.kind == "user" and envUser.id == 1234567891, "FORGE_ROBLOX_CREATOR_USER_ID is used")

		-- A flag beats the environment, and a missing or contradictory creator is refused.
		local override, overrideErr =
			assetsCommand.resolveCreator(1234567890, nil, { FORGE_ROBLOX_CREATOR_USER_ID = "1234567891" })
		assert(overrideErr == nil and (override :: assetsCommand.Creator).kind == "group", "a flag beats the env")
		local missing, missingErr = assetsCommand.resolveCreator(nil, nil, {})
		assert(missing == nil and missingErr ~= nil, "no creator is refused, never defaulted")
		local both, bothErr = assetsCommand.resolveCreator(1234567890, 1234567891, {})
		assert(both == nil and bothErr ~= nil, "two creator flags are refused")
		local bothEnv, bothEnvErr = assetsCommand.resolveCreator(nil, nil, {
			FORGE_ROBLOX_CREATOR_GROUP_ID = "1234567890",
			FORGE_ROBLOX_CREATOR_USER_ID = "1234567891",
		})
		assert(bothEnv == nil and bothEnvErr ~= nil, "two creator env vars are refused")
		local zero, zeroErr = assetsCommand.resolveCreator(nil, nil, { FORGE_ROBLOX_CREATOR_GROUP_ID = "0" })
		assert(zero == nil and zeroErr ~= nil, "a non-positive env creator is refused")
	end,

	["upload-images --limit 2 uploads exactly two pending images and keeps the rest pending"] = function()
		uploadFixture(function(root, packDir)
			local deps, state = mockTransport()
			local ok = assetsCommand.run(uploadArgs(root, packDir, { "--limit", "2" }), nil, deps)
			assert(ok == true, "limited batch succeeds")
			assert(#state.creates == 2, "exactly two creates, got " .. tostring(#state.creates))
			assert(state.creates[1] == "iconA" and state.creates[2] == "iconB", "manifest order")
			local ids = manifestIds(packDir)
			assert(ids.iconA > 0 and ids.iconB > 0, "first two recorded")
			assert(ids.iconC == 0 and ids.iconD == 0, "remaining images stay pending")
			assert(ids.cueA == 5, "non-image entry untouched")
			assertFullCodegen(packDir)
			local generated = fs.readFile(packDir .. "/src/shared/Assets.luau")
			assert(string.find(generated, '["cueA"] = 5', 1, true) ~= nil, "partial run keeps other entries")

			-- The next batch skips what is already uploaded and takes the rest.
			local deps2, state2 = mockTransport()
			assert(
				assetsCommand.run(uploadArgs(root, packDir, { "--limit", "2" }), nil, deps2) == true,
				"second batch succeeds"
			)
			assert(
				#state2.creates == 2 and state2.creates[1] == "iconC" and state2.creates[2] == "iconD",
				"second batch takes the next two"
			)
			local deps3, state3 = mockTransport()
			assert(
				assetsCommand.run(uploadArgs(root, packDir, { "--limit", "2" }), nil, deps3) == true,
				"empty batch succeeds"
			)
			assert(state3.calls == 0, "nothing left to upload makes no request")
			assertFullCodegen(packDir)
		end)
	end,

	["upload-images --only uploads only the listed keys"] = function()
		uploadFixture(function(root, packDir)
			local deps, state = mockTransport()
			assert(
				assetsCommand.run(uploadArgs(root, packDir, { "--only", "iconC,iconA" }), nil, deps) == true,
				"--only succeeds"
			)
			assert(#state.creates == 2, "two creates")
			assert(state.creates[1] == "iconA" and state.creates[2] == "iconC", "listed keys in manifest order")
			local ids = manifestIds(packDir)
			assert(ids.iconA > 0 and ids.iconC > 0 and ids.iconB == 0 and ids.iconD == 0, "only listed keys")
			assertFullCodegen(packDir)

			local combined, combinedState = mockTransport()
			assert(
				assetsCommand.run(uploadArgs(root, packDir, { "--only", "iconB,iconD", "--limit", "1" }), nil, combined)
			)
			assert(#combinedState.creates == 1 and combinedState.creates[1] == "iconB", "--only with --limit")

			local unknown, unknownState = mockTransport()
			local unknownOk = assetsCommand.run(uploadArgs(root, packDir, { "--only", "cueA" }), nil, unknown)
			assert(unknownOk == false and unknownState.calls == 0, "a non-image key is refused before any request")
		end)
	end,

	["upload-images partial run renders the same Assets.luau as a full-manifest codegen"] = function()
		uploadFixture(function(root, packDir)
			local deps = mockTransport()
			assert(
				assetsCommand.run(uploadArgs(root, packDir, { "--limit", "1" }), nil, deps) == true,
				"partial batch succeeds"
			)
			local partial = fs.readFile(packDir .. "/src/shared/Assets.luau")
			-- The real `assets codegen` over the same full manifest (and so the same
			-- cached ids) must render byte-identical output.
			fs.removeFile(packDir .. "/src/shared/Assets.luau")
			assert(
				assetsCommand.run({ "assets", "codegen", "--pack", "batchpack" }, { packsDir = root }) == true,
				"codegen succeeds"
			)
			assert(fs.readFile(packDir .. "/src/shared/Assets.luau") == partial, "same cache, same codegen")
			assertFullCodegen(packDir)
			assert(string.find(partial, '["iconA"]', 1, true) ~= nil, "uploaded image is resolved")
			assert(string.find(partial, '["cueA"] = 5', 1, true) ~= nil, "untouched entry kept")
		end)
	end,

	["upload-images invalid --limit is a usage error with exit 2"] = function()
		uploadFixture(function(root, packDir)
			for _, value in { "0", "-1", "1.5", "abc", "inf" } do
				local deps, state = mockTransport()
				local ok, code = assetsCommand.run(uploadArgs(root, packDir, { "--limit", value }), nil, deps)
				assert(ok == false and code == 2, "--limit " .. value .. " exits 2")
				assert(state.calls == 0, "no request for --limit " .. value)
			end
			local ok, code = assetsCommand.run(uploadArgs(root, packDir, { "--only", "," }), nil, (mockTransport()))
			assert(ok == false and code == 2, "empty --only exits 2")
			local auditOk, auditCode =
				assetsCommand.run({ "assets", "upload-audio", "--limit", "2" }, nil, (mockTransport()))
			assert(auditOk == false and auditCode == 2, "--limit is upload-images only")
		end)
	end,

	["upload-images --dry-run --limit plans the batch with no request or write"] = function()
		uploadFixture(function(root, packDir)
			local before = fs.readFile(packDir .. "/assets/manifest.yml")
			local deps, state = mockTransport()
			local ok = assetsCommand.run(uploadArgs(root, packDir, { "--dry-run", "--limit", "3" }), nil, deps)
			assert(ok == true, "dry run succeeds")
			assert(state.calls == 0, "dry run makes no request")
			assert(fs.readFile(packDir .. "/assets/manifest.yml") == before, "manifest unchanged")
			assert(not fs.isFile(root .. "/image-upload-cache.json"), "no cache write")
			assert(not fs.isFile(packDir .. "/src/shared/Assets.luau"), "no codegen on dry run")
		end)
	end,
}
