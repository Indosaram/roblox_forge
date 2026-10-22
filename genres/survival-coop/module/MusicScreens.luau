--!strict
local Score = require("../../../core/domain/music/Score")
local ScoreRef = require("../../../core/domain/music/ScoreRef")
local Text = require("./MusicText")
local Transport = require("./ScoreTransport")
local Selection = require("./MusicSelection")
local Sheet = require("./MusicSheet")
local env: any = getfenv()
local game: any = env.game
local Instance: any = env.Instance
local Enum: any = env.Enum
local UDim2: any = env.UDim2
local Color3: any = env.Color3
local M = {}

local PREFIX = "survival-coop:"
local SHARE = PREFIX .. "score-share"
local JOIN = PREFIX .. "ensemble-join"
local READY = PREFIX .. "ensemble-ready"
local START = PREFIX .. "ensemble-start"
local LEAVE = PREFIX .. "ensemble-leave"
M.SHARE, M.JOIN, M.READY, M.START, M.LEAVE = SHARE, JOIN, READY, START, LEAVE

local function summary(score: any, rules: any): (number, number)
	local notes, lastTick = 0, 0
	for _, part in score.parts do
		notes += #part.notes
		for _, note in part.notes do
			lastTick = math.max(lastTick, note.startTick + note.durationTicks)
		end
	end
	return notes, math.ceil(lastTick * 60 / (score.tempo * rules.ticksPerQuarter))
end

function M.check(locale: string, text: string, rules: any, decode: (string) -> any): (any, string)
	local score, reason = Score.import(text, rules, decode)
	if not score then
		return nil, Text.refusal(locale, reason)
	end
	local notes, seconds = summary(score, rules)
	return score, Text.text(locale, "import_preview", score.tempo, #score.parts, notes, seconds)
end

function M.lookup(locale: string, text: string): (any, string)
	local scoreId, revision, reason = ScoreRef.parse(text)
	if not scoreId then
		return nil, Text.refusal(locale, reason)
	end
	return { scoreId = scoreId, revision = revision, owned = false },
		Text.text(locale, "import_selected", ScoreRef.format(scoreId, revision :: number))
end

function M.shareModel(locale: string, selection: any): any
	if not selection or not selection.owned then
		return { available = false, ref = "", line = Text.text(locale, "lock_unsaved") }
	end
	local ref = ScoreRef.format(selection.scoreId, selection.revision)
	return { available = true, ref = ref, line = Text.text(locale, "share_ref", ref) }
end

function M.shareArgs(actor: string, selection: any, recipient: string): ({ any }?, string?)
	if not selection or not selection.owned then
		return nil, "score.unsaved"
	end
	local id, reason = ScoreRef.recipient(actor, recipient)
	if not id then
		return nil, reason
	end
	return { selection.scoreId, selection.revision, id }, nil
end

local function count(map: any): number
	local n = 0
	for _ in map or {} do
		n += 1
	end
	return n
end

function M.lobbyModel(
	locale: string,
	room: any,
	actor: string,
	selection: any,
	part: number,
	nameOf: (string) -> string,
	inRange: boolean,
	maxPerformers: number
): any
	local scoreId = if room then room.scoreId elseif selection then selection.scoreId else nil
	local revision = if room then room.revision elseif selection then selection.revision else nil
	local view: any = {
		score = if scoreId
			then Text.text(locale, "lobby_score", ScoreRef.format(scoreId, revision))
			else Text.text(locale, "lobby_none"),
		slots = {},
		range = Text.text(locale, if inRange then "lobby_in_range" else "lobby_out_range"),
		part = part,
		partLabel = Text.text(locale, "lobby_part", part),
		joinArgs = if scoreId then { scoreId, revision, part } else nil,
	}
	local members = {}
	for id, member in if room then room.members else {} do
		table.insert(members, { id = id, part = member.part, ready = member.ready })
	end
	table.sort(members, function(a, b)
		return a.part < b.part
	end)
	for index = 1, maxPerformers do
		local member = members[index]
		if member then
			local tags = (if member.ready then Text.text(locale, "lobby_ready_tag") else "")
				.. (if room.host == member.id then Text.text(locale, "lobby_host_tag") else "")
			view.slots[index] = Text.text(locale, "lobby_slot", index, nameOf(member.id), member.part, tags)
		else
			view.slots[index] = Text.text(locale, "lobby_empty", index)
		end
	end
	local mine = room and room.members[actor]
	view.member = mine ~= nil
	view.ready = mine ~= nil and mine.ready == true
	view.host = room ~= nil and room.host == actor
	view.playing = room ~= nil and room.startAt ~= nil
	view.full = room ~= nil and mine == nil and count(room.members) >= maxPerformers
	view.join = Text.text(locale, "lobby_join", part)
	view.readyLabel = Text.text(locale, if view.ready then "lobby_unready" else "lobby_ready")
	return view
end

function M.playModel(locale: string, room: any, actor: string, now: number, joinedAt: number?): any
	if not room or not room.startAt then
		return { visible = false }
	end
	local member = room.members[actor]
	local vacancy = room.vacancies and room.vacancies[actor]
	if not member and not vacancy then
		return { visible = false }
	end
	local part = if member then member.part else vacancy
	local total, done = 0, 0
	for _, event in room.events or {} do
		if event.part == part then
			total += 1
			if event.untilAt <= now then
				done += 1
			end
		end
	end
	local late = joinedAt ~= nil and joinedAt > room.startAt
	return {
		visible = true,
		countdown = if now < room.startAt
			then Text.text(locale, "play_countdown", room.startAt - now)
			else Text.text(locale, "play_progress", part, done, total),
		sync = Text.text(locale, if late then "play_late" else "play_sync"),
		action = if member then "leave" else "rejoin",
		actionLabel = if member then Text.text(locale, "play_leave") else Text.text(locale, "play_rejoin", part),
		args = if member then {} else { room.scoreId, room.revision, part },
	}
end

function M.playBounds(width: number, _height: number): (number, number, number, number)
	local h = 128
	if width < 600 then
		return 12, 180, width - 24, h
	end
	local menuX = width - math.min(216, width - 100) - 84
	local x = if width >= 1000 then 548 else 12
	return x, 64, math.min(320, menuX - 12 - x), h
end

local function result(locale: string, value: any, ok: string?): string
	if value.ok then
		return ok or ""
	end
	return Text.refusal(locale, value.reason)
end

function M.factory(ctx: any): any
	if not ctx.dock then
		return nil
	end
	local locale = ctx.locale
	local players = game:GetService("Players")
	local actor = tostring(players.LocalPlayer.UserId)
	local connections: { any } = {}
	local unsubscribers: { () -> () } = {}

	local import = Sheet.mount(ctx, "score-import", "import_title", true, 20)
	local hint = import.label("ImportHint", Text.text(locale, "import_hint"))
	hint.TextSize = 14
	local json = import.box("ImportText", "{ }", 96)
	local importStatus = import.label("ImportStatus")
	local checked: any = nil
	local pendingId: string? = nil
	import.button("ImportCheck", Text.text(locale, "import_check"), function()
		local score, message = M.check(locale, json.Text, ctx.rules, ctx.decode)
		checked = score
		importStatus.Text = message
	end)
	import.button("ImportSave", Text.text(locale, "import_save"), function()
		local score, message = M.check(locale, json.Text, ctx.rules, ctx.decode)
		if not score then
			importStatus.Text = message
			return
		end
		checked = score
		pendingId = pendingId or ctx.requestId()
		local saved = Transport.send(ctx, json.Text, nil, pendingId :: string)
		if saved.ok then
			pendingId = nil
			Selection.set({
				scoreId = saved.data.scoreId,
				revision = saved.data.revision,
				parts = #checked.parts,
				owned = true,
			})
			importStatus.Text =
				Text.text(locale, "import_saved", ScoreRef.format(saved.data.scoreId, saved.data.revision))
		else
			importStatus.Text = Text.refusal(locale, saved.reason)
		end
	end)
	local lookup = import.box("ScoreLookup", Text.text(locale, "import_lookup"))
	import.button("ScoreLookupUse", Text.text(locale, "import_use"), function()
		local selection, message = M.lookup(locale, lookup.Text)
		if selection then
			Selection.set(selection)
		end
		importStatus.Text = message
	end)

	local share = Sheet.mount(ctx, "score-share", "share_title", true, 21)
	local refLine = share.label("ShareRef")
	local refBox = share.box("ShareRefText", "")
	refBox.TextEditable = false
	local note = share.label("ShareNote", Text.text(locale, "share_note"))
	note.TextSize = 14
	local recipient = share.box("ShareRecipient", Text.text(locale, "share_recipient"))
	local shareStatus = share.label("ShareStatus")
	share.button("ShareSend", Text.text(locale, "share_send"), function()
		local selection = Selection.get()
		local args, reason = M.shareArgs(actor, selection, recipient.Text)
		if not args then
			shareStatus.Text = Text.refusal(locale, reason)
			return
		end
		local value = ctx.send(SHARE, args)
		shareStatus.Text = result(locale, value, Text.text(locale, "share_done", ScoreRef.format(args[1], args[2])))
	end)
	local function renderShare(selection: any)
		local model = M.shareModel(locale, selection)
		refLine.Text, refBox.Text = model.line, model.ref
		share.handle.setAvailable(model.available, if model.available then nil else "lock_unsaved")
	end

	local lobby = Sheet.mount(ctx, "ensemble-lobby", "lobby_title", true, 22)
	local room: any = nil
	local part = 1
	local scoreLine = lobby.label("LobbyScore")
	local slots = {}
	for index = 1, ctx.rules.maxPerformers do
		slots[index] = lobby.label("LobbySlot" .. index)
	end
	local rangeLine = lobby.label("LobbyRange")
	local lobbyStatus = lobby.label("LobbyStatus")
	local partButton, joinButton, readyButton
	local function stations(): boolean
		local character = players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			return false
		end
		for _, station in game:GetService("CollectionService"):GetTagged("ForgeSurvivalStation") do
			local kind = station:GetAttribute("ForgeStationKind")
			if
				(kind == "campfire" or kind == "fireplace")
				and (station.Position - root.Position).Magnitude <= ctx.rules.radiusStuds
			then
				return true
			end
		end
		return false
	end
	local function nameOf(id: string): string
		local player = players:GetPlayerByUserId(tonumber(id) or 0)
		return if player then player.DisplayName else id
	end
	local function renderLobby()
		local view =
			M.lobbyModel(locale, room, actor, Selection.get(), part, nameOf, stations(), ctx.rules.maxPerformers)
		scoreLine.Text, rangeLine.Text = view.score, view.range
		for index, line in view.slots do
			slots[index].Text = line
		end
		partButton.Text, joinButton.Text, readyButton.Text = view.partLabel, view.join, view.readyLabel
		return view
	end
	local function act(action: string, args: { any })
		lobbyStatus.Text = result(locale, ctx.send(action, args))
		renderLobby()
	end
	partButton = lobby.button("LobbyPart", "", function()
		part = part % ctx.rules.maxParts + 1
		renderLobby()
	end)
	joinButton = lobby.button("LobbyJoin", "", function()
		local view = renderLobby()
		if not view.joinArgs then
			lobbyStatus.Text = Text.refusal(locale, "score.unsaved")
			return
		end
		act(JOIN, view.joinArgs)
	end)
	readyButton = lobby.button("LobbyReady", "", function()
		act(READY, { not renderLobby().ready })
	end)
	lobby.button("LobbyStart", Text.text(locale, "lobby_start"), function()
		act(START, {})
	end)
	lobby.button("LobbyLeave", Text.text(locale, "lobby_leave"), function()
		act(LEAVE, {})
	end)
	table.insert(lobby.opened, renderLobby)
	local function attach(station: any)
		local kind = station:GetAttribute("ForgeStationKind")
		if (kind ~= "campfire" and kind ~= "fireplace") or station:FindFirstChild("ForgeEnsemblePrompt") then
			return
		end
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name, prompt.ActionText, prompt.ObjectText =
			"ForgeEnsemblePrompt", Text.text(locale, "lobby_prompt"), Text.text(locale, "nav_music")
		prompt.MaxActivationDistance, prompt.HoldDuration, prompt.KeyboardKeyCode =
			ctx.rules.radiusStuds, 0, Enum.KeyCode.R
		prompt.RequiresLineOfSight = false
		prompt.Parent = station
		table.insert(
			connections,
			prompt.Triggered:Connect(function()
				if ctx.open then
					ctx.open("ensemble-lobby")
				end
			end)
		)
	end
	local tags = game:GetService("CollectionService")
	for _, station in tags:GetTagged("ForgeSurvivalStation") do
		attach(station)
	end
	table.insert(connections, tags:GetInstanceAddedSignal("ForgeSurvivalStation"):Connect(attach))

	local overlayGui = Instance.new("ScreenGui")
	overlayGui.Name, overlayGui.ResetOnSpawn, overlayGui.DisplayOrder = "ForgeEnsemblePlay", false, 21
	overlayGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	overlayGui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	local theme = ctx.ui.theme.default
	local overlay = ctx.ui.components.panel(theme, { name = "EnsemblePlay", size = UDim2.fromOffset(320, 128) })
	overlay.Visible, overlay.Parent = false, overlayGui
	local countdown = ctx.ui.components.label(theme, {
		text = "",
		size = UDim2.new(1, -16, 0, 32),
		position = UDim2.fromOffset(8, 4),
		parent = overlay,
	})
	countdown.Name = "PlayCountdown"
	local sync = ctx.ui.components.label(theme, {
		text = "",
		size = UDim2.new(1, -16, 0, 32),
		position = UDim2.fromOffset(8, 36),
		textSize = 13,
		parent = overlay,
	})
	sync.Name = "PlaySync"
	local playAction: any = nil
	local playModel: any = { visible = false }
	local playButton = ctx.ui.components.button(theme, {
		text = "",
		size = UDim2.new(1, -16, 0, 48),
		position = UDim2.fromOffset(8, 72),
		parent = overlay,
		onClick = function()
			if playModel.action == "leave" then
				act(LEAVE, {})
			elseif playModel.action == "rejoin" then
				act(JOIN, playModel.args)
			end
		end,
	})
	playButton.Name = "PlayAction"
	local joinedAt: number? = nil
	local function fitOverlay()
		local size = overlayGui.AbsoluteSize
		local x, y, w, h = M.playBounds(size.X, size.Y)
		overlay.Position, overlay.Size = UDim2.fromOffset(x, y), UDim2.fromOffset(w, h)
	end
	table.insert(connections, overlayGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitOverlay))
	fitOverlay()
	table.insert(
		connections,
		game:GetService("RunService").Heartbeat:Connect(function()
			local now = ctx.serverNow()
			if room and room.startAt and room.members[actor] and joinedAt == nil then
				joinedAt = now
			elseif not (room and room.startAt) then
				joinedAt = nil
			end
			playModel = M.playModel(locale, room, actor, now, joinedAt)
			overlay.Visible = playModel.visible
			if playModel.visible then
				countdown.Text, sync.Text, playButton.Text = playModel.countdown, playModel.sync, playModel.actionLabel
			end
			playAction = playModel.action
		end)
	)

	table.insert(
		unsubscribers,
		Selection.subscribe(function(selection)
			renderShare(selection)
			renderLobby()
		end)
	)
	table.insert(
		unsubscribers,
		ctx.onSnapshot(function(snapshot: any)
			local ensemble = snapshot.ensemble
			room = if ensemble then ensemble.room else nil
			renderLobby()
		end)
	)
	renderShare(Selection.get())
	renderLobby()
	return {
		playAction = function()
			return playAction
		end,
		destroy = function()
			for _, connection in connections do
				connection:Disconnect()
			end
			for _, stop in unsubscribers do
				stop()
			end
			import.gui:Destroy()
			share.gui:Destroy()
			lobby.gui:Destroy()
			overlayGui:Destroy()
		end,
	}
end

return M
