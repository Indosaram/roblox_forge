--!strict
-- Drives the real GatheringClient prompt (loaded as text into a minimal engine double, so the
-- Roblox-only module is never type-checked on the Lune platform).
local luau = require("@lune/luau")
local fs = require("@lune/fs")
local Transport = require("../../../core/infra/genre/CommandTransport")

-- Minimal engine double: just enough Instances/services for GatheringClient.start.
local function clientHarness(answer: (any) -> any, extra: { [string]: any }?, handshake: (() -> any)?): any
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
			return if handshake then handshake() else { ok = true, durable = policy }
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
	local stateEvent = { OnClientEvent = signal() }
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
				return if name == "ForgeAction" then remote else stateEvent
			end,
		},
	}
	local prompt: any = nil
	local touch: any = nil
	local notice: any = nil
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
					elseif class == "TextButton" then
						touch = o
					elseif class == "TextLabel" then
						notice = o
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
			task = {
				delay = function() end,
				spawn = function(callback, ...)
					callback(...)
				end,
			},
			require = function(path: string): any
				return if path == "./PackLocale" then require("./PackLocale") else Transport
			end,
		},
	})()
	local startOptions: any = { locale = "ko-kr" }
	if extra then
		for key, value in extra do
			startOptions[key] = value
		end
	end
	local handle = module.start(startOptions)
	return {
		node = node,
		touch = touch,
		prompt = prompt,
		sent = sent,
		policy = policy,
		notice = function(): any
			return notice
		end,
		packet = function(durable: any)
			stateEvent.OnClientEvent:Fire({ durable = durable })
		end,
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
	-- p134 v43: with a node's gather fan open, the big touch button acted on the nearest prompt
	-- (often another node, or none at all) instead of the node in the fan: no item, no notice.
	["the touch gather button acts on the node whose picker is open"] = function()
		local picked: { any } = {}
		local node: any = nil
		local h = clientHarness(function()
			return { ok = true, data = { status = "confirmed" } }
		end, {
			focus = function()
				return node
			end,
			pick = function(part)
				table.insert(picked, part)
				return false
			end,
		})
		node = h.node
		-- No prompt is the nearest one this frame (the fan covers it); the button is shown.
		h.touch.Visible = true
		h.touch.Activated:Fire()
		assert(picked[1] == h.node, "the picker is asked about the open node")
		assert(#h.sent == 1 and h.sent[1].args[1] == "rw.a1.s1.material.wood", "one gather of the open node")
		h.destroy()
	end,
	-- p134 v45/v46: "아직 연결 중이에요" flashed for 15-18 s after join while gathers were already
	-- confirming. Once the server issued a gather epoch, a transient refusal (a save or recovery
	-- sweep holding the profile) retries silently on the next packet instead of showing the banner.
	["a live session retries a transient refusal silently and never shows the connecting banner"] = function()
		local answers: { any } = {
			{ ok = false, reason = "COMMAND_PENDING" },
			{ ok = true, stateVersion = 2, data = { status = "confirmed" } },
			{ ok = false, reason = "TOOL_UNAVAILABLE", data = { status = "rejected" } },
		}
		local calls = 0
		local h = clientHarness(function()
			calls += 1
			return answers[calls]
		end)
		h.press()
		assert(#h.sent == 1, "one request sent")
		assert(not h.notice().Visible, "no connecting banner on a live session: " .. tostring(h.notice().Text))
		h.packet(h.policy)
		assert(#h.sent == 2 and h.sent[2] == h.sent[1], "the next packet replays the same frozen request")
		assert(not h.notice().Visible, "confirmed gather shows no banner")
		h.press()
		assert(
			h.notice().Visible and h.notice().Text == "맞는 도구를 장착하세요",
			"final refusals still explain"
		)
		h.destroy()
	end,
	["a confirmed gather clears a connecting banner shown while the profile loaded"] = function()
		local handshakes = 0
		local h = clientHarness(
			function()
				return { ok = true, stateVersion = 2, data = { status = "confirmed" } }
			end,
			nil,
			function()
				handshakes += 1
				return { ok = false, reason = "profile not ready" }
			end
		)
		assert(handshakes == 1, "initial handshake")
		assert(h.notice().Visible and string.find(h.notice().Text, "연결", 1, true), "loading shows connecting")
		h.packet(h.policy)
		h.press()
		assert(#h.sent == 1, "gather sent with the packet epoch")
		assert(not h.notice().Visible, "a confirmed gather clears the connecting banner")
		h.destroy()
	end,
}
