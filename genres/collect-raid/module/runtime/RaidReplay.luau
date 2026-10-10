--!strict
-- RaidReplay: camera swoop around the raided team's vault crate.

local TweenService = game:GetService("TweenService")

export type Options = {
	remotes: { RaidReplay: RemoteEvent },
	worldName: string,
}

local RaidReplay = {}

function RaidReplay.start(opts: Options): ()
	local playing = false

	opts.remotes.RaidReplay.OnClientEvent:Connect(function(data: any)
		if playing or type(data) ~= "table" then
			return
		end

		local world = workspace:FindFirstChild(opts.worldName)
		local folder = world and world:FindFirstChild(tostring(data.rival) .. "Base")
		local vault = folder and folder:FindFirstChild(tostring(data.rival) .. "Vault")
		local crate = vault and vault:FindFirstChild("Crate") :: BasePart?
		if not crate then
			return
		end

		playing = true

		local cam = workspace.CurrentCamera
		local prevType = cam.CameraType
		cam.CameraType = Enum.CameraType.Scriptable

		local target = crate.Position
		local r = 28
		for step = 0, 3 do
			local a = math.rad(step * 90 + 30)
			local cf = CFrame.lookAt(target + Vector3.new(math.cos(a) * r, 14, math.sin(a) * r), target)
			local tween = TweenService:Create(cam, TweenInfo.new(0.9, Enum.EasingStyle.Sine), { CFrame = cf })
			tween:Play()
			tween.Completed:Wait()
		end

		cam.CameraType = prevType
		playing = false
	end)
end

return RaidReplay
