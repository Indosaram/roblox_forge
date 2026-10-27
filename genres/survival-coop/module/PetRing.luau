--!strict
-- C4 (G13) capture, pet ring and riding presentation over the V2 companion commands. The server
-- owns every decision (PersonalCompanionExtension + CombatCompanion): this module only picks what
-- to offer, lays it out (ui-spec "shell fan": pebbles on an open arc above the target, 40 degrees
-- apart) and shows the outcome. No randomness and no clock reads in the pure part.
local PackLocale = require("./PackLocale")
local WildlifeNames = require("./WildlifeNames")
local HudShell = require("./HudShell")
local TamingPanel = require("./TamingPanel")
local M = {}

local PREFIX = "survival-coop:"
M.COMPANION = PREFIX .. "companion-action"
M.HIT, M.CAPTURE = PREFIX .. "tame-hit", PREFIX .. "tame-capture"
-- ui-spec section 3: arc radius 0.22H, 40 degrees per token, at most 200 degrees (6 tokens).
M.ARC_RADIUS, M.ARC_STEP, M.MAX_TOKENS = 0.22, 40, 6
-- A downed (stunnable) target: health at or under this share of the species maximum (the V2
-- SUBDUE_GATED rule, 25%).
M.DOWNED_SHARE = 0.25

local strings: { [string]: { string } } = PackLocale.rows({}, { "pet." })

local function pick(locale: string, entry: { string }): string
	return if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
end

--- Pure text lookup; falls back to the key.
function M.text(locale: string, key: string): string
	local entry = strings[key]
	return if entry then pick(locale, entry) else key
end

export type Token = { id: string, verb: string, label: string }

--- The verbs a deployed (or ridden) pet offers, in ring order: ride or saddle (rideable only),
--- follow/stay, feed, rename, send home, release. `rideable` comes from the species catalog.
function M.verbs(locale: string, pet: any, riding: boolean, rideable: boolean): { Token }
	local out: { Token } = {}
	local function add(id: string, verb: string)
		table.insert(out, { id = id, verb = verb, label = M.text(locale, id) })
	end
	if riding then
		add("dismount", "dismount")
	elseif rideable then
		if pet.saddle then
			add("ride", "mount")
		else
			add("saddle", "saddle")
		end
	end
	if not riding then
		add(if pet.stay then "follow" else "stay", if pet.stay then "follow" else "stay")
	end
	add("feed", "feed")
	add("rename", "rename")
	if not riding then
		add("recall", "recall")
		add("release", "release:" .. pet.id)
	end
	while #out > M.MAX_TOKENS do
		table.remove(out)
	end
	return out
end

--- Token centres for `count` tokens on the open arc above (cx, cy): centred straight up, 40
--- degrees apart, radius 0.22 of the safe height. Screen y grows downward.
function M.arc(count: number, cx: number, cy: number, safeHeight: number): { { x: number, y: number } }
	local radius = M.ARC_RADIUS * safeHeight
	local out = {}
	for index = 1, count do
		local degrees = 90 + ((count + 1) / 2 - index) * M.ARC_STEP
		local a = math.rad(degrees)
		table.insert(out, { x = cx + radius * math.cos(a), y = cy - radius * math.sin(a) })
	end
	return out
end

--- Species row by id from pack content.
function M.species(content: any, id: string): any?
	for _, row in (content and content.wildlifeDetails) or {} do
		if row.id == id then
			return row
		end
	end
	return nil
end

--- Whether a wild animal is downed enough to capture: tameable, alive and at or under a quarter of
--- its species health (healthMilli is the server-published value).
function M.downed(content: any, tameable: { [string]: boolean }, kind: string, healthMilli: number?): boolean
	local row = M.species(content, kind)
	if not row or not tameable[kind] or row.captureClass == "never" or type(healthMilli) ~= "number" then
		return false
	end
	return healthMilli > 0 and healthMilli <= row.health * 1000 * M.DOWNED_SHARE
end

export type Card = { success: boolean, title: string, lines: { string } }

--- Capture-result card: species, level and whether it can be ridden on success; the reason and a
--- retry hint on failure. `result` is the tame-capture result (refusals included).
function M.card(locale: string, content: any, result: any, kind: string): Card
	local captured = type(result) == "table"
		and result.ok == true
		and type(result.data) == "table"
		and result.data.captured == true
	local name = WildlifeNames.name(locale, kind)
	if captured then
		local row = M.species(content, kind)
		local lines = { name }
		if row then
			table.insert(lines, string.format(M.text(locale, "card_level"), row.level or 1))
			local rideable = row.mount ~= nil and row.mount.enabled == true
			table.insert(lines, M.text(locale, if rideable then "card_ride_yes" else "card_ride_no"))
		end
		table.insert(lines, M.text(locale, "card_next"))
		return { success = true, title = M.text(locale, "card_success"), lines = lines }
	end
	local reason = if type(result) == "table" and result.ok == true then nil else M.refusal(locale, result)
	return {
		success = false,
		title = M.text(locale, "card_fail"),
		lines = { name, reason or M.text(locale, "card_fail_hint") },
	}
end

local OWN_REFUSALS: { [string]: string } = {
	NOT_RIDEABLE = "refusal_not_rideable",
	PET_ABSENT = "refusal_absent",
	INVALID_NAME = "refusal_name",
	NAME_REJECTED = "refusal_name",
	NAME_FILTER_UNAVAILABLE = "refusal_name",
	MOUNTED = "refusal_mounted",
	MOUNT_GATED = "refusal_mount_gated",
	NO_SADDLE = "refusal_no_saddle",
	NO_FEED = "refusal_no_feed",
	RELEASE_CARGO_OR_INJURY = "refusal_release",
}

--- Message for a refused pet or capture command ("" on success).
function M.refusal(locale: string, result: any): string
	if type(result) ~= "table" or result.ok then
		return ""
	end
	local key = if result.reason then OWN_REFUSALS[result.reason] else nil
	return if key then M.text(locale, key) else TamingPanel.refusal(locale, result)
end

--- Engine side. `ctx` is the ExtensionPanels context (send, onSnapshot, locale, content, open).
--- Returns the panel handle plus the hooks the HUD shell and tap router use.
function M.factory(ctx: any): any
	local players = game:GetService("Players")
	local run = game:GetService("RunService")
	local player = players.LocalPlayer
	local P = HudShell.PALETTE
	local function color(c: any): Color3
		return Color3.fromRGB(c.r, c.g, c.b)
	end
	local locale = ctx.locale
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "ForgePetRing", false, 14
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.Parent = player:WaitForChild("PlayerGui")
	local taming: any = nil
	local tameable: { [string]: boolean } = {}
	local unsubscribe = ctx.onSnapshot(function(snapshot: any)
		taming = if type(snapshot.taming) == "table" then snapshot.taming else nil
		table.clear(tameable)
		for _, id in (if taming and type(taming.tameable) == "table" then taming.tameable else {}) :: { string } do
			tameable[id] = true
		end
	end)
	local function textLabel(name: string, parent: Instance, size: UDim2): TextLabel
		local label = Instance.new("TextLabel")
		label.Name, label.Size, label.BackgroundTransparency = name, size, 1
		label.TextColor3, label.Font, label.TextWrapped = color(P.bone), Enum.Font.BuilderSans, true
		label.Parent = parent
		return label
	end

	-- Ring ---------------------------------------------------------------------------------------
	local ring = Instance.new("Frame")
	ring.Name, ring.BackgroundTransparency, ring.Size, ring.Visible = "Ring", 1, UDim2.fromScale(1, 1), false
	ring.Parent = gui
	local namePill = textLabel("PetName", ring, UDim2.fromOffset(180, 26))
	namePill.AnchorPoint, namePill.BackgroundTransparency = Vector2.new(0.5, 0), 0.3
	namePill.BackgroundColor3 = color(P.ink)
	local status = textLabel("PetStatus", ring, UDim2.fromOffset(260, 22))
	status.AnchorPoint = Vector2.new(0.5, 0)
	local renameBox = Instance.new("TextBox")
	renameBox.Name, renameBox.Size, renameBox.Visible = "PetRename", UDim2.fromOffset(200, 34), false
	renameBox.AnchorPoint, renameBox.ClearTextOnFocus = Vector2.new(0.5, 0), true
	renameBox.BackgroundColor3, renameBox.TextColor3 = color(P.panel), color(P.bone)
	renameBox.PlaceholderText = M.text(locale, "rename_hint")
	renameBox.Parent = ring
	local open: { model: Model, petId: string, riding: boolean }? = nil
	local buttons: { TextButton } = {}
	local function close()
		open = nil
		ring.Visible = false
		renameBox.Visible = false
	end
	local function petState(petId: string): any?
		local companions = if taming then taming.companions else nil
		return if type(companions) == "table" and type(companions.pets) == "table" then companions.pets[petId] else nil
	end
	local function send(action: string, args: { any }): any
		local ok, result = pcall(ctx.send, action, args)
		if not ok then
			result = { ok = false, reason = "TRANSPORT_FAILED" }
		end
		status.Text = M.refusal(locale, result)
		return result
	end
	local function build()
		for _, button in buttons do
			button:Destroy()
		end
		table.clear(buttons)
		local current = open
		local pet = if current then petState(current.petId) else nil
		if not current or not pet then
			close()
			return
		end
		local row = M.species(ctx.content, pet.species)
		local rideable = row ~= nil and row.mount ~= nil and row.mount.enabled == true
		namePill.Text = if type(pet.name) == "string" and pet.name ~= ""
			then pet.name
			else WildlifeNames.name(locale, pet.species)
		for _, token in M.verbs(locale, pet, current.riding, rideable) do
			local button = Instance.new("TextButton")
			button.Name, button.Text, button.TextWrapped = "Pet-" .. token.id, token.label, true
			button.Parent = ring
			HudShell.pebble(button, token.id == "ride" or token.id == "dismount", true)
			button.Activated:Connect(function()
				if token.id == "rename" then
					renameBox.Visible = true
					renameBox:CaptureFocus()
					return
				end
				local result = send(M.COMPANION, { token.verb, current.petId })
				if result.ok and (token.id == "recall" or token.id == "release" or token.id == "ride") then
					close()
				end
			end)
			table.insert(buttons, button)
		end
		ring.Visible = true
	end
	renameBox.FocusLost:Connect(function(enter: boolean)
		local current = open
		renameBox.Visible = false
		if enter and current and renameBox.Text ~= "" then
			send(M.COMPANION, { "rename:" .. renameBox.Text, current.petId })
		end
	end)
	local function anchorOf(model: Model): BasePart?
		local part = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("MountRoot")
		return if part and part:IsA("BasePart") then part else nil
	end
	local follow = run.RenderStepped:Connect(function()
		local current = open
		if not current then
			return
		end
		local anchor = anchorOf(current.model)
		local camera = workspace.CurrentCamera
		if not anchor or not camera or not current.model:IsDescendantOf(workspace) then
			close()
			return
		end
		local point, visible = camera:WorldToViewportPoint(anchor.Position)
		local inset = gui.AbsolutePosition
		local cx, cy = point.X - inset.X, point.Y - inset.Y
		local h = gui.AbsoluteSize.Y
		local size = HudShell.tokenSize("M", h, true)
		local spots = M.arc(#buttons, cx, cy, h)
		for index, button in buttons do
			local spot = spots[index]
			button.Visible = visible
			button.Size = UDim2.fromOffset(size, math.floor(size * HudShell.PEBBLE.aspect))
			button.Position = UDim2.fromOffset(spot.x - size / 2, spot.y - size / 2)
			button.TextSize = HudShell.tokenText("caption", h, true)
		end
		namePill.Position = UDim2.fromOffset(cx, cy + size * 0.6)
		status.Position = UDim2.fromOffset(cx, cy + size * 0.6 + 28)
		renameBox.Position = UDim2.fromOffset(cx, cy - M.ARC_RADIUS * h - size)
	end)

	-- Capture -----------------------------------------------------------------------------------
	local card = Instance.new("Frame")
	card.Name, card.Visible, card.AnchorPoint = "CaptureCard", false, Vector2.new(0.5, 0.5)
	card.Position, card.Size = UDim2.fromScale(0.5, 0.42), UDim2.fromOffset(300, 176)
	card.BackgroundColor3, card.BackgroundTransparency = color(P.panel), 0.06
	card.Parent = gui
	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius, cardCorner.Parent = UDim.new(0, 14), card
	local cardRim = Instance.new("UIStroke")
	cardRim.Color, cardRim.Thickness, cardRim.Parent = color(P.drift), 3, card
	local cardTitle = textLabel("CardTitle", card, UDim2.new(1, -24, 0, 34))
	cardTitle.Position, cardTitle.TextSize, cardTitle.Font = UDim2.fromOffset(12, 8), 22, Enum.Font.BuilderSansBold
	local cardBody = textLabel("CardBody", card, UDim2.new(1, -24, 0, 80))
	cardBody.Position, cardBody.TextSize = UDim2.fromOffset(12, 44), 15
	cardBody.TextYAlignment = Enum.TextYAlignment.Top
	local progress = Instance.new("Frame")
	progress.Name, progress.Position, progress.Size =
		"CaptureProgress", UDim2.fromOffset(12, 128), UDim2.fromOffset(0, 6)
	progress.BackgroundColor3, progress.BorderSizePixel, progress.Parent = color(P.teal), 0, card
	local cardButton = Instance.new("TextButton")
	cardButton.Name, cardButton.Text = "CardList", M.text(locale, "card_list")
	cardButton.Position, cardButton.Size = UDim2.new(0.5, -70, 1, -44), UDim2.fromOffset(140, 36)
	cardButton.Parent = card
	HudShell.pebble(cardButton, true, true)
	cardButton.Activated:Connect(function()
		card.Visible = false
		if ctx.open then
			ctx.open("taming")
		end
	end)
	local cardSerial = 0
	local function showCard(title: string, lines: { string }, success: boolean?, busy: boolean)
		cardSerial += 1
		local mine = cardSerial
		cardTitle.Text = title
		cardTitle.TextColor3 = color(if success == true then P.moss elseif success == false then P.coral else P.bone)
		cardBody.Text = table.concat(lines, "\n")
		cardButton.Visible = success == true
		progress.Visible = busy
		progress.Size = UDim2.fromOffset(0, 6)
		card.Visible = true
		if not busy then
			task.delay(6, function()
				if mine == cardSerial then
					card.Visible = false
				end
			end)
		end
		return mine
	end
	local function target(): Model?
		local folder = workspace:FindFirstChild("ForgeWildlife")
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local rules = ctx.content and ctx.content.progressionPolicy and ctx.content.progressionPolicy.companion
		if not folder or not root or not root:IsA("BasePart") or not rules or (taming and taming.ride) then
			return nil
		end
		local best, distance = nil, rules.stunRange
		for _, model in folder:GetChildren() do
			local kind = model:GetAttribute("ForgeWildlifeKind")
			local anchor = model:FindFirstChild("HumanoidRootPart")
			if
				model:IsA("Model")
				and type(kind) == "string"
				and anchor
				and anchor:IsA("BasePart")
				and M.downed(ctx.content, tameable, kind, model:GetAttribute("ForgeWildlifeHealthMilli"))
			then
				local d = (anchor.Position - root.Position).Magnitude
				if d <= distance then
					best, distance = model, d
				end
			end
		end
		return best
	end
	local capturing = false
	local function capture()
		local model = target()
		local id = if model then model:GetAttribute("ForgeWildlifeId") else nil
		local kind = if model then model:GetAttribute("ForgeWildlifeKind") else nil
		if capturing or type(id) ~= "string" or type(kind) ~= "string" then
			return
		end
		capturing = true
		local name = WildlifeNames.name(locale, kind)
		local mine = showCard(M.text(locale, "capturing"), { name }, nil, true)
		local tween = game:GetService("TweenService")
			:Create(progress, TweenInfo.new(0.6, Enum.EasingStyle.Quad), { Size = UDim2.new(1, -24, 0, 6) })
		tween:Play()
		-- Stun with the club, then throw the rope inside the stun window; the server rolls the
		-- capture from its recorded seed and answers with the outcome.
		local ok, stunned = pcall(ctx.send, M.HIT, { id })
		local result = stunned
		-- RECOVERY: the club is still recovering from a stun that may still hold; throw anyway.
		if ok and type(stunned) == "table" and (stunned.ok or stunned.reason == "RECOVERY") then
			ok, result = pcall(ctx.send, M.CAPTURE, { id })
		end
		if not ok then
			result = { ok = false, reason = "TRANSPORT_FAILED" }
		end
		capturing = false
		if mine ~= cardSerial then
			return
		end
		local view = M.card(locale, ctx.content, result, kind)
		showCard(view.title, view.lines, view.success, false)
	end

	local handle = {}
	function handle.capturable(): boolean
		return not capturing and target() ~= nil
	end
	--- Opens the ring on one of the player's own pet bodies (or the ridden mount).
	function handle.openOn(model: Model): boolean
		local mine = tostring(player.UserId)
		local petId = model:GetAttribute("ForgePetId")
		local riding = false
		if model:GetAttribute("ForgePetOwner") ~= mine then
			local ride = if taming then taming.ride else nil
			if not (model:GetAttribute("ForgeMountSpecies") and model.Parent == player.Character and ride) then
				return false
			end
			petId, riding = ride.id, true
		end
		if type(petId) ~= "string" or not petState(petId) then
			return false
		end
		open = { model = model, petId = petId, riding = riding }
		status.Text = ""
		build()
		return true
	end
	function handle.act(id: string)
		if id == "capture" then
			task.spawn(capture)
		elseif id == "dismount" then
			local ride = if taming then taming.ride else nil
			if ride and type(ride.id) == "string" then
				task.spawn(send, M.COMPANION, { "dismount", ride.id })
			end
		elseif id == "pet" then
			local character = player.Character
			local mount = character and character:FindFirstChild("ForgeMount")
			if mount and mount:IsA("Model") then
				handle.openOn(mount)
			end
		end
	end
	handle.close = close
	local rebuild = ctx.onSnapshot(function()
		if open then
			build()
		end
	end)
	function handle.destroy()
		unsubscribe()
		rebuild()
		follow:Disconnect()
		gui:Destroy()
	end
	return handle
end

return M
