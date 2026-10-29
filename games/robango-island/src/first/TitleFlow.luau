--!strict
-- TitleFlow (engine-free): the join screen (R01, G14) shipped in ReplicatedFirst.
--   loading -> title -> done
-- * loading: a progress bar fed by real readiness (game loaded, pack text, ContentProvider queue,
--   SpawnGate's ground-ready, the character, the client's HUD-ready) and rotating tips. It ends on
--   the first frame the world is ready: there is no minimum show time.
-- * title: logo, Start, settings shortcut and version. It waits for one tap by design, so plan
--   D1 (first action <= 10 s) counts from the Start tap; the server join runs meanwhile
--   (JoinFirstAction.spec "title hold").
-- * done: Start routes by the server snapshot: the survivor picker first for a player with no
--   survivor, then the opening (new players), else straight into the saved world (returning).
-- Boot.client.luau owns the Instances; the client gates the picker and the cold open on `gate`.
local M = {}

M.DISPLAY_ORDER = 100
M.TIP_SECONDS = 4
M.TIP_KEYS = table.freeze({
	"cli.title.tip1",
	"cli.title.tip2",
	"cli.title.tip3",
	"cli.title.tip4",
	"cli.title.tip5",
	"cli.title.tip6",
})
M.MIN_TEXT = 14
-- A client that never reports ready (a script error) must not trap the player on the loading
-- screen: after this long with the game loaded, the title shows anyway.
M.GIVE_UP_SECONDS = 45
M.MIN_TOUCH = 44
-- Roblox topbar height: nothing tappable sits under it (D2b: a Close at y=11 never took taps).
M.TOP_INSET = 58
M.FADE_SECONDS = 0.25
-- Our palette (HudShell.PALETTE): sea-glass teal, driftwood and bone (decision 9). Duplicated as
-- plain numbers because this module runs before ReplicatedStorage has replicated.
M.COLORS = table.freeze({
	tealDeep = 0x1F4E4C,
	panel = 0x163735,
	teal = 0x5FA8A0,
	drift = 0x8A7560,
	driftDark = 0x4A3D31,
	bone = 0xEDE6D6,
	boneShade = 0xCFC4AD,
	ink = 0x1B2224,
})

export type Signals = {
	loaded: boolean, -- game:IsLoaded()
	text: boolean, -- the Strings table arrived and the copy is filled
	queue: number, -- ContentProvider.RequestQueueSize
	ground: boolean, -- ForgeRoleWorld ForgeSpawnReady (the ground SpawnGate waits for)
	character: boolean, -- the local character's HumanoidRootPart exists
	hud: boolean, -- the client set ForgeHudReady (HUD and panels built)
}

--- True when the world is ready to play: everything the first action needs exists.
function M.ready(s: Signals): boolean
	return s.loaded and s.text and s.character and s.hud
end

--- Loading fraction 0..1 from the signals; `peak` is the largest queue seen so far.
function M.progress(s: Signals, peak: number): number
	if M.ready(s) then
		return 1
	end
	local drained = if peak > 0 then 1 - math.clamp(s.queue / peak, 0, 1) elseif s.loaded then 1 else 0
	local value = (if s.loaded then 0.2 else 0)
		+ (if s.text then 0.1 else 0)
		+ 0.2 * drained
		+ (if s.ground or s.character then 0.2 else 0)
		+ (if s.character then 0.15 else 0)
		+ (if s.hud then 0.15 else 0)
	return math.min(value, 0.99)
end

function M.tipIndex(elapsed: number, count: number): number
	return math.floor(math.max(elapsed, 0) / M.TIP_SECONDS) % count + 1
end

function M.version(placeVersion: number): string
	return "v" .. tostring(placeVersion)
end

--- The locale the copy uses: the saved language (ForgeLanguage), else the player's LocaleId (the
--- SettingsModel.locale rule; that module is not replicated yet when this runs).
function M.locale(playerLocale: string, language: any): string
	return if language == "ko" then "ko-kr" elseif language == "en" then "en-us" else playerLocale
end

--- The background image: the place's primary store thumbnail (assets/store/store.yml, uploaded
--- and approved), or nil in an unpublished place (Studio local), which falls back to the palette.
function M.background(placeId: number): string?
	return if placeId > 0 then "rbxthumb://type=GameThumbnail&id=" .. placeId .. "&w=768&h=432" else nil
end

export type Machine = {
	phase: string,
	progress: number,
	tip: number,
	readyAt: number?,
	step: (signals: Signals, now: number) -> string,
	start: () -> boolean,
}

--- The join-screen state machine.
function M.machine(): Machine
	local startedAt: number? = nil
	local peak = 0
	local machine: Machine
	machine = {
		phase = "loading",
		progress = 0,
		tip = 1,
		readyAt = nil,
		step = function(signals: Signals, now: number): string
			startedAt = startedAt or now
			if machine.phase ~= "loading" then
				return machine.phase
			end
			peak = math.max(peak, signals.queue)
			machine.progress = math.max(machine.progress, M.progress(signals, peak))
			machine.tip = M.tipIndex(now - (startedAt :: number), #M.TIP_KEYS)
			if M.ready(signals) or (signals.loaded and now - (startedAt :: number) >= M.GIVE_UP_SECONDS) then
				machine.phase, machine.progress, machine.readyAt = "title", 1, now
			end
			return machine.phase
		end,
		start = function(): boolean
			if machine.phase ~= "title" then
				return false
			end
			machine.phase = "done"
			return true
		end,
	}
	return machine
end

--- Where Start leads: "picker" (no survivor chosen yet), "opening" (the C1 opening runs),
--- "resume" (a returning player: the saved world) or nil before the first snapshot.
function M.route(snapshot: any): string?
	if type(snapshot) ~= "table" then
		return nil
	end
	local trip = snapshot.archipelago
	local survivor = if type(trip) == "table" then trip.survivor else nil
	if type(survivor) == "table" and survivor.chosen == false then
		return "picker"
	end
	local opening = snapshot.opening
	if type(opening) == "table" and opening.active == true then
		return "opening"
	end
	return "resume"
end

--- What may show now: nothing before Start; the picker before the cold open.
function M.gate(titleDone: boolean, snapshot: any): { picker: boolean, coldOpen: boolean }
	local route = if titleDone then M.route(snapshot) else nil
	return { picker = route == "picker", coldOpen = route == "opening" }
end

export type Rect = { x: number, y: number, width: number, height: number, textSize: number? }

-- The store thumbnail's aspect (Flow.background asks for 768x432).
M.ART_ASPECT = 768 / 432

--- Key art rect for a `width` x `height` IgnoreGuiInset view whose top bar reaches `top` px. The
--- wordmark sits at the top of the art, so the art starts below the top bar and fills the safe
--- area at its own aspect, cropping only the bottom and the sides (p134 v49: a centred full-screen
--- crop put the logo under the Roblox top bar).
function M.art(width: number, height: number, top: number, aspect: number?): Rect
	local ratio = aspect or M.ART_ASPECT
	local artWidth = math.max(width, math.ceil((height - top) * ratio))
	return {
		x = math.floor((width - artWidth) / 2),
		y = top,
		width = artWidth,
		height = math.ceil(artWidth / ratio),
	}
end

--- Whether the Roblox Backpack hotbar may show: never under the title (p134 v49: tool tiles drew
--- over it) and never under a full sheet (the bag and craft sheets reach the hotbar band).
--- Hiding the Backpack CoreGui only hides the bar; an equipped tool stays equipped.
function M.backpackShown(titleDone: boolean, sheetOpen: boolean): boolean
	return titleDone and not sheetOpen
end

M.SHEET_ATTRIBUTES = table.freeze({ "ForgeSurvivalSheetOpen", "ForgeExtensionSheetOpen" })

--- Keeps the Backpack CoreGui on `backpackShown` for the session: `apply(shown)` sets it (the boot
--- passes StarterGui:SetCoreGuiEnabled). Applies at once (hidden under the title) and on every
--- change of ForgeTitleDone or a sheet attribute. Returns the disconnect.
function M.bindBackpack(player: any, apply: (boolean) -> ()): () -> ()
	local last: boolean? = nil
	local function sync()
		local sheet = false
		for _, name in M.SHEET_ATTRIBUTES do
			sheet = sheet or player:GetAttribute(name) == true
		end
		local shown = M.backpackShown(player:GetAttribute("ForgeTitleDone") == true, sheet)
		if shown ~= last then
			last = shown
			apply(shown)
		end
	end
	local connections = {}
	for _, name in { "ForgeTitleDone", table.unpack(M.SHEET_ATTRIBUTES) } do
		table.insert(connections, player:GetAttributeChangedSignal(name):Connect(sync))
	end
	sync()
	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
	end
end

--- Landscape layout in screen pixels (IgnoreGuiInset ScreenGui) for a `width` x `height` view.
--- One unit is height/360, capped at 1.6. The left column stacks the title and tagline over the
--- loading block (tip, status, bar), whose area the Start button takes over in the title phase. The
--- background (the place's own store thumbnail) carries the wordmark in its upper-left sky, above
--- this column.
function M.layout(width: number, height: number, top: number?): { [string]: Rect }
	local u = math.min(height / 360, 1.6)
	local function px(value: number): number
		return math.floor(value * u + 0.5)
	end
	local inset = top or M.TOP_INSET
	local margin = math.max(px(16), math.floor(width * 0.05))
	local bottom = height - px(12)
	local column = math.floor(math.min(width * 0.56, px(520)))
	local out: { [string]: Rect } = {}
	out.version = { x = margin, y = bottom - px(18), width = px(160), height = px(18), textSize = px(14) }
	local settingsWidth, settingsHeight = math.max(px(120), M.MIN_TOUCH), math.max(px(44), M.MIN_TOUCH)
	out.settings = {
		x = width - margin - settingsWidth,
		y = bottom - settingsHeight,
		width = settingsWidth,
		height = settingsHeight,
		textSize = px(16),
	}
	local barY = out.version.y - px(14) - px(10)
	out.bar = { x = margin, y = barY, width = column, height = px(10) }
	out.status = { x = margin, y = barY - px(6) - px(18), width = column, height = px(18), textSize = px(14) }
	out.tip = { x = margin, y = out.status.y - px(6) - px(42), width = column, height = px(42), textSize = px(15) }
	-- The Start button fills the loading block's area once the world is ready.
	local blockTop, blockBottom = out.tip.y, barY + px(10)
	local startHeight = math.max(px(56), M.MIN_TOUCH)
	out.start = {
		x = margin,
		y = math.floor((blockTop + blockBottom - startHeight) / 2),
		width = math.max(px(220), M.MIN_TOUCH),
		height = startHeight,
		textSize = px(24),
	}
	out.tagline = { x = margin, y = blockTop - px(12) - px(22), width = column, height = px(22), textSize = px(16) }
	out.title = { x = margin, y = out.tagline.y - px(48), width = column, height = px(48), textSize = px(40) }
	assert(out.title.y >= inset, "TITLE_UNDER_TOPBAR")
	return out
end

return M
