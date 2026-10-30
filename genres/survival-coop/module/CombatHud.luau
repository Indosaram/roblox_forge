--!strict
-- Combat presentation (Robango plan C3, G12; ui-spec "Tideglass"). A tapped creature becomes the
-- target and the character attacks it semi-automatically: approach to reach, swing, wait, swing
-- again until it falls, the player steps back, or the server refuses for good. Around that: a
-- target bar (name, Lv, HP), the end-combat pill ("Step back"), floating damage numbers, a coral
-- corner vignette that deepens at low health, a short dodge hop, and on a kill the carcass fan
-- (CarcassExtension outputs: meat, hide, bone ...). The client is presentation only: every swing
-- and every carcass take is a durable command the server validates (range, cooldown, death,
-- killer, reach); a refusal only steers what the client shows or tries next.
--
-- Pure helpers first (Lune specs); the Roblox runtime follows (M.start). One module on purpose:
-- the pack's QA-PERF-01 static budget counts every shipped ModuleScript.
local PackLocale = require("./PackLocale")
local HudShell = require("./HudShell")

local M = {}

-- Copy: the cmb.* rows of the pack's Strings table (KO/EN), read through PackLocale.
local strings: { [string]: { string } } = PackLocale.rows({}, { "cmb." })
function M.text(locale: string, key: string): string
	local entry = strings[key]
	return if entry then entry[if string.sub(locale, 1, 2) == "ko" then 2 else 1] else key
end
--- Player copy for a server refusal; a reason without its own row reads as the generic line.
function M.refusal(locale: string, reason: string): string
	return M.text(locale, if strings["refused." .. reason] then "refused." .. reason else "refused")
end

--- Player copy for a refused swing, or nil for a refusal the loop handles by itself (cooldown,
--- windup, busy, out of range). D2b R08: every swing was refused WEAPON_UNAVAILABLE and the player
--- saw nothing at all.
function M.attackRefusal(locale: string, reason: any): string?
	if type(reason) ~= "string" or not (M.FINAL[reason] or reason == "BLOCKED" or reason == "NOT_FACING") then
		return nil
	end
	return M.text(locale, if strings["attack." .. reason] then "attack." .. reason else "attack")
end

-- Studs (flat) to stop the approach at. The server measures melee reach centre to centre in 3D and
-- the starter rule reaches 5, so the old 6-stud stop could leave every swing OUT_OF_RANGE.
M.REACH = 4
M.MIN_REACH = 1.5 -- an OUT_OF_RANGE refusal closes in by REACH_STEP down to this
M.REACH_STEP = 1
M.DRIFT = 3 -- studs the target may move from the approach goal before the walk is re-aimed
M.SWING_SECONDS = 0.9 -- pause after a confirmed swing before the next
M.BACKOFF_SECONDS = 0.4 -- pause after a transient refusal (cooldown, windup, busy)
M.APPROACH_SECONDS = 4 -- an approach that has not arrived by then is retried
M.LOW_HEALTH = 0.35 -- health fraction under which the vignette deepens
M.COMBAT_GLOW = 0.12 -- corner glow opacity while a target is engaged
M.MAX_GLOW = 0.6
M.FAN_STEP = 40 -- degrees between carcass tokens (ui-spec section 3 shell fan)
M.FAN_SPAN = 200
-- Seconds a body can be harvested after the kill (CarcassExtension.LIFETIME_SECONDS; a spec pins
-- the two together) and the flat studs the walk stops at (the server reaches 10 in 3D).
M.CARCASS_SECONDS = 300
M.HARVEST_REACH = 5
M.TOAST_SECONDS = 4

-- Refusals that end the auto loop (the target is gone, or nothing the player does here fixes it).
M.FINAL = table.freeze({
	ALREADY_DEAD = true,
	ALREADY_CAPTURED = true,
	UNKNOWN_TARGET = true,
	NOT_ALIVE = true,
	WEAPON_UNAVAILABLE = true,
	MOUNTED = true,
	UNAUTHORIZED = true,
	INVALID_MODE = true,
}) :: { [string]: boolean }
-- Refusals that mean "get closer / line up" before swinging again.
M.REPOSITION = table.freeze({ OUT_OF_RANGE = true, NOT_FACING = true, BLOCKED = true }) :: { [string]: boolean }

export type Session = {
	target: string,
	auto: boolean,
	nextAt: number,
	inFlight: boolean,
	approachUntil: number?,
	reason: string?,
	-- Current approach stop distance (flat studs); shrinks on OUT_OF_RANGE.
	reach: number?,
	-- A Backpack tool was taken up after a WEAPON_UNAVAILABLE refusal (tried once per target).
	armed: boolean?,
}

--- Engages `target` at `now`. Re-tapping the same target keeps its pacing.
function M.engage(session: Session?, target: string, now: number): Session
	if session and session.target == target then
		local same = table.clone(session)
		same.auto = true
		same.reason = nil
		return same
	end
	return {
		target = target,
		auto = true,
		nextAt = now,
		inFlight = false,
		approachUntil = nil,
		reason = nil,
		reach = M.REACH,
	}
end

--- What the loop does this frame: "swing", "approach", "wait" or "idle".
function M.step(session: Session?, now: number, alive: boolean, distance: number?): string
	if not session or not session.auto or not alive or distance == nil then
		return "idle"
	end
	if session.inFlight or now < session.nextAt then
		return "wait"
	end
	if distance > (session.reach or M.REACH) then
		return if session.approachUntil and now < session.approachUntil then "wait" else "approach"
	end
	return "swing"
end

-- Flat studs from the character to the engaged target beyond which a paused engagement ends.
M.RELEASE_STUDS = 40

--- Backpack Tool to raise for a melee swing (first by name, melee weapon-tool), or nil.
function M.pickWeapon(content: any, children: { any }): any
	local melee: { [string]: boolean } = {}
	for _, item in (content and content.items) or {} do
		if table.find(item.tags or {}, "weapon-tool") then
			melee[item.id] = true
		end
	end
	for _, row in (content and content.brawlPolicy and content.brawlPolicy.weapons) or {} do
		melee[row.item] = nil
	end
	local best: any = nil
	for _, child in children do
		if child:IsA("Tool") and melee[child:GetAttribute("ForgeCatalogId")] then
			if not best or child.Name < best.Name then
				best = child
			end
		end
	end
	return best
end

--- True when the combat bar must clear: player dead or bodiless, target gone, or walked away
--- from a paused loop (p134 v50: the step-back pill outlived a death by ~10 min).
function M.release(session: Session?, playerAlive: boolean, targetAlive: boolean, distance: number?): boolean
	if not session then
		return false
	end
	if not playerAlive or not targetAlive or distance == nil then
		return true
	end
	return not session.auto and distance > M.RELEASE_STUDS
end

--- Session after an attack result. The server decided it; this only paces the next try.
function M.settle(session: Session, now: number, result: any): Session
	local nextSession = table.clone(session)
	nextSession.inFlight = false
	local reason = if type(result) == "table" then result.reason else "TRANSPORT"
	-- WINDUP: the server accepted the swing and resolves it after the draw; pace like a hit.
	if type(result) == "table" and (result.ok or reason == "WINDUP") then
		nextSession.nextAt, nextSession.reason = now + M.SWING_SECONDS, nil
	elseif type(reason) == "string" and M.FINAL[reason] then
		nextSession.auto, nextSession.reason = false, reason
	elseif type(reason) == "string" and M.REPOSITION[reason] then
		-- Close in a little more before the next swing.
		nextSession.nextAt, nextSession.approachUntil, nextSession.reason = now, nil, reason
		nextSession.reach = math.max(M.MIN_REACH, (session.reach or M.REACH) - M.REACH_STEP)
	else
		-- COOLDOWN / COMBAT_PENDING / transport: the same swing settles on a later try.
		nextSession.nextAt, nextSession.reason = now + M.BACKOFF_SECONDS, reason
	end
	return nextSession
end

--- Whole hit points lost between two health readings (milli), or nil when nothing was lost.
function M.hit(previous: number?, current: number?): number?
	if type(previous) ~= "number" or type(current) ~= "number" or current >= previous then
		return nil
	end
	return math.max(1, math.floor((previous - current) / 1000 + 0.5))
end

--- Health bar fill in [0, 1].
function M.fraction(healthMilli: number?, maxMilli: number?): number
	if type(healthMilli) ~= "number" or type(maxMilli) ~= "number" or maxMilli <= 0 then
		return 0
	end
	return math.clamp(healthMilli / maxMilli, 0, 1)
end

--- Corner vignette opacity for the local health fraction: a faint coral glow while engaged,
--- deepening linearly from LOW_HEALTH down to MAX_GLOW at zero health in or out of combat.
function M.vignette(health: number, engaged: boolean): number
	local base = if engaged then M.COMBAT_GLOW else 0
	if health >= M.LOW_HEALTH then
		return base
	end
	local depth = 1 - math.max(health, 0) / M.LOW_HEALTH
	return math.max(base, M.COMBAT_GLOW + (M.MAX_GLOW - M.COMBAT_GLOW) * depth)
end

--- Species level and full health (milli) from content wildlifeDetails; nil level for legacy ids.
function M.species(content: any, kind: string?): (number?, number?)
	for _, row in (content and content.wildlifeDetails) or {} do
		if row.id == kind then
			return row.level, row.health * 1000
		end
	end
	return nil, nil
end

--- Carcass outputs still to take (content order), given the items already taken.
function M.offer(content: any, kind: string?, taken: { [string]: boolean }): { { item: string, quantity: number } }
	local out = {}
	for _, row in (content and content.wildlifeDetails) or {} do
		if row.id == kind then
			for _, reservoir in row.dropReservoirs or {} do
				if not taken[reservoir.item] then
					table.insert(out, { item = reservoir.item, quantity = reservoir.quantity })
				end
			end
		end
	end
	return out
end

--- True while a body is the local player's open carcass: dead, killed by `me`, and (when the server
--- clock is known) inside its harvest window. Bodies others killed or that spoiled are not marked.
function M.carcassOpen(healthMilli: any, killer: any, me: string, killedAt: any, serverNow: number?): boolean
	if healthMilli ~= 0 or killer ~= me then
		return false
	end
	return serverNow == nil or type(killedAt) ~= "number" or serverNow < killedAt + M.CARCASS_SECONDS
end

--- Shell fan token centres (ui-spec section 3): `count` tokens on an arc above (cx, cy) that opens
--- upward, FAN_STEP degrees apart and at most FAN_SPAN wide, symmetric about straight up.
function M.fan(count: number, cx: number, cy: number, radius: number): { { x: number, y: number } }
	local out = {}
	if count <= 0 then
		return out
	end
	local span = if count == 1 then 0 else math.min(M.FAN_SPAN, (count - 1) * M.FAN_STEP)
	for index = 1, count do
		local degrees = 90 + span / 2 - (if count == 1 then 0 else (index - 1) * span / (count - 1))
		local a = math.rad(degrees)
		table.insert(out, { x = cx + radius * math.cos(a), y = cy - radius * math.sin(a) })
	end
	return out
end

-- The picker's title pill and Leave pill hang under the anchor (offsets from the anchor's y).
M.FAN_TITLE_DROP, M.FAN_LEAVE_DROP, M.FAN_LEAVE_HEIGHT = 18, 50, 30
-- p134 v55: 'Leave it' sat on the Roblox Backpack hotbar (bottom centre) and a tap on it selected
-- the bola instead; the picker stayed open. The whole picker (arc, title, Leave) is kept inside the
-- screen and above the hotbar band (HudKit.HOTBAR_RESERVE from the bottom), whatever the body's
-- screen point. Returns the clamped anchor (cx, cy) the arc and pills are laid out from.
M.FAN_HOTBAR_RESERVE = 116
function M.fanAnchor(
	px: number,
	py: number,
	width: number,
	height: number,
	radius: number,
	token: number
): (number, number)
	local margin = 8
	local half = radius + token / 2 + margin
	local low = height - M.FAN_HOTBAR_RESERVE - M.FAN_LEAVE_DROP - M.FAN_LEAVE_HEIGHT
	local y = math.min(py, low)
	y = math.max(y, radius + token / 2 + margin)
	local x = math.clamp(px, math.min(half, width / 2), math.max(width - half, width / 2))
	return x, y
end
-- Set on the local player while the picker shows: Robango's Backpack binding (TitleFlow
-- SHEET_ATTRIBUTES) hides the hotbar under it, so no picker tap can land on a hotbar slot.
M.PICKER_ATTRIBUTE = "ForgeCarcassPickerOpen"

-- ---------------------------------------------------------------------------------------------
-- Runtime (Roblox only). Engine globals come through the environment, as in HudShell, so Lune
-- specs can load the pure part above.
local env: any = getfenv()
local game: any = env.game
local Instance: any, Enum: any, UDim: any, UDim2: any = env.Instance, env.Enum, env.UDim, env.UDim2
local Vector2: any, Vector3: any, Color3: any, CFrame: any = env.Vector2, env.Vector3, env.Color3, env.CFrame
local NumberSequence: any, NumberSequenceKeypoint: any = env.NumberSequence, env.NumberSequenceKeypoint
local task: any = env.task

local function color(c: any): any
	return Color3.fromRGB(c.r, c.g, c.b)
end

export type Options = {
	content: any,
	locale: string,
	-- Sends a durable client command and returns the server result (TapRouter.installActions).
	send: (string, { any }) -> any,
	-- Walks toward a world point and calls back on arrival (TapRouter moveTo).
	approach: (any, number, () -> ()) -> (),
	stop: () -> (),
	name: (string) -> string,
	itemName: (string) -> string,
	hidden: () -> boolean,
	-- Server clock seconds (workspace:GetServerTimeNow); without it a carcass mark never expires.
	serverNow: (() -> number)?,
}

function M.start(options: Options)
	local players = game:GetService("Players")
	local run = game:GetService("RunService")
	local world = game:GetService("Workspace")
	local player = players.LocalPlayer
	local P = HudShell.PALETTE
	local t = function(key: string): string
		return M.text(options.locale, key)
	end
	local connections: { any } = {}
	local destroyed = false
	local function clock(): number
		return os.clock()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.IgnoreGuiInset = "ForgeCombatHUD", false, false
	gui.ScreenInsets, gui.DisplayOrder = Enum.ScreenInsets.CoreUISafeInsets, 5
	-- Vignette: four corner squares, coral fading toward the screen centre (corners only).
	local corners: { any } = {}
	for index, spec in { { 0, 0, 45 }, { 1, 0, 135 }, { 0, 1, -45 }, { 1, 1, -135 } } do
		local corner = Instance.new("Frame")
		corner.Name = "Vignette" .. index
		corner.AnchorPoint, corner.Position = Vector2.new(spec[1], spec[2]), UDim2.fromScale(spec[1], spec[2])
		corner.BorderSizePixel, corner.BackgroundColor3, corner.Active = 0, color(P.coral), false
		corner.ZIndex = 0
		-- The glow is decoration: a tap on a creature under a corner must still reach the world.
		corner:SetAttribute("ForgeTapThrough", true)
		local fade = Instance.new("UIGradient")
		fade.Rotation = spec[3]
		fade.Parent = corner
		corner.Parent = gui
		table.insert(corners, corner)
	end
	-- Target bar: name and Lv on one line, the HP track under it.
	local bar = Instance.new("Frame")
	bar.Name, bar.BackgroundColor3, bar.BackgroundTransparency, bar.Visible = "TargetBar", color(P.ink), 0.35, false
	bar.BorderSizePixel = 0
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius, barCorner.Parent = UDim.new(0, 8), bar
	local barName = Instance.new("TextLabel")
	barName.Name, barName.BackgroundTransparency, barName.Font = "Name", 1, Enum.Font.BuilderSansBold
	barName.TextColor3, barName.TextXAlignment = color(P.bone), Enum.TextXAlignment.Left
	barName.Position, barName.Size = UDim2.fromOffset(10, 2), UDim2.new(1, -20, 0.5, -2)
	barName.RichText, barName.Parent = true, bar
	local track = Instance.new("Frame")
	track.Name, track.BackgroundColor3, track.BorderSizePixel = "Track", color(P.driftDark), 0
	track.Position, track.Size = UDim2.new(0, 10, 0.55, 0), UDim2.new(1, -20, 0.32, 0)
	track.Parent = bar
	local fill = Instance.new("Frame")
	fill.Name, fill.BackgroundColor3, fill.BorderSizePixel = "Fill", color(P.coral), 0
	fill.Size, fill.Parent = UDim2.fromScale(1, 1), track
	local hpText = Instance.new("TextLabel")
	hpText.Name, hpText.BackgroundTransparency, hpText.Font = "Health", 1, Enum.Font.BuilderSansBold
	hpText.TextColor3, hpText.Size, hpText.ZIndex = color(P.ink), UDim2.fromScale(1, 1), 2
	hpText.Parent = track
	bar.Parent = gui
	-- End-combat pill: tealDeep with bone text and a small coral warning dot.
	local stepBack = Instance.new("TextButton")
	stepBack.Name, stepBack.AutoButtonColor, stepBack.Visible = "EndCombat", false, false
	stepBack.BackgroundColor3, stepBack.TextColor3 = color(P.tealDeep), color(P.bone)
	stepBack.Font, stepBack.Text = Enum.Font.BuilderSansBold, t("end_combat")
	local pill = Instance.new("UICorner")
	pill.CornerRadius, pill.Parent = UDim.new(0.5, 0), stepBack
	local rim = Instance.new("UIStroke")
	rim.Color, rim.Thickness, rim.ApplyStrokeMode, rim.Parent = color(P.drift), 2, Enum.ApplyStrokeMode.Border, stepBack
	local dot = Instance.new("Frame")
	dot.Name, dot.BackgroundColor3, dot.BorderSizePixel = "Warning", color(P.coral), 0
	dot.AnchorPoint, dot.Position, dot.Size = Vector2.new(0.5, 0.5), UDim2.new(0, 16, 0.5, 0), UDim2.fromOffset(10, 10)
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius, dotCorner.Parent = UDim.new(0.5, 0), dot
	dot.Parent = stepBack
	stepBack.Parent = gui
	-- Carcass fan: pebble tokens over the body plus a heading pill under it.
	local fan = Instance.new("Frame")
	fan.Name, fan.BackgroundTransparency, fan.Size, fan.Visible = "CarcassFan", 1, UDim2.fromScale(1, 1), false
	fan.Parent = gui
	local fanTitle = Instance.new("TextLabel")
	fanTitle.Name, fanTitle.BackgroundColor3, fanTitle.BackgroundTransparency = "Title", color(P.ink), 0.3
	fanTitle.TextColor3, fanTitle.Font, fanTitle.AnchorPoint =
		color(P.bone), Enum.Font.BuilderSansBold, Vector2.new(0.5, 0)
	fanTitle.AutomaticSize, fanTitle.Size = Enum.AutomaticSize.X, UDim2.fromOffset(0, 26)
	local titlePad = Instance.new("UIPadding")
	titlePad.PaddingLeft, titlePad.PaddingRight, titlePad.Parent = UDim.new(0, 12), UDim.new(0, 12), fanTitle
	local titleCorner = Instance.new("UICorner")
	titleCorner.CornerRadius, titleCorner.Parent = UDim.new(0.5, 0), fanTitle
	fanTitle.Parent = fan
	local fanTokens: { any } = {}
	-- Kill toast (p134 v53: a dodo died off screen and nothing said so): "Dodo down - tap the carcass".
	local toast = Instance.new("TextLabel")
	toast.Name, toast.BackgroundColor3, toast.BackgroundTransparency = "KillToast", color(P.ink), 0.25
	toast.TextColor3, toast.Font, toast.AnchorPoint = color(P.ochre), Enum.Font.BuilderSansBold, Vector2.new(0.5, 0)
	toast.AutomaticSize, toast.Size, toast.Visible = Enum.AutomaticSize.X, UDim2.fromOffset(0, 30), false
	toast.Position = UDim2.fromScale(0.5, 0.26)
	-- Information only: a tap under it still reaches the world (the carcass itself).
	toast:SetAttribute("ForgeTapThrough", true)
	local toastPad = Instance.new("UIPadding")
	toastPad.PaddingLeft, toastPad.PaddingRight, toastPad.Parent = UDim.new(0, 14), UDim.new(0, 14), toast
	local toastCorner = Instance.new("UICorner")
	toastCorner.CornerRadius, toastCorner.Parent = UDim.new(0.5, 0), toast
	toast.Parent = gui
	local toastUntil = -math.huge
	-- Floating numbers: pooled billboards in PlayerGui. A respawn deletes every PlayerGui child that is
	-- not a non-resetting LayerCollector, so a Folder here took the pool's labels with it and every
	-- later hit indexed a missing "Text" (staging v40: CombatHud:316 ~57/s). A ScreenGui that does not
	-- reset survives, its BillboardGuis still render in the world, and a dead board leaves the pool.
	local numberFolder = Instance.new("ScreenGui")
	numberFolder.Name, numberFolder.ResetOnSpawn = "ForgeDamageNumbers", false
	numberFolder.Parent = player:WaitForChild("PlayerGui")
	local pool: { any } = {}
	local function float(anchor: any, text: string, tint: any)
		if not anchor or not anchor.Parent then
			return
		end
		for index = #pool, 1, -1 do
			local item = pool[index]
			if item.Parent ~= numberFolder or not item:FindFirstChild("Text") then
				item:Destroy()
				table.remove(pool, index)
			end
		end
		local board: any = nil
		for _, item in pool do
			if not item.Enabled then
				board = item
				break
			end
		end
		if not board then
			if #pool >= 16 then
				return
			end
			board = Instance.new("BillboardGui")
			board.Name, board.Size, board.AlwaysOnTop, board.LightInfluence =
				"DamageNumber", UDim2.fromOffset(120, 40), true, 0
			local label = Instance.new("TextLabel")
			label.Name, label.BackgroundTransparency, label.Size = "Text", 1, UDim2.fromScale(1, 1)
			label.Font, label.TextScaled, label.TextStrokeColor3 = Enum.Font.BuilderSansBold, true, color(P.ink)
			label.TextStrokeTransparency, label.Parent = 0.2, board
			board.Parent = numberFolder
			table.insert(pool, board)
		end
		local label = board:FindFirstChild("Text")
		label.Text, label.TextColor3, label.TextTransparency = text, color(tint), 0
		board.Adornee, board.Enabled = anchor, true
		local started = clock()
		local drift = (#text % 3 - 1) * 0.6
		task.spawn(function()
			while not destroyed and board.Enabled and clock() - started < 0.9 do
				local p = (clock() - started) / 0.9
				board.StudsOffsetWorldSpace = Vector3.new(drift, 3 + p * 2.5, 0)
				label.TextTransparency = math.max(0, (p - 0.5) * 2)
				task.wait()
			end
			board.Enabled, board.Adornee = false, nil
		end)
	end

	local session: Session? = nil
	local targetModel: any = nil
	local maxSeen: { [string]: number } = {}
	local lastHealth: { [any]: number } = {}
	local carcass: { model: any, kind: string?, taken: { [string]: boolean }, busy: boolean, opened: number }? = nil
	-- Outputs already taken per corpse (wildId:killedAt), so a reopened picker offers only the rest.
	local harvested: { [string]: { [string]: boolean } } = {}
	-- World marks over the local player's open carcasses: a ground ring and a tappable name label.
	local marks: { [any]: { board: any, ring: any } } = {}
	local seenAlive: { [any]: boolean } = {}
	local toasted: { [string]: boolean } = {}
	local markFolder = Instance.new("ScreenGui")
	markFolder.Name, markFolder.ResetOnSpawn = "ForgeCarcassMarks", false
	markFolder.Parent = player:WaitForChild("PlayerGui")
	local me = tostring(player.UserId)
	local function corpseKey(model: any): string
		return tostring(model:GetAttribute("ForgeWildlifeId"))
			.. ":"
			.. tostring(model:GetAttribute("ForgeWildlifeKilledAt"))
	end
	local function serverNow(): number?
		return if options.serverNow then options.serverNow() else nil
	end
	local function mine(model: any): boolean
		return M.carcassOpen(
			model:GetAttribute("ForgeWildlifeHealthMilli"),
			model:GetAttribute("ForgeWildlifeKiller"),
			me,
			model:GetAttribute("ForgeWildlifeKilledAt"),
			serverNow()
		)
	end

	local function rootOf(model: any): any
		local part = model and model:FindFirstChild("HumanoidRootPart")
		return if part and part:IsA("BasePart") then part else nil
	end
	local function body(): (any, any)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		return humanoid, if root and root:IsA("BasePart") then root else nil
	end
	local function closeCarcass()
		carcass = nil
		fan.Visible = false
	end
	local function disengage()
		session, targetModel = nil, nil
		options.stop()
	end
	local function openCarcass(model: any)
		local kind = model:GetAttribute("ForgeWildlifeKind")
		local key = corpseKey(model)
		local taken = harvested[key] or {}
		if #M.offer(options.content, kind, taken) == 0 then
			return
		end
		harvested[key] = taken
		carcass = { model = model, kind = kind, taken = taken, busy = false, opened = clock() }
	end
	local function take(item: string)
		local open = carcass
		if not open or open.busy then
			return
		end
		local id = open.model:GetAttribute("ForgeWildlifeId")
		if type(id) ~= "string" then
			closeCarcass()
			return
		end
		open.busy = true
		task.spawn(function()
			local result = options.send("survival-coop:carcass-take", { id, item })
			open.busy = false
			if carcass ~= open then
				return
			end
			local anchor = rootOf(open.model)
			if type(result) == "table" and result.ok then
				open.taken[item] = true
				local quantity = if type(result.data) == "table" then result.data.quantity else nil
				float(anchor, string.format(t("taken"), quantity or 1, options.itemName(item)), P.ochre)
			elseif type(result) == "table" and result.reason == "ALREADY_TAKEN" then
				open.taken[item] = true
			elseif type(result) == "table" and type(result.reason) == "string" then
				float(anchor, M.refusal(options.locale, result.reason), P.bone)
				if result.reason == "OUT_OF_RANGE" and anchor then
					-- Walk up to the body; the fan stays so the pick can be tapped again on arrival.
					options.approach(anchor.Position, M.HARVEST_REACH, function() end)
				elseif result.reason ~= "COMMAND_PENDING" then
					closeCarcass()
				end
			end
			if carcass == open and #M.offer(options.content, open.kind, open.taken) == 0 then
				closeCarcass()
			end
		end)
	end
	local fanClose = Instance.new("TextButton")
	fanClose.Name, fanClose.AutoButtonColor, fanClose.Text = "Leave", false, t("carcass_leave")
	fanClose.Font, fanClose.TextColor3, fanClose.BackgroundColor3 =
		Enum.Font.BuilderSansMedium, color(P.bone), color(P.driftDark)
	fanClose.AnchorPoint, fanClose.AutomaticSize = Vector2.new(0.5, 0), Enum.AutomaticSize.X
	local leavePad = Instance.new("UIPadding")
	leavePad.PaddingLeft, leavePad.PaddingRight, leavePad.Parent = UDim.new(0, 12), UDim.new(0, 12), fanClose
	local leaveCorner = Instance.new("UICorner")
	leaveCorner.CornerRadius, leaveCorner.Parent = UDim.new(0.5, 0), fanClose
	fanClose.Parent = fan
	table.insert(connections, fanClose.Activated:Connect(closeCarcass))
	table.insert(connections, stepBack.Activated:Connect(disengage))

	-- Holds a Backpack melee weapon (never the bola) when none is held; true when one was taken.
	local function arm(): boolean
		local humanoid = body()
		local character = player.Character
		local backpack = player:FindFirstChildOfClass("Backpack")
		if not humanoid or not character or not backpack or character:FindFirstChildOfClass("Tool") then
			return false
		end
		local tool = M.pickWeapon(options.content, backpack:GetChildren())
		if not tool then
			return false
		end
		humanoid:EquipTool(tool)
		return true
	end
	local function swing()
		local current = session
		if not current then
			return
		end
		current.inFlight = true
		task.spawn(function()
			local result = options.send("survival-coop:attack", { current.target })
			if session and session.target == current.target then
				local previous = session.reason
				session = M.settle(session, clock(), result)
				if session.reason == "WEAPON_UNAVAILABLE" and not session.armed and arm() then
					-- Nothing in hand: take a tool from the Backpack and swing again (once).
					session.auto, session.armed = true, true
					session.nextAt = clock() + M.BACKOFF_SECONDS
					return
				end
				local line = M.attackRefusal(options.locale, session.reason)
				if line and session.reason ~= previous then
					local _, root = body()
					float(rootOf(targetModel) or root, line, P.bone)
				end
			end
		end)
	end

	local api = {}
	--- A tap on one of the local player's open carcasses (body or its mark), from any distance: walk
	--- there and open the harvest picker on arrival. False when the body is not one to harvest.
	function api.harvest(model: any): boolean
		local anchor = rootOf(model)
		if not anchor or not mine(model) then
			return false
		end
		if
			#M.offer(options.content, model:GetAttribute("ForgeWildlifeKind"), harvested[corpseKey(model)] or {}) == 0
		then
			return false
		end
		session, targetModel = nil, nil
		closeCarcass()
		local function open()
			if model.Parent and mine(model) then
				openCarcass(model)
			end
		end
		local _, root = body()
		local gap = if root
			then Vector3.new(anchor.Position.X - root.Position.X, 0, anchor.Position.Z - root.Position.Z).Magnitude
			else math.huge
		if gap <= M.HARVEST_REACH then
			open()
		else
			options.approach(anchor.Position, M.HARVEST_REACH, open)
		end
		return true
	end
	--- The fan token at `index` (content order of the outputs still offered) was picked.
	function api.pick(index: number)
		local current = carcass
		local list = if current then M.offer(options.content, current.kind, current.taken) else {}
		if list[index] then
			take(list[index].item)
		end
	end
	--- The open carcass picker's body, or nil.
	function api.picking(): any
		return if carcass then carcass.model else nil
	end
	function api.engage(model: any): boolean
		local id = model:GetAttribute("ForgeWildlifeId")
		if type(id) ~= "string" then
			return false
		end
		session, targetModel = M.engage(session, id, clock()), model
		closeCarcass()
		return true
	end
	--- A ground tap pauses the auto loop (the player walks away on purpose); the bar stays.
	function api.pause()
		if session then
			session.auto = false
		end
	end
	api.disengage = disengage

	-- Dodge hop and HUD-attack targeting from the HUD's local result stream.
	local results = player:FindFirstChild("ForgeHUDResult")
	if results and results:IsA("BindableEvent") then
		table.insert(
			connections,
			results.Event:Connect(function(event: any)
				local request = type(event) == "table" and event.request
				local result = type(event) == "table" and event.result
				if type(request) ~= "table" or type(result) ~= "table" or not result.ok then
					return
				end
				local _, root = body()
				if request.action == "survival-coop:dodge" and root then
					local away = root.CFrame.LookVector * -1
					local anchor = rootOf(targetModel)
					if anchor then
						local delta = root.Position - anchor.Position
						local flat = Vector3.new(delta.X, 0, delta.Z)
						away = if flat.Magnitude > 0.01 then flat.Unit else away
					end
					root.AssemblyLinearVelocity = away * 38 + Vector3.new(0, 8, 0)
					float(root, t("dodged"), P.tealPale)
				end
			end)
		)
	end
	local ownHealth: number? = nil
	local approachGoal: any = nil
	table.insert(
		connections,
		run.Heartbeat:Connect(function()
			if destroyed then
				return
			end
			local now = clock()
			local size = gui.AbsoluteSize
			local regions = HudShell.regions(size.X, size.Y, HudShell.guiClear(gui), true)
			local hidden = options.hidden()
			local humanoid, root = body()
			-- Floating numbers: any creature within 60 studs that lost health, and the local player.
			local folder = world:FindFirstChild("ForgeWildlife")
			for _, model in if folder then folder:GetChildren() else {} do
				local hp = model:GetAttribute("ForgeWildlifeHealthMilli")
				local anchor = rootOf(model)
				if type(hp) == "number" and anchor then
					local kind = model:GetAttribute("ForgeWildlifeKind")
					if type(kind) == "string" then
						maxSeen[kind] = math.max(maxSeen[kind] or 0, hp)
					end
					local lost = M.hit(lastHealth[model], hp)
					if lost and root and (anchor.Position - root.Position).Magnitude < 60 then
						float(anchor, tostring(lost), P.ochre)
					end
					if hp > 0 then
						seenAlive[model] = true
					end
					if hp == 0 and lastHealth[model] and lastHealth[model] > 0 and model == targetModel then
						-- The engaged target fell: stop swinging, offer the carcass.
						if session then
							session.auto = false
						end
						openCarcass(model)
					end
					lastHealth[model] = hp
				end
			end
			for model in lastHealth do
				if not model.Parent then
					lastHealth[model] = nil
					seenAlive[model] = nil
				end
			end
			-- Carcass marks and the kill toast for the local player's open bodies.
			local live: { [any]: boolean } = {}
			for _, model in if folder then folder:GetChildren() else {} do
				local anchor = rootOf(model)
				local kind = model:GetAttribute("ForgeWildlifeKind")
				local key = corpseKey(model)
				if anchor and mine(model) and #M.offer(options.content, kind, harvested[key] or {}) > 0 then
					live[model] = true
					local name = options.name(if type(kind) == "string" then kind else "")
					if seenAlive[model] and not toasted[key] then
						toasted[key] = true
						toast.Text = string.format(t("kill_toast"), name)
						toastUntil = now + M.TOAST_SECONDS
					end
					local mark = marks[model]
					if not mark then
						local ring = Instance.new("CylinderHandleAdornment")
						ring.Name, ring.Adornee, ring.Color3 = "CarcassRing", anchor, color(P.ochre)
						ring.Radius, ring.InnerRadius, ring.Height = 3.2, 2.6, 0.2
						ring.Transparency, ring.AlwaysOnTop, ring.ZIndex = 0.2, false, 1
						local rig = model:FindFirstChildOfClass("Humanoid")
						local drop = anchor.Size.Y * 0.5 + (if rig then rig.HipHeight else 0) - 0.1
						ring.CFrame = CFrame.new(0, -drop, 0) * CFrame.Angles(math.rad(90), 0, 0)
						ring.Parent = markFolder
						local board = Instance.new("BillboardGui")
						board.Name, board.Adornee, board.Size = "CarcassMark", anchor, UDim2.fromOffset(190, 34)
						board.StudsOffset, board.AlwaysOnTop, board.LightInfluence = Vector3.new(0, 3.5, 0), true, 0
						board.MaxDistance, board.Active = 400, true
						local label = Instance.new("TextButton")
						label.Name, label.AutoButtonColor, label.Size = "Label", false, UDim2.fromScale(1, 1)
						label.BackgroundColor3, label.BackgroundTransparency = color(P.ink), 0.25
						label.TextColor3, label.Font, label.TextScaled = color(P.ochre), Enum.Font.BuilderSansBold, true
						local labelCorner = Instance.new("UICorner")
						labelCorner.CornerRadius, labelCorner.Parent = UDim.new(0.5, 0), label
						label.Parent = board
						table.insert(
							connections,
							label.Activated:Connect(function()
								api.harvest(model)
							end)
						)
						board.Parent = markFolder
						mark = { board = board, ring = ring }
						marks[model] = mark
					end
					local markLabel = mark.board:FindFirstChild("Label")
					if markLabel then
						markLabel.Text = string.format(t("carcass_mark"), name)
					end
					mark.board.Enabled = not hidden
					mark.ring.Visible = not hidden
				end
			end
			for model, mark in marks do
				if not live[model] then
					mark.board:Destroy()
					mark.ring:Destroy()
					marks[model] = nil
				end
			end
			toast.Visible = now < toastUntil and not hidden
			if toast.Visible then
				toast.TextSize = HudShell.textSize("label", regions.safeHeight)
			end
			if humanoid and root then
				local health = humanoid.Health * 1000
				local lost = M.hit(ownHealth, health)
				if lost then
					float(root, "-" .. tostring(lost), P.coral)
				end
				ownHealth = health
			end
			-- Auto loop.
			local anchor = rootOf(targetModel)
			local hp = targetModel and targetModel:GetAttribute("ForgeWildlifeHealthMilli")
			local alive = anchor ~= nil
				and targetModel.Parent ~= nil
				and type(hp) == "number"
				and hp > 0
				and targetModel:GetAttribute("ForgeWildlifeState") ~= "captured"
			local distance = if anchor and root
				then Vector3.new(anchor.Position.X - root.Position.X, 0, anchor.Position.Z - root.Position.Z).Magnitude
				else nil
			-- A target that moved away from the walk's goal (a fleeing dodo) re-aims the walk.
			if session and anchor and session.approachUntil and approachGoal then
				local drift = anchor.Position - approachGoal
				if Vector3.new(drift.X, 0, drift.Z).Magnitude > M.DRIFT then
					session.approachUntil = nil
				end
			end
			local decision = M.step(session, now, alive, distance)
			if decision == "approach" and session and anchor then
				local walking = session
				walking.approachUntil = now + M.APPROACH_SECONDS
				approachGoal = anchor.Position
				options.approach(anchor.Position, walking.reach or M.REACH, function()
					if session == walking then
						walking.approachUntil = nil
					end
				end)
			elseif decision == "swing" then
				swing()
			end
			local playerAlive = humanoid ~= nil and root ~= nil and humanoid.Health > 0
			if session and M.release(session, playerAlive, alive or carcass ~= nil, distance) then
				-- A carcass on the engaged kill keeps the bar until the fan closes.
				session, targetModel = nil, nil
				if not playerAlive then
					closeCarcass()
				end
			end
			-- Target bar.
			local engaged = session ~= nil and targetModel ~= nil
			bar.Visible = engaged and not hidden
			stepBack.Visible = engaged and not hidden
			if engaged then
				HudShell.put(bar, regions.target)
				HudShell.put(stepBack, regions.endCombat)
				local kind = targetModel:GetAttribute("ForgeWildlifeKind")
				local level, full = M.species(options.content, kind)
				local maximum = math.max(full or 0, if type(kind) == "string" then maxSeen[kind] or 0 else 0, 1)
				local heading = HudShell.textSize("heading", regions.safeHeight)
				barName.TextSize = heading
				local name = options.name(if type(kind) == "string" then kind else "")
				barName.Text = if level
					then string.format(
						'%s  <font color="#%02X%02X%02X">%s</font>',
						name,
						P.coral.r,
						P.coral.g,
						P.coral.b,
						string.format(t("level"), level)
					)
					else name
				fill.Size = UDim2.fromScale(M.fraction(hp, maximum), 1)
				hpText.TextSize = HudShell.textSize("caption", regions.safeHeight)
				hpText.Text = string.format("%d / %d", math.ceil((hp or 0) / 1000), math.ceil(maximum / 1000))
				stepBack.TextSize = HudShell.textSize("label", regions.safeHeight)
			end
			-- Vignette.
			local health = if humanoid and humanoid.MaxHealth > 0 then humanoid.Health / humanoid.MaxHealth else 1
			local glow = if hidden then 0 else M.vignette(health, engaged)
			local pulse = if health < M.LOW_HEALTH then 0.85 + 0.15 * math.sin(now * 5) else 1
			local edge = math.floor(math.min(size.X, size.Y) * (0.28 + 0.2 * glow) + 0.5)
			for _, corner in corners do
				corner.Size = UDim2.fromOffset(edge, edge)
				corner.BackgroundTransparency = 0
				local fade = corner:FindFirstChildOfClass("UIGradient")
				fade.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1 - glow * pulse),
					NumberSequenceKeypoint.new(0.6, 1),
					NumberSequenceKeypoint.new(1, 1),
				})
				corner.Visible = glow > 0
			end
			-- Carcass fan over the body.
			local open = carcass
			local camera = world.CurrentCamera
			local corpse = open and rootOf(open.model)
			if open and (not corpse or not open.model.Parent or now - open.opened > 120) then
				closeCarcass()
				open, corpse = nil, nil
			end
			if open and corpse and camera and not hidden then
				local point, onScreen = camera:WorldToViewportPoint(corpse.Position)
				local offset = gui.AbsolutePosition
				local outputs = M.offer(options.content, open.kind, open.taken)
				local tokenSize = HudShell.tokenSize("M", regions.safeHeight, true)
				local radius = 0.22 * regions.safeHeight
				local ax, ay = M.fanAnchor(
					point.X - offset.X,
					point.Y - offset.Y,
					size.X,
					size.Y,
					radius,
					math.floor(tokenSize * HudShell.PEBBLE.aspect + 0.5)
				)
				local spots = M.fan(#outputs, ax, ay, radius)
				for index, output in outputs do
					local token = fanTokens[index]
					if not token then
						token = Instance.new("TextButton")
						token.Name, token.TextWrapped = "Output", true
						token.AnchorPoint, token.Parent = Vector2.new(0.5, 0.5), fan
						local which = index
						table.insert(
							connections,
							token.Activated:Connect(function()
								api.pick(which)
							end)
						)
						fanTokens[index] = token
					end
					token.Size = UDim2.fromOffset(tokenSize, math.floor(tokenSize * HudShell.PEBBLE.aspect + 0.5))
					token.Position = UDim2.fromOffset(spots[index].x, spots[index].y)
					token.Text = string.format("%s\n×%d", options.itemName(output.item), output.quantity)
					token.TextSize = HudShell.tokenText("caption", regions.safeHeight, true)
					token.Visible = true
					HudShell.pebble(token, false, not open.busy)
				end
				for index = #outputs + 1, #fanTokens do
					fanTokens[index].Visible = false
				end
				fanTitle.Text = t("carcass_title")
				fanTitle.TextSize = HudShell.textSize("heading", regions.safeHeight)
				fanTitle.Position = UDim2.fromOffset(ax, ay + M.FAN_TITLE_DROP)
				fanClose.TextSize = HudShell.textSize("label", regions.safeHeight)
				fanClose.Size = UDim2.fromOffset(0, M.FAN_LEAVE_HEIGHT)
				fanClose.Position = UDim2.fromOffset(ax, ay + M.FAN_LEAVE_DROP)
				fan.Visible = onScreen and #outputs > 0
			else
				fan.Visible = false
			end
			if player:GetAttribute(M.PICKER_ATTRIBUTE) ~= (fan.Visible or nil) then
				player:SetAttribute(M.PICKER_ATTRIBUTE, fan.Visible or nil)
			end
		end)
	)
	gui.Parent = player:WaitForChild("PlayerGui")
	function api.destroy()
		if destroyed then
			return
		end
		destroyed = true
		for _, connection in connections do
			connection:Disconnect()
		end
		gui:Destroy()
		numberFolder:Destroy()
		markFolder:Destroy()
		if player:GetAttribute(M.PICKER_ATTRIBUTE) ~= nil then
			player:SetAttribute(M.PICKER_ATTRIBUTE, nil)
		end
	end
	return api
end

return M
