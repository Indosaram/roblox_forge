--!strict
local Aerial = require("./AerialView")
return {
	["portrait and desktop frame all island corners with margin at every orbit"] = function()
		for _, aspect in { 360 / 640, 1280 / 720 } do
			for _, yaw in { 0, math.pi / 2, math.pi, math.pi * 1.5 } do
				local frame = Aerial.frame({ x = -160, y = 2, z = -160 }, { x = 160, y = 28, z = 160 }, aspect, 30, yaw)
				local halfAngle = math.min(math.rad(15), math.atan(math.tan(math.rad(15)) * aspect))
				local radius = math.sqrt(320 ^ 2 + 26 ^ 2 + 320 ^ 2) / 2
				assert(
					frame.distance * math.sin(halfAngle) >= radius * 1.099999,
					"AerialView.spec.luau: invariant at line 10"
				)
			end
		end
	end,
	["aerial restores exact camera and UI state once and captures locally"] = function()
		local saved = { camera = "previous", ui = false }
		local restores, captures = 0, 0
		local last: any = nil
		local view = Aerial.start({
			read = function()
				return saved
			end,
			apply = function(frame)
				last = frame
			end,
			hideUI = function(hidden)
				assert(hidden, "AerialView.spec.luau: invariant at line 26")
			end,
			captureLocal = function()
				captures += 1
				return "local.png"
			end,
			restore = function(value)
				assert(value == saved, "AerialView.spec.luau: invariant at line 33")
				restores += 1
			end,
		}, { x = -160, y = 2, z = -160 }, { x = 160, y = 28, z = 160 }, 360 / 640, 30)
		local minimum = last.distance
		view.zoom(0)
		assert(last.distance == minimum, "AerialView.spec.luau: invariant at line 39")
		view.zoom(math.huge)
		assert(last.distance == minimum * 2, "AerialView.spec.luau: invariant at line 41")
		view.orbit(math.pi)
		view.hideUI(true)
		assert(view.capture() == "local.png" and captures == 1, "AerialView.spec.luau: invariant at line 44")
		view.close()
		view.close()
		assert(restores == 1 and not pcall(view.orbit, 1), "AerialView.spec.luau: invariant at line 47")
	end,
}
