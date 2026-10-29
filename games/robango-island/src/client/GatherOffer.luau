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

--- L10b small second line of a node's floating label (R05-1 "돌멩이 Lv 1"): its authored level and
--- what it is gathered with, e.g. "Lv 1 - By hand". `nodes` are the node rows that may carry a level or
--- requiredToolTag (layout resourceNodes, preview world nodes), matched on ForgeNodeId. `text(key)`
--- returns the cli.gather.* line, `tagName(tag)` a tool tag's display name. nil when nothing to say.
function M.hint(part: any, nodes: { any }, text: (string) -> string?, tagName: (string) -> string): string?
	if part:GetAttribute("ForgeNodeDepleted") == true then
		return nil
	end
	local id = part:GetAttribute("ForgeNodeId")
	local row: any = nil
	for _, node in nodes do
		if node.id == id then
			row = node
		end
	end
	local tool = if row and type(row.requiredToolTag) == "string"
		then string.format(text("tool") or "%s", tagName(row.requiredToolTag))
		else text("hand")
	local level = if row and type(row.level) == "number"
		then string.format(text("level") or "Lv %d", row.level)
		else nil
	if level and tool then
		return level .. " - " .. tool
	end
	return level or tool
end

return M
