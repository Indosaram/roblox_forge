--!strict
local Extension = require("../../../../genres/survival-coop/module/ArchipelagoExtension")
local Domain = require("../../../../core/domain/island/Archipelago")
local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")
local M = {}
M.operations = {
	archi_open = function(ctx, step): string?
		local result = ctx.fixture.extension.open(ctx.playerOf(step), {
			id = "native-expedition",
			index = 1,
			seed = ctx.scenario.seed,
			ttl = 1000,
			revision = "v2",
			entryBuffer = 30,
		})
		ctx.results[ctx.playerOf(step)] = result
		return if result.ok then nil else result.reason
	end,
	archi_next = function(ctx, step): string?
		local result = ctx.fixture.extension.nextIsland(ctx.playerOf(step))
		ctx.results[ctx.playerOf(step)] = result
		return if result.ok == (step.expect == "refused") then "unexpected departure" else nil
	end,
	archi_settle = function(ctx, step): string?
		local actor = ctx.playerOf(step)
		local state = ctx.fixture.document.archipelago
		for _, definition in Content.stages :: any do
			if definition.layout ~= Domain.layout(state) then
				continue
			end
			for _, objective in definition.objectives do
				-- Only this fixture's server ledger can issue verified operations.
				ctx.fixture.ledger[objective.id] = {
					id = objective.id,
					actor = actor,
					expedition = state.id,
					revision = state.revision,
					objective = objective.id,
					target = objective.target,
					action = objective.action,
					quantity = objective.quantity,
				}
				local result = ctx.fixture.extension.objective(actor, objective.id)
				if not result.ok then
					return result.reason
				end
			end
		end
		return nil
	end,
	archi_expire = function(ctx, step): string?
		local fixture = ctx.fixture
		fixture.setTime(fixture.document.archipelago.expiresAt)
		local result = fixture.extension.recover(ctx.playerOf(step), "reconnect")
		ctx.results[ctx.playerOf(step)] = {
			ok = result.ok,
			data = {
				status = fixture.document.archipelago.status,
				owned = fixture.document.bag[1].id,
				durability = fixture.document.bag[1].durability,
				cargoCleared = fixture.document.archipelago.questCargo == nil,
			},
		}
		return if result.ok then nil else result.reason
	end,
}
function M.new(ctx): any
	local document: any = { bag = { { id = "owned-pick", durability = 27 } } }
	local ledger: any = {}
	local now = 0
	return {
		document = document,
		ledger = ledger,
		setTime = function(value)
			now = value
		end,
		extension = Extension.new({
			content = Content,
			entryBuffer = 30,
			now = function()
				return now
			end,
			facts = function()
				return { level = 60, developmentRank = 10, instabilityAccess = 5 }
			end,
			verify = function(actor, id)
				local receipt = ledger[id]
				return if receipt and receipt.actor == actor then receipt else nil
			end,
			store = {
				transaction = function(_actor, transform)
					return transform(document)
				end,
			},
			returnHome = function(actor)
				-- Actual Session handoff exercises owned-player persistence; the
				-- fixture document above is only the isolated archipelago port.
				local result = ctx.session.prepareHandoff(actor)
				if result.ok then
					return ctx.session.resumeHandoff(actor)
				end
				return result
			end,
		}),
	}
end
return M
