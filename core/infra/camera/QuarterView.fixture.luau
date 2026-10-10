--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
-- Lune's generated declarations omit its dynamically registered Roblox datatypes.
local roblox: any = require("@lune/roblox")
local M = {}
function M.new(): any
	local signals = {}
	local function signal(): any
		local listeners: { { callback: (...any) -> (), connection: { Connected: boolean, Disconnect: () -> () } } } = {}
		local event = {}
		function event:Connect(callback)
			local connection = { Connected = true }
			function connection.Disconnect()
				connection.Connected = false
			end
			table.insert(listeners, { callback = callback, connection = connection })
			return connection
		end
		function event:Fire(...)
			for _, listener in table.clone(listeners) do
				if listener.connection.Connected then
					listener.callback(...)
				end
			end
		end
		function event:count()
			local count = 0
			for _, listener in listeners do
				if listener.connection.Connected then
					count += 1
				end
			end
			return count
		end
		table.insert(signals, event)
		return event
	end
	local f: any = { signals = signals, now = 0, obscuring = {}, hit = nil, tags = {} }
	f.world = {}
	f.character = {}
	f.root = {
		Position = roblox.Vector3.zero,
		IsA = function()
			return true
		end,
	}
	function f.character:FindFirstChild(name)
		return if name == "HumanoidRootPart" then f.root else nil
	end
	f.player = { Character = f.character, CharacterAdded = signal(), CharacterRemoving = signal() }
	f.input = { InputChanged = signal(), InputBegan = signal(), TouchPinch = signal(), TouchRotate = signal() }
	function f.input:GetFocusedTextBox()
		return f.focusedTextBox
	end
	function f.input:IsMouseButtonPressed(button)
		return button == roblox.Enum.UserInputType.MouseButton2 and f.rightMousePressed == true
	end
	f.run = {
		RenderStepped = signal(),
		IsClient = function()
			return true
		end,
	}
	function f.camera(): any
		return {
			CameraType = roblox.Enum.CameraType.Custom,
			CameraSubject = f.root,
			CFrame = roblox.CFrame.new(1, 2, 3),
			Focus = roblox.CFrame.new(),
			FieldOfView = 70,
			GetPartsObscuringTarget = function(_, _, ignore)
				assert(ignore[1] == f.character, "camera fixture invariant")
				return f.obscuring
			end,
		}
	end
	f.world.CurrentCamera = f.camera()
	function f.world:Spherecast(origin, radius, direction, params)
		assert(
			radius == 0.75 and params.RespectCanCollide and params.FilterDescendantsInstances[1] == f.character,
			"camera fixture invariant"
		)
		f.cast = { origin = origin, direction = direction }
		return f.hit
	end
	function f.part(original: number?, parent: any?): any
		return {
			Parent = parent or f.world,
			Transparency = 0.2,
			LocalTransparencyModifier = original or 0,
			IsA = function(_, class)
				return class == "BasePart"
			end,
			IsDescendantOf = function(self, ancestor)
				return self.Parent == ancestor
			end,
		}
	end
	f.safe = { Min = roblox.Vector2.new(0, 30), Max = roblox.Vector2.new(390, 810) }
	local services = {
		Workspace = f.world,
		Players = { LocalPlayer = f.player },
		RunService = f.run,
		UserInputService = f.input,
		GuiService = {
			GetInsetArea = function()
				return f.safe
			end,
		},
		CollectionService = {
			HasTag = function(_, part, tag)
				return f.tags[part] == tag
			end,
		},
	}
	f.module = luau.load(fs.readFile("core/infra/camera/QuarterView.luau"), {
		environment = {
			game = {
				GetService = function(_, name)
					return services[name]
				end,
			},
			Vector3 = roblox.Vector3,
			CFrame = roblox.CFrame,
			Enum = roblox.Enum,
			RaycastParams = {
				new = function()
					return {}
				end,
			},
		},
	})()
	function f.step(dt: number)
		assert(dt >= 0, "camera fixture invariant")
		f.now += dt
		f.run.RenderStepped:Fire(dt)
	end
	return f
end
return M
