--!strict
-- No multistorey production command exists until integration. This fixture
-- exercises the exact domain candidate and collision/camera ports, not a fake
-- settlement-place command that would prove only the legacy flat grid.
local Building = require("../../../../core/domain/settlement/Multistorey")
local Aerial = require("../../../../genres/survival-coop/module/AerialView")
local Content: any = require("../../../../games/robango-island/src/shared/SurvivalContent")
local M = {}
M.operations = {
	multistorey_home = function(ctx, step): string?
		local err = ctx.fixture.run()
		ctx.results[ctx.playerOf(step)] = { ok = err == nil }
		return err
	end,
}
function M.new(_ctx): any
	local state = Building.new()
	local captures: { any } = {}
	return {
		run = function(): string?
			local region = nil
			for _, candidate in Content.supportRegions do
				if candidate.id == "rw.home" then
					region = candidate
				end
			end
			assert(region, "home catalog required")
			local policy = { floors = 3, cellStuds = 16, floorHeight = 12, baseY = 2, stairSteps = 16 }
			for floor = 1, 3 do
				local function place(kind: string, x: number)
					state = assert(
						Building.place(
							state,
							policy,
							{ id = kind .. floor .. x, kind = kind, floor = floor, x = x, z = 0 },
							state.version
						),
						"scenario.luau: invariant at line 31"
					)
				end
				place("floor", 0)
				assert(Building.reachable(state, floor, 0, 0), "scenario.luau: invariant at line 41")
				place("floor", 1)
				if floor < 3 then
					place("pillar", 0)
					place("pillar", 1)
					place("stairs", 0)
				end
			end
			for _, id in { "pillar10", "pillar20", "stairs10", "stairs20" } do
				assert(not Building.remove(state, id, state.version), "scenario.luau: invariant at line 50")
			end
			for _, aspect in { 360 / 640, 1280 / 720 } do
				for floor = 1, 3 do
					local boxes = {}
					for _, part in state.parts do
						if part.floor == floor then
							for _, box in Building.geometry(policy, part, state) do
								assert(box.canCollide, "scenario.luau: invariant at line 58")
								table.insert(boxes, box)
							end
						end
					end
					table.insert(captures, { aspect = aspect, floor = floor, boxes = boxes })
				end
				local frame = Aerial.frame({ x = -160, y = 2, z = -160 }, { x = 160, y = 28, z = 160 }, aspect, 30, 0)
				table.insert(captures, { aspect = aspect, aerial = frame })
			end
			return nil
		end,
		snapshot = function()
			return { building = state, geometry = captures }
		end,
	}
end
return M
