--!strict
-- The journal port writes state and rewards in ONE personal aggregate transform.
-- update(actor, transform) invokes transform(document) atomically; document.journal
-- is owned here. grant(document, rewards, chapterId) must be pure and receipt-safe.
local Chapters = require("../../../core/domain/journal/Chapters")
local Ledger = require("../../../core/domain/command/Ledger")
local M = {}
function M.factory(ctx: any): any
	local port = ctx.journal
	if not port or not ctx.content.chapters then
		return nil
	end
	local catalog = ctx.content.chapters
	local function change(actor: string, transform: any): any
		local result: any = nil
		local saved, err = port.update(actor, function(document)
			local original = document
			document = Chapters.copy(document)
			local state = Chapters.restore(document.journal or Chapters.new(), catalog)
			local nextState, detail = transform(state, document)
			result = if nextState
				then { ok = true, data = Chapters.copy(nextState) }
				else { ok = false, reason = detail }
			if nextState then
				document.journal = nextState
			else
				return original
			end
			return document
		end)
		return if saved then result else { ok = false, reason = err }
	end
	return {
		id = "journal",
		handles = function(action: string): boolean
			return action == "survival-coop:journal-open" or action == "survival-coop:journal-claim"
		end,
		command = function(actor, action, args, context, _origin, admit)
			local admission = admit()
			if not admission.ok then
				return admission
			end
			local binding = Ledger.canonical({ action = action, args = args })
			local replay: any = nil
			local changed = change(actor, function(state: Chapters.State, document: any): (Chapters.State?, any)
				document.journalOutcomes = document.journalOutcomes or {}
				local known = document.journalOutcomes[context.requestId]
				if known then
					if known.binding ~= binding then
						return nil, "REQUEST_CONFLICT"
					end
					replay = Chapters.copy(known.result)
					return state, nil
				end
				local nextState, detail
				if action == "survival-coop:journal-open" then
					nextState, detail = Chapters.open(state, catalog, args[1], port.level(document))
				else
					nextState, detail = Chapters.claim(state, catalog)
					if nextState then
						local refused = port.grant(document, detail, state.active)
						if refused then
							return nil, refused
						end
					end
				end
				if not nextState then
					return nil, detail
				end
				document.journalOutcomes[context.requestId] = {
					binding = binding,
					result = { ok = true, data = Chapters.copy(nextState) },
				}
				return nextState, nil
			end)
			return replay or changed
		end,
		observe = function(actor, action, args, result)
			if not result.ok then
				return
			end
			-- Resolver verifies actual committed receipts, position and biological provenance.
			local evidence = port.evidence(actor, action, args, result)
			if evidence then
				return change(actor, function(state)
					return Chapters.observe(state, catalog, evidence)
				end)
			end
			return nil
		end,
		snapshot = function(actor)
			local document, err = port.read(actor)
			return if document then Chapters.copy(document.journal or Chapters.new()) else nil, err
		end,
	}
end
return M
