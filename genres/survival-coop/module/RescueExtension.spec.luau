--!strict
local RescueExtension = require("./RescueExtension")
local Extensions = require("./Extensions")
local ExtensionPanels = require("./ExtensionPanels")
local Contract = require("./Contract")
local DownPanel = require("./DownPanel")
local _packText = (require :: any)("../../../games/robango-island/PackText.fixture") -- installs the strings.csv lookup

type World = { health: { [string]: number }, at: { [string]: any }, safe: boolean, now: number, admits: number }

local function build(flares: boolean?): (any, any, World)
	local w: World = {
		health = { ["1"] = 0, ["2"] = 100000, ["3"] = 100000 },
		at = { ["1"] = { x = 0, y = 0, z = 0 }, ["2"] = { x = 4, y = 0, z = 3 }, ["3"] = { x = 80, y = 0, z = 0 } },
		safe = false,
		now = 1000,
		admits = 0,
	}
	local port = {
		position = function(actor: string)
			return w.at[actor]
		end,
		health = function(actor: string)
			return w.health[actor]
		end,
		safe = function()
			return w.safe
		end,
		camp = function(_actor: string)
			return { x = 50, y = 2, z = 50 }
		end,
		name = function(actor: string)
			return "P" .. actor
		end,
		flares = flares,
	}
	local extension, hold = RescueExtension.new(port, function()
		return w.now
	end, function()
		return { "1", "2", "3" }
	end)
	return extension, hold, w
end

local function send(extension: any, w: World, actor: string, action: string, args: { any }): any
	return extension.command(actor, action, args, {}, "client", function()
		w.admits += 1
		return { ok = true }
	end)
end

return {
	-- Single-player mode (Robango play_mode.flares = false): nobody else can answer a flare, so the
	-- down screen offers only rift and camp and a stale client's flare choice is refused.
	["flares off: no flare card and the flare choice is refused"] = function()
		local extension, _, w = build(false)
		local options = extension.snapshot("1").options
		assert(table.concat(options, ",") == "rift,camp", "solo cards: " .. table.concat(options, ","))
		local refused = send(extension, w, "1", RescueExtension.CHOOSE, { "rescue" })
		assert(not refused.ok and refused.reason == "INVALID_OPTION", "flare refused: " .. tostring(refused.reason))
		assert(send(extension, w, "1", RescueExtension.CHOOSE, { "camp" }).ok, "camp still works")
		local multi = build(nil)
		assert(table.find(multi.snapshot("1").options, "rescue"), "default keeps the flare")
	end,
	["opt-in: no rescue port means no extension"] = function()
		assert(RescueExtension.factory({ world = nil }) == nil, "no world")
		assert(RescueExtension.factory({ world = {} }) == nil, "world without rescue port")
	end,
	["actions and factories are registered in the genre seams"] = function()
		for _, id in { "rescue-choose", "rescue-revive" } do
			assert(table.find(Contract.extensionActions :: { string }, id), id .. " is an extension action")
			local declared = false
			for _, action in Contract.actions do
				declared = declared or (action.id == id and action.origin == "client" and #action.args == 1)
			end
			assert(declared, id .. " declared as a one-argument client action")
		end
		assert(table.find(Extensions.factories, RescueExtension.factory), "server factory registered")
		assert(table.find(ExtensionPanels.factories, DownPanel.factory), "panel factory registered")
	end,
	["a downed actor flares, a nearby player revives it and the hold wakes it there"] = function()
		local extension, hold, w = build()
		assert(hold.decide("1") == nil, "undecided actor is held")
		local view = extension.snapshot("1")
		assert(view.down and #view.options == 3 and view.choice == nil, "three cards while down")
		assert(send(extension, w, "1", RescueExtension.CHOOSE, { "rescue" }).ok, "flare")
		assert(hold.decide("1") == nil, "flare keeps holding")
		local seen = extension.snapshot("2")
		assert(
			#seen.flares == 1 and seen.flares[1].id == "1" and seen.flares[1].reachable,
			"rescuer sees a reachable flare"
		)
		assert(seen.flares[1].name == "P1", "flare carries the display name")
		assert(#extension.snapshot("1").flares == 0, "own flare not listed")
		w.now += 3000
		local result = send(extension, w, "2", RescueExtension.REVIVE, { "1" })
		assert(result.ok, "revive accepted: " .. tostring(result.reason))
		local wake = hold.decide("1")
		assert(wake and wake.at and wake.at.x == 0 and wake.at.z == 0, "wakes where it fell")
		hold.settle("1")
		assert(next(hold.state.choices) == nil, "settled")
	end,
	["camp and rift choices wake at the camp fire or the spawn"] = function()
		local extension, hold, w = build()
		assert(send(extension, w, "1", RescueExtension.CHOOSE, { "camp" }).ok, "camp")
		local wake = hold.decide("1")
		assert(wake and wake.at and wake.at.x == 50, "camp fire")
		hold.settle("1")
		assert(send(extension, w, "1", RescueExtension.CHOOSE, { "rift" }).ok, "rift")
		local rift = hold.decide("1")
		assert(rift and rift.at == nil, "rift wakes at the spawn")
	end,
	["NEGATIVE: a far rescuer is refused"] = function()
		local extension, hold, w = build()
		assert(send(extension, w, "1", RescueExtension.CHOOSE, { "rescue" }).ok, "flare")
		local view = extension.snapshot("3")
		assert(#view.flares == 1 and not view.flares[1].reachable, "far player sees it but cannot reach")
		local result = send(extension, w, "3", RescueExtension.REVIVE, { "1" })
		assert(not result.ok and result.reason == "TOO_FAR", "far refused: " .. tostring(result.reason))
		assert(hold.decide("1") == nil, "still held")
	end,
	["NEGATIVE: an expired request is refused"] = function()
		local extension, hold, w = build()
		assert(send(extension, w, "1", RescueExtension.CHOOSE, { "rescue" }).ok, "flare")
		w.now += 90000
		local result = send(extension, w, "2", RescueExtension.REVIVE, { "1" })
		assert(not result.ok and result.reason == "REQUEST_EXPIRED", "expired refused: " .. tostring(result.reason))
		assert(#extension.snapshot("2").flares == 0, "expired flare gone")
		assert(extension.snapshot("1").choice == nil, "downed actor picks again")
		assert(hold.decide("1") == nil, "still held until a new choice")
	end,
	["NEGATIVE: a downed rescuer, an alive chooser and unknown targets are refused"] = function()
		local extension, _, w = build()
		assert(send(extension, w, "2", RescueExtension.CHOOSE, { "rift" }).reason == "NOT_DOWN", "alive cannot choose")
		assert(send(extension, w, "1", RescueExtension.CHOOSE, { "rescue" }).ok, "flare")
		w.health["2"] = 0
		assert(send(extension, w, "2", RescueExtension.REVIVE, { "1" }).reason == "RESCUER_DOWN", "downed rescuer")
		assert(send(extension, w, "3", RescueExtension.REVIVE, { "42" }).reason == "NO_REQUEST", "non-member target")
		local refused = extension.command("2", RescueExtension.REVIVE, { "1" }, {}, "client", function()
			return { ok = false, reason = "rate limited" }
		end)
		assert(not refused.ok and refused.reason == "rate limited", "admission refusal passes through")
	end,
	["safe roles offer one get-up card"] = function()
		local extension, hold, w = build()
		w.safe = true
		local view = extension.snapshot("1")
		assert(#view.options == 1 and view.options[1] == "get-up", "one card")
		assert(
			send(extension, w, "1", RescueExtension.CHOOSE, { "rescue" }).reason == "INVALID_OPTION",
			"no flare in town"
		)
		assert(send(extension, w, "1", RescueExtension.CHOOSE, { "get-up" }).ok, "get up")
		local wake = hold.decide("1")
		assert(wake and wake.at == nil, "wakes at the spawn")
	end,
	["down panel text is localized in both locales and uses our own wording"] = function()
		for _, key in DownPanel.KEYS do
			assert(DownPanel.text("en-us", key) ~= key and DownPanel.text("ko-kr", key) ~= key, "localized " .. key)
		end
		assert(
			DownPanel.text("ko-kr", "title") == "쓰러졌다" and DownPanel.text("en-us", "title") == "You're down",
			"title"
		)
		local wild = DownPanel.model("ko-kr", { down = true, options = { "rift", "camp", "rescue" } })
		assert(#wild.cards == 3, "three cards")
		assert(wild.cards[1].title == "균열로 돌아가기", "rift card")
		assert(wild.cards[2].title == "캠프에서 깨어나기", "camp card")
		assert(wild.cards[3].title == "구조 신호 올리기", "flare card")
		for _, card in wild.cards do
			for _, banned in { "워프홀", "부활", "구조 요청" } do
				assert(not string.find(card.title, banned, 1, true), "not the reference wording: " .. card.title)
			end
		end
		local en = DownPanel.model("en-us", { down = true, options = { "get-up" } })
		assert(#en.cards == 1 and en.cards[1].title == "Get up", "safe card")
		assert(DownPanel.model("en-us", { down = false, options = {} }) == nil, "no panel while up")
		assert(DownPanel.model("en-us", nil) == nil, "no panel without the extension")
		local waiting =
			DownPanel.model("en-us", { down = true, options = { "rescue" }, choice = "rescue", waitingMillis = 41500 })
		assert(waiting.waiting == "Flare up: 42 s left" and waiting.cards[1].active, "countdown and active card")
	end,
	["U3b: every down card asks the icon resolver for item art for its pebble badge"] = function()
		local asked = {}
		local icons = {
			item = function(id: string)
				table.insert(asked, id)
				return { image = "rbxassetid://" .. #asked }
			end,
		}
		for _, option in { "rift", "camp", "rescue", "get-up" } do
			local image = DownPanel.icon(icons, option)
			assert(string.match(image, "^rbxassetid://%d+$"), option .. " art: " .. image)
			assert(asked[#asked] == DownPanel.ICON_ASSETS[option], option .. " asks its item")
		end
		assert(DownPanel.icon(nil, "rift") == "", "no resolver, no image")
	end,
	["flare chat line, drop label and refusals"] = function()
		local flare = { id = "1", name = "Mira", x = 911, y = 3, z = 594 }
		assert(DownPanel.flareLine("en-us", flare) == "Mira sent up a flare at (911, 594)", "EN chat line")
		assert(
			DownPanel.flareLine("ko-kr", flare) == "Mira님이 구조 신호를 올렸습니다 (911, 594)",
			"KO chat line"
		)
		assert(DownPanel.dropLabel("en-us", "owner:Mira") == "Lost belongings: Mira", "EN drop label")
		assert(DownPanel.dropLabel("ko-kr", "owner:Mira") == "잃어버린 짐: Mira", "KO drop label")
		assert(DownPanel.dropLabel("en-us", "wood") == nil, "plain drops keep the generic label")
		assert(DownPanel.refusal("en-us", "TOO_FAR") == "Too far away to help", "distance refusal")
		assert(DownPanel.refusal("ko-kr", "REQUEST_EXPIRED") == "구조 신호가 꺼졌어요", "expiry refusal")
		assert(DownPanel.refusal("en-us", "WHATEVER") == DownPanel.text("en-us", "failed"), "generic refusal")
		local seen = {}
		assert(#DownPanel.newFlares(seen, { flare }) == 1, "first sighting announces")
		assert(#DownPanel.newFlares(seen, { flare }) == 0, "announced once")
		assert(#DownPanel.newFlares(seen, {}) == 0 and next(seen) == nil, "gone flares forgotten")
	end,
	-- p134 v43: the first rift tap was refused 'That did not work' with no server log. The down
	-- push came while the death commit held the profile, so it carried no rescue-choose epoch and
	-- ExtensionPanels.send answered COMMAND_UNAVAILABLE locally; the second tap had one.
	["a down choice re-sends transient refusals and lands on the first tap"] = function()
		local answers: { any } = {
			{ ok = false, reason = "COMMAND_UNAVAILABLE" },
			{ ok = false, reason = "COMMAND_PENDING" },
			{ ok = true, data = { option = "rift" } },
		}
		local sent, waits = 0, 0
		local result = DownPanel.choose(
			function(action, args)
				assert(action == DownPanel.CHOOSE and args[1] == "rift", "the rift choice is sent")
				sent += 1
				return answers[sent]
			end,
			"rift",
			function()
				waits += 1
			end
		)
		assert(result.ok and sent == 3 and waits == 2, "retried until confirmed, sends " .. sent)
		-- A final refusal is shown at once, never re-sent.
		sent = 0
		result = DownPanel.choose(function()
			sent += 1
			return { ok = false, reason = "NOT_DOWN" }
		end, "rift", function() end)
		assert(not result.ok and sent == 1, "final refusal sent once")
		-- A server that stays busy ends after a bounded number of sends.
		sent = 0
		DownPanel.choose(function()
			sent += 1
			return { ok = false, reason = "COMMAND_PENDING" }
		end, "rift", function() end)
		assert(sent == DownPanel.CHOOSE_TRIES, "bounded retries")
	end,
}
