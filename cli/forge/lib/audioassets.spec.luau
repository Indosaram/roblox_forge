--!strict
-- Specs for audioassets: the upload plan, the Open Cloud response parsing and
-- the two manifest write-back styles. All pure - no network, no filesystem.

local audioassets = require("./audioassets")
local assetsLib = require("./assets")
local serde = require("@lune/serde")

local M = {}

local function manifest(assets: { any }): assetsLib.Manifest
	return { version = 2, assets = assets }
end

local function asset(fields: any): any
	local entry = {
		key = "cue",
		kind = "sfx",
		tool = "forge-procgen",
		source = "procedural audio/cue",
		assetId = 0,
		moderation = "Approved",
	}
	for key, value in fields do
		entry[key] = value
	end
	return entry
end

M["plan keeps only audio cues whose artifact digest is known"] = function()
	local parsed = manifest({
		asset({ key = "buy", kind = "sfx", path = "assets/audio/buy.wav" }),
		asset({ key = "music", kind = "bgm", path = "assets/audio/music.wav" }),
		asset({ key = "prop", kind = "model", path = "assets/prop.rbxm" }),
		asset({ key = "thumb", kind = "image", path = "assets/thumb.png" }),
		asset({ key = "missing", kind = "sfx", path = "assets/audio/missing.wav" }),
		asset({ key = "nopath", kind = "sfx" }),
	})
	local cues, skipped = audioassets.plan(parsed, {
		buy = "sha256:aa",
		music = "sha256:bb",
		prop = "sha256:cc",
		thumb = "sha256:dd",
	})
	assert(#cues == 2, "only the two audio cues with digests are planned")
	assert(cues[1].key == "buy" and cues[1].kind == "sfx" and cues[1].sha256 == "sha256:aa", "the sfx cue is planned")
	assert(cues[2].key == "music" and cues[2].kind == "bgm", "the bgm cue is planned")
	assert(#skipped == 2, "a missing digest and a missing path are both reported")
	assert(string.find(skipped[1], "missing", 1, true) ~= nil, "the cue with no digest is reported")
	assert(string.find(skipped[2], "no local path", 1, true) ~= nil, "the cue with no path is reported")
end

M["plan with no digests plans nothing and reports each audio cue"] = function()
	local parsed = manifest({ asset({ key = "buy", kind = "sfx", path = "assets/audio/buy.wav" }) })
	local cues, skipped = audioassets.plan(parsed, {})
	assert(#cues == 0, "no digest means no uploadable cue")
	assert(
		#skipped == 1 and string.find(skipped[1], "no artifact digest", 1, true) ~= nil,
		"the missing digest is named"
	)
end

M["digestHex extracts the bare sha256 hex and rejects other forms"] = function()
	assert(
		audioassets.digestHex("sha256:" .. string.rep("a", 64)) == string.rep("a", 64),
		"a sha256 digest yields its hex"
	)
	assert(audioassets.digestHex("sha256:XYZ") == nil, "a non-hex digest is refused")
	assert(audioassets.digestHex("md5:abc") == nil, "another algorithm is refused")
end

M["moderationOf maps Reviewing to PendingModeration and refuses unknown states"] = function()
	assert(audioassets.moderationOf("Approved") == "Approved", "Approved maps through")
	assert(audioassets.moderationOf("Rejected") == "Rejected", "Rejected maps through")
	assert(audioassets.moderationOf("Reviewing") == "PendingModeration", "Reviewing is PendingModeration")
	assert(audioassets.moderationOf("Quarantined") == nil, "an unknown state is refused")
	assert(audioassets.moderationOf(nil) == nil, "a missing state is refused")
	assert(audioassets.moderationOf(7) == nil, "a non-string state is refused")
end

M["parseCreateResponse reads operationId, then the operations/<id> path"] = function()
	local fromField = audioassets.parseCreateResponse('{"operationId":"op-1","done":false}')
	assert(fromField == "op-1", "operationId is used when present")
	local fromPath = audioassets.parseCreateResponse('{"path":"operations/8b42ef30","done":false}')
	assert(fromPath == "8b42ef30", "the operations path is used otherwise")
	local missing, reason = audioassets.parseCreateResponse("{}")
	assert(missing == nil, "a reply with neither is refused")
	assert(reason ~= nil, "a refused reply always carries a reason")
	assert(string.find(reason, "no operationId", 1, true) ~= nil, "the refusal names the missing operationId")
	local notJson, jsonReason = audioassets.parseCreateResponse("not json")
	assert(notJson == nil, "a non-JSON reply is refused")
	assert(jsonReason ~= nil, "a refused reply always carries a reason")
	assert(
		string.find(jsonReason, "not a JSON object", 1, true) ~= nil,
		"the refusal says the reply is not a JSON object"
	)
end

M["parseOperationResponse reads an in-flight reply, then a finished one"] = function()
	local pending = audioassets.parseOperationResponse('{"done":false,"path":"operations/op-1"}')
	assert(pending ~= nil and pending.done == false and pending.assetId == nil, "an in-flight operation is not done")
	local done = audioassets.parseOperationResponse(
		'{"done":true,"response":{"assetId":"123456","path":"assets/123456"},"moderationResult":{"moderationState":"Reviewing"}}'
	)
	assert(done ~= nil and done.done == true and done.assetId == 123456, "a finished operation carries its id")
	assert(done.moderationState == "Reviewing", "the moderation state is carried")
	local numeric = audioassets.parseOperationResponse('{"done":true,"response":{"assetId":77}}')
	assert(numeric ~= nil and numeric.assetId == 77, "a numeric assetId is accepted")
	local noId, reason = audioassets.parseOperationResponse('{"done":true,"response":{}}')
	assert(noId == nil, "a done reply with no id is refused")
	assert(reason ~= nil, "a refused reply always carries a reason")
	assert(string.find(reason, "without a positive assetId", 1, true) ~= nil, "the refusal names the missing assetId")
	local failed, failure = audioassets.parseOperationResponse(
		'{"done":true,"error":{"code":3,"message":"Asset is invalid"},"response":{}}'
	)
	assert(failed == nil and failure == "Asset is invalid", "the operation's own error message is surfaced")
end

local BLOCK = table.concat({
	"# hand-written manifest",
	"assets:",
	"  - key: buy",
	"    kind: sfx",
	"    tool: forge-procgen",
	"    source: procedural audio/buy",
	"    path: assets/audio/buy.wav",
	"    assetId: 0",
	"    moderation: Approved",
	"  - key: plant",
	"    kind: sfx",
	"    tool: forge-procgen",
	"    source: procedural audio/plant",
	"    path: assets/audio/plant.wav",
	"    assetId: 0",
	"",
	"# keep the trailing section",
	"metadata:",
	"  owner: forge",
}, "\n") .. "\n"

M["applyUploads edits block style in place and preserves comments"] = function()
	local updated = audioassets.applyUploads(BLOCK, {
		buy = { assetId = 111, moderation = "Approved" },
		plant = { assetId = 222, moderation = "PendingModeration" },
	})
	local parsed, err = assetsLib.parseManifest(serde.decode("yaml", updated))
	assert(parsed ~= nil, err)
	local byKey: { [string]: any } = {}
	for _, entry in (parsed :: any).assets do
		byKey[entry.key] = entry
	end
	assert(byKey.buy.assetId == 111 and byKey.buy.moderation == "Approved", "the first block is updated")
	assert(byKey.plant.assetId == 222 and byKey.plant.moderation == "PendingModeration", "the second block is updated")
	assert(string.find(updated, "# hand-written manifest", 1, true) ~= nil, "the leading comment is preserved")
	assert(string.find(updated, "# keep the trailing section", 1, true) ~= nil, "the trailing comment is preserved")
	assert(string.find(updated, "    path: assets/audio/plant.wav", 1, true) ~= nil, "sibling fields are preserved")
	assert(string.sub(updated, -1) == "\n", "the trailing newline is preserved")
	-- The plant block had no moderation line: it is inserted, not left absent.
	assert(
		string.find(updated, "    moderation: PendingModeration\n", 1, true) ~= nil,
		"the missing moderation is inserted"
	)
end

M["applyUploads inserts an assetId line when a block lacks one"] = function()
	local text = "assets:\n"
		.. "  - key: buy\n"
		.. "    kind: sfx\n"
		.. "    tool: forge-procgen\n"
		.. "    source: procedural audio/buy\n"
		.. "    path: assets/audio/buy.wav\n"
		.. "    moderation: Approved\n"
	local updated = audioassets.applyUploads(text, { buy = { assetId = 9, moderation = "Approved" } })
	local parsed, err = assetsLib.parseManifest(serde.decode("yaml", updated))
	assert(parsed ~= nil, err)
	assert((parsed :: any).assets[1].assetId == 9, "the missing assetId line is inserted")
end

M["applyUploads is a no-op for an empty update set"] = function()
	assert(audioassets.applyUploads(BLOCK, {}) == BLOCK, "an empty update set changes nothing")
end

M["applyUploads rewrites the serde-encoded scratch manifest in place"] = function()
	local source = manifest({
		asset({ key = "prop", kind = "model", assetId = 0 }),
		asset({ key = "buy", kind = "sfx", path = "assets/audio/buy.wav", assetId = 0 }),
	})
	local text = serde.encode("yaml", source)
	local updated = audioassets.applyUploads(text, { buy = { assetId = 4242, moderation = "PendingModeration" } })
	local decoded = serde.decode("yaml", updated)
	local byKey: { [string]: any } = {}
	for _, entry in decoded.assets do
		byKey[entry.key] = entry
	end
	assert(byKey.buy.assetId == 4242 and byKey.buy.moderation == "PendingModeration", "the audio cue is updated")
	assert(byKey.prop.assetId == 0 and byKey.prop.moderation == "Approved", "the unrelated asset is untouched")
	-- A field the update did not name survives the re-encode byte-for-byte.
	assert(byKey.buy.path == "assets/audio/buy.wav" and byKey.buy.tool == "forge-procgen", "the other fields survive")
end

M["isCurrent is true only when every id and moderation already match"] = function()
	local parsed = manifest({ asset({ key = "buy", assetId = 5, moderation = "Approved" }) })
	assert(
		audioassets.isCurrent(parsed, { buy = { assetId = 5, moderation = "Approved" } }),
		"an exact match is current"
	)
	assert(
		not audioassets.isCurrent(parsed, { buy = { assetId = 6, moderation = "Approved" } }),
		"a different id is not current"
	)
	assert(
		not audioassets.isCurrent(parsed, { buy = { assetId = 5, moderation = "PendingModeration" } }),
		"a different moderation is not current"
	)
	assert(
		not audioassets.isCurrent(parsed, { missing = { assetId = 1, moderation = "Approved" } }),
		"an absent key is not current"
	)
end

return M
