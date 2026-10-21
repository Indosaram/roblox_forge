--!strict
local Upload = require("../../../core/domain/music/ChunkUpload")
local Hash = require("../../../core/domain/music/ChunkHash")
local Score = require("../../../core/domain/music/Score")
local Schema = require("../../../core/infra/net/Schema")
local M = {}
local prefix = "survival-coop:"
local configured: any = nil
function M.configure(config: any)
	configured = config
end
function M.actions(): { any }
	local id = Schema.string({ maxLen = 64, pattern = "^[%w_-]+$" })
	local text = Schema.string({ maxLen = 256 })
	local definitions: any = {
		["score-upload-begin"] = { id, Schema.number({ min = 1, integer = true }), text, text },
		["score-upload-chunk"] = { id, Schema.number({ min = 1, integer = true }), text },
		["score-upload-commit"] = { id },
		["score-upload-cancel"] = {},
	}
	local actions = {}
	for name, args in definitions do
		table.insert(
			actions,
			{ id = name, args = args, origin = "client", rate = { capacity = 100, refillPerSecond = 100 } }
		)
	end
	table.sort(actions, function(a, b)
		return a.id < b.id
	end)
	return actions
end
function M.factory(ctx: any): any
	if not configured then
		return nil
	end
	local config = table.clone(configured)
	config.rules, config.now = ctx.content.music, ctx.now
	return M.new(config)
end
function M.new(config: any): any
	local upload = Upload.new(config.rules, config.uploadTtl)
	local api: any = { id = "scoreTransport" }
	function api.handles(action: string): boolean
		action = string.gsub(action, "^survival%-coop:", "")
		return action == "score-upload-begin"
			or action == "score-upload-chunk"
			or action == "score-upload-commit"
			or action == "score-upload-cancel"
	end
	function api.command(
		actor: string,
		action: string,
		args: { any },
		_command: any,
		_origin: any,
		fence: () -> any
	): any
		local gate = fence()
		if not gate.ok then
			return gate
		end
		action = string.gsub(action, "^survival%-coop:", "")
		local now = config.now()
		if action == "score-upload-begin" then
			return upload.begin(actor, args[1], args[2], args[3], args[4], now)
		elseif action == "score-upload-chunk" then
			return upload.put(actor, args[1], args[2], args[3], now)
		elseif action == "score-upload-cancel" then
			upload.clear(actor)
			return { ok = true }
		elseif action == "score-upload-commit" then
			local result = upload.finish(actor, args[1], now)
			if not result.ok then
				return result
			end
			local value, reason = Score.import(result.text, config.rules, config.decode)
			if not value then
				return { ok = false, reason = reason }
			end
			-- Keep chunks until cancel/expiry: an ambiguous DataStore response can be retried
			-- with the same owner-scoped receipt without producing another revision.
			return config.repository.save(actor, if result.scoreId == "" then nil else result.scoreId, value, args[1])
		end
		return { ok = false, reason = "score.upload_action" }
	end
	function api.disconnect(actor: string)
		upload.clear(actor)
	end
	api.releaseActor = function(actor: string): any
		api.disconnect(actor)
		return { ok = true }
	end
	return api
end
function M.send(ctx: any, text: string, scoreId: string?, requestId: string): any
	if #text < 1 or #text > ctx.rules.maxBytes then
		return { ok = false, reason = "score.bytes" }
	end
	local beginArgs: { any } = { requestId, #text, Hash.digest(text), scoreId or "" }
	local result = ctx.send(prefix .. "score-upload-begin", beginArgs)
	if not result.ok then
		return result
	end
	for offset = 1, #text, Upload.CHUNK_BYTES do
		local chunkArgs: { any } = {
			requestId,
			(offset - 1) / Upload.CHUNK_BYTES + 1,
			Upload.hex(string.sub(text, offset, offset + Upload.CHUNK_BYTES - 1)),
		}
		result = ctx.send(prefix .. "score-upload-chunk", chunkArgs)
		if not result.ok then
			return result
		end
	end
	result = ctx.send(prefix .. "score-upload-commit", { requestId })
	if result.ok then
		ctx.send(prefix .. "score-upload-cancel", {})
	end
	return result
end
return M
