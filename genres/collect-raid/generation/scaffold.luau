--!strict
local Assets = require("../../../cli/forge/lib/assets")
local M = require("../../../cli/forge/lib/packidentity")
local Scaffold = {}
local PROC_GEN = [==[# Procedural asset specs for __TITLE__. `lune run cli/forge gen procedural --pack __SLUG__`
# reads this list and writes src/shared/ProcAssets.luau; edit and re-run to regenerate.
# kind is creature|prop; creature archetypes: quad|serpent|titan|biped.
assets:
  - key: emberling
    kind: creature
    archetype: quad
    scale: 1
    body: [220, 96, 48]
    accent: [255, 190, 80]
    eye: [40, 30, 30]
    seed: 1042
  - key: tidepup
    kind: creature
    archetype: biped
    scale: 0.9
    body: [70, 140, 220]
    accent: [180, 230, 255]
    eye: [20, 30, 50]
    seed: 2718
  - key: starter-egg
    kind: prop
    archetype: egg
    scale: 1
    body: [240, 230, 210]
    accent: [200, 90, 60]
    eye: [60, 60, 60]
    seed: 7
  - key: decor-rock
    kind: prop
    archetype: rock
    scale: 1
    body: [120, 120, 115]
    accent: [140, 140, 135]
    eye: [0, 0, 0]
    seed: 4400
]==]

-- Procedural audio cues for a fresh pack: one explore loop plus the two SFX the
-- scaffolded server loop actually triggers (hatch, coin). `lune run cli/forge
-- gen audio --pack __SLUG__` synthesises them with the pure core DSP/composer
-- (no API keys, no network); seeds are stable so every WAV is byte-identical.
local AUDIO_YML = [==[# Procedural audio cues for __TITLE__. `lune run cli/forge gen audio --pack __SLUG__`
# synthesises every cue under Lune with the pure core/domain/procgen DSP and
# composer (no API keys, no network), writes games/__SLUG__/assets/audio/<cue>.wav
# and upserts one forge-procgen/Approved manifest entry per cue.
#
# kind: music (mood explore|siege), sfx (type click|coin|hatch|rare|raid|error),
#       ambience (type wind|birds). duration is seconds; sampleRate optional.
cues:
  - key: musicExplore
    kind: music
    mood: explore
    duration: 75
    sampleRate: 22050
    seed: 1001
  - key: sfxHatch
    kind: sfx
    type: hatch
    duration: 0.5
    sampleRate: 44100
    seed: 3103
  - key: sfxCoin
    kind: sfx
    type: coin
    duration: 0.45
    sampleRate: 44100
    seed: 3102
]==]

local PROC_ASSETS = [==[--!strict
-- ProcAssets: written by `lune run cli/forge gen procedural --pack __SLUG__` from
-- assets/procgen.yml. Until it runs, this empty table keeps the pack playable:
-- the server falls back to simple colored parts for any key without a spec.
return {}
]==]

local CONFIG = [==[--!strict
-- Config: pure data for __TITLE__ (collect-raid).

export type ConfigData = {
	currency: string,
	startingCoins: number,
	teams: { string },
	teamColors: { [string]: BrickColor },
	maxIncubators: number,
	hatchSeconds: number,
	paradeSlots: number,
	creatureKeys: { string },
	coinsPerSecond: { [string]: number },
}

local Config: ConfigData = {
	currency = "Coins",
	startingCoins = 100,
	teams = { "Red", "Blue" },
	teamColors = {
		Red = BrickColor.new("Really red"),
		Blue = BrickColor.new("Bright blue"),
	},
	maxIncubators = 2,
	hatchSeconds = 2,
	paradeSlots = 3,
	-- Keys must match assets/procgen.yml.
	creatureKeys = { "emberling", "tidepup" },
	coinsPerSecond = { emberling = 1, tidepup = 2 },
}

return Config
]==]

local WORLD_LAYOUT = [==[--!strict
-- WorldLayout: pure world data for __TITLE__ (no Roblox APIs). WorldBuilder turns
-- it into the arena, two team bases with incubators, and parade slots.

export type Vec = { x: number, y: number, z: number }

export type ParadeLayout = {
	name: string,
	positions: { Vec },
}

export type BaseLayout = {
	team: string,
	center: Vec,
	size: Vec,
	spawn: Vec,
	spawnTeamColor: string,
	incubators: { Vec },
	vault: Vec,
	parade: ParadeLayout,
	shop: Vec,
	color: { r: number, g: number, b: number },
}

export type ArenaLayout = {
	center: Vec,
	radius: number,
	covers: { { position: Vec, size: Vec } },
	torches: { Vec },
}

export type Layout = {
	name: string,
	ground: { cells: number, cellSize: number, originX: number, originZ: number, y: number, thickness: number },
	bases: { BaseLayout },
	arena: ArenaLayout,
}

local INCUBATORS = 2
local PARADE_SLOTS = 3
local BASE_X = 70

local function vec(x: number, y: number, z: number): Vec
	return { x = x, y = y, z = z }
end

local function base(team: string, sign: number): BaseLayout
	local cx = sign * BASE_X
	local incubators: { Vec } = {}
	for i = 1, INCUBATORS do
		table.insert(incubators, vec(cx + sign * 14, 1, -12 + (i - 1) * 24))
	end
	local positions: { Vec } = {}
	for k = 1, PARADE_SLOTS do
		table.insert(positions, vec(cx - sign * 16, 1, -16 + (k - 1) * 16))
	end
	return {
		team = team,
		center = vec(cx, 0, 0),
		size = vec(56, 8, 56),
		spawn = vec(cx + sign * 20, 3, 0),
		spawnTeamColor = if sign < 0 then "Really red" else "Bright blue",
		incubators = incubators,
		vault = vec(cx - sign * 22, 2, 0),
		parade = { name = "Slot", positions = positions },
		shop = vec(cx + sign * 16, 1, 20),
		color = if sign < 0 then { r = 200, g = 50, b = 50 } else { r = 50, g = 90, b = 210 },
	}
end

local WorldLayout = {}

WorldLayout.layout = {
	name = "__PASCAL__World",
	ground = { cells = 12, cellSize = 25, originX = -150, originZ = -150, y = -0.5, thickness = 1 },
	bases = { base("Red", -1), base("Blue", 1) },
	arena = {
		center = vec(0, 0, 0),
		radius = 34,
		covers = {
			{ position = vec(16, 3, 16), size = vec(8, 6, 2) },
			{ position = vec(-16, 3, -16), size = vec(8, 6, 2) },
		},
		torches = { vec(26, 0, 0), vec(-26, 0, 0), vec(0, 0, 26), vec(0, 0, -26) },
	},
	decorations = {
		{ kind = "Rock", position = vec(44, 2, 44), scale = vec(5, 4, 5), seed = 1.5 },
		{ kind = "Rock", position = vec(-44, 2, -44), scale = vec(4, 3, 6), seed = 3.1 },
	},
	flowers = {},
}

return WorldLayout
]==]

local WORLD_THEME = [==[--!strict
-- WorldTheme: palette, materials, and lighting for __TITLE__, handed to the
-- collect-raid WorldBuilder. Art lives in the pack, not the genre module.

local WorldTheme = {
	palette = {
		ground = { Color3.fromRGB(96, 156, 88), Color3.fromRGB(84, 142, 78) },
		path = Color3.fromRGB(170, 168, 160),
		red = Color3.fromRGB(200, 50, 50),
		blue = Color3.fromRGB(50, 90, 210),
		accent = Color3.fromRGB(255, 160, 60),
		platform = Color3.fromRGB(112, 112, 122),
		metal = Color3.fromRGB(70, 70, 80),
		glass = Color3.fromRGB(180, 220, 255),
		slot = Color3.fromRGB(205, 205, 214),
		crate = Color3.fromRGB(92, 92, 102),
		wood = Color3.fromRGB(160, 110, 60),
		arena = Color3.fromRGB(150, 140, 130),
		cover = Color3.fromRGB(140, 90, 70),
		decoration = Color3.fromRGB(120, 120, 115),
	},
	materials = {
		ground = Enum.Material.Grass,
		path = Enum.Material.Cobblestone,
		platform = Enum.Material.Slate,
		trim = Enum.Material.Neon,
		metal = Enum.Material.Metal,
		glass = Enum.Material.Glass,
		crate = Enum.Material.DiamondPlate,
		slot = Enum.Material.SmoothPlastic,
		shop = Enum.Material.Wood,
		arena = Enum.Material.Concrete,
		cover = Enum.Material.Brick,
		torch = Enum.Material.Wood,
		decoration = Enum.Material.Rock,
	},
	lighting = {
		technology = "Future",
		clockTime = 14,
		brightness = 2.5,
		ambient = Color3.fromRGB(140, 140, 150),
		outdoorAmbient = Color3.fromRGB(150, 150, 160),
		globalShadows = true,
		shadowSoftness = 0.25,
		environmentDiffuseScale = 1,
		environmentSpecularScale = 1,
		fogEnd = 100000,
		sky = {
			celestialBodiesShown = true,
			sunAngularSize = 22,
			starCount = 3000,
			skybox = {},
		},
		clouds = { cover = 0.2, density = 0.35, color = Color3.fromRGB(255, 255, 255) },
		atmosphere = {
			density = 0.3,
			haze = 1.2,
			color = Color3.fromRGB(255, 235, 210),
			decay = Color3.fromRGB(120, 150, 190),
		},
		colorCorrection = { saturation = 0.12, contrast = 0.08 },
		bloom = { intensity = 0.4, size = 24, threshold = 1.5 },
		sunRays = { intensity = 0.05 },
		depthOfField = { farIntensity = 0.15, focusDistance = 45, inFocusRadius = 70, nearIntensity = 0.08 },
	},
	particles = {
		sparkle = "rbxasset://textures/particles/sparkles_main.dds",
		glow = "rbxasset://textures/sparkle.png",
		firefly = "rbxasset://textures/particles/sparkles_main.dds",
		dust = "rbxasset://textures/sparkle.png",
	},
	-- Terrain is disabled: the starter keeps the flat ground Parts.
	terrain = {
		enabled = false,
		half = 300,
		flatHalf = 160,
		cellSize = 16,
		baseY = 0,
		hillHeight = 20,
		waterLevel = -4,
		waterDepth = 12,
		columnDepth = 40,
		noiseScale = 0.02,
		seed = 20260929,
		water = {
			color = Color3.fromRGB(52, 122, 168),
			waveSize = 0.35,
			waveSpeed = 8,
			transparency = 0.35,
			reflectance = 0.2,
		},
	},
	detail = {
		cornerRadius = 2.5,
		fenceHeight = 5,
		fencePostSpacing = 14,
		bannerHeight = 10,
		flagHeight = 15,
		standRadius = 60,
		standCount = 6,
		incubatorSparkleRate = 4,
		fireflyRate = 1.2,
		dustRate = 0.8,
	},
	budget = { worldPartsMax = 6000 },
}

return WorldTheme
]==]

local SERVER = [==[--!strict
-- __PASCAL__Server: bootstraps the __TITLE__ collect-raid pack and pays Coins on parade.
--
-- Creatures render client-side (see __PASCAL__Client / genres/collect-raid's
-- CreatureView): EditableMesh content does not replicate, so a server-built
-- procgen model would be invisible to real clients. The server instead spawns
-- an invisible placeholder Part tagged with CreatureKey/ProcSeed, which every
-- client swaps for the real model.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Teams = game:GetService("Teams")

local Forge = ReplicatedStorage:WaitForChild("Forge")
local Config = require(Forge.games["__SLUG__"].src.shared.Config)
local WorldLayout = require(Forge.games["__SLUG__"].src.shared.WorldLayout)
local WorldTheme = require(Forge.games["__SLUG__"].src.shared.WorldTheme)
local ProcSpecs: any = require(Forge.games["__SLUG__"].src.shared.ProcAssets)
local WorldBuilder = require(Forge.genres["collect-raid"].module.WorldBuilder)
local Wallet = require(Forge.core.domain.economy.Wallet)
local Production = require(Forge.core.domain.economy.Production)
local HatchTimer = require(Forge.core.domain.progression.HatchTimer)
local ProfileSchema = require(Forge.core.domain.state.ProfileSchema)
local ProfileStore = require(Forge.core.infra.data.ProfileStore)
local MemoryBackend = require(Forge.core.infra.data.MemoryBackend)

local LAYOUT = WorldLayout.layout

local store = ProfileStore.new(MemoryBackend.new(), {
	sessionId = if game.JobId ~= "" then game.JobId else "studio",
	lockTimeout = 30,
	retries = 3,
	now = function(): number
		return os.time()
	end,
})

local function migrate(raw: any): { [string]: any }
	return ProfileSchema.migrate(raw, 1, function(): { [string]: any }
		return { coins = Config.startingCoins }
	end, {})
end

-- An invisible placeholder for a creature key: the client-side CreatureView
-- watches for CreatureKey/ProcSeed and swaps in the real procgen model built
-- from ProcSpecs.
local function spawnCreaturePlaceholder(key: string): Model
	local spec = ProcSpecs[key]
	local seed = if type(spec) == "table" and type(spec.seed) == "number" then spec.seed else 0
	local part = Instance.new("Part")
	part.Name = key
	part.Size = Vector3.new(3, 3, 3)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part:SetAttribute("CreatureKey", key)
	part:SetAttribute("ProcSeed", seed)
	local model = Instance.new("Model")
	model.Name = key
	part.Parent = model
	model.PrimaryPart = part
	return model
end

WorldBuilder.build(LAYOUT, WorldTheme)
local teamOrder: { Team } = {}
for _, teamName in Config.teams do
	local existing = Teams:FindFirstChild(teamName)
	if existing == nil then
		local created = Instance.new("Team")
		created.Name = teamName
		created.AutoAssignable = false
		created.TeamColor = Config.teamColors[teamName]
		created.Parent = Teams
		existing = created
	end
	if existing:IsA("Team") then
		table.insert(teamOrder, existing)
	end
end

type Session = {
	wallet: Wallet.Wallet,
	acc: Production.Accumulator,
	rate: number,
	profile: ProfileStore.Profile?,
	coins: IntValue,
}

local sessions: { [Player]: Session } = {}
local hatchTimers: { [string]: HatchTimer.Timer? } = {}
local cursors: { [string]: number } = {}
local function hatch(team: string, player: Player): ()
	local now = os.clock()
	local timer = hatchTimers[team]
	if timer ~= nil and not HatchTimer.isReady(timer, now) then
		return
	end
	hatchTimers[team] = HatchTimer.start(now, Config.hatchSeconds)

	local cursor = (cursors[team] or 0) + 1
	cursors[team] = cursor
	local key = Config.creatureKeys[((cursor - 1) % #Config.creatureKeys) + 1]

	local model = spawnCreaturePlaceholder(key)
	local slot = WorldBuilder.slot(LAYOUT, team, ((cursor - 1) % Config.paradeSlots) + 1)
	if slot ~= nil then
		model:PivotTo(slot.CFrame + Vector3.new(0, 3, 0))
	end
	model.Parent = workspace

	local session = sessions[player]
	if session ~= nil then
		session.rate += Config.coinsPerSecond[key] or 1
	end
end

for _, base in LAYOUT.bases do
	for index = 1, #base.incubators do
		local incubator = WorldBuilder.incubator(LAYOUT, base.team, index)
		if incubator ~= nil then
			local prompt = Instance.new("ProximityPrompt")
			-- A stable Name makes the prompt addressable by the QA driver's exact path (the walk names
			-- the incubator part, the hold step names the prompt on it).
			prompt.Name = "Hatch"
			prompt.ActionText = "Hatch"
			prompt.ObjectText = base.team .. " Incubator"
			prompt.HoldDuration = 0.4
			prompt.MaxActivationDistance = 12
			prompt.RequiresLineOfSight = false
			prompt.Parent = incubator
			prompt.Triggered:Connect(function(player: Player)
				if player.Team and player.Team.Name == base.team then
					hatch(base.team, player)
				end
			end)
		end
	end
end

local function sessionFor(player: Player): ()
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	local coins = Instance.new("IntValue")
	coins.Name = Config.currency
	coins.Parent = folder
	folder.Parent = player

	local profile: ProfileStore.Profile? = store:load("player_" .. tostring(player.UserId), migrate)
	local saved = if profile ~= nil then profile.data.coins else nil
	local start = if type(saved) == "number" then saved else Config.startingCoins
	coins.Value = start
	sessions[player] = {
		wallet = Wallet.new({ [Config.currency] = start }),
		acc = Production.new(),
		rate = 0,
		profile = profile,
		coins = coins,
	}
	if #teamOrder > 0 then
		player.Team = teamOrder[(#Players:GetPlayers() % #teamOrder) + 1]
	end
end

RunService.Heartbeat:Connect(function(dt: number)
	for _, session in sessions do
		local earned = Production.accrue(session.acc, session.rate, dt)
		if earned > 0 then
			Wallet.credit(session.wallet, Config.currency, earned)
			session.coins.Value = Wallet.balance(session.wallet, Config.currency)
		end
	end
end)

Players.PlayerAdded:Connect(sessionFor)
Players.PlayerRemoving:Connect(function(player: Player)
	local session = sessions[player]
	if session ~= nil and session.profile ~= nil then
		session.profile.data.coins = Wallet.balance(session.wallet, Config.currency)
		store:save(session.profile)
	end
	sessions[player] = nil
end)

for _, player in Players:GetPlayers() do
	task.spawn(sessionFor, player)
end

-- ---- The standard surface, over THIS runtime -------------------------------
-- The QA driver and a HUD read ForgeState/ForgeAction. Both are backed by the real runtime here:
-- an action dispatches the real hatch, and every push carries the real leaderstats balance. This is
-- what makes the QA surface the game's own surface rather than a second, parallel contract runtime.
local function snapshotFor(player: Player): any
	local session = sessions[player]
	local creatures = 0
	for _, child in workspace:GetChildren() do
		if child:IsA("Model") then
			local part = child.PrimaryPart
			if part ~= nil and type(part:GetAttribute("CreatureKey")) == "string" then
				creatures += 1
			end
		end
	end
	return {
		balance = if session ~= nil then session.coins.Value else 0,
		rate = if session ~= nil then session.rate else 0,
		team = if player.Team ~= nil then player.Team.Name else nil,
		creatures = creatures,
	}
end
local revision = 0
local ForgeAction = Instance.new("RemoteFunction")
ForgeAction.Name = "ForgeAction"
local ForgeState = Instance.new("RemoteEvent")
ForgeState.Name = "ForgeState"
local function pushState(player: Player): ()
	revision += 1
	ForgeState:FireClient(player, { snapshots = { ["collect-raid"] = snapshotFor(player) }, revision = revision })
end
ForgeAction.OnServerInvoke = function(player: Player, id: any, args: any): any
	if id == nil and args == nil then
		pushState(player)
		return { ok = true }
	end
	local action = tostring(id)
	if action == "hatch" or action == "collect-raid:hatch" then
		if player.Team == nil then
			return { ok = false, reason = "NO_TEAM" }
		end
		hatch(player.Team.Name, player)
		pushState(player)
		return { ok = true }
	end
	return { ok = false, reason = "UNDECLARED_ACTION" }
end
ForgeAction.Parent, ForgeState.Parent = ReplicatedStorage, ReplicatedStorage

-- ---- ForgeQA: the QA surface bound to THIS runtime -------------------------
-- The pack's own server is the playable runtime, so the QA surface dispatches the
-- real hatch, snapshots the real leaderstats balance and saves the real profile.
-- A separate contract runtime beside this one would let QA pass while the
-- incubators, the visible balance or the persistence were broken.
if RunService:IsStudio() then
	local ServerStorage = game:GetService("ServerStorage")
	assert(not ServerStorage:FindFirstChild("ForgeQA"), "ForgeQA already exists")
	local qa = Instance.new("Folder")
	qa.Name = "ForgeQA"
	local changed = Instance.new("BindableEvent")
	changed.Name, changed.Parent = "StateChanged", qa
	local function bind(name: string, callback: (...any) -> ...any)
		local fn = Instance.new("BindableFunction")
		fn.Name, fn.OnInvoke, fn.Parent = name, callback, qa
	end
	local function playerOf(playerId: any): Player?
		return Players:GetPlayerByUserId(tonumber(playerId) or 0)
	end
	local function snapshotForQa(playerId: any): any
		local player = playerOf(playerId)
		local session = if player ~= nil then sessions[player] else nil
		local creatures = {}
		for _, child in workspace:GetChildren() do
			if child:IsA("Model") then
				local part = child.PrimaryPart
				if part ~= nil and type(part:GetAttribute("CreatureKey")) == "string" then
					table.insert(creatures, { key = part:GetAttribute("CreatureKey"), name = child.Name })
				end
			end
		end
		return {
			balance = if session ~= nil then session.coins.Value else 0,
			rate = if session ~= nil then session.rate else 0,
			team = if player ~= nil and player.Team ~= nil then player.Team.Name else nil,
			creatures = creatures,
		}
	end
	bind("revision", function()
		return revision
	end)
	bind("snapshot", function(_genre: string, playerId: string)
		return snapshotForQa(playerId)
	end)
	bind("dispatch", function(_genre: string, id: string, _args: { any }, playerId: string)
		local player = playerOf(playerId)
		if player == nil then
			return { ok = false, reason = "PLAYER_NOT_FOUND" }
		end
		local action = tostring(id)
		if action == "hatch" or action == "collect-raid:hatch" then
			if player.Team == nil then
				return { ok = false, reason = "NO_TEAM" }
			end
			hatch(player.Team.Name, player)
			changed:Fire(1)
			return { ok = true }
		end
		return { ok = false, reason = "UNDECLARED_ACTION" }
	end)
	bind("save", function(playerId: string)
		local player = playerOf(playerId)
		local session = if player ~= nil then sessions[player] else nil
		if session == nil or session.profile == nil then
			return { ok = false, reason = "NO_PROFILE" }
		end
		session.profile.data.coins = Wallet.balance(session.wallet, Config.currency)
		store:save(session.profile)
		return { ok = true }
	end)
	qa.Parent = ServerStorage
end
]==]

local CLIENT = [==[--!strict
-- __PASCAL__Client: ui-kit HUD with the player's Coins and a control hint, plus
-- client-side procgen rendering (CreatureView/DecorView) and the generated
-- audio bed (SoundBank). EditableMesh content does not replicate, so the
-- procgen creatures/decorations built by `forge gen procedural` only ever
-- render on the client; the server spawns invisible placeholders instead.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = ReplicatedStorage:WaitForChild("Forge")
local Theme = require(Forge.core["ui-kit"].Theme)
local Layout = require(Forge.core["ui-kit"].Layout)
local Components = require(Forge.core["ui-kit"].Components)
local Config = require(Forge.games["__SLUG__"].src.shared.Config)
local ProcAssetsSpecs: any = require(Forge.games["__SLUG__"].src.shared.ProcAssets)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local theme = Theme.default

local gui = Instance.new("ScreenGui")
gui.Name = "__PASCAL__Hud"
gui.ResetOnSpawn = false
-- Safe area by construction: the ScreenGui carries CoreUISafeInsets and one
-- SafeArea frame holds every element, so no control can fall outside the inset
-- region on any device.
gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui
Components.attachScale(gui)

local safeArea = Instance.new("Frame")
safeArea.Name = "SafeArea"
safeArea.BackgroundTransparency = 1
safeArea.Position = UDim2.fromOffset(12, 8)
safeArea.Size = UDim2.new(1, -24, 1, -16)
safeArea.Parent = gui

local panel = Components.panel(theme, {
	name = "Hud",
	size = UDim2.fromOffset(260, 96),
	position = UDim2.fromOffset(0, 0),
	parent = safeArea,
})

-- The Roblox chat window owns the top-left corner, and it is core UI this HUD cannot
-- restyle. The panel is placed below the chat's live footprint and re-placed whenever the
-- chat appears, grows or moves, never below a documented floor that clears the chat on its
-- own: the desktop chat window reaches ~283px and the phone chat ~379px, so the floor is
-- 300 on a desktop viewport and 390 on a phone-sized one. A live capture caught the panel on
-- the chat once, and under-reserved once when the chat's message area appeared after the
-- first measure.
local DESKTOP_CHAT_FLOOR = 300
local PHONE_CHAT_FLOOR = 390
local function chatFloor(): number
	local camera = workspace.CurrentCamera
	local viewport = if camera ~= nil then camera.ViewportSize else Vector2.new(1280, 720)
	local phone = viewport.X < 500 or viewport.Y < 500
	return if phone then PHONE_CHAT_FLOOR else DESKTOP_CHAT_FLOOR
end
local function chatBottom(): number
	local chat = playerGui:FindFirstChild("Chat")
	local lowest = 0
	if chat ~= nil and chat:IsA("ScreenGui") and chat.Enabled then
		for _, item in chat:GetDescendants() do
			if item:IsA("GuiObject") and item.Visible then
				local size = item.AbsoluteSize
				-- Frame chrome only: a container that fills the screen is not the chat box.
				if size.X >= 80 and size.Y >= 16 and size.X <= safeArea.AbsoluteSize.X * 0.6 then
					lowest = math.max(lowest, item.AbsolutePosition.Y + size.Y)
				end
			end
		end
	end
	return math.max(if lowest > 0 then lowest + 8 else 0, chatFloor())
end
local function placePanel(bottom: number): ()
	panel.Position = UDim2.fromOffset(0, math.max(bottom - safeArea.AbsolutePosition.Y, 0))
end
-- The chat's layout settles over the first seconds (its message area appears only once
-- messages arrive) and can change at any time, so the reservation follows it: the measured
-- bottom is compared each frame and the panel is re-placed only when it changes.
local RunService = game:GetService("RunService")
local lastBottom: number? = nil
local function reserveChat(): ()
	local bottom = chatBottom()
	if bottom ~= lastBottom then
		lastBottom = bottom
		placePanel(bottom)
	end
end
reserveChat()
safeArea:GetPropertyChangedSignal("AbsoluteSize"):Connect(reserveChat)
local existingChat = playerGui:FindFirstChild("Chat")
if existingChat ~= nil then
	existingChat.DescendantAdded:Connect(reserveChat)
end
playerGui.ChildAdded:Connect(function(child)
	if child.Name == "Chat" then
		child.DescendantAdded:Connect(reserveChat)
		reserveChat()
	end
end)
RunService.Heartbeat:Connect(reserveChat)

local coins = Components.label(theme, {
	text = "Coins: 0",
	size = UDim2.new(1, 0, 0, 30),
	textSize = theme.textSizes.title,
	color = theme.colors.accent,
	parent = panel,
})

local hint = Components.label(theme, {
	-- The hint carries its own Name: `Components.label` names every label "Label", and two
	-- siblings sharing one name are indistinguishable to the QA driver, which addresses a
	-- control by its exact path and refuses a capture with two controls at one path.
	text = "Walk to an incubator and hold E to hatch a free creature",
	size = UDim2.new(1, 0, 0, 48),
	position = UDim2.fromOffset(0, 36),
	textSize = theme.textSizes.small,
	color = theme.colors.muted,
	parent = panel,
})
hint.Name = "Hint"

local leaderstats = player:WaitForChild("leaderstats")
local coinsValue = leaderstats:WaitForChild(Config.currency) :: IntValue

local function render(value: number): ()
	coins.Text = "Coins: " .. Layout.formatNumber(value)
end

coinsValue.Changed:Connect(render)
render(coinsValue.Value)

-- Renders procgen creatures/decorations at the server's placeholders (see
-- __PASCAL__Server) and plays the generated music/SFX bed through SoundBank.
local CreatureView = require(Forge.genres["collect-raid"].module.CreatureView)
local DecorView = require(Forge.genres["collect-raid"].module.DecorView)
local SoundBank = require(Forge.core.infra.audio.SoundBank)
local Assets = require(Forge.games["__SLUG__"].src.shared.Assets)

CreatureView.watchCreatures(workspace, ProcAssetsSpecs)
DecorView.watchDecor(workspace, ProcAssetsSpecs, { Rock = "decor-rock" })

local bank = SoundBank.new()
bank:define("music", { soundId = Assets.musicExplore, volume = 1, looped = true, group = "Music" })
bank:define("hatch", { soundId = Assets.sfxHatch, volume = 0.6, group = "SFX" })
bank:define("coin", { soundId = Assets.sfxCoin, volume = 0.35, playbackSpeed = 1.2, group = "SFX" })
bank:preload()
bank:playPlaylist({ "music" }, { crossfade = 2, volume = 1 })

local lastCoins = coinsValue.Value
local lastCoinAt = 0
coinsValue.Changed:Connect(function(value: number)
	if value > lastCoins then
		local now = os.clock()
		if now - lastCoinAt >= 0.3 then
			lastCoinAt = now
			bank:play("coin")
		end
	end
	lastCoins = value
end)

local function isCreaturePlaceholder(instance: Instance): boolean
	return instance:IsA("BasePart") and type(instance:GetAttribute("CreatureKey")) == "string"
end

-- Only newly-hatched creatures play the cue; parades already standing when
-- this client starts must stay silent.
workspace.DescendantAdded:Connect(function(descendant: Instance)
	if isCreaturePlaceholder(descendant) then
		bank:play("hatch")
	end
end)
]==]

--- Files a `collect-raid` pack starts from (path relative to the pack dir). The
--- world data, server loop, ui-kit HUD, and asset specs are all placeholders that
--- gen/build overwrite or consume, so the pack is playable with no hand edits.
function Scaffold.collectRaidFiles(slug: string, pascal: string): { [string]: string }
	local vars = { __SLUG__ = slug, __PASCAL__ = pascal, __TITLE__ = M.titleCase(slug) }
	return {
		["assets/procgen.yml"] = M.fill(PROC_GEN, vars),
		["assets/audio.yml"] = M.fill(AUDIO_YML, vars),
		["src/shared/Config.luau"] = M.fill(CONFIG, vars),
		["src/shared/WorldLayout.luau"] = M.fill(WORLD_LAYOUT, vars),
		["src/shared/WorldTheme.luau"] = M.fill(WORLD_THEME, vars),
		["src/shared/ProcAssets.luau"] = M.fill(PROC_ASSETS, vars),
		["src/shared/Assets.luau"] = Assets.renderLuau({
			assets = {
				{
					key = "musicExplore",
					kind = "bgm",
					tool = "forge-procgen",
					source = "pending forge gen audio",
					assetId = 0,
					moderation = "NotUploaded",
				},
				{
					key = "sfxHatch",
					kind = "sfx",
					tool = "forge-procgen",
					source = "pending forge gen audio",
					assetId = 0,
					moderation = "NotUploaded",
				},
				{
					key = "sfxCoin",
					kind = "sfx",
					tool = "forge-procgen",
					source = "pending forge gen audio",
					assetId = 0,
					moderation = "NotUploaded",
				},
			},
		}, slug),
		["src/server/" .. pascal .. "Server.server.luau"] = M.fill(SERVER, vars),
		["src/client/" .. pascal .. "Client.client.luau"] = M.fill(CLIENT, vars),
	}
end

return Scaffold
