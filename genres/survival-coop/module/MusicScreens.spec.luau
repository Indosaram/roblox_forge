--!strict
-- Behaviour of the music lane screens (navigator, score import/share, ensemble lobby/play) on a
-- minimal fake engine: real modules, real buttons, real command ids; only Instances are fakes.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Rules = require("../../../core/domain/music/TestCatalog")
local Text = require("./MusicText")
local Selection = require("./MusicSelection")
local Screens = require("./MusicScreens")
local Navigator = require("./NavigatorPanel")

local function signal(): any
	local callbacks: { any } = {}
	return {
		Connect = function(_self: any, callback: any)
			table.insert(callbacks, callback)
			return { Disconnect = function() end }
		end,
		fire = function(...)
			for _, callback in callbacks do
				callback(...)
			end
		end,
	}
end

-- Fake engine; `find(name)` returns the last created node with that Name.
local function engine(): any
	local nodes: { any } = {}
	local function node(class: string?): any
		local item: any = {
			ClassName = class,
			Activated = signal(),
			Triggered = signal(),
			Visible = true,
			Enabled = true,
			Text = "",
			AbsoluteSize = { X = 360, Y = 640 },
		}
		function item.GetPropertyChangedSignal()
			return signal()
		end
		function item.Destroy(self)
			self.Parent = nil
		end
		function item.FindFirstChild(self, name)
			for _, other in nodes do
				if other.Parent == self and other.Name == name then
					return other
				end
			end
			return nil
		end
		function item.WaitForChild()
			return node("PlayerGui")
		end
		table.insert(nodes, item)
		return item
	end
	local dim = function(...)
		return { ... }
	end
	local fire = node("Part")
	fire.Position = { X = 0, Y = 0, Z = 0 }
	fire.GetAttribute = function(_self, key)
		return if key == "ForgeStationKind" then "campfire" else nil
	end
	local root = { Position = { X = 0, Y = 0, Z = 0 } }
	local vector: any = {}
	setmetatable(root.Position, {
		__sub = function()
			return { Magnitude = 4 }
		end,
	})
	local services: any = {
		Players = {
			LocalPlayer = {
				UserId = 7,
				WaitForChild = function()
					return node("PlayerGui")
				end,
				Character = {
					FindFirstChild = function()
						return root
					end,
				},
			},
			GetPlayerByUserId = function()
				return nil
			end,
		},
		CollectionService = {
			GetTagged = function()
				return { fire }
			end,
			GetInstanceAddedSignal = function()
				return signal()
			end,
		},
		RunService = { Heartbeat = signal() },
	}
	local env: any = {
		game = {
			GetService = function(_self, name)
				return services[name]
			end,
		},
		Instance = { new = node },
		UDim2 = { new = dim, fromOffset = dim, fromScale = dim },
		Color3 = { fromRGB = dim },
		Enum = setmetatable({}, {
			__index = function()
				return {}
			end,
		}),
		Vector3 = vector,
	}
	local ui = {
		theme = { default = {} },
		components = {
			modalSheet = function(_theme, props)
				local frame = node("Frame")
				frame.Name = props.name
				return { frame = frame, scroll = node("ScrollingFrame"), close = node("TextButton") }
			end,
			label = function(_theme, props)
				local label = node("TextLabel")
				label.Text, label.Parent = props.text, props.parent
				return label
			end,
			button = function(_theme, props)
				local button = node("TextButton")
				button.Text, button.Parent = props.text, props.parent
				button.Activated:Connect(function()
					if props.onClick then
						props.onClick()
					end
				end)
				return button
			end,
			panel = function(_theme, props)
				local frame = node("Frame")
				frame.Name = props.name
				return frame
			end,
		},
	}
	local function load(name: string): any
		local chunk = assert(loadstring(fs.readFile("genres/survival-coop/module/" .. name .. ".luau")))
		local scope: any = setmetatable(table.clone(env), { __index = getfenv() })
		scope.require = function(path: string): any
			if path == "./MusicSheet" then
				return load("MusicSheet")
			elseif path == "./MusicText" then
				return Text
			elseif path == "./MusicSelection" then
				return Selection
			end
			local domain: { [string]: any } = {
				["../../../core/domain/music/Score"] = require("../../../core/domain/music/Score"),
				["../../../core/domain/music/ScoreRef"] = require("../../../core/domain/music/ScoreRef"),
			}
			return assert(domain[path], "unexpected require " .. path)
		end
		if name == "MusicScreens" then
			local inner = scope.require
			scope.require = function(path: string): any
				if path == "./ScoreTransport" then
					return require("./ScoreTransport")
				end
				return inner(path)
			end
		end
		setfenv(chunk, scope)
		return chunk()
	end
	local function find(name: string): any
		for index = #nodes, 1, -1 do
			if nodes[index].Name == name and nodes[index].Parent ~= nil then
				return nodes[index]
			end
		end
		error("no node " .. name)
	end
	return { load = load, find = find, ui = ui, heartbeat = services.RunService.Heartbeat, fire = fire }
end

local function context(world: any, locale: string, replies: { [string]: any }): (any, any, any, any)
	local sent: { any } = {}
	local snapshot: any = nil
	local docks: { [string]: any } = {}
	local ctx: any = {
		ui = world.ui,
		locale = locale,
		rules = Rules,
		decode = function(text)
			return serde.decode("json", text)
		end,
		requestId = function()
			return "req-1"
		end,
		serverNow = function()
			return 100
		end,
		send = function(action, args)
			table.insert(sent, { action = action, args = args })
			local reply = replies[action]
			return if type(reply) == "function" then reply(args) else reply or { ok = true }
		end,
		onSnapshot = function(callback)
			snapshot = callback
			return function() end
		end,
		dock = function(entry)
			docks[entry.id] = { entry = entry, available = true }
			return {
				open = function() end,
				setAvailable = function(available, reason)
					docks[entry.id].available, docks[entry.id].reason = available, reason
				end,
			}
		end,
	}
	ctx.open = function(id)
		local dock = docks[id]
		if dock and dock.available then
			dock.entry.setOpen(true)
			return true
		end
		return false
	end
	ctx.availability = function(id)
		local dock = docks[id]
		return dock ~= nil, dock ~= nil and dock.available, if dock then dock.reason else nil
	end
	return ctx, sent, docks, function(value)
		snapshot(value)
	end
end

local function textOf(item: any): string
	return item.Text
end

local SCORE = '{"version":1,"tempo":120,"parts":[{"instrumentId":"piano","notes":['
	.. '{"startTick":0,"durationTicks":480,"pitch":60,"velocity":90}]}]}'

return {
	["navigator routes Inbox to the registered inbox panel"] = function()
		for _, locale in { "en-us", "ko-kr" } do
			local function availability(id: string): (boolean, boolean, string?)
				return id == "inbox", id == "inbox", nil
			end
			local inbox: any = nil
			for _, row in Navigator.model(locale, availability) do
				if row.text == Text.text(locale, "nav_inbox") then
					inbox = row
				end
			end
			assert(inbox and inbox.open and inbox.id == "inbox", locale .. " inbox row opens the inbox panel")
			local opened: string? = nil
			assert(Navigator.press(inbox, function(id)
				opened = id
				return true
			end) == nil and opened == "inbox", "press opens inbox")
			local function missing(_id: string): (boolean, boolean, string?)
				return false, false, nil
			end
			for _, row in Navigator.model(locale, missing) do
				if row.id == "inbox" then
					assert(
						not row.open and row.reason == Text.text(locale, "lock_unknown"),
						"unregistered inbox stays locked"
					)
				end
			end
		end
	end,
	["navigator lists locked screens with their reason and opens unlocked ones"] = function()
		for _, locale in { "en-us", "ko-kr" } do
			Selection.set(nil)
			local world = engine()
			local ctx, _, docks = context(world, locale, {})
			local screens = world.load("MusicScreens").factory(ctx)
			world.load("NavigatorPanel").factory(ctx)
			docks.navigator.entry.setOpen(true)
			-- Share is registered but locked until a score is saved; inbox is not mounted in this harness.
			local share = world.find("Nav-score-share")
			assert(
				share.Text
					== Text.text(
						locale,
						"nav_locked",
						Text.text(locale, "nav_share"),
						Text.text(locale, "lock_unsaved")
					),
				share.Text
			)
			share.Activated.fire()
			local status = world.find("NavigatorStatus")
			assert(status.Visible and status.Text == Text.text(locale, "lock_unsaved"), "lock reason shown")
			assert(not docks["score-share"].entry.isOpen(), "locked screen stays closed")
			local inboxButton = world.find("Nav-inbox")
			assert(
				inboxButton.Text
					== Text.text(
						locale,
						"nav_locked",
						Text.text(locale, "nav_inbox"),
						Text.text(locale, "lock_unknown")
					),
				inboxButton.Text
			)
			inboxButton.Activated.fire()
			assert(textOf(status) == Text.text(locale, "lock_unknown"), "unmounted inbox reason")
			world.find("Nav-ensemble-lobby").Activated.fire()
			assert(docks["ensemble-lobby"].entry.isOpen() and not status.Visible, "unlocked screen opens")
			local missing = Navigator.model(locale, ctx.availability)
			assert(missing[1].reason == Text.text(locale, "lock_unknown"), "launcher missing in this harness is locked")
			screens.destroy()
		end
	end,
	["score import validates fields, saves through the chunked upload and unlocks share"] = function()
		Selection.set(nil)
		local world = engine()
		local ctx, sent, docks = context(world, "ko-kr", {
			["survival-coop:score-upload-commit"] = { ok = true, data = { scoreId = "7:score:1", revision = 3 } },
		})
		local screens = world.load("MusicScreens").factory(ctx)
		assert(not docks["score-share"].available and docks["score-share"].reason == "lock_unsaved", "share locked")
		local json, status = world.find("ImportText"), world.find("ImportStatus")
		json.Text = string.gsub(SCORE, '"pitch":60', '"pitch":200')
		world.find("ImportSave").Activated.fire()
		assert(textOf(status) == "파트 1 음표 1: 음높이는 21~108", status.Text)
		assert(#sent == 0, "invalid score never sent")
		json.Text = SCORE
		world.find("ImportCheck").Activated.fire()
		assert(textOf(status) == "템포 120, 파트 1개, 음표 1개, 1초", status.Text)
		world.find("ImportSave").Activated.fire()
		assert(sent[1].action == "survival-coop:score-upload-begin" and sent[1].args[1] == "req-1", "upload begins")
		assert(textOf(status) == "저장됨 7:score:1#3", status.Text)
		local selection = Selection.get()
		assert(selection.scoreId == "7:score:1" and selection.revision == 3 and selection.owned, "selected")
		assert(docks["score-share"].available, "share unlocked by a saved revision")
		assert(world.find("ShareRefText").Text == "7:score:1#3", "copyable id")
		world.find("ScoreLookup").Text = "https://www.roblox.com/7:score:1#3"
		world.find("ScoreLookupUse").Activated.fire()
		assert(textOf(status) == Text.text("ko-kr", "score.ref_url"), "url refused")
		world.find("ScoreLookup").Text = "9:score:2#1"
		world.find("ScoreLookupUse").Activated.fire()
		assert(Selection.get().scoreId == "9:score:2" and not Selection.get().owned, "lookup selects a read-only score")
		assert(not docks["score-share"].available, "someone else's score cannot be shared")
		screens.destroy()
	end,
	["score share sends the saved revision and shows the server refusal"] = function()
		Selection.set({ scoreId = "7:score:1", revision = 2, owned = true })
		local world = engine()
		local ctx, sent = context(world, "en-us", {
			["survival-coop:score-share"] = function(args)
				return if args[3] == "99" then { ok = false, reason = "score.owner" } else { ok = true }
			end,
		})
		local screens = world.load("MusicScreens").factory(ctx)
		local recipient, status = world.find("ShareRecipient"), world.find("ShareStatus")
		recipient.Text = "7"
		world.find("ShareSend").Activated.fire()
		assert(#sent == 0 and status.Text == Text.text("en-us", "score.self"), "self share refused locally")
		recipient.Text = "42"
		world.find("ShareSend").Activated.fire()
		assert(sent[1].action == Screens.SHARE, "share command")
		assert(sent[1].args[1] == "7:score:1" and sent[1].args[2] == 2 and sent[1].args[3] == "42", "share args")
		assert(textOf(status) == "Shared 7:score:1#2", status.Text)
		recipient.Text = "99"
		world.find("ShareSend").Activated.fire()
		assert(textOf(status) == "Only the owner can share this revision", status.Text)
		screens.destroy()
	end,
	["ensemble lobby joins the room's locked revision, shows refusals and reflects the roster"] = function()
		Selection.set({ scoreId = "7:score:1", revision = 5, owned = true })
		local world = engine()
		local ctx, sent, _, push = context(world, "en-us", {
			["survival-coop:ensemble-join"] = { ok = false, reason = "ensemble.part_taken" },
		})
		local screens = world.load("MusicScreens").factory(ctx)
		push({
			ensemble = {
				room = {
					host = "1",
					scoreId = "1:score:4",
					revision = 2,
					members = { ["1"] = { part = 1, ready = true } },
					vacancies = {},
				},
			},
		})
		assert(world.find("LobbyScore").Text == "Score 1:score:4#2 (locked revision)", world.find("LobbyScore").Text)
		assert(world.find("LobbySlot1").Text == "1. 1 - part 1 (ready) (host)", world.find("LobbySlot1").Text)
		assert(world.find("LobbySlot2").Text == "2. Open", "open slot")
		assert(world.find("LobbyRange").Text == Text.text("en-us", "lobby_in_range"), "near the fire")
		world.find("LobbyJoin").Activated.fire()
		assert(sent[1].action == Screens.JOIN, "join command")
		assert(sent[1].args[1] == "1:score:4" and sent[1].args[2] == 2 and sent[1].args[3] == 1, "room revision kept")
		assert(world.find("LobbyStatus").Text == "Someone already plays that part", "refusal shown")
		world.find("LobbyPart").Activated.fire()
		assert(world.find("LobbyJoin").Text == "Join with part 2", "part picker")
		world.find("LobbyReady").Activated.fire()
		assert(sent[2].action == Screens.READY and sent[2].args[1] == true, "ready command")
		world.find("LobbyStart").Activated.fire()
		world.find("LobbyLeave").Activated.fire()
		assert(sent[3].action == Screens.START and sent[4].action == Screens.LEAVE, "start and leave")
		local prompt = world.fire:FindFirstChild("ForgeEnsemblePrompt")
		assert(prompt and prompt.MaxActivationDistance == Rules.radiusStuds, "campfire prompt within 16 studs")
		screens.destroy()
	end,
	["ensemble play overlay counts down, tracks the part and offers rejoin after leaving"] = function()
		local world = engine()
		local ctx, sent, _, push = context(world, "ko-kr", {})
		local screens = world.load("MusicScreens").factory(ctx)
		local room: any = {
			host = "7",
			scoreId = "7:score:1",
			revision = 1,
			startAt = 101.5,
			members = { ["7"] = { part = 2, ready = true } },
			vacancies = {},
			events = {
				{ part = 2, at = 101.5, untilAt = 102 },
				{ part = 2, at = 102, untilAt = 103 },
				{ part = 1, at = 101.5, untilAt = 102 },
			},
		}
		push({ ensemble = { room = room } })
		world.heartbeat.fire()
		assert(world.find("EnsemblePlay") ~= nil, "overlay exists")
		assert(world.find("PlayCountdown").Text == "1.5초 후 시작", world.find("PlayCountdown").Text)
		assert(world.find("PlaySync").Text == Text.text("ko-kr", "play_sync"), "sync state")
		world.find("PlayAction").Activated.fire()
		assert(sent[1].action == Screens.LEAVE, "leave from overlay")
		local playing = Screens.playModel("ko-kr", room, "7", 102.5, 100)
		assert(playing.countdown == "파트 2: 음표 1/2", playing.countdown)
		room.members, room.vacancies = {}, { ["7"] = 2 }
		push({ ensemble = { room = room } })
		world.heartbeat.fire()
		assert(screens.playAction() == "rejoin", "vacated performer can rejoin")
		world.find("PlayAction").Activated.fire()
		assert(sent[2].action == Screens.JOIN and sent[2].args[1] == "7:score:1" and sent[2].args[3] == 2, "rejoin")
		local late =
			Screens.playModel("en-us", { startAt = 10, members = { a = { part = 1 } }, events = {} }, "a", 12, 11)
		assert(late.sync == Text.text("en-us", "play_late"), "late join named")
		screens.destroy()
	end,
}
