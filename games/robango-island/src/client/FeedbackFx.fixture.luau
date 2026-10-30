--!strict
-- Stub engine for FeedbackFx.start (L13): just enough Instance / service surface to run the shipped
-- runtime under Lune and count what it emits. Not a Roblox emulator: properties are plain fields.
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local M = {}

local function signal(): any
	local handlers: { [number]: (...any) -> () } = {}
	local serial = 0
	local s: any = { live = 0 }
	function s.Fire(_, ...)
		for _, fn in table.clone(handlers) do
			fn(...)
		end
	end
	function s.Connect(_, fn)
		serial += 1
		local id = serial
		handlers[id] = fn
		s.live += 1
		return {
			Disconnect = function()
				if handlers[id] then
					handlers[id] = nil
					s.live -= 1
				end
			end,
		}
	end
	return s
end
M.signal = signal

local function vector(x: number, y: number, z: number): any
	local v: any = { X = x, Y = y, Z = z }
	setmetatable(v, {
		__add = function(a: any, b: any): any
			return vector(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
		end,
		__sub = function(a: any, b: any): any
			return vector(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
		end,
		__div = function(a: any, k: number): any
			return vector(a.X / k, a.Y / k, a.Z / k)
		end,
		__index = function(self: any, key: string): any
			if key == "Magnitude" then
				return math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2)
			elseif key == "Position" then
				return self
			end
			return nil
		end,
	})
	return v
end
M.vector = vector

function M.new(): any
	local created: { any } = {}
	local function instance(class: string, name: string?): any
		local item: any = { ClassName = class, Name = name or class, children = {}, attributes = {} }
		local attributeSignals: { [string]: any } = {}
		item.ChildAdded, item.ChildRemoved, item.Destroying = signal(), signal(), signal()
		item.Event, item.OnClientEvent, item.Completed = signal(), signal(), signal()
		item.emitted = 0
		function item.IsA(_, wanted)
			return wanted == class
				or (wanted == "GuiObject" and (class == "ImageLabel" or class == "TextLabel" or class == "Frame"))
				or (wanted == "BasePart" and (class == "Part" or class == "MeshPart"))
		end
		function item.GetAttribute(_, key)
			return item.attributes[key]
		end
		function item.SetAttribute(_, key, value)
			item.attributes[key] = value
			if attributeSignals[key] then
				attributeSignals[key]:Fire()
			end
		end
		function item.GetAttributeChangedSignal(_, key)
			attributeSignals[key] = attributeSignals[key] or signal()
			return attributeSignals[key]
		end
		function item.GetChildren()
			local out = {}
			for _, child in item.children do
				table.insert(out, child)
			end
			return out
		end
		function item.FindFirstChild(_, wanted, recursive)
			for _, child in item.children do
				if child.Name == wanted then
					return child
				end
			end
			if recursive then
				for _, child in item.children do
					local found = child:FindFirstChild(wanted, true)
					if found then
						return found
					end
				end
			end
			return nil
		end
		function item.FindFirstChildOfClass(_, wanted)
			for _, child in item.children do
				if child.ClassName == wanted then
					return child
				end
			end
			return nil
		end
		function item.FindFirstChildWhichIsA(_, wanted)
			for _, child in item.children do
				if child:IsA(wanted) then
					return child
				end
			end
			return nil
		end
		function item.WaitForChild(_, wanted)
			return assert(item:FindFirstChild(wanted), "stub WaitForChild " .. wanted)
		end
		function item.IsDescendantOf(_, ancestor)
			local at = item.Parent
			while at do
				if at == ancestor then
					return true
				end
				at = at.Parent
			end
			return false
		end
		function item.Emit(_, count)
			item.emitted += count
			table.insert(item.emits, { count = count, at = item.Parent and item.Parent.CFrame })
		end
		item.emits = {}
		function item.Destroy()
			item.destroyed = true
			item.Parent = nil
		end
		function item.Disconnect() end
		setmetatable(item, {
			__newindex = function(self, key, value)
				if key == "Parent" then
					local old = rawget(self, "_parent")
					if old then
						for index, child in old.children do
							if child == self then
								table.remove(old.children, index)
								old.ChildRemoved:Fire(self)
								break
							end
						end
					end
					rawset(self, "_parent", value)
					if value then
						table.insert(value.children, self)
						value.ChildAdded:Fire(self)
					end
					return
				end
				rawset(self, key, value)
			end,
			__index = function(self, key)
				if key == "Parent" then
					return rawget(self, "_parent")
				end
				return nil
			end,
		})
		table.insert(created, item)
		return item
	end
	local workspace = instance("Workspace", "Workspace")
	local camera = instance("Camera", "Camera")
	camera.Focus = { Position = vector(0, 0, 0) }
	function camera.WorldToViewportPoint(_, p)
		return { X = 400 + p.X, Y = 300 - p.Y, Z = 10 }, true
	end
	workspace.CurrentCamera = camera
	local player = instance("Player", "Player")
	player.UserId = 11734795308
	local playerGui = instance("PlayerGui", "PlayerGui")
	playerGui.Parent = player
	local storage = instance("ReplicatedStorage", "ReplicatedStorage")
	local state = instance("RemoteEvent", "ForgeState")
	state.Parent = storage
	local heartbeat = signal()
	local tagged: { [string]: { any } } = {}
	local tweens: { any } = {}
	local delays: { () -> () } = {}
	local services: { [string]: any } = {
		Players = { LocalPlayer = player },
		RunService = { Heartbeat = heartbeat },
		ReplicatedStorage = storage,
		CollectionService = {
			GetTagged = function(_, tag)
				return tagged[tag] or {}
			end,
		},
		TweenService = {
			Create = function(_, target, _info, goal)
				local t: any = { target = target, goal = goal, Completed = signal() }
				function t.Play()
					table.insert(tweens, t)
					for key, value in goal do
						target[key] = value
					end
					t.Completed:Fire()
				end
				return t
			end,
		},
	}
	local function enumOf(names: { string }): any
		local out = {}
		for _, n in names do
			out[n] = n
		end
		return out
	end
	local Enum = {
		NormalId = enumOf({ "Top", "Bottom" }),
		ParticleOrientation = enumOf({ "VelocityParallel" }),
		HighlightDepthMode = enumOf({ "Occluded" }),
		EasingStyle = enumOf({ "Back", "Quad" }),
		EasingDirection = enumOf({ "In", "Out" }),
		SizeConstraint = enumOf({ "RelativeYY" }),
		HumanoidStateType = enumOf({ "Swimming", "Running" }),
	}
	local env = {
		game = {
			GetService = function(_, name)
				return assert(services[name], name)
			end,
		},
		workspace = workspace,
		Enum = Enum,
		Instance = { new = instance },
		Vector3 = { new = vector },
		Vector2 = {
			new = function(x, y)
				return { X = x, Y = y }
			end,
		},
		UDim2 = {
			fromOffset = function(x, y)
				return { x = x, y = y }
			end,
			fromScale = function(x, y)
				return { sx = x, sy = y }
			end,
			new = function(a, b, c, d)
				return { a, b, c, d }
			end,
		},
		CFrame = {
			new = function(x, y, z)
				return if type(x) == "table" then vector(x.X, x.Y, x.Z) else vector(x, y, z)
			end,
		},
		Color3 = {
			fromRGB = function(r, g, b)
				return { r, g, b }
			end,
		},
		NumberRange = {
			new = function(a, b)
				return { a, b or a }
			end,
		},
		NumberSequence = {
			new = function(a, b)
				return { a, b or a }
			end,
		},
		ColorSequence = {
			new = function(c)
				return { c }
			end,
		},
		TweenInfo = {
			new = function(...)
				return { ... }
			end,
		},
		task = {
			delay = function(_, fn)
				table.insert(delays, fn)
			end,
		},
	}
	local Fx = luau.load(fs.readFile("games/robango-island/src/client/FeedbackFx.luau"), {
		debugName = "FeedbackFx",
		environment = env,
	})()
	return {
		Fx = Fx,
		env = env,
		instance = instance,
		created = created,
		workspace = workspace,
		player = player,
		playerGui = playerGui,
		state = state,
		heartbeat = heartbeat,
		tagged = tagged,
		tweens = tweens,
		flushDelays = function()
			local queued = table.clone(delays)
			table.clear(delays)
			for _, fn in queued do
				fn()
			end
		end,
		-- The emitters FeedbackFx built, by name, with their Emit totals.
		emitters = function(): { [string]: any }
			local out = {}
			for _, item in created do
				if item.ClassName == "ParticleEmitter" then
					out[item.Name] = item
				end
			end
			return out
		end,
	}
end

return M
