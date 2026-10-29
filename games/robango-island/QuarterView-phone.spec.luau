--!strict
-- Durango camera (refs R05/R08/R09) on an 800x360 landscape phone, through the robango client's real
-- QuarterView config (src/shared/CameraConfig) and the module the client runs.
-- p134 v54: the A1 6% share put the arm at ~93 studs, so the survivor was ~20 px tall and a held
-- tool was invisible; pinch did nothing on the phone (TouchPinch arrives gameProcessed there and
-- was dropped) and raising CameraMaxZoomDistance changed nothing (the share ignored stud limits).
local fs = require("@lune/fs")
local Fixture = require("../../core/infra/camera/QuarterView.fixture")
local Config = require("./src/shared/CameraConfig")
local roblox: any = require("@lune/roblox")

local CLIENT = "games/robango-island/src/client/RobangoIslandClient.client.luau"
local PHONE = roblox.Vector2.new(800, 360)

local function near(actual: number, expected: number)
	assert(math.abs(actual - expected) < 0.001, tostring(actual) .. " ~= " .. tostring(expected))
end

-- Screen extent (fraction of the short axis) of a ranger-sized R15 body box: 5.5 studs tall,
-- 2 studs shoulder width, 1 stud deep, turned `heading` degrees, feet on the root - 3 studs.
local function bodyShare(f: any, heading: number): number
	local camera = f.world.CurrentCamera
	-- View basis from eye and focus (Lune's CFrame.lookAt basis is not used as the reference).
	local eye = camera.CFrame.Position
	local look = (camera.Focus.Position - eye).Unit
	local right = look:Cross(roblox.Vector3.new(0, 1, 0)).Unit
	local up = right:Cross(look)
	local feet = f.root.Position - roblox.Vector3.new(0, 3, 0)
	local c, s = math.cos(math.rad(heading)), math.sin(math.rad(heading))
	local low, high = math.huge, -math.huge
	for _, x in { -1, 1 } do
		for _, y in { 0, 5.5 } do
			for _, z in { -0.5, 0.5 } do
				local offset = feet + roblox.Vector3.new(x * c - z * s, y, x * s + z * c) - eye
				local ndc = offset:Dot(up) / (offset:Dot(look) * math.tan(math.rad(Config.fieldOfView) / 2))
				low, high = math.min(low, ndc), math.max(high, ndc)
			end
		end
	end
	return (high - low) / 2
end

local function start(): (any, any)
	local f = Fixture.new()
	f.world.CurrentCamera = f.camera()
	f.world.CurrentCamera.ViewportSize = PHONE
	local config = table.clone(Config) :: any
	config.yaw = 45
	config.pinchBlocked = function()
		return false
	end
	local api = f.module.start(config)
	f.step(0)
	return f, api
end

return {
	["the client starts QuarterView from CameraConfig with the raw pinch on the TapRouter UI test"] = function()
		local source = fs.readFile(CLIENT)
		for _, needle in
			{
				"table.clone(require(Shared.CameraConfig))",
				"cameraConfig.pinchBlocked = function(x: number, y: number): boolean",
				"return TapRouter.overUi(player, x, y)",
				"camera = QuarterView.start(cameraConfig)",
			}
		do
			assert(string.find(source, needle, 1, true), needle .. " wired")
		end
		assert(not string.find(source, "zoom = {", 1, true), "no share zoom: it ignored stud limits")
		assert(Config.minDistance == 12 and Config.maxDistance == 60, "12-60 stud zoom")
		assert(Config.touchRotate == false, "fixed yaw on touch")
		-- TapRouter's UI test is the one the pinch uses (the same rule decides taps).
		local router = fs.readFile("games/robango-island/src/client/TapRouter.luau")
		assert(string.find(router, "function M.overUi(player: Player, x: number, y: number): boolean", 1, true))
		assert(string.find(router, "return M.overUi(player, x, y)", 1, true), "taps use the shared UI test")
	end,
	["default view shows the survivor 50-70 px tall on an 800x360 phone, closest zoom 4x that"] = function()
		local f, api = start()
		near(f.cast.direction.Magnitude, Config.distance)
		for heading = 0, 90, 30 do
			local px = bodyShare(f, heading) * PHONE.Y
			assert(px >= 50 and px <= 70, string.format("default survivor %.0f px at heading %d", px, heading))
		end
		-- Farthest zoom still reads (Durango R08: ~12% of the frame height).
		api.zoomTo(1000)
		f.step(0)
		near(f.cast.direction.Magnitude, 60)
		local far = bodyShare(f, 0)
		assert(far >= 0.12, string.format("far survivor %.1f%%", far * 100))
		-- Closest: the arm is 12 studs, the pitch eased to 30 and the body fills most of the height.
		api.zoomTo(0)
		f.step(0)
		near(f.cast.direction.Magnitude, 12)
		local d = f.cast.direction
		near(math.deg(math.asin(d.Y / d.Magnitude)), Config.closePitch)
		local close = bodyShare(f, 0)
		assert(close >= 0.6, string.format("close survivor %.1f%%", close * 100))
		api.stop()
	end,
	["a two-finger pinch zooms 12-60 studs on the phone and yaw never moves"] = function()
		local f, api = start()
		local yaw0 = math.atan2(f.cast.direction.X, f.cast.direction.Z)
		local function finger(x: number, y: number): any
			return {
				UserInputType = roblox.Enum.UserInputType.Touch,
				UserInputState = roblox.Enum.UserInputState.Begin,
				Position = roblox.Vector3.new(x, y, 0),
			}
		end
		local a, b = finger(350, 180), finger(450, 180)
		-- Phones mark world touches processed; the pinch must not care.
		f.input.InputBegan:Fire(a, true)
		f.input.InputBegan:Fire(b, true)
		b.UserInputState, b.Position = roblox.Enum.UserInputState.Change, roblox.Vector3.new(850, 180, 0)
		f.input.InputChanged:Fire(b, true)
		f.step(0)
		near(f.cast.direction.Magnitude, 12)
		b.Position = roblox.Vector3.new(355, 180, 0)
		f.input.InputChanged:Fire(b, true)
		f.step(0)
		near(f.cast.direction.Magnitude, 60)
		near(math.atan2(f.cast.direction.X, f.cast.direction.Z), yaw0)
		-- A two-finger twist does not rotate on touch.
		f.input.TouchRotate:Fire({ roblox.Vector2.new(400, 180) }, 0, 0, roblox.Enum.UserInputState.Begin, false)
		f.input.TouchRotate:Fire({ roblox.Vector2.new(400, 180) }, 1.2, 0, roblox.Enum.UserInputState.Change, false)
		f.step(0)
		near(math.atan2(f.cast.direction.X, f.cast.direction.Z), yaw0)
		api.stop()
	end,
}
