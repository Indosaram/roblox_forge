--!strict
-- Forge QA gather per-attempt reset, one source of truth for the Studio gameplay driver and its
-- Lune fixture. Like the correlation module it is ordinary typed Luau with no Roblox global, so
-- the driver embeds it and the fixture requires it without a copy or a suppression.
--
-- The reset is per dispatch, not per attempt. The real client holds one request identity until it
-- settles the request (a confirmation, a refusal that decided against the frozen payload, or an
-- expired epoch), so a result for that identity can arrive between two attempts and must survive
-- the reset. Only a result that ended the client's request lets the next activation allocate a
-- fresh identity, and only then is the captured identity cleared. The step's input gate is armed
-- once for the whole step: clearing it per attempt would drop a result that arrived while the next
-- attempt was still preparing, and it still refuses any result that no injected input preceded.
local M = {}

function M.reset(m: any, clearValue: boolean, clearIdentity: boolean): { ready: boolean }
	m:SetAttribute("Attempt", (m:GetAttribute("Attempt") or 0) + 1)
	m:SetAttribute("InputAt", false)
	if clearValue or m.Value == "INVALID" then
		m.Value = ""
	end
	if clearIdentity then
		m:SetAttribute("RequestId", false)
		m:SetAttribute("DispatchAt", false)
		m:SetAttribute("Captured", false)
	end
	return { ready = true }
end

return M
