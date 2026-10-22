--!strict
-- Behaviour of the expedition-lane panels on a minimal fake engine: real ExpeditionPanels,
-- real models and text; ctx.send records the durable commands the server would receive.
local fs = require("@lune/fs")
local Models = require("./ExpeditionModels")
local Text = require("./ExpeditionText")

local function signal(): any
	local callbacks: { () -> () } = {}
	return {
		Connect = function(_self, callback)
			table.insert(callbacks, callback)
			return { Disconnect = function() end }
		end,
		fire = function()
			for _, callback in callbacks do
				callback()
			end
		end,
	}
end

local function mount(locale: string, replies: { [string]: any }?): any
	local nodes: { any } = {}
	local methods: any = {}
	methods.__index = methods
	function methods:IsA(kind)
		return kind == "GuiObject" or self.ClassName == kind
	end
	function methods:Destroy()
		self.Parent = nil
	end
	function methods:GetChildren()
		local out = {}
		for _, item in nodes do
			if item.Parent == self then
				table.insert(out, item)
			end
		end
		return out
	end
	function methods:FindFirstChild(name)
		for _, item in nodes do
			if item.Parent == self and item.Name == name then
				return item
			end
		end
		return nil
	end
	function methods:WaitForChild(name)
		return self:FindFirstChild(name) or self
	end
	local function node(class: string?): any
		local item =
			setmetatable({ ClassName = class or "Frame", Name = class or "Frame", Activated = signal() }, methods)
		table.insert(nodes, item)
		return item
	end
	local playerGui = node("PlayerGui")
	local player: any = { UserId = 7, DisplayName = "Me", PlayerGui = playerGui }
	function player:WaitForChild()
		return playerGui
	end
	local friend: any = { UserId = 8, DisplayName = "Mina" }
	local environment: any = table.clone(getfenv())
	environment.game = {
		GetService = function(_self, name)
			assert(name == "Players", "only Players is used")
			return {
				LocalPlayer = player,
				GetPlayers = function()
					return { player, friend }
				end,
			}
		end,
	}
	environment.Instance = { new = node }
	environment.Enum = { ZIndexBehavior = { Sibling = "Sibling" } }
	environment.UDim2 = { new = function() end, fromOffset = function() end }
	environment.require = function(path)
		local name = string.match(path, "^%./(%w+)$")
		if name == "ExpeditionSheet" then
			local chunk = assert(loadstring(fs.readFile("genres/survival-coop/module/ExpeditionSheet.luau")))
			setfenv(chunk, environment)
			return chunk()
		end
		return if name == "ExpeditionModels" then Models else Text
	end
	local clicks: { [any]: () -> () } = {}
	local h: any = { sent = {}, docks = {}, listener = nil }
	local function make(props: any): any
		local item = node("TextLabel")
		item.Text = props.text
		return item
	end
	local ctx = {
		locale = locale,
		names = {},
		ui = {
			theme = { default = {} },
			components = {
				label = function(_theme, props)
					return make(props)
				end,
				button = function(_theme, props)
					local item = make(props)
					item.ClassName = "TextButton"
					clicks[item] = props.onClick
					return item
				end,
				modalSheet = function(_theme, props)
					local frame = node()
					frame.Name = props.name
					local header = node()
					header.Name, header.Parent = "Header", frame
					local title = node("TextLabel")
					title.Name, title.Parent, title.Text = "Title", header, props.title
					local scroll = node("ScrollingFrame")
					scroll.Parent = frame
					return { frame = frame, scroll = scroll, close = node("TextButton") }
				end,
			},
		},
		send = function(action: string, args: { any })
			table.insert(h.sent, action .. ":" .. table.concat(args, ","))
			return (replies and replies[args[1]]) or { ok = true }
		end,
		onSnapshot = function(callback)
			h.listener = callback
			return function() end
		end,
		dock = function(entry)
			h.docks[entry.id] = entry
			return {
				open = function()
					entry.setOpen(true)
				end,
				setAvailable = function(available)
					h.docks[entry.id].available = available
				end,
			}
		end,
	}
	local chunk = assert(loadstring(fs.readFile("genres/survival-coop/module/ExpeditionPanels.luau")))
	setfenv(chunk, environment)
	h.panel = chunk().factory(ctx)
	function h.find(name: string): any
		for _, item in nodes do
			if item.Name == name and item.Parent ~= nil then
				return item
			end
		end
		return nil
	end
	function h.click(name: string)
		local item = assert(h.find(name), "no control " .. name)
		local onClick = assert(clicks[item], name .. " is not a button")
		onClick()
	end
	function h.push(state: any, packet: any?)
		h.listener({ expedition = state }, packet or {})
	end
	return h
end

local function state(extra: any?): any
	local cards = {}
	for route = 1, 5 do
		table.insert(cards, {
			route = route,
			biome = "grassland",
			level = 2,
			rank = 2,
			stages = 4,
			missions = 8,
			capacity = 8,
			expiresAt = 1800,
			ok = route == 1,
			reason = if route == 1 then nil else "level_gate",
		})
	end
	local base: any = {
		now = 100,
		routes = cards,
		party = { members = {}, capacity = 8, invites = {}, pending = 0 },
	}
	for key, value in extra or {} do
		base[key] = value
	end
	return base
end

return {
	["routes confirm departs through party-action and shows a localized refusal with retry"] = function()
		local h = mount("ko-kr", { depart = { ok = false, reason = "expiry_imminent" } })
		h.push(state())
		assert(h.docks.routes and h.docks.party and h.docks.expedition, "menu tiles registered")
		assert(h.docks.routes.available and not h.docks.expedition.available, "expedition tile only on an expedition")
		h.click("Route-1")
		assert(h.find("DepartBody") and h.find("DepartConfirm"), "depart confirm shown")
		h.click("DepartConfirm")
		assert(h.sent[1] == Models.PARTY_ACTION .. ":depart,1", "depart command sent")
		assert(h.find("TravelRefusal").Text == Text.reason("ko-kr", "expiry_imminent"), "refusal localized")
		h.click("TravelRetry")
		assert(h.sent[2] == h.sent[1], "retry repeats the same operation")
		h.click("TravelBack")
		h.click("Route-2")
		assert(h.find("DepartRefusal").Text == Text.reason("ko-kr", "level_gate"), "gate shown before confirm")
		h.click("DepartStay")
		assert(h.find("Route-1"), "stay returns to the list")
	end,
	["party invites a player on this server and a received invite can be accepted"] = function()
		local h = mount("en-us", { invite = { ok = false, reason = "party_full" } })
		h.push(state())
		assert(h.find("PartyEmpty"), "empty party explained")
		h.click("Invite-8")
		assert(h.sent[1] == Models.PARTY_ACTION .. ":invite,8", "invite sent")
		assert(h.find("PartyRefusal").Text == Text.reason("en-us", "party_full"), "invite refusal shown")
		local invited = state()
		invited.party.invites = { { from = "8", route = 1, expiresAt = 220, members = 2, capacity = 8 } }
		h.push(invited)
		assert(string.find(h.find("InviteBody").Text, "Route 1, 2/8 members. Expires in 2:00", 1, true), "invite facts")
		h.click("InviteAccept")
		assert(h.sent[2] == Models.PARTY_ACTION .. ":accept,8", "accept sent")
		local joined = state()
		joined.party = {
			id = "party-1",
			leader = "7",
			members = { "7", "8" },
			capacity = 8,
			invites = {},
			pending = 0,
			roster = { { id = "7", leader = true, ready = true }, { id = "8", leader = false, ready = false } },
		}
		h.push(joined)
		assert(h.find("Member-8").Text == "8 (not ready)", "readiness reflected")
		h.click("Share-1")
		h.click("Remove-8")
		h.click("PartyLeave")
		assert(h.sent[3] == Models.PARTY_ACTION .. ":share,1", "share")
		assert(
			h.sent[4] == Models.PARTY_ACTION .. ":remove,8" and h.sent[5] == Models.PARTY_ACTION .. ":leave,",
			"remove, leave"
		)
	end,
	["expedition tracker locks the next island and travels after confirmation"] = function()
		local h = mount("en-us", { next = { ok = false, reason = "mission_gate" } })
		local tracker = {
			route = 1,
			stage = 2,
			expiresAt = 1800,
			unlocked = false,
			objectives = {
				{ id = "o1", action = "craft", target = "dry-twig", progress = 1, quantity = 1 },
				{ id = "o2", action = "rescue", target = "castaway", progress = 0, quantity = 1 },
			},
		}
		h.push(state({ tracker = tracker }))
		assert(h.docks.expedition.available, "expedition tile available")
		assert(h.find("NextLocked") and not h.find("ExpeditionNext"), "next island locked")
		assert(h.find("Objective-o2").Text == "rescue castaway: 0/1", "objective progress")
		tracker.unlocked = true
		h.push(state({ tracker = tracker }))
		h.click("ExpeditionNext")
		h.click("TravelConfirm")
		assert(h.sent[1] == Models.PARTY_ACTION .. ":next,", "next island sent")
		assert(h.find("TravelRefusal").Text == Text.reason("en-us", "mission_gate"), "refusal shown")
	end,
	["results knockout and hazard popups follow the snapshot"] = function()
		local h = mount("ko-kr")
		local results = {
			id = "trip",
			status = "complete",
			rows = {
				{ mission = "rw.m1.gather", xp = 120, coins = 30, trust = 20, repeatClear = false, delivered = true },
			},
		}
		h.push(state({ results = results }))
		assert(h.find("ResultDelivery").Text == Text.text("ko-kr", "exp_delivered"), "delivery shown")
		h.click("ResultsClose")
		h.push(state({
			results = results,
			hazard = { kind = "lava", intensity = 2, refuge = false, volcano = { health = 1, fatigue = 2 } },
		}))
		assert(h.find("HazardVolcano"), "volcano details shown")
		local packet = {
			snapshots = {
				["survival-coop"] = { vitals = { healthMilli = 0, respawnWaitMillis = 4000 } },
				survivalExtensions = {
					["death-zone"] = { zone = "danger" },
					taming = {
						companions = { pets = { p1 = { species = "boar", phase = "Downed", injuredUntil = 160000 } } },
					},
				},
			},
		}
		h.push(state({ results = results }), packet)
		assert(h.find("KnockoutWait").Text == Text.text("ko-kr", "ko_wait", 4), "recovery wait")
		assert(h.find("KnockoutZone").Text == Text.text("ko-kr", "ko_danger"), "mode-specific loss")
		h.click("KnockoutFeed-p1")
		assert(h.sent[1] == Models.COMPANION_ACTION .. ":feed,p1", "one feed recovers the pet")
	end,
	["finished travel results hazard and knockout screens"] = function()
		local h = mount(
			"en-us",
			{ claim = { ok = false, reason = "ledger_claimed" }, home = { ok = false, reason = "route_expired" } }
		)
		local arrival = {
			id = "trip",
			route = 1,
			stage = 2,
			party = { token = "tok", leader = "7", members = { "7", "8" } },
			left = { items = 5, coins = 40 },
			arrived = { items = 5, coins = 55 },
		}
		h.push(state({ arrival = arrival }))
		assert(h.find("TravelIdentity").Text == Text.text("en-us", "travel_arrived", 1, "Grassland", 2), "identity")
		assert(not string.find(h.find("TravelIdentity").Text, "trip", 1, true), "raw expedition id hidden")
		assert(h.find("TravelCrew") and h.find("TravelReconcile"), "crew and reconciliation")
		assert(h.find("TravelRefund").Text == Text.text("en-us", "travel_refund", 15), "refund line")
		h.click("TravelBack")
		assert(h.find("Route-1"), "back to the route list after acknowledging arrival")
		local results = {
			id = "trip",
			status = "complete",
			rows = {},
			ledger = { id = "trip", source = "expedition:rw.a1", items = {}, coins = 30, xp = 120, claimed = false },
			contributors = { { id = "7", points = 3 }, { id = "8", points = 1 } },
		}
		h.push(state({ results = results }))
		assert(h.find("Contrib-7") and h.find("Contrib-8"), "per-player contribution")
		h.click("ResultsClaim")
		assert(h.sent[1] == Models.PARTY_ACTION .. ":claim,trip", "claim sent")
		assert(h.find("ClaimRefusal").Text == Text.reason("en-us", "ledger_claimed"), "claim refusal shown")
		h.push(state({
			hazard = {
				kind = "lava",
				intensity = 2,
				refuge = false,
				boots = true,
				resist = 0,
				exposure = 2,
				volcano = { health = 0.5, fatigue = 1 },
			},
		}))
		assert(h.find("HazardBoots").Text == Text.text("en-us", "hazard_boots_on"), "worn boots shown")
		assert(h.find("HazardResist"), "worn resistance shown")
		local packet =
			{ snapshots = { ["survival-coop"] = { vitals = { healthMilli = 0, respawnWaitMillis = 2000 } } } }
		local tracker = { route = 1, stage = 2, expiresAt = 1800, unlocked = false, objectives = {} }
		h.push(state({ tracker = tracker, cargo = { item = "crate", quantity = 2 } }), packet)
		assert(h.find("KnockoutCargo").Text == Text.text("en-us", "ko_cargo", "crate", 2), "retained cargo listed")
		h.click("KnockoutHome")
		assert(h.sent[2] == Models.PARTY_ACTION .. ":home,", "return home while downed")
		assert(h.find("KnockoutRefusal").Text == Text.reason("en-us", "route_expired"), "home refusal shown")
	end,
	["route rows and the arrival line show localized biome names, never raw ids"] = function()
		for _, locale in { "en-us", "ko-kr" } do
			local cards = {}
			for route, id in { "grassland", "tropical", "desert", "snow", "volcano" } do
				table.insert(cards, {
					route = route,
					biome = id,
					level = 1,
					rank = 1,
					stages = 4,
					missions = 8,
					capacity = 8,
					expiresAt = 1800,
					ok = true,
				})
			end
			local _, items = Models.routes(locale, { now = 0, routes = cards }, {}, function() end)
			for _, item in items do
				for _, id in { "grassland", "tropical", "desert", "snow", "volcano" } do
					assert(not string.find(item.text, id, 1, true), locale .. " raw biome id shown: " .. item.text)
				end
			end
			assert(string.find(items[1].text, Text.text(locale, "biome_grassland"), 1, true), "localized biome name")
			local _, arrived = Models.travel(locale, 1, nil, function() end, function() end, {
				id = "b3da0de5-5842-4c1e-9d55-000000000000",
				route = 1,
				stage = 2,
				biome = "tropical",
			})
			assert(not string.find(arrived[1].text, "b3da0de5", 1, true), "raw expedition id shown")
			assert(string.find(arrived[1].text, Text.text(locale, "biome_tropical"), 1, true), "arrival names biome")
		end
	end,
}
