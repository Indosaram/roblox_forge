--!strict
local Components = {}
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local function color(c: { r: number, g: number, b: number }): Color3
	return Color3.fromRGB(c.r, c.g, c.b)
end

export type Theme = {
	font: string,
	colors: {
		bg: { r: number, g: number, b: number },
		panel: { r: number, g: number, b: number },
		accent: { r: number, g: number, b: number },
		text: { r: number, g: number, b: number },
		onAccent: { r: number, g: number, b: number },
		muted: { r: number, g: number, b: number },
		good: { r: number, g: number, b: number },
		bad: { r: number, g: number, b: number },
	},
	corner: number,
	padding: number,
	textSizes: { title: number, body: number, small: number },
}

type PanelProps = {
	name: string?,
	size: UDim2,
	position: UDim2?,
	parent: Instance?,
	header: string?,
}

type LabelProps = {
	text: string,
	size: UDim2,
	position: UDim2?,
	textSize: number?,
	color: { r: number, g: number, b: number }?,
	parent: Instance?,
	-- A label is never bare text over the world: every label carries a dark stroke
	-- so it reads over any backdrop, and `chip` additionally paints an opaque
	-- background the text owns (the readability contract in
	-- core/ui-kit/genre/HudContrast measures text against exactly this chip).
	chip: boolean?,
}

type ButtonProps = {
	text: string,
	size: UDim2,
	position: UDim2?,
	parent: Instance?,
	onClick: (() -> ())?,
}

type ProgressBarProps = {
	size: UDim2,
	position: UDim2?,
	parent: Instance?,
}

function Components.panel(theme: Theme, props: PanelProps): Frame
	local frame = Instance.new("Frame")
	frame.Name = props.name or "Panel"
	frame.Size = props.size
	frame.Position = props.position or UDim2.new()
	frame.BackgroundColor3 = color(theme.colors.panel)
	frame.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, theme.corner)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = color(theme.colors.muted)
	stroke.Thickness = 1
	stroke.Parent = frame

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(
		color(theme.colors.panel):Lerp(Color3.new(1, 1, 1), 0.06),
		color(theme.colors.panel):Lerp(Color3.new(0, 0, 0), 0.28)
	)
	gradient.Rotation = 90
	gradient.Parent = frame

	if props.header ~= nil then
		local ribbon = Instance.new("Frame")
		ribbon.Name = "Header"
		ribbon.Size = UDim2.new(1, 0, 0, 30)
		ribbon.BackgroundColor3 = color(theme.colors.accent)
		ribbon.BorderSizePixel = 0
		ribbon.LayoutOrder = -1

		local ribbonCorner = Instance.new("UICorner")
		ribbonCorner.CornerRadius = UDim.new(0, theme.corner)
		ribbonCorner.Parent = ribbon

		local ribbonGradient = Instance.new("UIGradient")
		ribbonGradient.Color = ColorSequence.new(
			color(theme.colors.accent):Lerp(Color3.new(1, 1, 1), 0.3),
			color(theme.colors.accent):Lerp(Color3.new(0, 0, 0), 0.2)
		)
		ribbonGradient.Rotation = 90
		ribbonGradient.Parent = ribbon

		local title = Instance.new("TextLabel")
		title.Name = "HeaderTitle"
		title.Size = UDim2.fromScale(1, 1)
		title.BackgroundTransparency = 1
		title.Font = (Enum.Font :: any)[theme.font]
		title.TextSize = theme.textSizes.body
		title.TextColor3 = color(theme.colors.onAccent)
		title.Text = props.header
		title.Parent = ribbon

		ribbon.Parent = frame
	end

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, theme.padding)
	padding.PaddingBottom = UDim.new(0, theme.padding)
	padding.PaddingLeft = UDim.new(0, theme.padding)
	padding.PaddingRight = UDim.new(0, theme.padding)
	padding.Parent = frame

	if props.parent then
		frame.Parent = props.parent
	end

	return frame
end

type ModalSheetProps = {
	name: string?,
	title: string,
	parent: Instance?,
}

export type ModalSheet = {
	frame: Frame,
	scroll: ScrollingFrame,
	content: UIListLayout,
	close: TextButton,
}

-- Header geometry for a modal sheet. The close button is anchored to the right
-- edge and occupies CLOSE_FOOTPRINT of it; the title must stop before that
-- footprint or the two rectangles overlap. These are plain numbers so the same
-- reserve can be reasoned about without constructing Instances.
local TITLE_MARGIN = 14
local CLOSE_SIZE = 44
local CLOSE_INSET = 6
local CLOSE_FOOTPRINT = CLOSE_SIZE + CLOSE_INSET
local TITLE_GAP = 6

--- A centered modal sheet: a title bar with a 44px close button over an
--- internal vertical ScrollingFrame whose children are laid out by
--- LayoutOrder. Callers size the frame (see Layout.sheetSize) and toggle
--- `Visible`; the sheet owns no input, so a shared backdrop can close it.
function Components.modalSheet(theme: Theme, props: ModalSheetProps): ModalSheet
	local frame = Instance.new("Frame")
	frame.Name = props.name or "ModalSheet"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(320, 240)
	frame.BackgroundColor3 = color(theme.colors.panel)
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.ZIndex = 50

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, theme.corner)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = color(theme.colors.muted)
	stroke.Thickness = 1.5
	stroke.Parent = frame

	local frameGradient = Instance.new("UIGradient")
	frameGradient.Color = ColorSequence.new(
		color(theme.colors.panel):Lerp(Color3.new(1, 1, 1), 0.06),
		color(theme.colors.panel):Lerp(Color3.new(0, 0, 0), 0.24)
	)
	frameGradient.Rotation = 90
	frameGradient.Parent = frame

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 44)
	header.BackgroundColor3 = color(theme.colors.accent)
	header.BorderSizePixel = 0
	header.ZIndex = 51
	header.Parent = frame

	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, theme.corner)
	headerCorner.Parent = header

	local headerGradient = Instance.new("UIGradient")
	headerGradient.Color = ColorSequence.new(
		color(theme.colors.accent):Lerp(Color3.new(1, 1, 1), 0.16),
		color(theme.colors.accent):Lerp(Color3.new(0, 0, 0), 0.18)
	)
	headerGradient.Rotation = 90
	headerGradient.Parent = header

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	-- The close button owns the rightmost CLOSE_FOOTPRINT of the header. The title
	-- must stop before it: left margin + close footprint + a small gap. A narrower
	-- reserve lets the two rectangles intersect, which is a real overlap (not just
	-- visual crowding) and fails the capture geometry contract.
	title.Size = UDim2.new(1, -(TITLE_MARGIN + CLOSE_FOOTPRINT + TITLE_GAP), 1, 0)
	title.Position = UDim2.fromOffset(TITLE_MARGIN, 0)
	title.BackgroundTransparency = 1
	title.Font = (Enum.Font :: any)[theme.font]
	title.TextSize = theme.textSizes.body
	title.TextColor3 = color(theme.colors.onAccent)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Text = props.title
	title.ZIndex = 52
	title.Parent = header

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.Size = UDim2.fromOffset(CLOSE_SIZE, CLOSE_SIZE)
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, -CLOSE_INSET, 0.5, 0)
	close.BackgroundColor3 = color(theme.colors.bad)
	close.AutoButtonColor = false
	close.BorderSizePixel = 0
	close.Font = (Enum.Font :: any)[theme.font]
	close.TextSize = theme.textSizes.body
	close.TextColor3 = color(theme.colors.onAccent)
	close.Text = "X"
	close.ZIndex = 52
	close.Parent = header

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(1, 0)
	closeCorner.Parent = close

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Content"
	scroll.Position = UDim2.fromOffset(0, 44)
	scroll.Size = UDim2.new(1, 0, 1, -44)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ZIndex = 51
	scroll.Parent = frame

	local content = Instance.new("UIListLayout")
	content.Padding = UDim.new(0, 6)
	content.SortOrder = Enum.SortOrder.LayoutOrder
	content.Parent = scroll

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = scroll

	if props.parent then
		frame.Parent = props.parent
	end

	return { frame = frame, scroll = scroll, content = content, close = close }
end

function Components.label(theme: Theme, props: LabelProps): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = props.size
	label.Position = props.position or UDim2.new()
	label.Font = (Enum.Font :: any)[theme.font]
	label.TextSize = props.textSize or theme.textSizes.body
	label.TextColor3 = color(props.color or theme.colors.text)
	label.TextWrapped = true
	label.Text = props.text

	if props.chip then
		-- An opaque chip behind the text, so a string drawn over a bright world
		-- still sits on a background the kit owns.
		label.BackgroundColor3 = color(theme.colors.bg)
		label.BackgroundTransparency = 0.15
		label.BorderSizePixel = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, theme.corner)
		corner.Parent = label
		local padding = Instance.new("UIPadding")
		padding.PaddingLeft, padding.PaddingRight = UDim.new(0, 8), UDim.new(0, 8)
		padding.Parent = label
	else
		label.BackgroundTransparency = 1
	end

	-- The stroke is what makes any label legible over any world backdrop, chip or
	-- not: it outlines the glyphs in the theme's dark ink so a bright sky or snow
	-- field cannot swallow the text.
	local stroke = Instance.new("UIStroke")
	stroke.Color = color(theme.colors.bg)
	stroke.Thickness = 2
	stroke.Transparency = 0.25
	stroke.Parent = label

	if props.parent then
		label.Parent = props.parent
	end

	return label
end

function Components.button(theme: Theme, props: ButtonProps): TextButton
	local button = Instance.new("TextButton")
	button.Name = "Button"
	button.Size = props.size
	button.Position = props.position or UDim2.new()
	button.BackgroundColor3 = color(theme.colors.accent)
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Font = (Enum.Font :: any)[theme.font]
	button.TextSize = theme.textSizes.body
	button.TextColor3 = color(theme.colors.onAccent)
	button.Text = props.text

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, theme.corner)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = color(theme.colors.accent):Lerp(Color3.new(1, 1, 1), 0.25)
	stroke.Thickness = 1
	stroke.Transparency = 0.25
	stroke.Parent = button

	local btnGradient = Instance.new("UIGradient")
	btnGradient.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(218, 224, 220))
	btnGradient.Rotation = 90
	btnGradient.Parent = button

	local constraint = Instance.new("UISizeConstraint")
	constraint.MinSize = Vector2.new(0, 44)
	constraint.Parent = button

	local baseColor = color(theme.colors.accent)
	local hoveredColor = baseColor:Lerp(Color3.new(1, 1, 1), 0.15)
	button.MouseEnter:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.15), { BackgroundColor3 = hoveredColor }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.15), { BackgroundColor3 = baseColor }):Play()
	end)
	button.Activated:Connect(function()
		if props.onClick then
			props.onClick()
		end
	end)

	if props.parent then
		button.Parent = props.parent
	end

	return button
end

type IconButtonProps = {
	name: string?,
	text: string,
	size: UDim2,
	position: UDim2?,
	parent: Instance?,
	onClick: (() -> ())?,
	icon: Content?,
	iconSize: number?,
	baseColor: { r: number, g: number, b: number }?,
	corner: UDim?,
	iconOnly: boolean?,
}

local function gradientFor(base: Color3): ColorSequence
	return ColorSequence.new(base:Lerp(Color3.new(1, 1, 1), 0.3), base:Lerp(Color3.new(0, 0, 0), 0.3))
end

-- Standard control height; icon/text buttons derive their left icon slot from it
-- when the button is sized by scale rather than a fixed pixel height.
local DEFAULT_BUTTON_HEIGHT = 44

--- Re-tints an icon button created by Components.iconButton, keeping its
--- gradient and outline in sync with the new base color.
function Components.setIconButtonColor(button: TextButton, base: { r: number, g: number, b: number }): ()
	local c = color(base)
	local face = button:FindFirstChild("Face")
	if face and face:IsA("GuiObject") then
		face.BackgroundColor3 = c
	end
	local gradient = if face then face:FindFirstChildOfClass("UIGradient") else nil
	if gradient == nil then
		gradient = button:FindFirstChildOfClass("UIGradient")
	end
	if gradient then
		gradient.Color = gradientFor(c)
	end
	local stroke = if face then face:FindFirstChildOfClass("UIStroke") else nil
	if stroke == nil then
		stroke = button:FindFirstChildOfClass("UIStroke")
	end
	if stroke then
		stroke.Color = c:Lerp(Color3.new(1, 1, 1), 0.45)
	end
end

--- A rounded, glossy button: gradient fill, outline, drop shadow, an optional
--- generated icon in a square left slot, and a press-scale tween. The visible
--- text is a child label that starts after the slot, so icons never overlap it.
--- `corner` overrides the corner radius (use `UDim.new(1, 0)` for a round
--- button) and `iconOnly` centres the icon in place of the text label.
--- Min height stays 44px.
function Components.iconButton(theme: Theme, props: IconButtonProps): TextButton
	local base = color(props.baseColor or theme.colors.accent)
	local cornerRadius = props.corner or UDim.new(0, theme.corner)
	local button = Instance.new("TextButton")
	button.Name = props.name or "IconButton"
	button.Size = props.size
	button.Position = props.position or UDim2.new()
	button.BackgroundTransparency = 1
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.ClipsDescendants = false
	button.Font = (Enum.Font :: any)[theme.font]
	button.TextSize = theme.textSizes.body
	button.TextColor3 = color(theme.colors.onAccent)
	button.Text = props.text
	button.TextTransparency = 1
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.ZIndex = 1

	local constraint = Instance.new("UISizeConstraint")
	constraint.MinSize = Vector2.new(0, 44)
	constraint.Parent = button

	-- The button is a transparent input root. Shadow and Face are siblings so a
	-- parent-relative (Sibling) ZIndexBehavior still draws the shadow (ZIndex 1)
	-- behind the face (ZIndex 2) instead of darkening it.
	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.Size = UDim2.fromScale(1, 1)
	shadow.Position = UDim2.fromOffset(0, 3)
	shadow.BackgroundColor3 = Color3.new(0, 0, 0)
	shadow.BackgroundTransparency = 0.55
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 1
	shadow.Parent = button

	local shadowCorner = Instance.new("UICorner")
	shadowCorner.CornerRadius = cornerRadius
	shadowCorner.Parent = shadow

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.fromScale(1, 1)
	face.BackgroundColor3 = base
	face.BorderSizePixel = 0
	face.ZIndex = 2
	face.Parent = button

	local corner = Instance.new("UICorner")
	corner.CornerRadius = cornerRadius
	corner.Parent = face

	local gradient = Instance.new("UIGradient")
	gradient.Color = gradientFor(base)
	gradient.Rotation = 90
	gradient.Parent = face

	local stroke = Instance.new("UIStroke")
	stroke.Color = base:Lerp(Color3.new(1, 1, 1), 0.45)
	stroke.Thickness = 2
	stroke.Transparency = 0.15
	stroke.Parent = face

	local scale = Instance.new("UIScale")
	scale.Parent = button
	button.MouseButton1Down:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.08), { Scale = 0.94 }):Play()
	end)
	button.MouseButton1Up:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.12), { Scale = 1 }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.12), { Scale = 1 }):Play()
	end)

	-- Icon occupies a square slot inset 4px from the left; its side is the
	-- button height minus 8. The label starts 8px after the slot, so generated
	-- art can never draw over the text. Scale-height buttons use the standard
	-- 44px control height (every current call site is 44px tall).
	local height = if props.size.Y.Offset > 0 then props.size.Y.Offset else DEFAULT_BUTTON_HEIGHT
	local slot = math.max(16, height - 8)
	local iconPx = math.clamp(props.iconSize or slot, 8, slot)
	local iconOnly = props.iconOnly == true

	if not iconOnly then
		local text = Instance.new("TextLabel")
		text.Name = "Text"
		text.Size = UDim2.new(1, -(slot + 12), 1, 0)
		text.Position = UDim2.new(0, slot + 8, 0.5, 0)
		text.AnchorPoint = Vector2.new(0, 0.5)
		text.BackgroundTransparency = 1
		text.Font = (Enum.Font :: any)[theme.font]
		text.Text = props.text
		text.TextColor3 = color(theme.colors.onAccent)
		text.TextXAlignment = Enum.TextXAlignment.Left
		text.TextYAlignment = Enum.TextYAlignment.Center
		text.TextScaled = true
		text.TextTruncate = Enum.TextTruncate.AtEnd
		text.ZIndex = 3

		local textConstraint = Instance.new("UITextSizeConstraint")
		textConstraint.MaxTextSize = 22
		textConstraint.MinTextSize = 12
		textConstraint.Parent = text
		text.Parent = button

		-- The button's own text is transparent and stays the source of truth, so
		-- existing `button.Text = ...` updates keep working through this mirror.
		button:GetPropertyChangedSignal("Text"):Connect(function()
			text.Text = button.Text
		end)
	end

	if props.icon ~= nil then
		local image = Instance.new("ImageLabel")
		image.Name = "Icon"
		image.BackgroundTransparency = 1
		image.ImageContent = props.icon
		image.ZIndex = 3
		if iconOnly then
			local roundPx = math.clamp(props.iconSize or math.floor(height * 0.58), 8, math.max(8, height - 8))
			image.Size = UDim2.fromOffset(roundPx, roundPx)
			image.Position = UDim2.fromScale(0.5, 0.5)
			image.AnchorPoint = Vector2.new(0.5, 0.5)
		else
			image.Size = UDim2.fromOffset(iconPx, iconPx)
			image.Position = UDim2.new(0, 4 + (slot - iconPx) / 2, 0.5, 0)
			image.AnchorPoint = Vector2.new(0, 0.5)
		end
		image.Parent = button

		button.MouseEnter:Connect(function()
			TweenService:Create(scale, TweenInfo.new(0.12), { Scale = 1.03 }):Play()
		end)
		button.MouseLeave:Connect(function()
			TweenService:Create(scale, TweenInfo.new(0.12), { Scale = 1 }):Play()
		end)
	end

	button.Activated:Connect(function()
		if props.onClick then
			props.onClick()
		end
	end)

	if props.parent then
		button.Parent = props.parent
	end

	return button
end

function Components.progressBar(theme: Theme, props: ProgressBarProps): (Frame, (number) -> ())
	local track = Instance.new("Frame")
	track.Name = "ProgressBar"
	track.Size = props.size
	track.Position = props.position or UDim2.new()
	track.BackgroundColor3 = color(theme.colors.bg)
	track.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, theme.corner)
	corner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = color(theme.colors.accent)
	fill.BorderSizePixel = 0
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, theme.corner)
	fillCorner.Parent = fill

	local function setProgress(fraction: number)
		fill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
	end

	if props.parent then
		track.Parent = props.parent
	end

	return track, setProgress
end

local KIND_COLORS = {
	good = "good",
	bad = "bad",
}

function Components.toast(theme: Theme, parent: Instance, text: string, kind: string?, seconds: number?)
	-- The toast enters at the parent's own origin and slides out upward on exit. It
	-- used to enter at -60, i.e. already off the top of its region, so a toast was
	-- never visible at all.
	local frame = Components.panel(theme, {
		name = "Toast",
		size = UDim2.fromOffset(320, 48),
		position = UDim2.fromScale(0.5, 0),
	})

	frame.AnchorPoint = Vector2.new(0.5, 0)

	local strokeColorName = KIND_COLORS[kind or ""]
	if strokeColorName then
		local stroke = frame:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = color(theme.colors[strokeColorName])
		end
	elseif kind == "accent" then
		local stroke = frame:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = color(theme.colors.accent)
		end
	end

	Components.label(theme, {
		text = text,
		size = UDim2.fromScale(1, 1),
		textSize = theme.textSizes.small,
		parent = frame,
	})

	frame.Parent = parent

	TweenService:Create(
		frame,
		TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, 0, 0, 20) }
	):Play()

	task.delay(seconds or 3, function()
		local tween = TweenService:Create(frame, TweenInfo.new(0.25), { Position = UDim2.new(0.5, 0, 0, -60) })
		tween.Completed:Connect(function()
			frame:Destroy()
		end)
		tween:Play()
	end)
end

--- Attaches a UIScale that tracks the viewport height. `scaleFor` maps a
--- viewport height to a scale factor; the default shrinks small desktop windows.
--- Pass Layout.uiScaleForViewport to guarantee an absolute-size touch minimum.
function Components.attachScale(screenGui: Instance, scaleFor: ((number) -> number)?): UIScale
	local scale = Instance.new("UIScale")
	scale.Parent = screenGui

	local compute = scaleFor or function(height: number): number
		return math.clamp(height / 900, 0.75, 1.25)
	end

	local camera = workspace.CurrentCamera
	local function update()
		if camera then
			scale.Scale = compute(camera.ViewportSize.Y)
		end
	end

	update()
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(update)
	end

	return scale
end

--- Warns (Studio only) for every visible GuiButton under `root` whose
--- AbsoluteSize is below `minSize` on either axis. `root` is the game's own
--- ScreenGui, so Roblox core GUI is never scanned. Returns the violation count,
--- which lets tests and callers assert on it.
function Components.assertTouchTargets(root: Instance, minSize: number?): number
	-- 44 matches Layout.MIN_TOUCH_TARGET; Components cannot require a ui-kit
	-- sibling because some packs do not mount ui-kit in their sourcemap.
	local minimum = minSize or 44
	if not RunService:IsStudio() then
		return 0
	end

	local function effectivelyVisible(object: GuiObject): boolean
		if not object.Visible then
			return false
		end
		local parent: Instance? = object.Parent
		while parent ~= nil do
			if parent:IsA("GuiObject") and not (parent :: GuiObject).Visible then
				return false
			end
			parent = parent.Parent
		end
		return true
	end

	local violations = 0
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiButton") and effectivelyVisible(descendant) then
			local size = descendant.AbsoluteSize
			-- A 0x0 size means the layout has not run yet; skip instead of warning.
			if (size.X > 0 or size.Y > 0) and (size.X < minimum or size.Y < minimum) then
				violations += 1
				warn(
					string.format(
						"[ui-kit] touch target %s (%s) is %.0fx%.0f, below the %dpx minimum",
						descendant.Name,
						descendant.ClassName,
						size.X,
						size.Y,
						minimum
					)
				)
			end
		end
	end
	return violations
end

return Components
