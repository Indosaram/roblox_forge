--!strict
-- Build-mode ghost input and occupancy rules (p60 real-input Studio run). Pure: the HUD passes
-- input kinds, positions and a world probe, so Lune specs exercise every branch.
local M = {}

-- PC rotate key for the build ghost. R is rest; Y is bound nowhere else (I C B R F V X Q G Z M P T E).
M.ROTATE_KEY = "Y"

-- The touch camera marks every touch drag processed, so touch ignores `processed` and only skips
-- touches over a HUD control. A mouse hover moves the ghost only while it is not over the GUI and
-- no click has locked a cell (p68: hovering toward 'reserve' dragged the ghost under the bar edge).
function M.pointerUse(kind: string, processed: boolean, overControl: boolean, locked: boolean?): boolean
	if kind == "MouseMovement" then
		return not processed and not overControl and not locked
	end
	return kind == "Touch" and not overControl
end

-- A left click on the world (not on any GUI) moves the ghost there and locks it, so the pointer can
-- travel to the placement bar without moving the picked cell. Another world click re-picks.
function M.clickLocks(kind: string, processed: boolean, overControl: boolean): boolean
	return kind == "MouseButton1" and not processed and not overControl
end

-- A touch that ends within 12 px of where it began is a tap: the ghost jumps to that cell.
function M.isTap(startX: number, startY: number, endX: number, endY: number): boolean
	return (endX - startX) ^ 2 + (endY - startY) ^ 2 <= 144
end

-- True when the instance or an ancestor is a wildlife model (WildlifeWorld sets ForgeWildlifeId).
function M.creature(instance: any): boolean
	local node = instance
	while node do
		if node:GetAttribute("ForgeWildlifeId") ~= nil then
			return true
		end
		node = node.Parent
	end
	return false
end

-- Mirror of SurvivalWorld settlementPorts.verify after its reach check (server and HUD share it).
-- probe(cell) returns the support ray hit (or nil) and the parts in the cell box. Without
-- requireSupport (client: terrain may not be streamed in) a missing hit is unknown, not a refusal.
function M.occupancy(cells: { any }, probe: (any) -> (any, { any }), requireSupport: boolean): string?
	for _, cell in cells do
		local support, parts = probe(cell)
		if support and M.creature(support.Instance) then
			return "PLACEMENT_BLOCKED_CREATURE"
		end
		if (requireSupport and not support) or (support and support.Normal.Y < 0.9) then
			return "PLACEMENT_UNSUPPORTED"
		end
		for _, part in parts do
			if M.creature(part) then
				return "PLACEMENT_BLOCKED_CREATURE"
			end
		end
		if #parts > 0 then
			return "PLACEMENT_BLOCKED"
		end
	end
	return nil
end

return M
