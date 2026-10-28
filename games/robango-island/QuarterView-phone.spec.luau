--!strict
-- A1 phone zoom: the robango client's default QuarterView config must render the survivor at
-- 6 +- 1% of the short screen axis, measured the way the phone check measures it (head to feet on
-- screen, so the body's depth and shoulder width seen from the 57 degree pitch count too).
-- p134 v36 on the SM-N981N measured 8.2-8.8% while the config counted the height alone.
local fs = require("@lune/fs")
local Fixture = require("../../core/infra/camera/QuarterView.fixture")
local roblox: any = require("@lune/roblox")

local CLIENT = "games/robango-island/src/client/RobangoIslandClient.client.luau"

-- The zoom table literal the client passes to QuarterView.start, evaluated as Luau.
local function clientZoom(): any
	local source = fs.readFile(CLIENT)
	local literal = assert(string.match(source, "zoom = (%b{})"), "client zoom config")
	return (loadstring("return " .. literal) :: any)()
end
local function clientNumber(name: string): number
	local source = fs.readFile(CLIENT)
	local start = assert(string.find(source, "QuarterView.start({", 1, true), "QuarterView.start call")
	return assert(tonumber(string.match(source, name .. " = ([%d%.]+)", start)), name)
end

-- Screen extent (fraction of the short axis) of a ranger-sized R15 body box: 5.5 studs tall,
-- 2 studs shoulder width, 1 stud deep, turned `heading` degrees, centred on the camera focus.
local function bodyShare(camera: any, fov: number, viewport: any, heading: number): number
	local focus = camera.Focus.Position
	local eye = camera.CFrame.Position
	local look = (focus - eye).Unit
	local right = look:Cross(roblox.Vector3.new(0, 1, 0)).Unit
	local up = right:Cross(look)
	local c, s = math.cos(math.rad(heading)), math.sin(math.rad(heading))
	local low, high = math.huge, -math.huge
	for _, x in { -1, 1 } do
		for _, y in { -2.75, 2.75 } do
			for _, z in { -0.5, 0.5 } do
				local corner = focus + roblox.Vector3.new(x * c - z * s, y, x * s + z * c)
				local offset = corner - eye
				local ndc = offset:Dot(up) / (offset:Dot(look) * math.tan(math.rad(fov) / 2))
				low, high = math.min(low, ndc), math.max(high, ndc)
			end
		end
	end
	return (high - low) / 2 * viewport.Y / math.min(viewport.X, viewport.Y)
end

return {
	["default zoom renders the survivor at 6 +- 1 percent of a landscape phone and 720p"] = function()
		local zoom = clientZoom()
		local pitch, fov = clientNumber("pitch"), clientNumber("fieldOfView")
		assert(zoom.share == 0.06, "default share is 6%")
		for _, viewport in { roblox.Vector2.new(2400, 1080), roblox.Vector2.new(1280, 720) } do
			local f = Fixture.new()
			f.world.CurrentCamera = f.camera()
			f.world.CurrentCamera.ViewportSize = viewport
			local api = f.module.start({ pitch = pitch, fieldOfView = fov, zoom = zoom, touchRotate = false })
			f.step(0)
			for heading = 0, 90, 15 do
				local share = bodyShare(f.world.CurrentCamera, fov, viewport, heading)
				assert(
					share >= 0.05 and share <= 0.07,
					string.format("%dx%d heading %d: survivor %.2f%%", viewport.X, viewport.Y, heading, share * 100)
				)
			end
			api.stop()
		end
	end,
}
