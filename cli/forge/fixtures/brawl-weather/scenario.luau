--!strict
-- Real brawl command module behind injected match/personal transactions.
-- Session join/snapshot are real; brawl action registration awaits integrate3.
local Match = require("../../../../core/domain/brawl/Match")
local Data = require("../../../../core/domain/genre/SerializedData")
local Extension = require("../../../../genres/survival-coop/module/BrawlExtension")
local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")
local Policy = require("../../../../core/domain/brawl/Policy.fixture")
local M = {}
M.operations = {
	brawl_command = function(ctx, step): string?
		local actor = ctx.playerOf(step)
		if not ctx.session.snapshot(actor) then
			return "Session actor not joined"
		end
		local result = ctx.fixture.command(actor, step.action, step.token)
		ctx.results[actor] = result
		return if (step.expect == "refused") == result.ok then "unexpected brawl command result" else nil
	end,
	brawl_frame = function(ctx, step): string?
		local result = ctx.fixture.frame(step.elapsed, step.damage or {})
		ctx.results[ctx.playerOf(step)] = result
		return if result.ok then nil else result.reason
	end,
	brawl_assert = function(ctx, step): string?
		local saved = ctx.fixture.snapshot()
		if step.check == "draw" then
			return if saved.match.phase == "finished" and not saved.match.winner then nil else "not a simultaneous draw"
		end
		return if saved.wallets.owner.balance == 50
				and saved.wallets.rival.balance == 50
				and saved.original.durability == 10
			then nil
			else "reward or equipment conservation failed"
	end,
}
function M.new(ctx): any
	local policy = (Content :: any).brawlPolicy or Policy
	local state = Match.new("native-brawl-weather", policy)
	local clock = ctx.now()
	local original = { durability = 10 }
	local wallets: any = { owner = { balance = 0 }, rival = { balance = 0 } }
	local damage: any = {}
	local extension = Extension.new({
		match = {
			snapshot = function()
				return state
			end,
			transaction = function(transform)
				local candidate = Data.clone(state)
				local result = transform(candidate)
				if result.ok then
					state = candidate
				end
				return result
			end,
		},
		personal = {
			transaction = function(actor, transform)
				local candidate = Data.clone(wallets[actor])
				local result = transform(candidate)
				if result.ok then
					wallets[actor] = candidate
				end
				return result
			end,
		},
		facts = function()
			return { level = 60, maxHealth = 100, equipment = original }
		end,
		now = function()
			return clock
		end,
		utc = ctx.now,
		action = function(_actor, token)
			if token == "shot" then
				return { kind = "ranged", range = 40 }
			end
			if token == "mount" then
				return { kind = "mount", range = 0 }
			end
			return { kind = "sprint", range = 0 }
		end,
		apply = function(candidate: any, actor, _fact, allowed)
			candidate.actors[actor].equipment.durability -= 1
			return allowed
		end,
		frame = function()
			return {}, damage
		end,
	})
	return {
		command = function(actor, action, token)
			if action == "start" then
				return extension.start()
			end
			return extension.command(actor, "brawl-" .. action, { token })
		end,
		frame = function(elapsed, losses)
			clock = state.startsAt + elapsed
			damage = losses
			return extension.tick()
		end,
		snapshot = function()
			return { match = extension.snapshot(), wallets = Data.clone(wallets), original = original }
		end,
	}
end
return M
