--!strict
-- Connect only server-owned post-commit signals. No RemoteEvent may supply these.
local Chapters = require("../../../core/domain/journal/Chapters")
local M = {}

function M.new(port: any, content: any, signals: any): any
	local connections = {}
	local closed = false
	local api = {}
	function api.stage(actor: string, id: string, binding: any): any
		local saved, reason = port.update(actor, function(document)
			document.journalPending = document.journalPending or {}
			if not document.journalPending[id] then
				document.journalPending[id] = binding
			end
			return document
		end)
		return { ok = saved, reason = reason }
	end
	function api.recover(actor: string, resolve: any): any
		local document, reason = port.read(actor)
		if not document then
			return { ok = false, reason = reason }
		end
		for id, binding in document.journalPending or {} do
			local events = resolve(binding)
			if events then
				for _, event in events do
					event.actor, event.chapterId, event.committed, event.ok = actor, binding.chapterId, true, true
					local result = api.accept(event)
					if
						not result.ok
						and result.reason ~= "CHAPTER_MISMATCH"
						and result.reason ~= "WRONG_OBJECTIVE"
						and result.reason ~= "AWAITING_CLAIM"
						and result.reason ~= "DISTINCT_MARKER_REQUIRED"
					then
						return result
					end
				end
				local saved, err = port.update(actor, function(current)
					current.journalPending[id] = nil
					return current
				end)
				if not saved then
					return { ok = false, reason = err }
				end
			end
		end
		return { ok = true }
	end
	function api.accept(event: any): any
		if closed or event.committed ~= true or event.ok ~= true then
			return { ok = false, reason = "UNCOMMITTED_EVENT" }
		elseif type(event.receiptId) ~= "string" or event.receiptId == "" then
			return { ok = false, reason = "MISSING_RECEIPT" }
		end
		local outcome: any = nil
		local saved, reason = port.update(event.actor, function(document)
			local state = Chapters.restore(document.journal or Chapters.new(), content.chapters)
			-- A delayed pre-chapter receipt cannot become a fresh kill/checkpoint.
			if not state.active or event.chapterId ~= state.active then
				outcome = { ok = false, reason = "CHAPTER_MISMATCH" }
				return document
			end
			local nextState, refusal = Chapters.observe(state, content.chapters, {
				id = event.receiptId,
				action = event.action,
				target = event.target,
				quantity = event.quantity,
				marker = event.marker,
			})
			outcome = { ok = nextState ~= nil, reason = refusal }
			if nextState then
				document.journal = nextState
			end
			return document
		end)
		return if saved then outcome else { ok = false, reason = reason }
	end
	for _, signal in signals do
		table.insert(connections, signal:Connect(api.accept))
	end
	function api.close()
		closed = true
		for _, connection in connections do
			connection:Disconnect()
		end
	end
	return api
end

return M
