--!strict
local Fixture = require("./QuarterView.fixture")
-- Matches the native fixture boundary for Lune's dynamic Roblox exports.
local roblox: any = require("@lune/roblox")
local function near(actual: number, expected: number)
	assert(math.abs(actual - expected) < 0.001, tostring(actual) .. " ~= " .. tostring(expected))
end
-- Projects a vertical segment of `height` studs centred on the camera focus through the camera's
-- actual CFrame and vertical FOV; returns its height as a fraction of the short screen axis.
local function projectedShare(camera: any, height: number, fov: number, viewport: any): number
	local focus = camera.Focus.Position
	-- View basis from eye and focus (Lune's CFrame.lookAt basis is not used as the reference).
	local eye = camera.CFrame.Position
	local look = (focus - eye).Unit
	local right = look:Cross(roblox.Vector3.new(0, 1, 0)).Unit
	local up = right:Cross(look)
	local function ndcY(point: any): number
		local offset = point - eye
		return offset:Dot(up) / (offset:Dot(look) * math.tan(math.rad(fov) / 2))
	end
	local top = ndcY(focus + roblox.Vector3.new(0, height / 2, 0))
	local bottom = ndcY(focus - roblox.Vector3.new(0, height / 2, 0))
	local pixels = math.abs(top - bottom) / 2 * viewport.Y
	return pixels / math.min(viewport.X, viewport.Y)
end
return {
	["zoom by on-screen character height matches the projection and clamps the pinch range"] = function()
		local f = Fixture.new()
		local zoom = { characterHeight = 5.5, share = 0.06, minShare = 0.03, maxShare = 0.15 }
		for _, viewport in
			{ roblox.Vector2.new(2400, 1080), roblox.Vector2.new(1280, 720), roblox.Vector2.new(1080, 2400) }
		do
			f.world.CurrentCamera = f.camera()
			f.world.CurrentCamera.ViewportSize = viewport
			local api = f.module.start({ pitch = 57, fieldOfView = 30, zoom = zoom, touchRotate = false })
			f.step(0)
			local camera = f.world.CurrentCamera
			local distance = f.cast.direction.Magnitude
			near(f.cast.direction.Y, math.sin(math.rad(57)) * distance)
			near(f.module.screenShare(distance, 5.5, 57, 30, viewport.X / viewport.Y), 0.06)
			-- Independent check: project the character through the rendered camera transform.
			local projected = projectedShare(camera, 5.5, 30, viewport)
			assert(math.abs(projected - 0.06) < 0.0005, "default share " .. projected)
			assert(api.share() == 0.06, "api share")
			local positions = { roblox.Vector2.new(100, 100), roblox.Vector2.new(200, 200) }
			local state = roblox.Enum.UserInputState
			f.input.TouchPinch:Fire(positions, 1, 0, state.Begin, false)
			f.input.TouchPinch:Fire(positions, 0.1, 0, state.Change, false)
			f.step(0)
			local far = f.cast.direction.Magnitude
			assert(math.abs(projectedShare(camera, 5.5, 30, viewport) - 0.03) < 0.0005, "pinch-out floor 3%")
			f.input.TouchPinch:Fire(positions, 10, 0, state.Change, false)
			f.step(0)
			local close = f.cast.direction.Magnitude
			assert(math.abs(projectedShare(camera, 5.5, 30, viewport) - 0.15) < 0.001, "pinch-in ceiling 15%")
			near(far / close, 5)
			f.input.TouchPinch:Fire(positions, 1, 0, state.End, false)
			if viewport.X == 2400 then
				-- 20:9 landscape phone: default arm 6% = ~93 studs; range ~37 (15%) to ~186 (3%) studs.
				near(distance, f.module.distanceForShare(0.06, 5.5, 57, 30, 2400 / 1080))
				assert(distance > 90 and distance < 96, "phone default arm " .. distance)
			end
			api.stop()
		end
	end,
	["touch rotation can be disabled while keys keep rotating"] = function()
		local f = Fixture.new()
		local api = f.module.start({ touchRotate = false })
		f.step(0)
		local original = f.cast.direction
		local state = roblox.Enum.UserInputState
		f.input.TouchRotate:Fire({ roblox.Vector2.new(100, 100) }, 0, 0, state.Begin, false)
		f.input.TouchRotate:Fire({ roblox.Vector2.new(100, 100) }, math.pi / 2, 0, state.Change, false)
		f.step(0)
		near(f.cast.direction.X, original.X)
		near(f.cast.direction.Z, original.Z)
		f.input.InputBegan:Fire({ KeyCode = roblox.Enum.KeyCode.RightBracket }, false)
		f.step(0)
		near(f.cast.direction.Z, 0)
		api.stop()
	end,
	["rotation respects consumed input safe area and disposal"] = function()
		local f = Fixture.new()
		local api = f.module.start()
		f.step(0)
		local original = f.cast.direction
		f.input.InputBegan:Fire({ KeyCode = roblox.Enum.KeyCode.RightBracket }, true)
		f.step(0)
		near(f.cast.direction.X, original.X)
		f.input.InputBegan:Fire({ KeyCode = roblox.Enum.KeyCode.RightBracket }, false)
		f.step(0)
		near(f.cast.direction.X, math.cos(math.rad(55)) * 85)
		near(f.cast.direction.Z, 0)
		f.input.TouchRotate:Fire({ roblox.Vector2.new(10, 0) }, 1, 0, roblox.Enum.UserInputState.Begin, false)
		f.step(0)
		near(f.cast.direction.Z, 0)
		f.input.TouchRotate:Fire(
			{ roblox.Vector2.new(100, 100) },
			math.pi / 4,
			0,
			roblox.Enum.UserInputState.Begin,
			false
		)
		f.step(0)
		near(f.cast.direction.X, original.X)
		near(f.cast.direction.Z, original.Z)
		api.stop()
		assert(
			f.input.InputBegan:count() == 0 and f.input.TouchRotate:count() == 0,
			"rotation input connections disposed"
		)
	end,
	["quarter view projection zoom and solid collision retain character visibility"] = function()
		local f = Fixture.new()
		local api = f.module.start()
		f.step(1 / 60)
		local camera = f.world.CurrentCamera
		assert(
			camera.CameraType == roblox.Enum.CameraType.Scriptable and camera.FieldOfView == 30,
			"camera fixture invariant"
		)
		near(f.cast.direction.Magnitude, 85)
		near(f.cast.direction.Y, math.sin(math.rad(55)) * 85)
		near(f.cast.direction.X, f.cast.direction.Z)
		f.input.InputChanged:Fire(
			{ UserInputType = roblox.Enum.UserInputType.MouseWheel, Position = { Z = 100 } },
			true
		)
		f.step(0)
		near(f.cast.direction.Magnitude, 85)
		f.input.InputChanged:Fire(
			{ UserInputType = roblox.Enum.UserInputType.MouseWheel, Position = { Z = 100 } },
			false
		)
		f.step(0)
		near(f.cast.direction.Magnitude, 60)
		api.setView(135, 55, 500)
		f.step(0)
		near(f.cast.direction.Magnitude, 110)
		f.hit = { Distance = 12 }
		f.step(0)
		near((camera.CFrame.Position - camera.Focus.Position).Magnitude, 11.75)
		api.stop()
	end,
	["tagged local fades restore on clear respawn camera replacement and stop"] = function()
		local f = Fixture.new()
		local roof, wall, avatar = f.part(0.1), f.part(), f.part(0, f.character)
		f.tags[roof], f.tags[avatar] = "ForgeCameraRoof", "ForgeCameraOccluder"
		f.obscuring = { roof, wall, avatar }
		local api = f.module.start()
		local original = f.world.CurrentCamera
		f.step(0)
		assert(roof.LocalTransparencyModifier == 0.7 and roof.Transparency == 0.2, "camera fixture invariant")
		assert(
			wall.LocalTransparencyModifier == 0 and avatar.LocalTransparencyModifier == 0,
			"camera fixture invariant"
		)
		f.obscuring = {}
		f.step(0)
		assert(roof.LocalTransparencyModifier == 0.1, "camera fixture invariant")
		f.obscuring = { roof }
		f.step(0)
		f.player.CharacterRemoving:Fire(f.character)
		assert(roof.LocalTransparencyModifier == 0.1, "camera fixture invariant")
		f.step(0)
		f.player.CharacterAdded:Fire(f.character)
		assert(roof.LocalTransparencyModifier == 0.1, "camera fixture invariant")
		f.world.CurrentCamera = f.camera()
		f.step(0)
		assert(
			original.CameraType == roblox.Enum.CameraType.Custom and original.FieldOfView == 70,
			"camera fixture invariant"
		)
		local replacement = f.world.CurrentCamera
		api.stop()
		api.stop()
		assert(roof.LocalTransparencyModifier == 0.1 and replacement.FieldOfView == 70, "camera fixture invariant")
		assert(
			replacement.CFrame == roblox.CFrame.new(1, 2, 3) and replacement.CameraSubject == f.root,
			"camera fixture invariant"
		)
		for _, signal in f.signals do
			assert(signal:count() == 0, "connection leaked")
		end
		f.step(1)
		assert(replacement.FieldOfView == 70, "camera fixture invariant")
	end,
	["mobile pinch uses cumulative scale and safe area rejects UI gestures"] = function()
		local f = Fixture.new()
		local api = f.module.start()
		local positions = { roblox.Vector2.new(100, 100), roblox.Vector2.new(200, 200) }
		local state = roblox.Enum.UserInputState
		f.input.TouchPinch:Fire(positions, 1, 0, state.Begin, false)
		f.input.TouchPinch:Fire(positions, 2, 0, state.Change, false)
		f.step(0)
		near(f.cast.direction.Magnitude, 60)
		f.input.TouchPinch:Fire(positions, 0.5, 0, state.Change, false)
		f.step(0)
		near(f.cast.direction.Magnitude, 110)
		f.input.TouchPinch:Fire(positions, 1, 0, state.End, false)
		f.input.TouchPinch:Fire(positions, 2, 0, state.Change, false)
		f.step(0)
		near(f.cast.direction.Magnitude, 110)
		positions[1] = roblox.Vector2.new(5, 5)
		f.input.TouchPinch:Fire(positions, 1, 0, state.Begin, false)
		f.input.TouchPinch:Fire(positions, 2, 0, state.Change, false)
		f.step(0)
		near(f.cast.direction.Magnitude, 110)
		api.stop()
	end,
}
