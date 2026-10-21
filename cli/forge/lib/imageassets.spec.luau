--!strict
local imageassets = require("./imageassets")
local assets = require("./assets")
local audioassets = require("./audioassets")
local serde = require("@lune/serde")

local M = {}
local function options(): any
	return {
		key = "icon",
		sha256 = "abc",
		creator = "user:1",
		creatorFields = { userId = "1" },
		apiKey = "test",
		bytes = "PNG",
	}
end

local function fixture(replies: { any }): (any, any)
	local state: any = { calls = {}, waits = {}, checkpoints = {} }
	return {
		request = function(params)
			table.insert(state.calls, params)
			local reply = table.remove(replies, 1)
			assert(reply ~= nil, "unexpected request")
			return reply
		end,
		wait = function(seconds)
			table.insert(state.waits, seconds)
		end,
		checkpoint = function(entry)
			table.insert(state.checkpoints, table.clone(entry))
		end,
	},
		state
end

local function response(body: any): any
	return { ok = true, statusCode = 200, body = serde.encode("json", body) }
end

M["image upload creates multipart decal and resolves image content without leaking key"] = function()
	local xml =
		'<roblox version="4"><Item class="Decal" referent="RBX0"><Properties><Content name="Texture"><url>rbxassetid://222</url></Content></Properties></Item></roblox>'
	local deps, state = fixture({
		response({ path = "operations/op" }),
		response({
			done = true,
			response = { assetId = "111", assetType = "Decal", moderationResult = { moderationState = "Approved" } },
		}),
		response({ location = "https://assetdelivery.roblox.com/test" }),
		{ ok = true, statusCode = 200, body = xml },
	})
	local entry = imageassets.publish(options(), deps)
	assert(entry.assetId == 222 and entry.decalAssetId == 111, "content id differs from decal id")
	assert(
		string.find(state.calls[1].body, '"Decal"', 1, true) and string.find(state.calls[1].body, "image/png", 1, true),
		"multipart declares Decal and PNG"
	)
	assert(state.calls[4].headers == nil, "CDN gets no API key")
	assert(state.checkpoints[1].operationId == "op", "operation durable before polling")
	local again = options()
	again.cached = entry
	local noNetwork = fixture({})
	assert(imageassets.publish(again, noNetwork).assetId == 222, "same creator and hash reuse image")
end

M["dry run performs no requests checkpoints or waits"] = function()
	local input = options()
	input.dryRun = true
	local deps, state = fixture({})
	imageassets.publish(input, deps)
	assert(#state.calls == 0 and #state.checkpoints == 0 and #state.waits == 0, "dry run is read-only")
end

M["429 backoff is bounded and in flight operation resumes without creating"] = function()
	local input = options()
	input.cached = { creator = input.creator, operationId = "saved" }
	local deps, state = fixture({
		{ ok = false, statusCode = 429, headers = { ["retry-after"] = "2" } },
		response({
			done = true,
			response = {
				assetId = "222",
				assetType = "Image",
				moderationResult = { moderationState = "MODERATION_STATE_APPROVED" },
			},
		}),
	})
	assert(imageassets.publish(input, deps).assetId == 222, "Image response needs no Decal resolution")
	assert(state.calls[1].method == "GET" and state.waits[1] == 2, "resume polls and honors retry-after")
	local replies = {}
	for _ = 1, 6 do
		table.insert(replies, { ok = false, statusCode = 429 })
	end
	local limited, limitedState = fixture(replies)
	assert(not pcall(imageassets.publish, options(), limited), "exhausted limit fails")
	assert(#limitedState.calls == 6 and #limitedState.waits == 5, "bounded retries")
end

M["pending moderation stays unresolved and refreshes without duplicate upload"] = function()
	local input = options()
	input.cached = { creator = input.creator, decalAssetId = 111, moderation = "PendingModeration" }
	local deps, state = fixture({ response({ moderationResult = { moderationState = "Reviewing" } }) })
	local result = imageassets.publish(input, deps)
	assert(result.assetId == nil and result.moderation == "PendingModeration", "pending not resolved")
	assert(#state.calls == 1 and state.calls[1].method == "GET", "pending refresh never creates")
	local rendered = assets.renderLuau(
		{ assets = { { key = "icon", kind = "image", assetId = 111, moderation = "PendingModeration" } } } :: any
	)
	assert(not string.find(rendered, '["icon"]', 1, true), "pending image never generated as playable")
end

M["operation failure preserves checkpoint for resume and never resolves content"] = function()
	local deps, state =
		fixture({ response({ path = "operations/op" }), response({ done = true, error = { message = "denied" } }) })
	assert(not pcall(imageassets.publish, options(), deps), "operation error fails")
	assert(#state.calls == 2 and state.checkpoints[1].operationId == "op", "checkpoint survives failure")
end

M["different creator does not reuse cached content and HTTP failure is not retried"] = function()
	local input = options()
	input.cached = { creator = "group:2", decalAssetId = 111, assetId = 222, moderation = "Approved" }
	local deps, state = fixture({ { ok = false, statusCode = 403, body = "denied" } })
	assert(not pcall(imageassets.publish, input, deps), "permission failure propagates")
	assert(#state.calls == 1 and state.calls[1].method == "POST", "other creator cannot reuse content")
	assert(#state.waits == 0 and #state.checkpoints == 0, "failed create is not cached or retried")
end

M["manifest records separate decal and image ids preserving provenance"] = function()
	local text = "version: 2\nassets:\n  - key: icon\n    kind: image\n    source: original\n    assetId: 0\n"
	local result =
		audioassets.applyUploads(text, { icon = { assetId = 222, decalAssetId = 111, moderation = "Approved" } })
	local decoded = serde.decode("yaml", result).assets[1]
	assert(
		decoded.assetId == 222 and decoded.decalAssetId == 111 and decoded.source == "original",
		"ids and provenance preserved"
	)
end

return M
