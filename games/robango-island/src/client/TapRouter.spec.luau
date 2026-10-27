--!strict
local TapRouter = require("./TapRouter")
local function probe(fields: { [string]: any }): any
	return fields
end
return {
	["tap priority is ui then creature then node then ground and handlers can pass"] = function()
		local router = TapRouter.new()
		local seen = {}
		for _, kind in { "ground", "node", "creature" } do
			router.register(kind :: any, function(target)
				table.insert(seen, kind .. ":" .. tostring(target))
				return true
			end)
		end
		local all = { creature = "rex", node = "flint", ground = "dirt" }
		assert(
			router.dispatch(probe({ overUi = true, creature = "rex", node = "flint", ground = "dirt" })) == "ui",
			"ui first"
		)
		assert(#seen == 0, "ui tap reaches no world handler")
		assert(router.dispatch(probe(all)) == "creature" and seen[1] == "creature:rex", "creature over node")
		assert(
			router.dispatch(probe({ node = "flint", ground = "dirt" })) == "node" and seen[2] == "node:flint",
			"node over ground"
		)
		assert(router.dispatch(probe({ ground = "dirt" })) == "ground" and seen[3] == "ground:dirt", "ground last")
		assert(router.dispatch(probe({})) == nil, "empty tap routes nowhere")
		-- A newer handler (C2/C3) runs first; returning false passes to older ones, then lower kinds.
		local remove = router.register("creature", function()
			table.insert(seen, "combat")
			return false
		end)
		assert(router.dispatch(probe(all)) == "creature" and seen[4] == "combat" and seen[5] == "creature:rex", "pass")
		remove()
		local unregisterNode = router.register("node", function()
			return false
		end)
		local fallthrough = TapRouter.new()
		fallthrough.register("node", function()
			return false
		end)
		fallthrough.register("ground", function()
			return true
		end)
		assert(
			fallthrough.dispatch(probe({ node = "flint", ground = "dirt" })) == "ground",
			"declined node falls to ground"
		)
		unregisterNode()
		assert(router.dispatch(probe(all)) == "creature" and seen[6] == "creature:rex", "removed handler gone")
		assert(not pcall(router.register, "wall" :: any, function() end), "unknown kind rejected")
	end,
	["tap versus drag versus pinch gesture sessions"] = function()
		local g = TapRouter.gesture()
		g.began(1, 100, 100, false)
		assert(g.moved(1, 108, 104) == nil, "inside slop is still a tap")
		assert(g.ended(1, 108, 104) == "tap", "clean tap")
		g.began(1, 100, 100, false)
		assert(g.moved(1, 140, 100) == "steer" and g.steering(), "drag steers")
		local ox, oy = g.origin()
		assert(ox == 100 and oy == 100, "drag origin")
		assert(g.ended(1, 140, 100) == "release", "drag release")
		g.began(1, 100, 100, false)
		g.began(2, 300, 300, false)
		assert(g.moved(1, 200, 100) == nil, "pinch never steers")
		assert(g.ended(2, 300, 300) == nil and g.ended(1, 100, 100) == nil, "pinch is no tap")
		g.began(1, 100, 100, true)
		assert(g.moved(1, 200, 100) == nil and g.ended(1, 100, 100) == nil, "ui touches never reach the world")
		g.began(1, 100, 100, false)
		g.cancel()
		assert(g.ended(1, 100, 100) == nil and not g.steering(), "respawn cancels")
	end,
	["picking prefers the closest visible candidate inside the radius"] = function()
		local list = {
			{ target = "behind", x = 101, y = 101, visible = false },
			{ target = "far", x = 180, y = 100, visible = true },
			{ target = "near", x = 120, y = 110, visible = true },
		}
		assert(TapRouter.nearest(100, 100, list, TapRouter.PICK_RADIUS) == "near", "nearest visible")
		assert(TapRouter.nearest(500, 500, list, TapRouter.PICK_RADIUS) == nil, "none in radius")
	end,
	["path route drops the start point and falls back to a straight line"] = function()
		local a, b, goal = { x = 0 }, { x = 5 }, { x = 9 }
		local route =
			TapRouter.route("Success", { { position = a, jump = false }, { position = b, jump = true } }, goal)
		assert(#route == 1 and route[1].position == b and route[1].jump, "computed path")
		for _, status in { "NoPath", "ClosestNoPath", "Error" } do
			local line = TapRouter.route(status, {}, goal)
			assert(#line == 1 and line[1].position == goal and not line[1].jump, status .. " straight line")
		end
		local short = TapRouter.route("Success", { { position = a, jump = false } }, goal)
		assert(#short == 1 and short[1].position == goal, "single-point path walks to the goal")
	end,
	["ground taps stop at the last land point and refuse a tap straight into the sea"] = function()
		-- Land is x < 20; the sea starts at x = 20.
		local function isLand(x: number, _z: number): boolean
			return x < 20
		end
		local x, z = TapRouter.shore({ X = 0, Y = 0, Z = 0 }, { X = 10, Y = 0, Z = 5 }, isLand)
		assert(x == 10 and z == 5, "an all-land tap keeps its exact goal")
		x, z = TapRouter.shore({ X = 0, Y = 0, Z = 0 }, { X = 60, Y = 0, Z = 0 }, isLand)
		assert(x and z == 0 and x < 20 and x >= 20 - TapRouter.SHORE_STEP, "stops on the last land sample")
		x, z = TapRouter.shore({ X = 0, Y = 0, Z = 0 }, { X = 60, Y = 0, Z = 0 }, function(px)
			return px < 20 or px > 30
		end)
		assert(x and x < 20, "a far island behind open water is not reached by walking through it")
		x = TapRouter.shore({ X = 19, Y = 0, Z = 0 }, { X = 60, Y = 0, Z = 0 }, isLand)
		assert(x == nil, "standing on the shore, a sea tap is refused")
		x = TapRouter.shore({ X = 25, Y = 0, Z = 0 }, { X = 40, Y = 0, Z = 0 }, isLand)
		assert(x == nil, "a tap further out to sea is refused")
		x, z = TapRouter.shore({ X = 25, Y = 0, Z = 0 }, { X = 5, Y = 0, Z = 0 }, isLand)
		assert(x == 5 and z == 0, "a wading player can walk back ashore")
	end,
	["drag steers along the camera's flattened axes"] = function()
		-- Camera looking north (-Z): right is +X.
		local right, forward = { x = 1, z = 0 }, { x = 0, z = -1 }
		local x, z = TapRouter.steer(0, -50, right, forward)
		assert(x == 0 and z == -1, "drag up walks away from the camera")
		x, z = TapRouter.steer(50, 0, right, forward)
		assert(x == 1 and z == 0, "drag right walks screen-right")
		x, z = TapRouter.steer(5, 5, right, forward)
		assert(x == nil and z == nil, "inside slop no steer")
	end,
}
