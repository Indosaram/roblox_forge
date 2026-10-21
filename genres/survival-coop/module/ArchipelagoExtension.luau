--!strict
local Archipelago = require("../../../core/domain/island/Archipelago")
local Objectives = require("../../../core/domain/island/MissionObjectives")
local Rewards = require("./MissionRewards")
local M = {}

-- store.transaction(actor, transform) must fence the actor lease and durably
-- commit before returning. verify resolves an opaque operation ID, not remote
-- supplied facts. returnHome uses Session's durable handoff, leaving bag intact.
function M.new(env: any): any
	local function change(actor: string, transform: any): any
		return env.store.transaction(actor, function(document)
			local result = transform(document)
			if result.ok and document.archipelago then
				Rewards.enqueue(document, env.content)
				local state = document.archipelago
				local development = document.development or { points = 0, definitions = {}, instabilityAccess = 1 }
				for _, mission in env.content.missions do
					local completed = true
					for _, objective in mission.objectives do
						completed = completed and state.completed[objective.id] == true
					end
					if completed and not development.definitions[mission.id] then
						development.definitions[mission.id] = true
						development.points += if mission.rewards then mission.rewards.development or 0 else 0
					end
				end
				if state.status == "complete" then
					development.instabilityAccess =
						math.max(development.instabilityAccess, math.min(5, state.index + 1))
				end
				document.development = development
			end
			return result
		end)
	end
	return {
		settleRewards = function(actor: string): any
			return Rewards.settle(actor, env)
		end,
		mission = function(actor: string, operation: string, target: string): any
			return change(actor, function(document): any
				local state = document.archipelago
				if not state then
					return { ok = false, reason = "missing_expedition" }
				end
				local ok, reason =
					Objectives.apply(state, env.content, operation, target, env.position(actor), env.now())
				return { ok = ok, reason = reason }
			end)
		end,
		tick = function(actor: string): any
			local current, reason = env.store.snapshot(actor)
			if not current then
				return { ok = false, reason = reason }
			end
			if not current.archipelago or current.archipelago.status ~= "active" then
				return { ok = true }
			end
			return change(actor, function(document): any
				local state = document.archipelago
				if state then
					Objectives.tick(state, env.content, env.position(actor), env.now())
					for id, npc in if env.wildlife then env.wildlife(actor) or {} else {} do
						if
							npc.healthMilli == 0
							and npc.killer == actor
							and npc.killedAt
							and npc.killedAt >= state.openedAt
						then
							for _, stage in env.content.stages do
								if stage.layout == Archipelago.layout(state) then
									for _, objective in stage.objectives do
										if objective.action == "hunt" and objective.target == npc.catalogId then
											Archipelago.record(state, env.content, {
												id = "hunt:" .. id,
												actor = actor,
												expedition = state.id,
												revision = state.revision,
												objective = objective.id,
												action = "hunt",
												target = npc.catalogId,
												quantity = 1,
											}, env.now())
										end
									end
								end
							end
						end
					end
				end
				return { ok = true }
			end)
		end,
		survey = function(actor: string, objectiveId: string, markerId: string): any
			return change(actor, function(document): any
				local state = document.archipelago
				if not state or state.status ~= "active" then
					return { ok = false, reason = "missing_expedition" }
				end
				local receipt = env.surveyReceipt(actor, state, objectiveId, markerId)
				if not receipt then
					return { ok = false, reason = "unverified_objective" }
				end
				local ok, reason = Archipelago.record(state, env.content, receipt, env.now())
				return { ok = ok, reason = reason }
			end)
		end,
		open = function(actor: string, options: any): any
			return change(actor, function(document): any
				if document.archipelago and document.archipelago.status == "active" then
					return { ok = false, reason = "expedition_active" }
				end
				if document.expeditionIds and document.expeditionIds[options.id] then
					return { ok = false, reason = "duplicate_expedition" }
				end
				local input = table.clone(options)
				input.actor = actor
				local state, reason = Archipelago.open(env.content, input, env.facts(actor, document), env.now())
				if state then
					document.archipelago = state
					local ids = document.expeditionIds or {}
					ids[options.id] = true
					document.expeditionIds = ids
				end
				return { ok = state ~= nil, reason = reason }
			end)
		end,
		objective = function(actor: string, operationId: string): any
			return change(actor, function(document): any
				local receipt = env.verify(actor, operationId, document)
				if not receipt then
					return { ok = false, reason = "unverified_objective" }
				end
				if not document.archipelago then
					return { ok = false, reason = "missing_expedition" }
				end
				local ok, reason = Archipelago.record(document.archipelago, env.content, receipt, env.now())
				return { ok = ok, reason = reason }
			end)
		end,
		gatherObjective = function(actor: string, epoch: number, requestId: string): any
			return change(actor, function(document): any
				local state = document.archipelago
				if not state then
					return { ok = false, reason = "missing_expedition" }
				end
				local grant = env.gatherReceipt(actor, epoch, requestId)
				if not grant or not state.openedAt or not grant.createdAt or grant.createdAt < state.openedAt then
					return { ok = false, reason = "unverified_objective" }
				end
				local receiptId = "gather:" .. tostring(epoch) .. ":" .. requestId
				-- Keep consumption outside the per-expedition state, so a new route
				-- cannot recycle a receipt from an earlier route on the same layout.
				if document.gatherReceipts and document.gatherReceipts[receiptId] then
					return { ok = false, reason = "duplicate_receipt" }
				end
				local layoutId = Archipelago.layout(state)
				local item: string? = nil
				for _, layout in env.content.layouts do
					if layout.id == layoutId then
						for _, resource in layout.resourceNodes do
							if resource.id == grant.nodeId then
								item = resource.item
							end
						end
					end
				end
				if not item then
					return { ok = false, reason = "receipt_scope" }
				end
				for _, stage in env.content.stages do
					if stage.layout == layoutId then
						for _, objective in stage.objectives do
							if objective.action == "gather" and objective.target == item then
								local ok, reason = Archipelago.record(state, env.content, {
									id = receiptId,
									actor = actor,
									expedition = state.id,
									revision = state.revision,
									objective = objective.id,
									action = objective.action,
									target = item,
									quantity = if grant.items then grant.items[item] else nil,
								}, env.now())
								if ok then
									local receipts = document.gatherReceipts or {}
									receipts[receiptId] = true
									document.gatherReceipts = receipts
								end
								return { ok = ok, reason = reason }
							end
						end
					end
				end
				return { ok = false, reason = "objective_mismatch" }
			end)
		end,
		nextIsland = function(actor: string): any
			return change(actor, function(document): any
				if not document.archipelago then
					return { ok = false, reason = "missing_expedition" }
				end
				local ok, reason = Archipelago.advance(
					document.archipelago,
					env.content,
					env.facts(actor, document),
					env.now(),
					env.entryBuffer
				)
				return { ok = ok, reason = reason }
			end)
		end,
		recover = function(actor: string, cause: string): any
			local result = change(actor, function(document): any
				if not document.archipelago then
					return { ok = false, reason = "missing_expedition" }
				end
				return { ok = true, destination = Archipelago.recover(document.archipelago, env.now(), cause) }
			end)
			if result.ok and result.destination == "home" then
				return env.returnHome(actor)
			end
			return result
		end,
	}
end
return M
