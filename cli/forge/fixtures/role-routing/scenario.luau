--!strict
-- Native travel transport: the production router and real Session handoff;
-- only place services and durable progression facts are fixture ports.
local Bootstrap = require("../../../../genres/survival-coop/module/IslandBootstrap")
local M = {}
local Handoff = require("../handoff-conservation/scenario")
M.operations = {
	resume_handoff = Handoff.operations.resume_handoff,
	role_travel = function(ctx, step): string?
		local actor = ctx.playerOf(step)
		local result = ctx.fixture.travel(actor, step.from, step.destination, step.level, step.objectives)
		ctx.results[actor] = result
		return if (step.expect == "refused") == result.ok then "unexpected role travel result" else nil
	end,
}
function M.new(ctx): any
	assert(ctx.scenario.genre == "survival-coop" and ctx.scenario.pack == "robango-island", "fixture pack binding")
	local now: () -> number = ctx.now
	local session: any = nil
	local teleports = 0
	local places = { onboarding = 1, home = 2, harbor = 3, archipelago = 4, frontier60 = 5 }
	return {
		services = {},
		bind = function(value)
			session = value
		end,
		travel = function(actor: string, from: string, destination: string, level: number, objectives: number): any
			local router = Bootstrap.start({
				roles = places,
				placeId = places[from] or 999,
				privateServerId = "reserved",
				isStudio = false,
				players = {},
				now = now,
				newTeleportOptions = function()
					return {}
				end,
				teleportService = {
					TeleportAsync = function()
						teleports += 1
					end,
				},
				prepareHandoff = session.prepareHandoff,
				resumeHandoff = session.resumeHandoff,
				completeHandoff = session.completeHandoff,
				facts = function()
					return {
						level = level,
						homeAccessCode = "native-home",
						expedition = {
							level = level,
							index = 1,
							developmentGrade = 2,
							stage = 2,
							completedStage = 1,
							completedObjectives = objectives,
							expiresAt = now() + 60,
						},
					}
				end,
			})
			local ok, reason = router.travel({ UserId = actor }, destination)
			router.stop()
			return { ok = ok, reason = reason, data = { teleports = teleports } }
		end,
		close = function()
			return { ok = true }
		end,
	}
end
return M
