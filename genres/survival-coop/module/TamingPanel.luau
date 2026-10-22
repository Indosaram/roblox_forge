--!strict
-- Client taming panel: pen list (species, ready time, feed button) plus mount/dismount buttons,
-- rendered from snapshot.survivalExtensions.taming. The server owns every decision (ready time,
-- feed value, ride speed and carry); this panel only sends durable commands and renders results.
-- Strings mirror games/robango-island/locale/strings.csv keys (tame_*); species names are the
-- pack's wildlife_<id> strings, with the raw id as fallback.
-- World input: every wild model under Workspace.ForgeWildlife whose ForgeWildlifeKind is in
-- snapshot.taming.tameable gets a client-local ProximityPrompt (Q / click / tap) that sends
-- tame-hit until the stun gauge for that wild id is full, then tame-capture.
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

local strings: { [string]: { string } } = {
	companion_place = { "Place in pen", "우리에 놓기" },
	companion_train = { "Begin taming", "조련 시작" },
	companion_feed = { "Feed", "먹이 주기" },
	companion_claim = { "Claim", "조련 완료" },
	companion_cancel = { "Cancel", "취소" },
	companion_deploy = { "Deploy", "소환" },
	companion_recall = { "Recall", "보관" },
	companion_saddle = { "Equip saddle", "안장 장착" },
	companion_mount = { "Mount", "타기" },
	companion_dismount = { "Dismount", "내리기" },
	companion_release = { "Release", "놓아주기" },
	companion_recover = { "Recover", "회복" },
	tame_title = { "Tamed animals", "길들인 동물" },
	tame_empty = {
		"No tamed animals yet. Stun a wild animal, then capture it with a bola.",
		"길들인 동물이 아직 없어요. 야생 동물을 기절시킨 뒤 볼라로 붙잡으세요.",
	},
	tame_ready = { "Ready", "준비 완료" },
	tame_remaining = { "Ready in %s", "%s 후 준비" },
	tame_feed = { "Feed", "먹이 주기" },
	tame_mount = { "Mount", "타기" },
	tame_dismount = { "Dismount", "내리기" },
	tame_mounted = { "Riding %s", "%s 탑승 중" },
	tame_gauge = { "Stun gauge: %s", "기절 게이지: %s" },
	tame_failed = { "That did not work. Try again.", "잘 안 됐어요. 다시 시도하세요." },
	tame_pending = {
		"Saving... try the same action again.",
		"저장 중이에요. 같은 동작을 다시 시도하세요.",
	},
	tame_stun = { "Stun", "기절시키기" },
	tame_capture = { "Capture", "포획하기" },
	tame_no_tool = { "Craft a Hobble Bola first", "속박 볼라를 먼저 만드세요" },
	tame_not_full = {
		"Not stunned enough yet. Keep stunning it.",
		"아직 덜 기절했어요. 계속 기절시키세요.",
	},
	tame_too_far = { "Too far away. Get closer.", "너무 멀어요. 더 가까이 가세요." },
	tame_escaped = { "It broke free! Try again.", "빠져나갔어요! 다시 시도하세요." },
	tame_gone = { "That animal is not here anymore.", "그 동물은 이제 여기 없어요." },
	tame_captured = { "Captured %s! It is in your pen.", "%s 포획! 우리에 들어갔어요." },
	wildlife_ridge_strider = { "Ridge Strider", "능선걸음이" },
	wildlife_fen_trotter = { "Fen Trotter", "늪종종이" },
	wildlife_bluff_bounder = { "Bluff Bounder", "벼랑깡충이" },
	wildlife_compsognathus = { "Compsognathus", "콤프소그나투스" },
	wildlife_oviraptor = { "Oviraptor", "오비랍토르" },
	wildlife_protoceratops = { "Protoceratops", "프로토케라톱스" },
	wildlife_gallimimus = { "Gallimimus", "갈리미무스" },
	wildlife_parasaurolophus = { "Parasaurolophus", "파라사우롤로푸스" },
	wildlife_stegosaurus = { "Stegosaurus", "스테고사우루스" },
	wildlife_ankylosaurus = { "Ankylosaurus", "안킬로사우루스" },
	wildlife_triceratops = { "Triceratops", "트리케라톱스" },
	wildlife_brachiosaurus = { "Brachiosaurus", "브라키오사우루스" },
	wildlife_utahraptor = { "Utahraptor", "유타랍토르" },
	wildlife_velociraptor = { "Velociraptor", "벨로키랍토르" },
	wildlife_dilophosaurus = { "Dilophosaurus", "딜로포사우루스" },
	wildlife_allosaurus = { "Allosaurus", "알로사우루스" },
	wildlife_tyrannosaurus = { "Tyrannosaurus", "티라노사우루스" },
	wildlife_smilodon = { "Smilodon", "스밀로돈" },
	wildlife_tropicalSmilodon = { "Tropical Smilodon", "열대 스밀로돈" },
	wildlife_direWolf = { "Dire Wolf", "다이어울프" },
	wildlife_mammoth = { "Mammoth", "매머드" },
	wildlife_deer = { "Deer", "사슴" },
	wildlife_elephant = { "Elephant", "코끼리" },
	wildlife_crocodile = { "Crocodile", "악어" },
	wildlife_turtle = { "Turtle", "거북" },
	wildlife_dodo = { "Dodo", "도도" },
	wildlife_boar = { "Boar", "멧돼지" },
	wildlife_grazer = { "Meadow Plodder", "풀밭느림보" },
	wildlife_hunter = { "Brush Stalker", "덤불살금이" },
	wildlife_leaper_fernhop = { "Fernhopper", "고사리뜀이" },
	wildlife_leaper_reedvault = { "Reed Vaulter", "갈대도약이" },
	wildlife_charger_oakbrow = { "Oakbrow Rammer", "참나무이마박치기" },
	wildlife_charger_mudbrow = { "Mudbrow Rammer", "진흙이마박치기" },
	wildlife_tailswing_mossback = { "Mossback Swinger", "이끼등꼬리채" },
	wildlife_tailswing_shellclub = { "Shellclub Swinger", "조가비곤봉꼬리" },
	wildlife_roarer_thicket = { "Thicket Bellower", "덤불울림이" },
	wildlife_roarer_tidecall = { "Tidecall Bellower", "물때울림이" },
	wildlife_scavenger_barkpicker = { "Barkpicker", "껍질뒤짐이" },
	wildlife_scavenger_flotsam = { "Flotsam Sniffer", "표류물킁킁이" },
	wildlife_herd_acorncrest = { "Acorncrest Grazer", "도토리볏풀뜯이" },
	wildlife_herd_sedgewader = { "Sedge Wader", "사초건너미" },
}

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
	local entry = strings["wildlife_" .. string.gsub(species, "%-", "_")]
	return if entry then pick(locale, entry) else species
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
		if type(state) ~= "table" then
			return
		end
		if state.companions then
			local order = 0
			for id, pet in state.companions.pets do
				order += 1
				local frame = Instance.new("Frame")
				frame.Name, frame.BackgroundTransparency, frame.Size, frame.Parent =
					"Companion-" .. id, 1, UDim2.new(1, 0, 0, 160), rows
				frame.LayoutOrder = order
				ui.components.label(
					theme,
					{ text = pet.species .. " / " .. pet.phase, size = UDim2.new(1, 0, 0, 32), parent = frame }
				)
				local actions = if pet.phase == "Captured"
					then { "place" }
					elseif pet.phase == "PenPlaced" then { "train" }
					elseif pet.phase == "Taming" then { "feed", "claim", "cancel" }
					elseif pet.phase == "Stored" then { "deploy", "saddle", "release:" .. id }
					elseif pet.phase == "Deployed" then { "feed", "recall", "mount", "dismount" }
					else { "recover", "feed" }
				for index, verb in ipairs(actions) do
					local control = ui.components.button(theme, {
						text = M.text(
							ctx.locale,
							"companion_" .. (if string.sub(verb, 1, 8) == "release:" then "release" else verb)
						),
						size = UDim2.new(0.5, -4, 0, 48),
						position = UDim2.new((index - 1) % 2 / 2, 0, 0, 36 + math.floor((index - 1) / 2) * 52),
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
