--!strict
-- C2 gather fan, pack side: what a tapped node offers and when an open fan must close. A node
-- whose depleted mesh is up (ForgeNodeDepleted, published from the confirmed gather state) offers
-- nothing until it regrows, so the tap falls through to the gather prompt and the server's
-- NODE_DEPLETED refusal shows the regrow time instead of a fan of outputs it would refuse.
local M = {}

--- Outputs and level the fan shows for `part` (`offeredFor(kind, id)` is Gathering.offered over the
--- shipped content). Unregistered or depleted nodes offer nothing.
function M.offered(
	part: any,
	offeredFor: (string, string) -> ({ { item: string, quantity: number } }, number?)
): ({ { item: string, quantity: number } }, number?)
	local kind, id = part:GetAttribute("ForgeNodeKind"), part:GetAttribute("ForgeNodeId")
	if type(kind) ~= "string" or type(id) ~= "string" or part:GetAttribute("ForgeNodeDepleted") == true then
		return {}, nil
	end
	local offered, level = offeredFor(kind, id)
	return offered, level
end

--- Per frame: closes the fan once its node turns depleted (the last charge was just taken, by this
--- player or another). Returns true when it closed.
function M.step(picker: any): boolean
	local part = picker.node()
	if part ~= nil and part:GetAttribute("ForgeNodeDepleted") == true then
		picker.close()
		return true
	end
	return false
end

return M
