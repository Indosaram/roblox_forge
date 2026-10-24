--!strict
-- Client taming panel: pen list (species, ready time, feed button) plus mount/dismount buttons,
-- rendered from snapshot.survivalExtensions.taming. The server owns every decision (ready time,
-- feed value, ride speed and carry); this panel only sends durable commands and renders results.
-- Strings mirror games/robango-island/locale/strings.csv keys (tame_*); species names are the
-- pack's wildlife_<id> strings, with the raw id as fallback.
-- World input: every wild model under Workspace.ForgeWildlife whose ForgeWildlifeKind is in
-- snapshot.taming.tameable gets a client-local ProximityPrompt (Q / click / tap) that sends
-- tame-hit until the stun gauge for that wild id is full, then tame-capture.
local WildlifeNames = require("./WildlifeNames")
local M = {}

-- Durable ids are genre-qualified: ctx.send checks them against the published action list.
local PREFIX = "survival-coop:"
local FEED = PREFIX .. "tame-feed"
local MOUNT = PREFIX .. "tame-mount"
local DISMOUNT = PREFIX .. "tame-dismount"
local HIT = PREFIX .. "tame-hit"
local CAPTURE = PREFIX .. "tame-capture"
local PROMPT_NAME = "ForgeTame"
local DEFAULT_REACH = 10

local PackLocale = require("./PackLocale")
local strings: { [string]: { string } } = PackLocale.rows({})

local function pick(locale: string, entry: { string }): string
	return if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
end

--- Pure text lookup (specced): falls back to the key; `%s` is filled with `arg`.
function M.text(locale: string, key: string, arg: string?): string
	local entry = strings[key]
	if entry == nil then
		return key
	end
	local text = pick(locale, entry)
	if arg ~= nil then
		text = string.format(text, arg)
	end
	return text
end

--- Localized species name for a wildlife id.
function M.species(locale: string, species: string): string
	return WildlifeNames.name(locale, species)
end

--- m:ss for a remaining time in milliseconds (rounded up to whole seconds).
function M.clock(remainingMillis: number): string
	local seconds = math.max(0, math.ceil(remainingMillis / 1000))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

--- Pen label for a row: "Ready" once the timer is spent, else the localized countdown.
function M.pen(locale: string, remainingMillis: number): string
	if remainingMillis <= 0 then
		return M.text(locale, "tame_ready")
	end
	return M.text(locale, "tame_remaining", M.clock(remainingMillis))
end

--- Gauge line: "Stun gauge: Ridge Strider 60/100" (species omitted when unknown).
function M.gauge(locale: string, gauge: { species: string?, level: number, max: number }): string
	local name = if gauge.species then M.species(locale, gauge.species) .. " " else ""
	return M.text(locale, "tame_gauge", string.format("%s%d/%d", name, gauge.level, gauge.max))
end

--- Maps a send result to the message shown under the list ("" on success).
-- Refusal reasons with a specific message; COOLDOWN is silent (the next press just works).
local REFUSALS: { [string]: string } = {
	CHARGE_PENDING = "tame_pending",
	NO_CAPTURE_TOOL = "tame_no_tool",
	GAUGE_NOT_FULL = "tame_not_full",
	OUT_OF_REACH = "tame_too_far",
	WILD_GONE = "tame_gone",
	WILD_ABSENT = "tame_gone",
	COOLDOWN = "",
	TOO_FAR = "tame_too_far",
	TARGET_UNAVAILABLE = "tame_gone",
}
local requirements = {
	SUBDUE_GATED = {
		"Learn melee_2; weaken it to 25% health",
		"근접 전투 2를 배우고 체력을 25% 이하로 낮추세요",
	},
	CLUB_REQUIRED = { "Bring a usable club", "사용 가능한 몽둥이가 필요해요" },
	CAPTURE_GATED = { "Learn survival_3 and stun it", "생존 3을 배우고 기절시키세요" },
	NO_ROPE = { "Bring Capture Rope", "포획 밧줄이 필요해요" },
	NO_FEED_ITEM = { "Bring Herbivore Feed", "초식동물 사료가 필요해요" },
}

function M.refusal(locale: string, result: { ok: boolean?, reason: string? }): string
	if result.ok then
		return ""
	end
	local requirement = result.reason and requirements[result.reason]
	if requirement then
		return pick(locale, requirement)
	end
	local key = if result.reason then REFUSALS[result.reason] else nil
	if key == "" then
		return ""
	end
	return if key then M.text(locale, key) else M.text(locale, "tame_failed") .. " [" .. (result.reason or "?") .. "]"
end

export type CompanionRow = {
	id: string,
	title: string,
	detail: string,
	color: { r: number, g: number, b: number }?,
	actions: { string },
}

--- Pure view model for the V2 companion list (specced): a summary line plus one row per pet,
--- sorted by id, with the localized species/phase title, a stats line (species level, fullness,
--- taming feeds and timer, rest timer, saddle/ride), the species body colour and the verbs the
--- pet's phase allows. `content` is the pack content (wildlifeDetails, progressionPolicy.companion).
function M.companions(locale: string, state: any, content: any, nowMillis: number): (string, { CompanionRow })
	local rules = content and content.progressionPolicy and content.progressionPolicy.companion or {}
	local species: { [string]: any } = {}
	for _, row in (content and content.wildlifeDetails) or {} do
		species[row.id] = row
	end
	local companions = state and state.companions or {}
	local ids = {}
	for id in companions.pets or {} do
		table.insert(ids, id)
	end
	table.sort(ids)
	local rows: { CompanionRow } = {}
	for _, id in ids do
		local pet = companions.pets[id]
		local detailRow = species[pet.species]
		local riding = companions.ride == id
		local parts = {
			string.format(
				M.text(locale, "companion_stats"),
				if detailRow then detailRow.level else 1,
				math.floor(pet.satiety or 0),
				rules.maxSatiety or 100
			),
		}
		if pet.phase == "Taming" then
			table.insert(parts, string.format(M.text(locale, "companion_feeds"), pet.feeds or 0, rules.feedCount or 3))
			table.insert(parts, M.pen(locale, (pet.readyAt or 0) - nowMillis))
		elseif pet.phase == "Downed" then
			table.insert(parts, M.text(locale, "companion_resting", M.clock((pet.injuredUntil or 0) - nowMillis)))
		end
		if riding then
			table.insert(parts, M.text(locale, "companion_riding"))
		elseif pet.saddle then
			table.insert(parts, M.text(locale, "companion_saddled"))
		end
		local actions = if pet.phase == "Captured"
			then { "place", "release:" .. id }
			elseif pet.phase == "PenPlaced" then { "train" }
			elseif pet.phase == "Taming" then { "feed", "claim", "cancel" }
			elseif pet.phase == "Stored" then { "deploy", "release:" .. id }
			elseif pet.phase == "Deployed" then { "feed", "recall" }
			else { "recover", "feed" }
		if pet.phase == "Stored" and not pet.saddle then
			table.insert(actions, 2, "saddle")
		elseif pet.phase == "Deployed" then
			table.insert(actions, if riding then "dismount" elseif pet.saddle then "mount" else "saddle")
		end
		local phaseKey = "companion_phase_" .. tostring(pet.phase)
		local body = detailRow and detailRow.visual and detailRow.visual.body
		table.insert(rows, {
			id = id,
			title = M.species(locale, pet.species) .. " · " .. (if strings[phaseKey]
				then M.text(locale, phaseKey)
				else M.text(locale, "companion_phase_Stored")),
			detail = table.concat(parts, " · "),
			color = if body then { r = body.r, g = body.g, b = body.b } else nil,
			actions = actions,
		})
	end
	local out = if companions.deployed then 1 else 0
	local summary = string.format(M.text(locale, "companion_summary"), #ids, rules.capacity or 8, out)
	return summary, rows
end

export type Gauge = { wildId: string?, level: number, max: number, full: boolean? }

--- Pure prompt selection (specced): "capture" once the known gauge for this wild id is full,
--- else "stun". Returns the durable action id and the localized prompt text.
function M.promptAction(locale: string, gauge: Gauge?, wildId: string): (string, string)
	local full = gauge ~= nil
		and (gauge.wildId == nil or gauge.wildId == wildId)
		and (gauge.full == true or gauge.level >= gauge.max)
	if full then
		return CAPTURE, M.text(locale, "tame_capture")
	end
	return HIT, M.text(locale, "tame_stun")
end

--- Message for a stun/capture result (specced): capture outcomes get their own lines,
--- refusals go through `refusal`.
function M.outcome(locale: string, action: string, result: any, species: string?): string
	if result.ok and action == CAPTURE and type(result.data) == "table" then
		if result.data.captured then
			return M.text(locale, "tame_captured", M.species(locale, result.data.species or species or ""))
		end
		return M.text(locale, "tame_escaped")
	end
	return M.refusal(locale, result)
end

function M.factory(ctx: any): { destroy: () -> () }?
	local ui = ctx.ui
	local theme = ui.theme.default
	local players = game:GetService("Players")
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = "ForgeTaming", false, 15, false
	gui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	local sheet = ui.components.modalSheet(theme, {
		name = "TamingSheet",
		title = M.text(ctx.locale, "tame_title"),
		parent = gui,
	})
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sheet.frame.Visible = true
	if ctx.fitSheet then
		ctx.fitSheet(sheet.frame)
	end
	sheet.close.Activated:Connect(function()
		gui.Enabled = false
	end)
	if ctx.dock then
		ctx.dock({
			id = "taming",
			label = M.text(ctx.locale, "tame_title"),
			order = 3,
			setOpen = function(open: boolean)
				gui.Enabled = open
			end,
			isOpen = function()
				return gui.Enabled
			end,
		})
	end
	local status = ui.components.label(theme, { text = "", size = UDim2.new(1, 0, 0, 28), parent = sheet.scroll })
	status.Name = "TamingStatus"
	local rows = Instance.new("Frame")
	rows.Name, rows.BackgroundTransparency, rows.Size, rows.Parent =
		"TamingRows", 1, UDim2.fromScale(1, 0), sheet.scroll
	rows.AutomaticSize = Enum.AutomaticSize.Y
	local layout = Instance.new("UIListLayout")
	layout.Padding, layout.Parent = UDim.new(0, 6), rows
	local timers: { { label: TextLabel, remaining: number } } = {}
	local companionDetails: { [string]: TextLabel } = {}
	local lastCompanions: any = nil
	local function serverMillis(): number
		return workspace:GetServerTimeNow() * 1000
	end
	local received = os.clock()
	local function send(action: string, args: { any }): any
		local result = ctx.send(action, args)
		status.Text = M.refusal(ctx.locale, result)
		return result
	end
	local function feed(animalId: string, feeds: { string })
		for _, feedId in feeds do
			local result = send(FEED, { animalId, feedId })
			if result.ok or result.reason ~= "NO_FEED_ITEM" then
				return
			end
		end
	end
	local function render(snapshot: { [string]: any })
		for _, child in rows:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		table.clear(timers)
		received = os.clock()
		local state = snapshot.taming
		local v2 = ctx.content ~= nil
			and ctx.content.progressionPolicy ~= nil
			and ctx.content.progressionPolicy.companion ~= nil
		lastCompanions = nil
		table.clear(companionDetails)
		if type(state) ~= "table" or state.companions or v2 then
			-- V2 companions (or no snapshot yet): summary, one card per pet, else how to tame.
			local summaryText, list = M.companions(ctx.locale, state, ctx.content, serverMillis())
			local summary =
				ui.components.label(theme, { text = summaryText, size = UDim2.new(1, 0, 0, 28), parent = rows })
			summary.Name, summary.LayoutOrder = "CompanionSummary", 0
			if #list == 0 then
				local empty = ui.components.label(theme, {
					text = M.text(ctx.locale, if v2 or type(state) ~= "table" then "companion_empty" else "tame_empty"),
					size = UDim2.new(1, 0, 0, 120),
					parent = rows,
				})
				empty.Name, empty.LayoutOrder = "CompanionEmpty", 1
				return
			end
			lastCompanions = state
			for order, row in list do
				local id = row.id
				local frame = Instance.new("Frame")
				frame.Name, frame.BackgroundTransparency, frame.Size, frame.Parent =
					"Companion-" .. id, 1, UDim2.new(1, 0, 0, 172), rows
				frame.LayoutOrder = order
				local chip = Instance.new("Frame")
				chip.Name, chip.Size, chip.Position, chip.BorderSizePixel =
					"SpeciesChip", UDim2.fromOffset(22, 22), UDim2.fromOffset(0, 3), 0
				chip.BackgroundColor3 = if row.color
					then Color3.fromRGB(row.color.r, row.color.g, row.color.b)
					else Color3.fromRGB(150, 150, 150)
				chip.Parent = frame
				local title = ui.components.label(theme, {
					text = row.title,
					size = UDim2.new(1, -30, 0, 28),
					position = UDim2.fromOffset(30, 0),
					parent = frame,
				})
				title.Name = "CompanionTitle"
				local detail = ui.components.label(theme, {
					text = row.detail,
					size = UDim2.new(1, 0, 0, 40),
					position = UDim2.fromOffset(0, 28),
					parent = frame,
				})
				detail.Name = "CompanionDetail"
				companionDetails[id] = detail
				for index, verb in ipairs(row.actions) do
					local control = ui.components.button(theme, {
						text = M.text(
							ctx.locale,
							"companion_" .. (if string.sub(verb, 1, 8) == "release:" then "release" else verb)
						),
						size = UDim2.new(0.5, -4, 0, 48),
						position = UDim2.new((index - 1) % 2 / 2, 0, 0, 72 + math.floor((index - 1) / 2) * 52),
						parent = frame,
						onClick = function()
							send(PREFIX .. "companion-action", { verb, id })
						end,
					})
					control.Name = verb .. "-" .. id
				end
			end
			return
		end
		local order = 0
		local function line(): Frame
			order += 1
			local frame = Instance.new("Frame")
			frame.Name, frame.BackgroundTransparency, frame.Size = "Row" .. order, 1, UDim2.new(1, 0, 0, 48)
			frame.LayoutOrder, frame.Parent = order, rows
			return frame
		end
		if state.gauge then
			local gaugeRow = line()
			local gaugeLabel = ui.components.label(theme, {
				text = M.gauge(ctx.locale, state.gauge),
				size = UDim2.new(1, 0, 0, 22),
				parent = gaugeRow,
			})
			gaugeLabel.Name = "GaugeLabel"
			local bar, setBar = ui.components.progressBar(theme, {
				size = UDim2.new(1, 0, 0, 14),
				position = UDim2.fromOffset(0, 28),
				parent = gaugeRow,
			})
			bar.Name = "GaugeBar"
			setBar(state.gauge.level / math.max(1, state.gauge.max))
		end
		if state.ride then
			local mounted = line()
			ui.components.label(theme, {
				text = M.text(ctx.locale, "tame_mounted", M.species(ctx.locale, state.ride.species)),
				size = UDim2.fromScale(0.62, 1),
				parent = mounted,
			})
			local dismount = ui.components.button(theme, {
				text = M.text(ctx.locale, "tame_dismount"),
				size = UDim2.fromScale(0.36, 1),
				position = UDim2.fromScale(0.64, 0),
				parent = mounted,
				onClick = function()
					send(DISMOUNT, {})
				end,
			})
			dismount.Name = "Dismount"
		end
		if #state.animals == 0 then
			ui.components.label(
				theme,
				{ text = M.text(ctx.locale, "tame_empty"), size = UDim2.new(1, 0, 0, 48), parent = line() }
			)
		end
		for _, animal in state.animals do
			local frame = line()
			local label = ui.components.label(theme, {
				text = M.species(ctx.locale, animal.species) .. "  " .. M.pen(ctx.locale, animal.remainingMillis),
				size = UDim2.fromScale(0.5, 1),
				parent = frame,
			})
			table.insert(timers, { label = label, remaining = animal.remainingMillis, species = animal.species } :: any)
			local feedButton = ui.components.button(theme, {
				text = M.text(ctx.locale, "tame_feed"),
				size = UDim2.fromScale(0.23, 1),
				position = UDim2.fromScale(0.51, 0),
				parent = frame,
				onClick = function()
					feed(animal.id, state.feeds)
				end,
			})
			feedButton.Name = "Feed-" .. animal.id
			local mountButton = ui.components.button(theme, {
				text = M.text(ctx.locale, "tame_mount"),
				size = UDim2.fromScale(0.23, 1),
				position = UDim2.fromScale(0.76, 0),
				parent = frame,
				onClick = function()
					send(MOUNT, { animal.id })
				end,
			})
			mountButton.Name = "Mount-" .. animal.id
		end
	end
	-- World prompts -------------------------------------------------------------------------
	-- One client-local ProximityPrompt per tameable wild model. The server decides reach,
	-- cooldown, gauge and capture; the prompt only picks hit vs capture from the last gauge it
	-- saw (a hit result or the snapshot) and shows the outcome.
	local tameable: { [string]: boolean } = {}
	local reach = DEFAULT_REACH
	local gauge: Gauge? = nil
	local busy = false
	local prompts: { [Model]: { prompt: ProximityPrompt, connections: { RBXScriptConnection } } } = {}
	local function wildOf(model: Model): (string?, string?)
		local id, kind = model:GetAttribute("ForgeWildlifeId"), model:GetAttribute("ForgeWildlifeKind")
		return if type(id) == "string" then id else nil, if type(kind) == "string" then kind else nil
	end
	local function update(model: Model)
		local entry = prompts[model]
		if not entry then
			return
		end
		local id, kind = wildOf(model)
		local health = model:GetAttribute("ForgeWildlifeHealthMilli")
		local alive_ = health == nil or (type(health) == "number" and health > 0)
		local prompt = entry.prompt
		prompt.Enabled = id ~= nil and kind ~= nil and tameable[kind] == true and alive_
		prompt.MaxActivationDistance = reach
		if id then
			local _, text = M.promptAction(ctx.locale, gauge, id)
			prompt.ActionText = text
		end
		if kind and prompt.ObjectText == "" then
			prompt.ObjectText = M.species(ctx.locale, kind)
		end
	end
	local function updateAll()
		for model in prompts do
			update(model)
		end
	end
	local function trigger(model: Model)
		local id, kind = wildOf(model)
		if busy or not id or not kind or not tameable[kind] then
			return
		end
		busy = true
		local action = M.promptAction(ctx.locale, gauge, id)
		local ok, result = pcall(ctx.send, action, { id })
		busy = false
		if not ok then
			result = { ok = false, reason = "TRANSPORT_FAILED" }
		end
		local message = M.outcome(ctx.locale, action, result, kind)
		status.Text = message
		local data = if type(result.data) == "table" then result.data else {}
		if action == HIT and result.ok and type(data.level) == "number" then
			gauge = { wildId = id, level = data.level, max = data.max or data.level, full = data.full }
		elseif action == CAPTURE and (result.reason == "GAUGE_NOT_FULL" or (result.ok and data.captured)) then
			gauge = nil
		end
		local entry = prompts[model]
		if entry then
			entry.prompt.ObjectText = if message ~= "" then message else M.species(ctx.locale, kind)
		end
		updateAll()
		if action == CAPTURE and result.ok and data.captured then
			gui.Enabled = true
		end
	end
	local function attach(child: Instance)
		if not child:IsA("Model") or prompts[child] then
			return
		end
		local model = child :: Model
		local root = model:WaitForChild("HumanoidRootPart", 10)
		if not root or not root:IsA("BasePart") or prompts[model] or model.Parent == nil then
			return
		end
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = PROMPT_NAME
		prompt.KeyboardKeyCode, prompt.GamepadKeyCode = Enum.KeyCode.E, Enum.KeyCode.ButtonY
		prompt.HoldDuration, prompt.ClickablePrompt, prompt.RequiresLineOfSight = 0, true, false
		prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
		prompt.ObjectText, prompt.Enabled = "", false
		prompts[model] = {
			prompt = prompt,
			connections = {
				prompt.Triggered:Connect(function()
					trigger(model)
				end),
				model.AttributeChanged:Connect(function(name)
					if
						name == "ForgeWildlifeId"
						or name == "ForgeWildlifeKind"
						or name == "ForgeWildlifeHealthMilli"
					then
						update(model)
					end
				end),
			},
		}
		prompt.Parent = root
		update(model)
	end
	local function detach(child: Instance)
		local entry = prompts[child :: Model]
		if not entry then
			return
		end
		prompts[child :: Model] = nil
		for _, connection in entry.connections do
			connection:Disconnect()
		end
		entry.prompt:Destroy()
	end
	local alive = true
	local folderConnections: { RBXScriptConnection } = {}
	task.spawn(function()
		-- The wildlife folder is created when the server world binds, possibly after this panel.
		local folder = workspace:WaitForChild("ForgeWildlife", math.huge)
		if not alive or not folder then
			return
		end
		table.insert(
			folderConnections,
			folder.ChildAdded:Connect(function(child)
				task.spawn(attach, child)
			end)
		)
		table.insert(folderConnections, folder.ChildRemoved:Connect(detach))
		for _, child in folder:GetChildren() do
			task.spawn(attach, child)
		end
	end)
	local unsubscribe = ctx.onSnapshot(function(snapshot: { [string]: any })
		local state = snapshot.taming
		if type(state) == "table" then
			table.clear(tameable)
			for _, species in (if type(state.tameable) == "table" then state.tameable else {}) :: { string } do
				tameable[species] = true
			end
			reach = if type(state.reachStuds) == "number" then state.reachStuds else DEFAULT_REACH
			if type(state.gauge) == "table" then
				gauge = state.gauge
			end
			updateAll()
		end
		render(snapshot)
	end)
	task.spawn(function()
		while alive do
			task.wait(1)
			local elapsed = (os.clock() - received) * 1000
			if lastCompanions then
				local _, list = M.companions(ctx.locale, lastCompanions, ctx.content, serverMillis())
				for _, row in list do
					local detail = companionDetails[row.id]
					if detail then
						detail.Text = row.detail
					end
				end
			end
			for _, timer in timers do
				local entry: any = timer
				entry.label.Text = M.species(ctx.locale, entry.species)
					.. "  "
					.. M.pen(ctx.locale, entry.remaining - elapsed)
			end
		end
	end)
	local input = game:GetService("UserInputService")
	local keyConnection = input.InputBegan:Connect(function(event, processed)
		if not processed and event.KeyCode == Enum.KeyCode.T then
			gui.Enabled = not gui.Enabled
		end
	end)
	return {
		destroy = function()
			alive = false
			keyConnection:Disconnect()
			unsubscribe()
			for _, connection in folderConnections do
				connection:Disconnect()
			end
			for model in prompts do
				detach(model)
			end
			gui:Destroy()
		end,
	}
end

return M
