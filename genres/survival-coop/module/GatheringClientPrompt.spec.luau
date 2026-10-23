--!strict
-- Drives the real GatheringClient prompt (loaded as text into a minimal engine double, so the
-- Roblox-only module is never type-checked on the Lune platform).
local luau = require("@lune/luau")
local fs = require("@lune/fs")
local Transport = require("../../../core/infra/genre/CommandTransport")

-- Minimal engine double: just enough Instances/services for GatheringClient.start.
local function clientHarness(answer: (any) -> any): any
	local function signal(): any
		local listeners: { { c: any, f: (...any) -> () } } = {}
		local s = {}
		function s:Connect(callback)
			local connection = { Connected = true }
			function connection.Disconnect()
				connection.Connected = false
			end
			table.insert(listeners, { c = connection, f = callback })
			return connection
		end
		function s:Fire(...)
			for _, l in table.clone(listeners) do
				if l.c.Connected then
					l.f(...)
				end
			end
		end
		return s
	end
	local function new(class: string): any
		local o: any = { ClassName = class, Anchored = true, attrs = {} }
		o.Triggered, o.Activated, o.Event = signal(), signal(), signal()
		o.AttributeChanged, o.AncestryChanged = signal(), signal()
		function o:IsA(c)
			return c == self.ClassName or (c == "BasePart" and self.ClassName == "Part")
		end
		function o:IsDescendantOf(p)
			return self.Parent == p
		end
		function o:GetAttribute(k)
			return self.attrs[k]
		end
		function o:SetAttribute(k, v)
			self.attrs[k] = v
			self.AttributeChanged:Fire(k)
		end
		function o:Fire(...)
			self.Event:Fire(...)
		end
		function o:Destroy()
			self.Parent = nil
		end
		return o
	end
	local world = new("Workspace")
	function world:GetServerTimeNow()
		return 0
	end
	local player: any = { UserId = 1, children = {} }
	function player:FindFirstChild(_name)
		return nil
	end
	function player:WaitForChild(_name)
		return new("PlayerGui")
	end
	local node = new("Part")
	node.Parent = world
	node.attrs = {
		ForgeNodeId = "rw.a1.s1.material.wood",
		ForgeNodeKind = "rw-a1-s1-material-wood",
		ForgeNodeItem = "wood",
		ForgeNodeVersion = 3,
		ForgeNodeWorldRevision = "w",
		ForgeNodeCount = 10,
		ForgeNodeDepleted = false,
	}
	local policy = { actions = { "survival-coop:gather" }, epochs = { ["survival-coop:gather"] = 1 } }
	local sent: { any } = {}
	local remote = {}
	function remote:InvokeServer(...)
		local args = table.pack(...)
		if args.n == 0 then
			return { ok = true, durable = policy }
		end
		table.insert(sent, args[2])
		return answer(args[2])
	end
	local tags = {}
	function tags:GetTagged()
		return { node }
	end
	function tags:HasTag(part)
		return part == node
	end
	function tags:GetInstanceAddedSignal()
		return signal()
	end
	function tags:GetInstanceRemovedSignal()
		return signal()
	end
	local guid = 0
	local services: any = {
		Workspace = world,
		CollectionService = tags,
		Players = { LocalPlayer = player },
		ProximityPromptService = { PromptShown = signal(), PromptHidden = signal() },
		RunService = { RenderStepped = signal() },
		UserInputService = { TouchEnabled = false },
		HttpService = {
			GenerateGUID = function()
				guid += 1
				return "g" .. guid
			end,
		},
		ReplicatedStorage = {
			WaitForChild = function(_, name)
				return if name == "ForgeAction" then remote else { OnClientEvent = signal() }
			end,
		},
	}
	local prompt: any = nil
	local module = luau.load(fs.readFile("genres/survival-coop/module/GatheringClient.luau"), {
		environment = {
			game = {
				GetService = function(_, name)
					return services[name]
				end,
			},
			Instance = {
				new = function(class)
					local o = new(class)
					if class == "ProximityPrompt" then
						prompt = o
					end
					return o
				end,
			},
			Color3 = { fromRGB = function() end },
			UDim2 = { fromOffset = function() end, new = function() end },
			UDim = { new = function() end },
			Enum = {
				KeyCode = { E = "E" },
				ScreenInsets = { CoreUISafeInsets = 0 },
				Font = { GothamBold = 0 },
			},
			task = { delay = function() end },
			require = function()
				return Transport
			end,
		},
	})()
	local handle = module.start({ locale = "ko-kr" })
	return {
		prompt = prompt,
		sent = sent,
		press = function()
			prompt.Triggered:Fire(player)
		end,
		destroy = handle.destroy,
	}
end

return {
	["a final refusal (missing tool) ends the request and restores the prompt"] = function()
		-- Studio p37: wood without a starter axe answered TOOL_UNAVAILABLE and the prompt stayed
		-- '채집 중...' forever because the refused request was kept pending.
		local refusal = {
			ok = false,
			reason = "TOOL_UNAVAILABLE",
			data = { status = "rejected", requirement = { tool = "starter-axe" } },
		}
		local h = clientHarness(function()
			return refusal
		end)
		h.press()
		assert(#h.sent == 1, "one request sent")
		assert(h.prompt.ActionText == "채집하기", "label after refusal: " .. tostring(h.prompt.ActionText))
		assert(h.prompt.Enabled, "prompt stays usable")
		h.press()
		assert(#h.sent == 2 and h.sent[2].requestId ~= h.sent[1].requestId, "next press is a fresh request")
		h.destroy()
	end,
	["a transient refusal keeps the frozen request and its collecting label"] = function()
		local h = clientHarness(function()
			return { ok = false, reason = "SOURCE_BUSY", data = { status = "recovering" } }
		end)
		h.press()
		assert(h.prompt.ActionText == "채집 중...", "transient keeps pending label")
		h.press()
		assert(#h.sent == 2 and h.sent[2] == h.sent[1], "transient replays the identical request")
		h.destroy()
	end,
}
