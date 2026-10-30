--!strict
-- R20 travel screen (ReplicatedFirst): the loading screen of every island hop.
--   * departure: the server publishes LocalPlayer ForgeTravelTo = "<island>|<mode>|<serial>" just
--     before it routes an accepted voyage (sea chart, dock, rift, drift reset, the opening's boat)
--     and clears it when the route is refused. The client fills this screen (destination name and
--     biome, the biome medallion art, a tip) and hands it to TeleportService:SetTeleportGui, so
--     Roblox keeps showing it while the teleport loads.
--   * arrival: RobangoBoot takes TeleportService:GetArrivingTeleportGui() and keeps the same screen
--     up, its bar following the destination's readiness, instead of replaying the title.
--   * in place: when the destination is built on the same server (a new ForgeRoleWorld), the bar
--     follows that world's ForgeSpawnReady and the screen closes on the first ready frame.
-- Art: the start place's store thumbnail as the backdrop (TitleFlow.background) and the
-- destination's biome medallion (approved journal-seal icons); no new textures.
local M = {}

M.GUI = "ForgeTravelScreen"
M.ATTRIBUTE = "ForgeTravelTo"
M.DISPLAY_ORDER = 110 -- above the title (TitleFlow.DISPLAY_ORDER 100)
M.MIN_TEXT = 14
M.TIP_SECONDS = 4
M.TIMEOUT_SECONDS = 45
-- Departure fills toward DEPART_CAP while the teleport loads; arrival fills the rest.
M.DEPART_CAP = 0.6
M.DEPART_SECONDS = 3
M.TIP_KEYS = table.freeze({
	"cli.title.tip1",
	"cli.title.tip2",
	"cli.title.tip3",
	"cli.title.tip4",
	"cli.title.tip5",
	"cli.title.tip6",
})
-- Biome medallion per destination biome (approved L9 journal seals, assets/manifest.yml).
M.BIOME_ART = table.freeze({
	tropical = "item-icon-rw-journal-seal-1", -- palm
	snow = "item-icon-rw-journal-seal-2", -- peaks
	beach = "item-icon-rw-journal-seal-3", -- wave
	volcano = "item-icon-rw-journal-seal-4", -- fire
	grassland = "item-icon-rw-journal-seal-5", -- leaf
	forest = "item-icon-rw-journal-seal-5",
	swamp = "item-icon-rw-journal-seal-6", -- fish
	desert = "item-icon-rw-journal-seal-7", -- sun
})
-- Role islands with their own medallion: the home isle (compass star) and the harbor (wave).
M.ISLAND_ART = table.freeze({
	home = "item-icon-rw-journal-seal-8",
	harbor = "item-icon-rw-journal-seal-3",
})
-- Chart islands (SeaChart.ISLANDS) are named by cli.chart.isle.*; the other roles by cli.travel.isle.*.
local CHART = {
	home = true,
	harbor = true,
	explore10 = true,
	explore20 = true,
	frontier30 = true,
	frontier40 = true,
	frontier50 = true,
	frontier60 = true,
}
M.COLORS = table.freeze({
	night = 0x101C2C,
	ink = 0x0B1220,
	bone = 0xEDE6D6,
	boneShade = 0xCFC4AD,
	ember = 0xF08A3C,
	track = 0x22344A,
})

export type Info = { island: string, mode: string, serial: string }

--- Parses a ForgeTravelTo value; nil for an empty or malformed value.
function M.parse(value: any): Info?
	if type(value) ~= "string" then
		return nil
	end
	local island, mode, serial = string.match(value, "^([%w%-]+)|(%a+)|(.*)$")
	if not island or (mode ~= "sail" and mode ~= "rift") then
		return nil
	end
	return { island = island :: string, mode = mode :: string, serial = serial :: string }
end

--- The chart island a server travel destination lands on: drift isles by route.
function M.islandFor(destination: string, route: number?): string
	if destination == "archipelago" then
		return "drift" .. tostring(math.clamp(route or 1, 1, 5))
	end
	return destination
end

--- The ForgeTravelTo value the server publishes (`serial` keeps repeated voyages distinct).
function M.encode(destination: string, route: number?, mode: string, serial: any): string
	return M.islandFor(destination, route)
		.. "|"
		.. (if mode == "rift" then "rift" else "sail")
		.. "|"
		.. tostring(serial)
end

--- The layout id whose biomes describe `island`.
function M.layoutOf(island: string): string
	local route = string.match(island, "^drift(%d)$")
	return if route then "rw.a" .. route .. ".s1" else "rw." .. island
end

--- What the screen shows for an island: text keys, biome and art key (content.layouts gives biomes).
function M.describe(content: any, island: string, mode: string): any
	local id = M.layoutOf(island)
	local biome: string? = nil
	for _, layout in content.layouts do
		if layout.id == id then
			biome = layout.biomes[1]
		end
	end
	local drift = string.match(island, "^drift%d$") ~= nil
	return {
		heading = if mode == "rift" then "cli.travel.rift" else "cli.travel.sail",
		name = if CHART[island] or drift then "cli.chart.isle." .. island else "cli.travel.isle." .. island,
		biome = if biome then "cli.chart.biome_" .. biome else nil,
		art = M.ISLAND_ART[island] or (biome and M.BIOME_ART[biome]) or M.ISLAND_ART.home,
	}
end

--- Departure progress after `elapsed` seconds: rises fast, never reaches DEPART_CAP.
function M.departProgress(elapsed: number): number
	return M.DEPART_CAP * (1 - math.exp(-math.max(elapsed, 0) / M.DEPART_SECONDS))
end

--- Arrival progress from the destination's own readiness fraction (TitleFlow.progress, 0..1).
function M.arriveProgress(readiness: number): number
	return M.DEPART_CAP + (1 - M.DEPART_CAP) * math.clamp(readiness, 0, 1)
end

function M.tipIndex(elapsed: number, count: number): number
	return math.floor(math.max(elapsed, 0) / M.TIP_SECONDS) % count + 1
end

export type Flow = {
	phase: string, -- "idle" | "departing" | "arriving"
	progress: number,
	tip: number,
	depart: (now: number, origin: any) -> (),
	arrive: (now: number) -> (),
	cancel: () -> (),
	step: (now: number, world: any, ready: boolean, readiness: number) -> boolean,
}

--- The hop state machine. `depart` starts on an accepted voyage (origin = the current role
--- world); `arrive` starts on a place that received our teleport GUI. `step` returns whether the
--- screen shows: departing fills toward DEPART_CAP; a new role world on this server (in place) or
--- the arrival place fills the rest from its readiness and closes on the first ready frame.
function M.flow(): Flow
	local startedAt, origin = 0, nil :: any
	local flow: Flow
	flow = {
		phase = "idle",
		progress = 0,
		tip = 1,
		depart = function(now, world)
			flow.phase, flow.progress, startedAt, origin = "departing", 0, now, world
		end,
		arrive = function(now)
			flow.phase, flow.progress, startedAt, origin = "arriving", M.DEPART_CAP, now, nil
		end,
		cancel = function()
			flow.phase = "idle"
		end,
		step = function(now, world, ready, readiness)
			if flow.phase == "idle" then
				return false
			end
			local elapsed = now - startedAt
			flow.tip = M.tipIndex(elapsed, #M.TIP_KEYS)
			if elapsed >= M.TIMEOUT_SECONDS then
				flow.phase = "idle"
				return false
			end
			local landed = flow.phase == "arriving" or (world ~= nil and world ~= origin)
			if landed then
				if ready then
					flow.phase, flow.progress = "idle", 1
					return false
				end
				flow.progress = math.max(flow.progress, M.arriveProgress(readiness))
			else
				flow.progress = math.max(flow.progress, M.departProgress(elapsed))
			end
			return true
		end,
	}
	return flow
end

export type Rect = { x: number, y: number, width: number, height: number, textSize: number? }

--- Landscape layout (IgnoreGuiInset) for a `width` x `height` view; one unit is height/360 capped
--- at 1.6. The medallion sits left of the heading/name/biome block in the middle band; the tip,
--- status line and bar run along the bottom like the join screen (R01-1 / R20 hop).
function M.layout(width: number, height: number, top: number?): { [string]: Rect }
	local u = math.min(height / 360, 1.6)
	local function px(value: number): number
		return math.floor(value * u + 0.5)
	end
	local inset = top or 58
	local margin = math.max(px(16), math.floor(width * 0.06))
	local out: { [string]: Rect } = {}
	local bottom = height - px(14)
	local barWidth = width - margin * 2
	out.bar = { x = margin, y = bottom - px(8), width = barWidth, height = px(8) }
	out.status = { x = margin, y = out.bar.y - px(6) - px(18), width = barWidth, height = px(18), textSize = px(14) }
	out.tip = { x = margin, y = out.status.y - px(4) - px(40), width = barWidth, height = px(40), textSize = px(15) }
	local bandTop = math.max(inset + px(4), px(70))
	local bandBottom = out.tip.y - px(12)
	local art = math.min(px(132), bandBottom - bandTop)
	local artY = bandTop + math.floor((bandBottom - bandTop - art) / 2)
	out.art = { x = margin, y = artY, width = art, height = art }
	local textX = margin + art + px(18)
	local textWidth = width - textX - margin
	local block = px(20) + px(4) + px(44) + px(4) + px(20)
	local y = artY + math.floor((art - block) / 2)
	out.heading = { x = textX, y = y, width = textWidth, height = px(20), textSize = px(16) }
	out.name = { x = textX, y = y + px(24), width = textWidth, height = px(44), textSize = px(36) }
	out.biome = { x = textX, y = y + px(72), width = textWidth, height = px(20), textSize = px(16) }
	return out
end

--- The local fallback backdrop when the store thumbnail is missing (Studio): palette only.
local function rgb(value: number): Color3
	return Color3.fromRGB(bit32.rshift(value, 16), bit32.band(bit32.rshift(value, 8), 0xFF), bit32.band(value, 0xFF))
end

export type Screen = {
	gui: ScreenGui,
	fill: (view: { [string]: string? }) -> (),
	place: (width: number, height: number, top: number) -> (),
	setProgress: (value: number) -> (),
	setTip: (text: string) -> (),
	setStatus: (text: string) -> (),
}

--- Builds the travel ScreenGui (not parented). Every label is a direct child named after its
--- layout rect, so an arriving copy (GetArrivingTeleportGui) is driven by `adopt` the same way.
function M.build(): Screen
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = M.GUI, false, M.DISPLAY_ORDER
	gui.IgnoreGuiInset, gui.ZIndexBehavior, gui.Enabled = true, Enum.ZIndexBehavior.Sibling, true
	local backdrop = Instance.new("Frame")
	backdrop.Name, backdrop.Size, backdrop.BorderSizePixel = "Backdrop", UDim2.fromScale(1, 1), 0
	backdrop.BackgroundColor3, backdrop.ClipsDescendants, backdrop.Parent = rgb(M.COLORS.night), true, gui
	local key = Instance.new("ImageLabel")
	key.Name, key.Size, key.BackgroundTransparency = "KeyArt", UDim2.fromScale(1, 1), 1
	key.ScaleType, key.ImageTransparency, key.Parent = Enum.ScaleType.Crop, 0.35, backdrop
	-- A night-blue wash over the key art: the hop reads as a voyage at sea, and the copy stays legible.
	local wash = Instance.new("Frame")
	wash.Name, wash.Size, wash.BorderSizePixel = "Wash", UDim2.fromScale(1, 1), 0
	wash.BackgroundColor3, wash.BackgroundTransparency, wash.Parent = rgb(M.COLORS.ink), 0.25, backdrop
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(0.6, 0.2),
		NumberSequenceKeypoint.new(1, 0),
	})
	fade.Parent = wash
	local art = Instance.new("ImageLabel")
	art.Name, art.BackgroundTransparency, art.ScaleType = "art", 1, Enum.ScaleType.Fit
	art.Parent = backdrop
	local function label(name: string, color: number, font: Enum.Font): TextLabel
		local item = Instance.new("TextLabel")
		item.Name, item.BackgroundTransparency, item.Font = name, 1, font
		item.TextColor3, item.TextXAlignment, item.Text = rgb(color), Enum.TextXAlignment.Left, ""
		item.TextWrapped, item.TextTruncate, item.Parent = true, Enum.TextTruncate.AtEnd, backdrop
		return item
	end
	label("heading", M.COLORS.ember, Enum.Font.BuilderSansBold)
	local name = label("name", M.COLORS.bone, Enum.Font.BuilderSansBold)
	local stroke = Instance.new("UIStroke")
	stroke.Color, stroke.Thickness, stroke.Parent = rgb(M.COLORS.ink), 2, name
	label("biome", M.COLORS.boneShade, Enum.Font.BuilderSansMedium)
	label("tip", M.COLORS.bone, Enum.Font.BuilderSans).TextYAlignment = Enum.TextYAlignment.Bottom
	label("status", M.COLORS.boneShade, Enum.Font.BuilderSansMedium)
	local track = Instance.new("Frame")
	track.Name, track.BorderSizePixel, track.BackgroundColor3 = "bar", 0, rgb(M.COLORS.track)
	track.Parent = backdrop
	local fill = Instance.new("Frame")
	fill.Name, fill.BorderSizePixel, fill.BackgroundColor3 = "Fill", 0, rgb(M.COLORS.ember)
	fill.Size, fill.Parent = UDim2.fromScale(0, 1), track
	for _, frame in { track, fill } do
		local corner = Instance.new("UICorner")
		corner.CornerRadius, corner.Parent = UDim.new(0.5, 0), frame
	end
	return M.adopt(gui)
end

--- Drives an existing travel ScreenGui (built here, or the arriving teleport copy).
function M.adopt(gui: ScreenGui): Screen
	local backdrop = gui:WaitForChild("Backdrop") :: Frame
	local function find(name: string): any
		return backdrop:FindFirstChild(name)
	end
	local fill = (find("bar") :: Frame):FindFirstChild("Fill") :: Frame
	local shown = 0
	return {
		gui = gui,
		fill = function(view)
			for _, key in { "heading", "name", "biome" } do
				local item = find(key)
				if item then
					item.Text = view[key] or ""
				end
			end
			find("art").Image = view.art or ""
			find("KeyArt").Image = view.backdrop or ""
			shown = 0
			fill.Size = UDim2.fromScale(0, 1)
		end,
		place = function(width, height, top)
			for name, r in M.layout(width, height, top) do
				local item = find(name)
				if item then
					item.Position, item.Size = UDim2.fromOffset(r.x, r.y), UDim2.fromOffset(r.width, r.height)
					if r.textSize then
						item.TextSize = r.textSize
					end
				end
			end
		end,
		setProgress = function(value)
			-- The bar never runs backwards (a hop hands over from departure to arrival).
			shown = math.max(shown, math.clamp(value, 0, 1))
			fill.Size = UDim2.fromScale(shown, 1)
		end,
		setTip = function(text)
			find("tip").Text = text
		end,
		setStatus = function(text)
			find("status").Text = text
		end,
	}
end

return M
