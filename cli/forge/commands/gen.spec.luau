--!strict
-- Specs for generation manifest edits and fulfillment command validation.

local genCommand = require("./gen")
local genmanifest = require("./genmanifest")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local cliutil = require("../lib/cliutil")

local function fulfillmentFixture(test: (string, string, string) -> ())
	local root = (process.env.TEMP or process.env.TMP or "C:/Windows/Temp")
		.. "/forge-gen-fulfill-"
		.. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
	local requestPath = root .. "/request.json"
	local manifestPath = root .. "/fixture/assets/manifest.yml"
	local ok, reason = xpcall(function()
		fs.writeDir(root .. "/fixture/assets")
		fs.writeFile(manifestPath, "assets: []\n")
		test(root, requestPath, manifestPath)
	end, debug.traceback)
	local cleaned, cleanupError = pcall(function()
		if fs.isDir(root) then
			fs.removeDir(root)
		end
	end)
	assert(cleaned, tostring(cleanupError))
	assert(ok, tostring(reason))
end

local function editor(initial: string?)
	local text = initial
	return function(key: string)
		fulfillmentFixture(function(_, _, manifestPath)
			if text == nil then
				fs.removeFile(manifestPath)
			else
				fs.writeFile(manifestPath, text)
			end
			genmanifest.upsertAsset(
				manifestPath,
				key,
				"  - key: " .. key .. "\n    source: generated\n    assetId: 0\n    moderation: Approved\n"
			)
			text = fs.readFile(manifestPath)
		end)
		return serde.decode("yaml", (assert(text, "manifest was written"))), text
	end
end

local function unrelatedFixture(indent: string)
	local field = indent .. "  "
	local before = "before:\n  - key: same\n    owner: keep-before\n    assetId: 0\n"
	local after = "after:\n  - key: same\n    owner: keep-after\n    assetId: 0\n"
	local text = before
		.. "assets:\n"
		.. indent
		.. '- key: "same"\n'
		.. field
		.. "source: old\n"
		.. field
		.. "assetId: 123\n"
		.. field
		.. "metadata:\n"
		.. field
		.. "  - key: nested\n"
		.. field
		.. "    assetId: 999\n"
		.. indent
		.. "- key: neighbor\n"
		.. field
		.. "source: neighbor\n"
		.. after
	local upsert = editor(text)
	local replaced = upsert("same")
	assert(
		replaced.before[1].owner == "keep-before" and replaced.before[1].assetId == 0,
		"preceding metadata preserved"
	)
	assert(replaced.after[1].owner == "keep-after" and replaced.after[1].assetId == 0, "trailing metadata preserved")
	assert(#replaced.assets == 2 and replaced.assets[1].source == "generated", "actual asset replaced")
	assert(replaced.assets[2].source == "neighbor", "neighbor preserved")
	local appended = upsert("nested")
	assert(#appended.assets == 3 and appended.assets[3].key == "nested", "new asset appended inside sequence")
	assert(
		appended.before[1].owner == "keep-before" and appended.after[1].owner == "keep-after",
		"append preserves metadata"
	)
end

return {
	["actual generation roundtrip restores surviving uploaded fields"] = function()
		for _, indent in { "  ", "" } do
			local old = "assets:\n"
				.. indent
				.. "- key: same\n"
				.. indent
				.. "  assetId: 123\n"
				.. indent
				.. "  moderation: PendingModeration\n"
			local kept = cliutil.survivingBlocks(old, { same = true })
			local fields = cliutil.readAssetFields(table.concat(kept), { same = true })
			local _, generated = editor("assets:\n" .. table.concat(kept))("same")
			local restored = serde.decode("yaml", cliutil.applyAssetFields(generated, fields))
			assert(restored.assets[1].assetId == 123, "uploaded ID restored after actual upsert")
			assert(restored.assets[1].moderation == "PendingModeration", "moderation restored after actual upsert")
			assert(restored.assets[1].source == "generated", "generated fields retained")
		end
	end,
	["generation appends before trailing mapping without corrupting YAML"] = function()
		local doc = editor("assets:\n  - key: old\n    source: keep\nmetadata:\n  owner: keep\n")("new")
		assert(
			#doc.assets == 2 and doc.assets[1].source == "keep" and doc.assets[2].key == "new",
			"asset sequence extended"
		)
		assert(doc.metadata.owner == "keep", "trailing mapping preserved")
	end,
	["normal generation upserts only top-level assets before trailing metadata"] = function()
		unrelatedFixture("  ")
	end,
	["indentless generation preserves sequence indentation and unrelated keys"] = function()
		unrelatedFixture("")
	end,
	["generation appends a nested same-key without replacing nested metadata"] = function()
		local upsert = editor(
			"assets:\n  - key: parent\n    metadata:\n      - key: nested\n        owner: keep\nmetadata:\n  owner: document\n"
		)
		local doc = upsert("nested")
		assert(#doc.assets == 2 and doc.assets[2].key == "nested", "nested key is not a direct asset")
		assert(
			doc.assets[1].metadata[1].owner == "keep" and doc.metadata.owner == "document",
			"nested and document metadata preserved"
		)
	end,
	["generation creates missing assets and expands empty sequences in place"] = function()
		for _, text in
			{
				"",
				"metadata:\n  owner: keep\n",
				"assets: []\nmetadata:\n  owner: keep\n",
				"assets:\nmetadata:\n  owner: keep\n",
			}
		do
			local doc = editor(text)("new")
			assert(#doc.assets == 1 and doc.assets[1].key == "new", "new asset created")
			if text ~= "" then
				assert(doc.metadata.owner == "keep", "existing metadata preserved")
			end
		end
		assert(editor(nil)("new").assets[1].key == "new", "absent manifest created")
	end,
	["isValidFulfillRequest accepts a normal kind/tool pair"] = function()
		local ok, badField = genCommand.isValidFulfillRequest("mesh", "forge-procgen")
		assert(ok, "a normal kind/tool pair is valid: " .. tostring(badField))
	end,

	["fulfillment accepts a colon-bearing prompt and persists the request and asset"] = function()
		fulfillmentFixture(function(root, requestPath, manifestPath)
			local prompt = "Style: low-poly kaiju"
			fs.writeFile(
				requestPath,
				serde.encode("json", {
					pack = "fixture",
					kind = "mesh",
					tool = "forge-procgen",
					prompt = prompt,
					status = "pending",
				})
			)
			assert(
				genCommand.run(
					{ "gen", "fulfill", requestPath, "--key", "creature", "--asset-id", "123" },
					{ packsDir = root }
				),
				"valid fulfillment accepted"
			)
			local manifest = serde.decode("yaml", fs.readFile(manifestPath))
			assert(#manifest.assets == 1, "one asset appended")
			local asset = manifest.assets[1]
			assert(
				asset.key == "creature" and asset.kind == "mesh" and asset.tool == "forge-procgen",
				"asset fields persisted"
			)
			assert(asset.source == prompt, "quoted prompt roundtrips through YAML")
			assert(asset.assetId == 123 and asset.moderation == "PendingModeration", "uploaded asset awaits moderation")
			local request = serde.decode("json", fs.readFile(requestPath))
			assert(
				request.status == "fulfilled" and request.prompt == prompt,
				"request fulfilled without changing prompt"
			)
		end)
	end,

	["fulfillment rejects invalid inputs without writing the request or manifest"] = function()
		fulfillmentFixture(function(root, requestPath, manifestPath)
			local invalidInputs: { { kind: string?, tool: string?, key: string? } } = {
				{ kind = "mesh\n    moderation: Approved" },
				{ tool = "a: b" },
				{ kind = "unknown-kind" },
				{ tool = "unknown-tool" },
				{ key = "bad: key" },
			}
			for _, invalid in invalidInputs do
				local requestText = serde.encode("json", {
					pack = "fixture",
					kind = invalid.kind or "mesh",
					tool = invalid.tool or "forge-procgen",
					prompt = "Style: low-poly kaiju",
					status = "pending",
				})
				fs.writeFile(requestPath, requestText)
				local manifestText = fs.readFile(manifestPath)
				assert(
					not genCommand.run(
						{ "gen", "fulfill", requestPath, "--key", invalid.key or "creature" },
						{ packsDir = root }
					),
					"invalid fulfillment rejected"
				)
				assert(fs.readFile(requestPath) == requestText, "invalid input leaves request unchanged")
				assert(fs.readFile(manifestPath) == manifestText, "invalid input leaves manifest unchanged")
			end
		end)
	end,

	["isValidFulfillRequest still rejects an unsafe kind"] = function()
		local ok, badField = genCommand.isValidFulfillRequest("mesh\n    moderation: Approved", "forge-procgen")
		assert(not ok, "a YAML-breaking kind must still be rejected")
		assert(badField == "kind", "the reported field is kind")
	end,

	["isValidFulfillRequest still rejects an unsafe tool"] = function()
		local ok, badField = genCommand.isValidFulfillRequest("mesh", "a: b")
		assert(not ok, "a YAML-breaking tool must still be rejected")
		assert(badField == "tool", "the reported field is tool")
	end,
}
