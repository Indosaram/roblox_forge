--!strict
local Score = require("../../../core/domain/music/Score")
local Ensemble = require("../../../core/domain/music/Ensemble")
local M = {}
local configured: any = nil
local actions = {
	["score-import"] = true,
	["score-share"] = true,
	["ensemble-join"] = true,
	["ensemble-ready"] = true,
	["ensemble-start"] = true,
	["ensemble-leave"] = true,
}

function M.configure(config: any)
	configured = config
end

-- Repository.save creates an immutable revision and checks author ownership. share grants read access.
-- All ports are server-owned; the command carries no clock, range, audio asset, or author claims.
function M.new(config: any): any
	local rooms = Ensemble.new(config.rules, {
		inRange = config.inRange,
		load = config.repository.load,
	})
	local extension: any = { id = "ensemble" }
	function extension.handles(action: string): boolean
		return actions[string.gsub(action, "^survival%-coop:", "")] == true
	end
	function extension.command(
		actor: string,
		action: string,
		args: { any },
		_command: any,
		_origin: any,
		fence: () -> any
	): any
		action = string.gsub(action, "^survival%-coop:", "")
		local value: any = nil
		if action == "score-import" then
			local reason
			value, reason = Score.import(args[1], config.rules, config.decode)
			if not value then
				return { ok = false, reason = reason }
			end
		end
		local gate = fence()
		if not gate.ok then
			return gate
		end
		if action == "score-import" then
			return config.repository.save(actor, if args[2] == "" then nil else args[2], value)
		elseif action == "score-share" then
			return config.repository.share(actor, args[1], args[2], args[3])
		elseif action == "ensemble-join" then
			if not config.repository.canRead(actor, args[1], args[2]) then
				return { ok = false, reason = "score.private" }
			end
			local ok, reason = rooms.join(actor, args[1], args[2], args[3])
			return { ok = ok, reason = reason }
		elseif action == "ensemble-ready" then
			local ok, reason = rooms.ready(actor, args[1])
			return { ok = ok, reason = reason }
		elseif action == "ensemble-start" then
			local ok, reason = rooms.start(actor, config.now())
			return { ok = ok, reason = reason }
		elseif action == "ensemble-leave" then
			local ok, reason = rooms.leave(actor)
			return { ok = ok, reason = reason }
		end
		return { ok = false, reason = "ensemble.action" }
	end
	function extension.snapshot(_actor: string): any
		return { room = rooms.snapshot() }
	end
	function extension.recover(_actor: string, now: number)
		rooms.advance(now)
	end
	return extension
end

function M.factory(ctx: any): any
	if not configured then
		return nil
	end
	local config = table.clone(configured)
	config.now = ctx.now
	return M.new(config)
end

return M
