--!strict
-- Pack wiring binds only an already-authoritative progression owner. It never
-- synthesizes levels, paid nodes, inventories or development from client input.
local M = {}
function M.bind(world: any): ()
	if not world.progression then
		return
	end
	local owner = world.progression
	world.lateEquipment = {
		read = function(actor: string, slice: any, operationId: string?): (any?, any?)
			return owner.read(actor, slice), owner.facts(actor, operationId)
		end,
		write = function(slice: any, aggregate: any)
			owner.write(slice, aggregate)
		end,
	}
end
return M
