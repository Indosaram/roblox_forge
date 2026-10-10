--!strict
local Fixture = require("./QuarterView.fixture")
-- Matches the native fixture boundary for Lune's dynamic Roblox exports.
local roblox: any = require("@lune/roblox")
local function near(actual: number, expected: number)
	assert(math.abs(actual - expected) < 0.001, tostring(actual) .. " ~= " .. tostring(expected))
end
return {
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
