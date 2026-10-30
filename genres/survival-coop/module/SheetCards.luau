--!strict
-- U6 sheet art cards on the Theme.sheet parchment: empty state, portrait hero, icon tile grid.
-- Text carries ForgeShellKeep (the shell styler leaves it) and uses the caller's shell text size.
local env: any = getfenv()
local Instance, Enum, UDim, UDim2, Color3, Vector2 =
	env.Instance, env.Enum, env.UDim, env.UDim2, env.Color3, env.Vector2
local Theme = require("../../../core/ui-kit/Theme")
local IconFallback = require("../../../core/ui-kit/IconFallback")
local M = {}

export type Icon = { image: string?, category: string? }

local C = Theme.sheet.colors
local function rgb(c: any): any
	return Color3.fromRGB(c.r, c.g, c.b)
end

local function corner(parent: any, radius: number)
	local round = Instance.new("UICorner")
	round.CornerRadius, round.Parent = UDim.new(0, radius), parent
end

local function text(name: string, value: string, size: number, color: any, bold: boolean?): any
	local label = Instance.new("TextLabel")
	label.Name, label.Text, label.BackgroundTransparency = name, value, 1
	label.Font = if bold then Enum.Font.BuilderSansBold else Enum.Font.BuilderSans
	label.TextSize, label.TextColor3, label.TextWrapped = size, rgb(color), true
	label:SetAttribute("ForgeShellKeep", true)
	return label
end

local function badge(parent: any, icon: Icon?, size: number, position: any, name: string): any
	local image = if icon and icon.image and icon.image ~= "" then icon.image else nil
	local frame = IconFallback.mount(
		parent,
		(icon and icon.category) or "item",
		UDim2.fromOffset(size, size),
		position,
		image,
		name
	)
	frame.BackgroundTransparency = 1
	local glyph = frame:FindFirstChild("Glyph")
	if glyph then
		for _, part in glyph:GetChildren() do
			if part:IsA("Frame") then
				part.BackgroundColor3 = rgb(C.inkMuted)
			end
		end
	end
	return frame
end

local function card(name: string, order: number): any
	local frame = Instance.new("Frame")
	frame.Name, frame.LayoutOrder, frame.BorderSizePixel = name, order, 0
	frame.BackgroundColor3, frame.BackgroundTransparency = rgb(C.chip), 0
	frame.Size, frame.AutomaticSize = UDim2.new(1, -6, 0, 0), Enum.AutomaticSize.Y
	corner(frame, Theme.sheet.space.corner)
	local rim = Instance.new("UIStroke")
	rim.Color, rim.Thickness, rim.Transparency, rim.Parent = rgb(C.rim), 1.5, 0.45, frame
	local pad = Instance.new("UIPadding")
	local inset = UDim.new(0, Theme.sheet.space.pad)
	pad.PaddingTop, pad.PaddingBottom, pad.PaddingLeft, pad.PaddingRight = inset, inset, inset, inset
	pad.Parent = frame
	return frame
end

function M.empty(
	parent: any,
	spec: { name: string?, order: number?, icon: Icon?, title: string, hint: string?, size: number }
): any
	local frame = card(spec.name or "EmptyState", spec.order or 0)
	local list = Instance.new("UIListLayout")
	list.HorizontalAlignment, list.SortOrder = Enum.HorizontalAlignment.Center, Enum.SortOrder.LayoutOrder
	list.Padding, list.Parent = UDim.new(0, 6), frame
	local holder = Instance.new("Frame")
	holder.Name, holder.BackgroundTransparency, holder.LayoutOrder = "Art", 1, 1
	holder.Size = UDim2.fromOffset(64, 64)
	holder.Parent = frame
	local ring = Instance.new("Frame")
	ring.Name, ring.Size, ring.BackgroundColor3 = "Ring", UDim2.fromScale(1, 1), rgb(C.body)
	corner(ring, 32)
	local stroke = Instance.new("UIStroke")
	stroke.Color, stroke.Thickness, stroke.Parent = rgb(C.marker), 2, ring
	ring.Parent = holder
	badge(ring, spec.icon, 40, UDim2.fromOffset(12, 12), "EmptyIcon")
	local title = text("EmptyTitle", spec.title, spec.size + 2, C.ink, true)
	title.Size, title.AutomaticSize, title.LayoutOrder = UDim2.fromScale(1, 0), Enum.AutomaticSize.Y, 2
	title.Parent = frame
	if spec.hint and spec.hint ~= "" then
		local hint = text("EmptyHint", spec.hint, spec.size, C.inkMuted)
		hint.Size, hint.AutomaticSize, hint.LayoutOrder = UDim2.fromScale(1, 0), Enum.AutomaticSize.Y, 3
		hint.Parent = frame
	end
	frame.Parent = parent
	return frame
end

export type Chip = { icon: Icon?, text: string }

function M.hero(
	parent: any,
	spec: {
		name: string?,
		order: number?,
		icon: Icon?,
		title: string,
		fraction: number?,
		caption: string?,
		chips: { Chip }?,
		size: number,
	}
): any
	local frame = card(spec.name or "Hero", spec.order or 0)
	local portrait = Instance.new("Frame")
	portrait.Name, portrait.Size, portrait.BackgroundColor3 = "Portrait", UDim2.fromOffset(72, 72), rgb(C.header)
	corner(portrait, 36)
	local stroke = Instance.new("UIStroke")
	stroke.Color, stroke.Thickness, stroke.Parent = rgb(C.marker), 3, portrait
	badge(portrait, spec.icon, 48, UDim2.fromOffset(12, 12), "PortraitIcon")
	portrait.Parent = frame
	local right = Instance.new("Frame")
	right.Name, right.BackgroundTransparency = "Body", 1
	right.Position, right.Size = UDim2.fromOffset(84, 0), UDim2.new(1, -84, 0, 0)
	right.AutomaticSize = Enum.AutomaticSize.Y
	local list = Instance.new("UIListLayout")
	list.SortOrder, list.Padding, list.Parent = Enum.SortOrder.LayoutOrder, UDim.new(0, 6), right
	local title = text("HeroTitle", spec.title, spec.size + 6, C.ink, true)
	title.TextXAlignment, title.LayoutOrder = Enum.TextXAlignment.Left, 1
	title.Size, title.AutomaticSize = UDim2.fromScale(1, 0), Enum.AutomaticSize.Y
	title.Parent = right
	if spec.fraction ~= nil then
		local track = Instance.new("Frame")
		track.Name, track.LayoutOrder, track.BorderSizePixel = "Bar", 2, 0
		track.Size, track.BackgroundColor3 = UDim2.new(1, 0, 0, 12), rgb(C.disabled)
		corner(track, 6)
		local fill = Instance.new("Frame")
		fill.Name, fill.BorderSizePixel, fill.BackgroundColor3 = "Fill", 0, rgb(C.marker)
		fill.Size = UDim2.fromScale(math.clamp(spec.fraction, 0, 1), 1)
		corner(fill, 6)
		fill.Parent = track
		track.Parent = right
	end
	if spec.caption then
		local caption = text("HeroCaption", spec.caption, spec.size, C.inkMuted)
		caption.TextXAlignment, caption.LayoutOrder = Enum.TextXAlignment.Left, 3
		caption.Size, caption.AutomaticSize = UDim2.fromScale(1, 0), Enum.AutomaticSize.Y
		caption.Parent = right
	end
	if spec.chips and #spec.chips > 0 then
		local row = Instance.new("Frame")
		row.Name, row.BackgroundTransparency, row.LayoutOrder = "Chips", 1, 4
		row.Size, row.AutomaticSize = UDim2.fromScale(1, 0), Enum.AutomaticSize.Y
		local flow = Instance.new("UIListLayout")
		flow.FillDirection, flow.Wraps = Enum.FillDirection.Horizontal, true
		flow.Padding, flow.SortOrder, flow.Parent = UDim.new(0, 6), Enum.SortOrder.LayoutOrder, row
		for index, chip in spec.chips do
			local pill = Instance.new("Frame")
			pill.Name, pill.LayoutOrder, pill.BackgroundColor3 = "Chip" .. index, index, rgb(C.body)
			pill.Size, pill.AutomaticSize = UDim2.fromOffset(0, 32), Enum.AutomaticSize.X
			corner(pill, 16)
			local inset = Instance.new("UIPadding")
			inset.PaddingLeft, inset.PaddingRight, inset.Parent = UDim.new(0, 36), UDim.new(0, 12), pill
			badge(pill, chip.icon, 24, UDim2.new(0, -30, 0.5, -12), "ChipIcon")
			local value = text("ChipText", chip.text, spec.size, C.ink, true)
			value.Size, value.AutomaticSize, value.TextWrapped = UDim2.fromScale(0, 1), Enum.AutomaticSize.X, false
			value.Parent = pill
			pill.Parent = row
		end
		row.Parent = right
	end
	right.Parent = frame
	local floor = Instance.new("UISizeConstraint")
	floor.MinSize, floor.Parent = Vector2.new(0, 72 + 2 * Theme.sheet.space.pad), frame
	frame.Parent = parent
	return frame
end

export type Tile = { icon: Icon?, label: string, value: string, dim: boolean? }

function M.tiles(
	parent: any,
	spec: { name: string?, order: number?, tiles: { Tile }, columns: number, size: number }
): any
	local frame = Instance.new("Frame")
	frame.Name, frame.LayoutOrder, frame.BackgroundTransparency = spec.name or "Tiles", spec.order or 0, 1
	frame.Size, frame.AutomaticSize = UDim2.new(1, -6, 0, 0), Enum.AutomaticSize.Y
	local height = 2 * spec.size + 30
	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromOffset(6, 6)
	grid.CellSize = UDim2.new(1 / spec.columns, -6, 0, math.max(56, height))
	grid.SortOrder, grid.Parent = Enum.SortOrder.LayoutOrder, frame
	for index, tile in spec.tiles do
		local cell = Instance.new("Frame")
		cell.Name, cell.LayoutOrder, cell.BorderSizePixel = "Tile" .. index, index, 0
		cell.BackgroundColor3 = rgb(if tile.dim then C.body else C.chip)
		corner(cell, Theme.sheet.space.corner)
		local rim = Instance.new("UIStroke")
		rim.Color, rim.Thickness, rim.Transparency, rim.Parent = rgb(C.rim), 1, if tile.dim then 0.65 else 0.35, cell
		local art = badge(cell, tile.icon, 36, UDim2.new(0, 8, 0.5, -18), "TileIcon")
		if tile.dim then
			local asset = art:FindFirstChild("Asset")
			if asset then
				(asset :: any).ImageTransparency = 0.55
			end
		end
		local label = text("TileLabel", tile.label, spec.size, C.inkMuted)
		label.TextXAlignment, label.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Bottom
		label.Position, label.Size = UDim2.fromOffset(52, 4), UDim2.new(1, -58, 0.5, -4)
		label.TextTruncate, label.TextWrapped = Enum.TextTruncate.AtEnd, false
		label.Parent = cell
		local value = text("TileValue", tile.value, spec.size, if tile.dim then C.inkMuted else C.ink, not tile.dim)
		value.TextXAlignment, value.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top
		value.Position, value.Size = UDim2.new(0, 52, 0.5, 2), UDim2.new(1, -58, 0.5, -6)
		value.TextTruncate, value.TextWrapped = Enum.TextTruncate.AtEnd, false
		value.Parent = cell
		cell.Parent = frame
	end
	frame.Parent = parent
	return frame
end

export type Line = { icon: Icon?, text: string, done: boolean? }

-- U7 section card: icon + bold title (+ right badge), muted caption, icon lines, a muted note.
function M.section(
	parent: any,
	spec: {
		name: string?,
		order: number?,
		icon: Icon?,
		title: string,
		badge: string?,
		caption: string?,
		lines: { Line }?,
		note: string?,
		size: number,
	}
): any
	local frame = card(spec.name or "Section", spec.order or 0)
	local list = Instance.new("UIListLayout")
	list.SortOrder, list.Padding, list.Parent = Enum.SortOrder.LayoutOrder, UDim.new(0, 4), frame
	local head = Instance.new("Frame")
	head.Name, head.BackgroundTransparency, head.LayoutOrder = "Head", 1, 1
	head.Size = UDim2.new(1, 0, 0, math.max(32, spec.size + 14))
	badge(head, spec.icon, 30, UDim2.new(0, 0, 0.5, -15), "SectionIcon")
	local title = text("SectionTitle", spec.title, spec.size + 2, C.ink, true)
	title.TextXAlignment, title.TextTruncate, title.TextWrapped =
		Enum.TextXAlignment.Left, Enum.TextTruncate.AtEnd, false
	title.Position, title.Size = UDim2.fromOffset(38, 0), UDim2.new(1, if spec.badge then -150 else -38, 1, 0)
	title.Parent = head
	if spec.badge then
		local pill = text("SectionBadge", spec.badge, spec.size, C.headerText, true)
		pill.BackgroundTransparency, pill.BackgroundColor3 = 0, rgb(C.marker)
		pill.AnchorPoint, pill.Position = Vector2.new(1, 0.5), UDim2.fromScale(1, 0.5)
		pill.Size, pill.AutomaticSize, pill.TextWrapped =
			UDim2.fromOffset(0, spec.size + 10), Enum.AutomaticSize.X, false
		corner(pill, (spec.size + 10) // 2)
		local inset = Instance.new("UIPadding")
		inset.PaddingLeft, inset.PaddingRight, inset.Parent = UDim.new(0, 10), UDim.new(0, 10), pill
		pill.Parent = head
	end
	head.Parent = frame
	local function line(name: string, value: string, order: number, color: any, inset: number): any
		local label = text(name, value, spec.size, color)
		label.TextXAlignment, label.LayoutOrder = Enum.TextXAlignment.Left, order
		label.Size, label.AutomaticSize = UDim2.fromScale(1, 0), Enum.AutomaticSize.Y
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft, pad.Parent = UDim.new(0, inset), label
		label.Parent = frame
		return label
	end
	if spec.caption and spec.caption ~= "" then
		line("SectionCaption", spec.caption, 2, C.inkMuted, 0)
	end
	local lines: { Line } = spec.lines or {}
	for index, entry in lines do
		local row = line("Line" .. index, entry.text, 2 + index, if entry.done then C.inkMuted else C.ink, 30)
		row.TextYAlignment = Enum.TextYAlignment.Center
		local floor = Instance.new("UISizeConstraint")
		floor.MinSize, floor.Parent = Vector2.new(0, 26), row
		badge(row, entry.icon, 22, UDim2.new(0, -28, 0.5, -11), "LineIcon")
	end
	if spec.note and spec.note ~= "" then
		line("SectionNote", spec.note, 100, C.close, 0)
	end
	frame.Parent = parent
	return frame
end

function M.columns(width: number): number
	return math.clamp(math.floor(width / 190), 2, 4)
end

return M
