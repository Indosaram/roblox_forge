--!strict
-- ui.home-permissions, ui.home-move, ui.siege-lobby/-match/-results, ui.transaction,
-- ui.direct-trade, ui.dialogue: real panel modules on injected widgets. Layout cases render at
-- PC 1280x720, portrait 360x640 and landscape 640x339 in EN and KO; behaviour cases press the
-- rendered buttons and check the command sent, the localized refusal and the reflected state.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local HUDModel = require("../../genres/survival-coop/module/SurvivalHUDModel")
local Sheet = require("../../genres/survival-coop/module/SocialSheet")
local L = require("../../genres/survival-coop/module/SocialLocale")
local HudFit = require("../../core/ui-kit/genre/HudFit")
local Home = require("../../core/domain/home/HomeState")
local HomeContent = require("../../core/domain/home/HomeContent")
local Content: any = luau.load(fs.readFile("games/robango-island/src/shared/SurvivalContent.luau"))()
local JournalText: any = luau.load(fs.readFile("games/robango-island/src/shared/JournalText.luau"))()
local Durable: any = luau.load(fs.readFile("games/robango-island/src/shared/GenreDurable.luau"))()

local M = "../../genres/survival-coop/module/"
local Panels: { [string]: any } = {
	permissions = require(M .. "HomePermissionsPanel"),
	move = require(M .. "HomeMovePanel"),
	lobby = require(M .. "SiegeLobbyPanel"),
	match = require(M .. "SiegeMatchPanel"),
	results = require(M .. "SiegeResultsPanel"),
	transaction = require(M .. "TransactionPanel"),
	trade = require(M .. "DirectTradePanel"),
	dialogue = require(M .. "DialoguePanel"),
}

local VIEWPORTS = { { 1280, 720, false }, { 360, 640, true }, { 640, 339, true } }
local LOCALES = { "en-us", "ko-kr" }
local NOW = 1000

local function harness(locale: string, width: number, height: number, touch: boolean): any
	local h: any = { widgets = {}, sends = {}, docks = {}, replies = {} }
	local x, y, sw, sh = HUDModel.contextSheet(width, height, touch)
	h.rect = { x = x, y = y, width = sw, height = sh }
	local frame = { Visible = false, AbsoluteSize = { X = sw, Y = sh } }
	h.frame = frame
	local components: any = {}
	function components.modalSheet(_theme: any, props: any): any
		h.title = props.title
		return {
			frame = frame,
			scroll = {},
			close = {
				Activated = { Connect = function() end },
			},
		}
	end
	local function widget(_theme: any, props: any): any
		local made = table.clone(props)
		made.Destroy = function(self: any)
			self.destroyed = true
		end
		table.insert(h.widgets, made)
		return made
	end
	components.label, components.button = widget, widget
	local listener: any = nil
	h.ctx = {
		ui = { components = components, theme = { default = {} } },
		locale = locale,
		playerGui = {},
		actorId = "me",
		content = Content,
		names = {},
		outpostPolicy = Content.outpostPolicy,
		destinations = HomeContent.rules(Content).moveDestinations,
		instance = {
			new = function(): any
				return { Destroy = function() end }
			end,
		},
		udim2 = {
			new = function(xs: number, xo: number, ys: number, yo: number): any
				return { xs = xs, xo = xo, ys = ys, yo = yo }
			end,
		},
		fitSheet = function(fitted: any)
			assert(fitted == frame, "sheet joins the shared fitted rect")
		end,
		dock = function(entry: any): any
			h.docks[entry.id] = entry
			return {
				open = function()
					entry.setOpen(true)
				end,
				setAvailable = function() end,
			}
		end,
		onSnapshot = function(callback: any): any
			listener = callback
			return function() end
		end,
		send = function(action: string, args: any): any
			table.insert(h.sends, { action = action, args = args })
			return table.remove(h.replies, 1) or { ok = true }
		end,
		serverNow = function(): number
			return NOW
		end,
		journalText = function(key: string): string?
			return JournalText(locale, key)
		end,
	}
	h.push = function(extensions: any, packet: any?)
		listener(extensions, packet or {})
	end
	h.live = function(): { any }
		local out = {}
		for _, item in h.widgets do
			if not item.destroyed then
				table.insert(out, item)
			end
		end
		return out
	end
	h.press = function(pattern: string)
		for _, item in h.live() do
			if item.onClick and string.find(item.text, pattern, 1, true) then
				item.onClick()
				return
			end
		end
		error("no button containing " .. pattern)
	end
	h.has = function(pattern: string): boolean
		for _, item in h.live() do
			if string.find(item.text, pattern, 1, true) then
				return true
			end
		end
		return false
	end
	return h
end

local function home(owner: string): any
	local state = Home.new(owner, HomeContent.rules(Content), 1)
	state.revision = 4
	return state
end

local function outpostState(): any
	return {
		owner = "gamma",
		expiresAt = NOW + 7200,
		queue = { me = "alpha", b = "alpha", c = "alpha", d = "beta" },
		matches = {},
	}
end

local function activeOutpost(): any
	local state = outpostState()
	state.queue = {}
	state.matches.m1 = {
		status = "active",
		teams = { { clanId = "alpha", actors = { "me", "b", "c" } }, { clanId = "beta", actors = { "d", "e", "f" } } },
		actors = { me = "alpha", b = "alpha", c = "alpha", d = "beta", e = "beta", f = "beta" },
		score = { 75, 20 },
		finishAt = NOW + 300,
		winner = "",
	}
	return state
end

local function settledOutpost(winner: string): any
	local state = activeOutpost()
	local match = state.matches.m1
	match.status, match.winner, match.previousOwner, match.previousExpiresAt = "settled", winner, "gamma", NOW + 7200
	if winner ~= "" then
		state.owner, state.expiresAt = winner, NOW + 86400
	end
	return state
end

local function bagPacket(): any
	return {
		snapshots = {
			["survival-coop"] = {
				inventory = {
					{
						kind = "carried",
						items = {
							p1 = {
								itemId = "p1",
								catalogId = "wood",
								quantity = 4,
								qualityMilli = 2000,
								durabilityMilli = 0,
								attributes = {},
							},
						},
						reservations = {},
					},
				},
			},
		},
	}
end

-- Every screen in a representative state that shows its longest rows.
local function open(name: string, h: any): any
	local panel = Panels[name].factory(h.ctx)
	if name == "permissions" then
		h.push({ home = home("me"), clan = { clanId = "alpha" } })
	elseif name == "move" then
		h.push({ home = home("me") })
		panel.open()
		h.press(L.text(h.ctx.locale, "move.pick", L.text(h.ctx.locale, "dest.cove-south")))
		return panel
	elseif name == "lobby" then
		h.push({ outpost = outpostState() })
	elseif name == "match" then
		h.push({ outpost = activeOutpost() })
		h.press(L.text(h.ctx.locale, "match.leave"))
		return panel
	elseif name == "results" then
		h.push({ outpost = activeOutpost(), clan = { clanId = "alpha", research = {} } })
		h.push({
			outpost = settledOutpost("alpha"),
			clan = { clanId = "alpha", research = { ["advanced-capture"] = true } },
		})
		return panel
	elseif name == "transaction" then
		h.ctx.onSend = function(callback: any)
			h.observe = callback
			return function() end
		end
		panel = Panels.transaction.factory(h.ctx)
		h.observe("survival-coop:market-buy", { "listing", 1 }, { ok = false, reason = "COMMAND_PENDING" })
		h.observe(
			"survival-coop:trade-confirm",
			{ "t", 2 },
			{ ok = false, reason = "x", data = { status = "recovering", operationId = "me:abc:req-1234" } }
		)
		return panel
	elseif name == "trade" then
		h.push({
			trade = {
				peers = { "pal" },
				trade = {
					tradeId = "t1",
					participants = { "me", "pal" },
					revision = 3,
					offers = {
						me = {
							coins = 120,
							item = {
								catalogId = "wood",
								quantity = 4,
								qualityMilli = 2000,
								durabilityMilli = 9000,
								attributes = { level = 12 },
							},
						},
						pal = { coins = 999999 },
					},
					confirmed = { pal = true },
					status = "open",
				},
			},
		}, bagPacket())
	elseif name == "dialogue" then
		h.push({
			journal = {
				active = "rw.c01.signal-trace",
				counts = { ["rw.c01.signal-trace.1"] = 1, ["rw.c01.signal-trace.2"] = 1, ["rw.c01.signal-trace.3"] = 1 },
				completed = {},
			},
		})
		panel.talk("bram", "clan-membership")
		return panel
	end
	panel.open()
	return panel
end

local function checkLayout(h: any, label: string)
	local rect, at = h.rect, label .. " at " .. h.rect.width .. "w"
	local width = Sheet.contentWidth(rect.width)
	assert(rect.height >= 44 + 8 + Sheet.MIN_ROW, at .. ": header plus one full row visible")
	assert(width >= 44, at .. ": content width")
	-- Title shares the header with the close button (70 px reserve) and must not clip.
	assert(HudFit.textWidth(h.title, 15) <= rect.width - 70, at .. ": title clipped: " .. h.title)
	local rows = h.live()
	assert(#rows > 0, at .. ": blank sheet")
	local y = 8
	local buttons = 0
	for _, row in rows do
		assert(
			type(row.text) == "string" and row.text ~= "" and not string.find(row.text, "%%[ds]"),
			at .. ": bad row text"
		)
		local height = row.size.yo
		assert(row.size.xs == 1 and row.size.xo == 0, at .. ": row spans the content width")
		assert(height >= Sheet.MIN_ROW, at .. ": row under touch height")
		for _, line in string.split(row.text, "\n") do
			assert(not string.find(line, "^%s*$") or #row.text == 0, at .. ": empty line")
		end
		local lines = 0
		for _, line in string.split(row.text, "\n") do
			lines += math.max(1, math.ceil(HudFit.textWidth(line, Sheet.TEXT_SIZE) / (width - HudFit.PADDING * 2)))
		end
		assert(lines * Sheet.TEXT_SIZE * 1.2 <= height, at .. ": text clipped: " .. row.text)
		y += height + 6
		if row.onClick then
			buttons += 1
		end
	end
	assert(buttons > 0, at .. ": no reachable control")
end

local cases: { [string]: () -> () } = {}
for name in Panels do
	cases[name .. " layout fits PC portrait and landscape in EN and KO"] = function()
		for _, viewport in VIEWPORTS do
			for _, locale in LOCALES do
				local h = harness(locale, viewport[1], viewport[2], viewport[3])
				open(name, h)
				checkLayout(h, name .. " " .. locale)
			end
		end
	end
end

cases["sheet width estimate never under-measures ui-kit HudFit"] = function()
	for _, text in { "Confirm move", "집 이전 확인", "Time left 5:00", "%d shellmoney" } do
		assert(Sheet.textWidth(text, 15) >= HudFit.textWidth(text, 15), text)
	end
end

cases["every new screen command is a durable client action"] = function()
	for _, action in
		{
			"home-permissions",
			"home-move",
			"outpost-queue",
			"outpost-leave",
			"trade-open",
			"trade-offer",
			"trade-confirm",
			"trade-cancel",
			"journal-interact",
		}
	do
		assert(table.find(Durable.actions, "survival-coop:" .. action), action .. " not durable")
	end
end

cases["home permissions cycles one grant sends the full ACL and shows a refusal"] = function()
	local h = harness("ko-kr", 360, 640, true)
	open("permissions", h)
	assert(h.docks["home-permissions"], "reachable from the menu grid")
	h.replies = { { ok = false, reason = "CLAN_REQUIRED" } }
	h.press(L.text("ko-kr", "perm.build", L.text("ko-kr", "mode.none")))
	local sent = h.sends[1]
	assert(sent.action == "survival-coop:home-permissions" and sent.args[1] == "home:me", "command and token")
	local acl = sent.args[2].permissions
	assert(acl.grants.build == "friend" and acl.grants.use == "none" and acl.visit == "owner", "only build changed")
	assert(acl.friends == nil and acl.clanId == "alpha", "friend list stays server-side; clan from snapshot")
	assert(h.has(L.text("ko-kr", "refuse.CLAN_REQUIRED")), "localized refusal shown")
	local updated = home("me")
	updated.permissions.grants = { use = "owner", build = "friend", recover = "owner" }
	h.push({ home = updated, clan = { clanId = "alpha" } })
	assert(h.has(L.text("ko-kr", "perm.build", L.text("ko-kr", "mode.friend"))), "state reflected")
	local visitor = harness("en-us", 1280, 720, false)
	Panels.permissions.factory(visitor.ctx)
	visitor.push({ home = home("someone-else") })
	visitor.docks["home-permissions"].setOpen(true)
	assert(visitor.has(L.text("en-us", "refuse.FORBIDDEN")), "non-owner sees no controls")
end

cases["home move confirms with back, sends destination and shows lock refusal"] = function()
	local h = harness("en-us", 640, 339, true)
	open("move", h)
	assert(h.has("Access grants and property history are kept."), "preserved grants explained")
	h.press("Back")
	assert(h.has("Move to North cove") == false and h.has("Move to East cove"), "back returns to picker")
	h.press("Move to East cove")
	h.replies = { { ok = false, reason = "TRANSFER_LOCKED" } }
	h.press("Confirm move")
	assert(h.sends[1].action == "survival-coop:home-move" and h.sends[1].args[2].destination == "cove-east", "sent")
	assert(h.has(L.text("en-us", "refuse.TRANSFER_LOCKED")), "lock refusal shown")
	h.press("Confirm move")
	assert(h.has("Home moved. Grants kept."), "success shown")
	local moved = home("me")
	moved.location = "cove-east"
	h.push({ home = moved })
	assert(h.has("Current spot: East cove"), "state reflected")
end

cases["siege lobby shows roster readiness rules and queues"] = function()
	local h = harness("en-us", 1280, 720, false)
	open("lobby", h)
	assert(h.docks.outpost, "lobby is the outpost menu entry")
	assert(h.has("alpha: 3 queued (ready)") and h.has("beta: 1 queued (needs 2)"), "roster readiness")
	assert(h.has("3-8 vs 3-8") and h.has("10 minutes") and h.has("180 seconds"), "rules")
	h.replies = { { ok = false, reason = "NOT_TEAM_MEMBER" } }
	h.press("Leave queue")
	assert(h.sends[1].action == "survival-coop:outpost-queue" and h.sends[1].args[2].enabled == false, "leave sent")
	assert(h.has("Only clan members can queue for the siege."), "refusal shown")
	local state = outpostState()
	state.queue.me = nil
	h.push({ outpost = state })
	assert(h.has("Join queue"), "state reflected")
end

cases["siege match opens on arrival and leave needs explicit confirmation"] = function()
	local h = harness("en-us", 360, 640, true)
	Panels.match.factory(h.ctx)
	h.push({ outpost = outpostState() })
	assert(not h.frame.Visible, "no match, no sheet")
	h.push({ outpost = activeOutpost() })
	assert(h.frame.Visible, "match arrival opens the sheet")
	assert(h.has("alpha: 3 players, control 75/180 s") and h.has("Time left 5:00"), "teams progress timer")
	h.press("Leave match")
	assert(#h.sends == 0 and h.has("Yes, leave match"), "first press only asks")
	h.press("Stay")
	assert(#h.sends == 0, "stay sends nothing")
	h.press("Leave match")
	h.replies = { { ok = false, reason = "NOT_IN_MATCH" } }
	h.press("Yes, leave match")
	assert(h.sends[1].action == "survival-coop:outpost-leave" and h.sends[1].args[2].matchId == "m1", "leave sent")
	assert(h.has("You are not in this match."), "refusal shown")
end

cases["siege results open on settlement with ownership and research consequence"] = function()
	local h = harness("ko-kr", 640, 339, true)
	Panels.results.factory(h.ctx)
	h.push({ outpost = settledOutpost("beta"), clan = { clanId = "alpha" } })
	assert(not h.frame.Visible, "an old result is never replayed on join")
	local tie = harness("en-us", 1280, 720, false)
	Panels.results.factory(tie.ctx)
	tie.push({ outpost = activeOutpost(), clan = { clanId = "alpha" } })
	tie.push({ outpost = settledOutpost(""), clan = { clanId = "alpha" } })
	assert(tie.frame.Visible, "settlement opens results")
	assert(
		tie.has("Draw. No new owner.") and tie.has("Previous owner gamma keeps its original expiry (2h 00m left)."),
		"tie keeps previous"
	)
	assert(tie.has("Advanced capture needs clan research and outpost ownership."), "research consequence")
	local win = harness("en-us", 1280, 720, false)
	Panels.results.factory(win.ctx)
	win.push({ outpost = activeOutpost(), clan = { clanId = "alpha" } })
	win.push({
		outpost = settledOutpost("alpha"),
		clan = { clanId = "alpha", research = { ["advanced-capture"] = true } },
	})
	assert(win.has("alpha won the outpost.") and win.has("Owned for 24 hours (24h 00m left)."), "win and ownership")
	assert(
		win.has("Previous owner gamma lost the outpost.") and win.has("advanced capture research is active"),
		"consequence"
	)
	win.press("Continue")
	assert(not win.frame.Visible, "continue closes")
end

cases["transaction resends the same pending request and never a fresh debit"] = function()
	local h = harness("en-us", 360, 640, true)
	local observe: any = nil
	h.ctx.onSend = function(callback: any)
		observe = callback
		return function() end
	end
	Panels.transaction.factory(h.ctx)
	observe("survival-coop:market-buy", { "listing", 1 }, { ok = true })
	assert(not h.frame.Visible, "ordinary success shows nothing")
	observe("survival-coop:market-buy", { "listing", 1 }, { ok = false, reason = "COMMAND_PENDING" })
	assert(h.frame.Visible and h.has("Settling. Nothing is charged twice."), "settling surfaced")
	h.press("Check status")
	assert(h.sends[1].action == "survival-coop:market-buy" and h.sends[1].args[1] == "listing", "same action and args")
	observe("survival-coop:market-buy", { "listing", 1 }, { ok = false, reason = "INSUFFICIENT_FUNDS" })
	assert(h.has("Rejected: Not enough shellmoney."), "rejection localized")
	observe("survival-coop:market-buy", { "listing", 1 }, { ok = true, data = { operationId = "op-1" } })
	assert(h.has("Delivered.") and h.has("Ref op-1"), "delivered with operationId")
	h.press("Close (keeps settling)")
	assert(not h.frame.Visible, "safe close")
	local source = fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")
	assert(
		string.find(source, "pending[actionId] = CommandTransport.request(pending[actionId]", 1, true),
		"request id reuse"
	)
end

cases["direct trade invites, offers exact stack, confirms by revision and shows refusals"] = function()
	local h = harness("en-us", 1280, 720, false)
	Panels.trade.factory(h.ctx)
	h.push({ trade = { peers = { "pal" } } }, bagPacket())
	h.docks["direct-trade"].setOpen(true)
	h.replies = { { ok = false, reason = "DIFFERENT_SERVER" } }
	h.press("Trade with pal")
	assert(h.sends[1].action == "survival-coop:trade-open" and h.sends[1].args[1] == "pal", "invite sent")
	assert(h.has("That player is not on this server."), "refusal shown")
	local trade = {
		tradeId = "t1",
		participants = { "me", "pal" },
		revision = 1,
		offers = { me = { coins = 0 }, pal = { coins = 5 } },
		confirmed = { pal = true },
		status = "open",
	}
	h.push({ trade = { peers = { "pal" }, trade = trade } }, bagPacket())
	assert(h.has("Confirmed: you no, them yes"), "both confirmations visible")
	h.press("Quantity 1")
	h.press("Coins 0")
	h.press("Update my offer")
	local offer = h.sends[2]
	assert(offer.action == "survival-coop:trade-offer" and offer.args[2].revision == 1, "offer bound to revision")
	assert(offer.args[2].itemId == "p1" and offer.args[2].quantity == 2 and offer.args[2].coins == 10, "exact draft")
	h.replies = { { ok = false, reason = "STALE_REVISION" } }
	h.press("Confirm trade")
	assert(h.sends[3].action == "survival-coop:trade-confirm" and h.sends[3].args[2] == 1, "confirm revision")
	assert(h.has("The offer changed. Review it again."), "stale refusal")
	h.press("Cancel trade")
	assert(h.sends[4].action == "survival-coop:trade-cancel", "cancel sent")
	h.push({ trade = { peers = { "pal" }, last = { tradeId = "t1", status = "settled" } } }, bagPacket())
	assert(h.has("Trade complete."), "settled state reflected")
	local invited = harness("ko-kr", 360, 640, true)
	invited.ctx.actorId = "pal"
	Panels.trade.factory(invited.ctx)
	local fresh = table.clone(trade)
	fresh.revision = 0
	invited.push({ trade = { peers = { "me" }, trade = fresh } }, bagPacket())
	assert(invited.frame.Visible, "invitation opens the sheet for the invited player")
end

cases["dialogue offers objective dependent complete and service choices"] = function()
	local h = harness("en-us", 640, 339, true)
	local opened: string? = nil
	h.ctx.openPanel = function(id: string)
		opened = id
	end
	open("dialogue", h)
	assert(h.frame.Visible and h.has("Bram: A clan shares funds"), "original npc text")
	h.press("Continue")
	h.replies = { { ok = false, reason = "OUT_OF_REACH" } }
	h.press("Complete: Speak with Bram")
	assert(h.sends[1].action == "survival-coop:journal-interact", "checkpoint command")
	assert(h.sends[1].args[1] == "rw.c01.signal-trace.4:1", "objective checkpoint id")
	assert(h.has("Step closer first."), "refusal shown")
	h.press("Open: Clan membership")
	assert(opened == "clan-membership" and not h.frame.Visible, "service choice opens the panel")
	local other = harness("ko-kr", 360, 640, true)
	local panel = open("dialogue", other)
	panel.talk("pip", "shop")
	assert(not other.has("완료:"), "no complete choice when objective is for another npc")
	local source = fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")
	assert(string.find(source, "context.dialogue(string.sub(facility, 5)", 1, true), "npc prompt opens dialogue")
end

return cases
