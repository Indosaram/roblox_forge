--!strict
local Extension = require("../../../../genres/survival-coop/module/ArchipelagoExtension")
local Expedition = require("../../../../genres/survival-coop/module/ExpeditionExtension")
local Domain = require("../../../../core/domain/island/Archipelago")
local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")
local M = {}
M.operations = {
	-- p103 S7 route sharing through the production party-action handler; membership persists in
	-- the owner's route document and each member keeps their own level gate.
	route_share = function(ctx, step): string?
		local actor = ctx.playerOf(step)
		local result = ctx.fixture.crew.command(
			actor,
			Expedition.ACTION,
			{ step.verb, step.target },
			{},
			"client",
			function()
				return { ok = true }
			end
		)
		ctx.results[actor] = result
		return if result.ok == (step.expect == "refused")
			then "unexpected route share: " .. tostring(result.reason)
			else nil
	end,
	route_open = function(ctx, step): string?
		local actor = ctx.playerOf(step)
		local result = ctx.fixture.extension.open(actor, {
			id = "shared-" .. actor,
			index = step.route,
			seed = ctx.scenario.seed,
			ttl = 1000,
			revision = "v2",
			entryBuffer = 30,
			sharedBy = step.sharedBy,
		})
		ctx.results[actor] = result
		return if result.ok == (step.expect == "refused")
			then "unexpected shared open: " .. tostring(result.reason)
			else nil
	end,
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
	local documents: any = {}
	local ledger: any = {}
	local now = 0
	local owner = ctx.scenario.players[1]
	local function doc(actor: string): any
		if actor == owner then
			return document
		end
		documents[actor] = documents[actor] or {}
		return documents[actor]
	end
	local function transaction(actor, transform)
		return transform(doc(actor))
	end
	-- Owner: every route open; a helper: level 60 but no route access of their own; a newcomer: level 1.
	local function facts(actor: string): any
		if actor == owner then
			return { level = 60, developmentRank = 10, instabilityAccess = 5 }
		end
		return { level = if actor == "newcomer" then 1 else 60, developmentRank = 10, instabilityAccess = 1 }
	end
	return {
		crew = Expedition.new({
			content = Content,
			now = function()
				return now
			end,
			facts = facts,
			document = doc,
			transaction = transaction,
			online = function()
				return true
			end,
			onExpedition = function()
				return false
			end,
			layoutId = function()
				return nil
			end,
			position = function()
				return nil
			end,
			travel = function()
				return { ok = true }
			end,
		}),
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
			facts = facts,
			verify = function(actor, id)
				local receipt = ledger[id]
				return if receipt and receipt.actor == actor then receipt else nil
			end,
			store = {
				transaction = transaction,
				snapshot = doc,
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
