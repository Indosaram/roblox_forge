--!strict
-- Connect only server-owned post-commit signals. No RemoteEvent may supply these.
local Chapters = require("../../../core/domain/journal/Chapters")
local M = {}

function M.new(port: any, content: any, signals: any): any
	local connections = {}
	local closed = false
	local api = {}
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
