--!strict
-- Translate the generated survival catalog, never a second crop balance table.
local M = {}
function M.crops(content: any): any
	local crops = {}
	for _, operation in content.operations do
		local name = string.match(operation.id, "^plant%-(.+)$")
		if name then
			local seed = operation.primaryInputs[1]
			local output: string? = nil
			for _, recipe in content.recipes do
				if recipe.id == "extract-" .. name .. "-seed" then
					output = recipe.inputs[1].item
				end
			end
			local seconds, quantity = 0, 0
			for _, effect in operation.effects do
				if effect.id == "growth-minutes" then
					seconds = effect.value * 60
				elseif effect.id == "harvest-yield" then
					quantity = effect.value
				end
			end
			assert(output and seconds > 0 and quantity > 0, "INCOMPLETE_CROP")
			crops[name] = {
				seed = seed,
				output = output,
				seconds = seconds,
				quantity = quantity,
				inputs = operation.inputs,
				nodes = operation.gates.skillNodes,
			}
		end
	end
	return crops
end
return M
