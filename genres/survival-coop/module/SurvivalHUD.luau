--!strict
local Model = require("./SurvivalHUDModel")
local Locale = require("./SurvivalHUDLocale")
local IconFallback = require("../../../core/ui-kit/IconFallback")
local M = {}

function M.controls(components: any, theme: any, parent: any, fit: ((Instance) -> ())?): any
	local entries: { [string]: any } = {}
	local present: { [string]: boolean } = {}
	local order, scope = 0, ""
	local controls = { parent = parent }
	function controls.begin(section: string)
		present, order, scope = {}, 0, section
	end
	function controls.order(): number
		order += 1
		return order
	end
	function controls.button(id: string, text: string, callback: () -> (), enabled: boolean): any
		local key = scope .. ":" .. id
		present[key] = true
		local entry = entries[key]
		if not entry then
			entry = {}
			entries[key] = entry
			entry.item = components.button(theme, {
				text = text,
				size = UDim2.new(1, -8, 0, 48),
				parent = parent,
				onClick = function()
					if entry.enabled then
						entry.callback()
					end
				end,
			})
		end
		entry.callback, entry.enabled = callback, enabled
		local item = entry.item
		item.Parent = controls.parent or parent
		item.Name, item.Text, item.TextWrapped, item.TextScaled = id, text, true, true
		if fit ~= nil then
			fit(item)
		end
		item.LayoutOrder = controls.order()
		item.Active, item.Selectable, item.AutoButtonColor, item.Interactable = enabled, enabled, enabled, enabled
		item.BackgroundTransparency = if enabled then 0 else 0.7
		return item
	end
	function controls.finish()
		for key, entry in entries do
			if not present[key] then
				entry.enabled = false
				entry.item:Destroy()
				entries[key] = nil
			end
		end
	end
	return controls
end

export type Options = {
	ui: { components: any, grid: any, theme: any },
	content: any,
	icons: any?,
	locale: string?,
	settlementOrigin: Vector3,
	names: { [string]: string }?,
	contextual: boolean?,
}

function M.start(options: Options)
	local Components, Grid, Theme = options.ui.components, options.ui.grid, options.ui.theme
	local players = game:GetService("Players")
	local player = players.LocalPlayer
	local storage = game:GetService("ReplicatedStorage")
	local world = game:GetService("Workspace")
	local tags = game:GetService("CollectionService")
	local input = game:GetService("UserInputService")
	local run = game:GetService("RunService")
	local http = game:GetService("HttpService")
	local action = storage:WaitForChild("ForgeAction") :: RemoteFunction
	local state = storage:WaitForChild("ForgeState") :: RemoteEvent
	local locale = options.locale or player.LocaleId
	local content = options.content
	local contextual = options.contextual == true
	local function t(key: string): string
		local text = Locale.text(locale, key)
		local touchOnly = input.TouchEnabled and not input.KeyboardEnabled
		return if touchOnly then (string.gsub(text, " %[%u%]$", "")) else text
	end
	local function name(id: string): string
		return if options.names and options.names[id] then options.names[id] else t(id)
	end
	local theme = Theme.merge(Theme.default, {
		font = "Gotham",
		colors = {
			bg = { r = 18, g = 28, b = 26 },
			panel = { r = 27, g = 43, b = 40 },
			accent = { r = 67, g = 112, b = 93 },
			text = { r = 240, g = 244, b = 240 },
			onAccent = { r = 240, g = 244, b = 240 },
			muted = { r = 108, g = 148, b = 132 },
		},
	})
	local model = Model.new(tostring(player.UserId), function()
		return http:GenerateGUID(false)
	end)
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "ForgeSurvivalHUD", false, 15
	gui.ScreenInsets, gui.ZIndexBehavior = Enum.ScreenInsets.CoreUISafeInsets, Enum.ZIndexBehavior.Sibling
	local root = Instance.new("Frame")
	root.Name, root.BackgroundTransparency = "SafeArea", 1
	root.Position, root.Size, root.Parent = UDim2.fromOffset(12, 8), UDim2.new(1, -24, 1, -16), gui
	local vitals =
		Components.label(theme, { text = t("loading"), size = UDim2.new(1, 0, 0, 52), parent = root, textSize = 15 })
	vitals.Name = "Vitals"
	vitals.BackgroundColor3, vitals.BackgroundTransparency = Color3.fromRGB(22, 36, 33), 0.08
	pcall(function()
		local vc = Instance.new("UICorner")
		vc.CornerRadius = UDim.new(0, 8)
		vc.Parent = vitals
		local vs = Instance.new("UIStroke")
		vs.Color, vs.Thickness, vs.Transparency = Color3.fromRGB(88, 138, 114), 1.2, 0.25
		vs.Parent = vitals
	end)
	local statBars: { [string]: any } = {}
	for index, stat in { "health", "hunger", "fatigue" } do
		local icon = if options.icons then options.icons.ui(if stat == "hunger" then "energy" else stat) else nil
		-- Keep a localized label underneath the optional asset. Moderated or
		-- unavailable images must not leave the status row unidentified.
		local symbol = Instance.new("TextLabel")
		symbol.Name, symbol.BackgroundTransparency = stat .. "Icon", 1
		symbol.Position, symbol.Size = UDim2.fromOffset(4, 4 + (index - 1) * 23), UDim2.fromOffset(42, 20)
		symbol.Text, symbol.TextColor3, symbol.TextSize = t(stat), Color3.fromRGB(240, 244, 240), 10
		symbol.TextScaled = true
		local textLimit = Instance.new("UITextSizeConstraint")
		textLimit.MinTextSize, textLimit.MaxTextSize, textLimit.Parent = 8, 10, symbol
		if icon and icon.image then
			local image = Instance.new("ImageLabel")
			image.Name, image.BackgroundTransparency = "Asset", 1
			image.Size, image.Position = UDim2.fromOffset(20, 20), UDim2.fromOffset(11, 0)
			image.Image, image.Parent = icon.image, symbol
			local function loaded()
				symbol.TextTransparency = if image.IsLoaded then 1 else 0
			end
			image:GetPropertyChangedSignal("IsLoaded"):Connect(loaded)
			loaded()
		end
		symbol.Parent = vitals
		local track = Instance.new("Frame")
		track.Name, track.BorderSizePixel, track.BackgroundColor3 = stat .. "Track", 0, Color3.fromRGB(45, 62, 56)
		track.Position, track.Size, track.Parent =
			UDim2.fromOffset(50, 10 + (index - 1) * 23), UDim2.new(1, -96, 0, 8), vitals
		local fill = Instance.new("Frame")
		fill.Name, fill.BorderSizePixel = "Fill", 0
		fill.BackgroundColor3 = ({
			health = Color3.fromRGB(107, 207, 142),
			hunger = Color3.fromRGB(232, 190, 97),
			fatigue = Color3.fromRGB(119, 181, 220),
		})[stat]
		fill.Size, fill.Parent = UDim2.fromScale(1, 1), track
		for _, frame in { track, fill } do
			local corner = Instance.new("UICorner")
			corner.CornerRadius, corner.Parent = UDim.new(0, 4), frame
		end
		local value = Components.label(theme, {
			text = "",
			textSize = 11,
			parent = vitals,
			size = UDim2.fromOffset(38, 20),
			position = UDim2.new(1, -42, 0, 4 + (index - 1) * 23),
		})
		statBars[stat] = { fill = fill, value = value }
	end
	local status = Components.label(theme, {
		text = t("loading"),
		size = UDim2.new(1, 0, 0, 64),
		position = UDim2.fromOffset(0, 56),
		parent = root,
		textSize = 14,
	})
	status.Name = "Status"
	status.TextScaled = true
	local statusLimit = Instance.new("UITextSizeConstraint")
	statusLimit.MaxTextSize, statusLimit.MinTextSize, statusLimit.Parent = 14, 8, status
	status.BackgroundColor3, status.BackgroundTransparency = Color3.fromRGB(22, 36, 33), 0.08
	pcall(function()
		local sc = Instance.new("UICorner")
		sc.CornerRadius = UDim.new(0, 8)
		sc.Parent = status
		local ss = Instance.new("UIStroke")
		ss.Color, ss.Thickness, ss.Transparency = Color3.fromRGB(88, 138, 114), 1.2, 0.25
		ss.Parent = status
	end)
	local toolbar = Instance.new("Frame")
	toolbar.Name, toolbar.BackgroundTransparency = "Navigation", 1
	toolbar.Position, toolbar.Size, toolbar.Parent = UDim2.fromOffset(0, 124), UDim2.new(1, 0, 0, 48), root
	local sheet = Components.modalSheet(theme, { name = "SurvivalSheet", title = "", parent = root })
	local function fitText(item: Instance): ()
		local existing = item:FindFirstChild("ForgeTextFit")
		local constraint: UITextSizeConstraint
		if existing ~= nil and existing:IsA("UITextSizeConstraint") then
			constraint = existing
		else
			if existing ~= nil then
				existing:Destroy()
			end
			constraint = Instance.new("UITextSizeConstraint")
			constraint.Name, constraint.Parent = "ForgeTextFit", item
		end
		constraint.MinTextSize, constraint.MaxTextSize = 10, 15
	end
	sheet.frame.Visible = false
	local controls = M.controls(Components, theme, sheet.scroll, fitText)
	sheet.frame.AnchorPoint, sheet.frame.Position = Vector2.new(1, 0), UDim2.new(1, 0, 0, 178)
	sheet.close.Text = "X"
	local panes = Instance.new("Frame")
	panes.Name, panes.BackgroundTransparency = "PanelPanes", 1
	panes.Size, panes.AutomaticSize, panes.Parent = UDim2.new(1, -8, 0, 0), Enum.AutomaticSize.Y, sheet.scroll
	local listPane, detailPane = Instance.new("Frame"), Instance.new("Frame")
	for _, pane in { listPane, detailPane } do
		pane.BackgroundTransparency, pane.AutomaticSize, pane.Parent = 1, Enum.AutomaticSize.Y, panes
		local layout = Instance.new("UIListLayout")
		layout.Padding, layout.SortOrder, layout.Parent = UDim.new(0, 6), Enum.SortOrder.LayoutOrder, pane
	end
	listPane.Name, detailPane.Name = "ItemList", "ItemDetails"
	local function fitPanes()
		local wide = sheet.frame.AbsoluteSize.X >= 600
		listPane.Size = UDim2.new(if wide then 0.52 else 1, if wide then -8 else 0, 0, 0)
		detailPane.Size = UDim2.new(if wide then 0.48 else 1, if wide then -8 else 0, 0, 0)
		detailPane.Position = if wide
			then UDim2.new(0.52, 8, 0, 0)
			else UDim2.fromOffset(0, listPane.AbsoluteSize.Y + 12)
	end
	listPane:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitPanes)
	sheet.frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitPanes)
	fitPanes()
	local contentParent = sheet.scroll
	local capacityTrack = Instance.new("Frame")
	capacityTrack.Name, capacityTrack.BorderSizePixel = "CapacityBar", 0
	capacityTrack.Size, capacityTrack.BackgroundColor3 = UDim2.new(1, -8, 0, 8), Color3.fromRGB(45, 62, 56)
	capacityTrack.Parent = listPane
	local capacityFill = Instance.new("Frame")
	capacityFill.Name, capacityFill.BorderSizePixel = "Fill", 0
	capacityFill.BackgroundColor3, capacityFill.Parent = Color3.fromRGB(127, 224, 156), capacityTrack
	local section, selected, recipeId, structureId = "", nil, nil, nil
	local buildCards = Instance.new("Frame")
	buildCards.Name, buildCards.BackgroundTransparency = "BuildCards", 1
	buildCards.Size, buildCards.AutomaticSize, buildCards.Parent =
		UDim2.new(1, -8, 0, 0), Enum.AutomaticSize.Y, sheet.scroll
	local buildLayout = Instance.new("UIGridLayout")
	buildLayout.CellPadding, buildLayout.SortOrder, buildLayout.Parent =
		UDim2.fromOffset(8, 8), Enum.SortOrder.LayoutOrder, buildCards
	local function fitBuildCards()
		local columns = if sheet.frame.AbsoluteSize.X >= 600 then 3 else 2
		local rows = 1
		for _, definition in content.structures do
			rows = math.max(rows, #definition.cost)
		end
		buildLayout.CellSize = UDim2.new(1 / columns, -8, 0, 44 + rows * 40)
	end
	sheet.frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitBuildCards)
	fitBuildCards()
	local missingText: string? = nil
	local toast = Components.label(theme, {
		text = "",
		size = UDim2.new(1, -24, 0, 64),
		position = UDim2.new(0, 12, 1, -140),
		parent = gui,
	})
	toast.Name, toast.Visible = "MaterialToast", false
	toast.BackgroundColor3, toast.BackgroundTransparency = Color3.fromRGB(22, 36, 33), 0.08
	local function suppliesAvailable(bag: any, inputs: { any }): boolean
		local missing = Model.missingMaterials(bag, inputs)
		local details = {}
		for _, ingredient in missing do
			table.insert(details, name(ingredient.id) .. " " .. ingredient.available .. "/" .. ingredient.needed)
		end
		missingText = if #details > 0 then t("missing") .. ": " .. table.concat(details, ", ") else nil
		toast.Text, toast.Visible = missingText or "", missingText ~= nil
		return missingText == nil
	end
	local helpVisible = false
	local inventoryGrid: any = nil
	local x, z, rotation = 1, 1, 0
	local disposed, refreshing = false, false
	local connections: { RBXScriptConnection } = {}
	local ghost = Instance.new("Folder")
	ghost.Name, ghost.Parent = "ForgeBuildPreview", world
	local highlight = Instance.new("Highlight")
	highlight.Name, highlight.FillTransparency, highlight.OutlineColor =
		"ForgeTarget", 0.85, Color3.fromRGB(219, 229, 155)
	highlight.DepthMode, highlight.Parent = Enum.HighlightDepthMode.Occluded, world
	highlight.Enabled = false
	local resultEvent = Instance.new("BindableEvent")
	resultEvent.Name, resultEvent.Parent = "ForgeHUDResult", player
	local requestEvent = Instance.new("BindableEvent")
	requestEvent.Name, requestEvent.Parent = "ForgeHUDRequested", player
	local render: () -> ()
	local refresh: () -> ()
	local handshakeRetries = 0
	local function send(request: any)
		if not request then
			render()
			return
		end
		render()
		task.spawn(function()
			local ok, result = pcall(function()
				local envelope = game:GetService("HttpService")
					:JSONDecode(game:GetService("HttpService"):JSONEncode(request))
				local function freeze(value)
					if type(value) == "table" then
						for _, child in value do
							freeze(child)
						end
						table.freeze(value)
					end
				end
				freeze(envelope)
				local observed = table.freeze({
					requestId = request.requestId,
					action = request.action,
					envelope = envelope,
					actorId = tostring(player.UserId),
					serverTime = world:GetServerTimeNow(),
				})
				requestEvent:Fire(observed)
				if game:GetService("RunService"):IsStudio() then
					local gate = player:FindFirstChild("ForgeOwnedDispatchGate")
					if gate and gate:IsA("BindableFunction") then
						assert(gate:Invoke(observed) == true, "OWNED_DISPATCH_NOT_RELEASED")
					end
				end
				return action:InvokeServer("command", request)
			end)
			if disposed then
				return
			end
			model.finish(ok, result)
			resultEvent:Fire({ request = request, result = result, status = model.status })
			render()
			refresh()
		end)
	end
	local function command(verb: string, args: { any })
		send(model.begin(verb, args))
	end
	local function nearest(kind: string?): BasePart?
		local character = player.Character
		local pivot = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if not pivot or not pivot:IsA("BasePart") then
			return nil
		end
		local best: BasePart? = nil
		local distance = 12
		for _, part in tags:GetTagged("ForgeSurvivalStation") do
			if
				part:IsA("BasePart")
				and part:IsDescendantOf(world)
				and (not kind or part:GetAttribute("ForgeStationKind") == kind)
			then
				local d = (part.Position - pivot.Position).Magnitude
				if d < distance then
					best, distance = part, d
				end
			end
		end
		return best
	end
	local function rest()
		if model.pending then
			send(model.retry())
			return
		end
		if not model.durable or not table.find(model.durable.actions, "survival-coop:rest") then
			model.status, model.reason = "conflict", "HANDSHAKE_FAILED"
			render()
			return
		end
		local fire = nearest("campfire")
		if fire then
			command("rest", { fire:GetAttribute("ForgeStationId") })
		else
			model.status, model.reason = "conflict", "CAMPFIRE_UNREACHABLE"
			render()
		end
	end
	local function attack()
		if model.pending then
			send(model.retry())
			return
		end
		if not model.durable or not table.find(model.durable.actions, "survival-coop:attack") then
			return
		end
		local character = player.Character
		local pivot = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if not pivot or not pivot:IsA("BasePart") then
			return
		end
		local target: string? = nil
		local targetPos: Vector3? = nil
		local distance = 8
		for _, instance in world:GetDescendants() do
			local id = instance:GetAttribute("ForgeWildlifeId")
			local hp = instance:GetAttribute("ForgeWildlifeHealthMilli")
			if instance:IsA("Model") and type(id) == "string" and (type(hp) ~= "number" or hp > 0) then
				local rootPart = instance:FindFirstChild("HumanoidRootPart")
				if rootPart and rootPart:IsA("BasePart") then
					local offset = rootPart.Position - pivot.Position
					local d = offset.Magnitude
					if d < distance then
						target, targetPos, distance = id, rootPart.Position, d
					end
				end
			end
		end
		if target and targetPos then
			local flat = Vector3.new(targetPos.X - pivot.Position.X, 0, targetPos.Z - pivot.Position.Z)
			if flat.Magnitude > 0.001 then
				pivot.CFrame = CFrame.lookAt(pivot.Position, pivot.Position + flat)
			end
			command("attack", { target })
		else
			model.status, model.reason = "conflict", "WILDLIFE_UNREACHABLE"
			render()
		end
	end
	local notePool: { TextLabel } = {}
	local noteUsed = 0
	local function label(text: string, height: number?): TextLabel
		noteUsed += 1
		local pooled: TextLabel? = notePool[noteUsed]
		local item: TextLabel
		if pooled == nil then
			item = Components.label(
				theme,
				{ text = text, size = UDim2.new(1, -8, 0, height or 48), parent = sheet.scroll, textSize = 15 }
			)
			item.TextXAlignment = Enum.TextXAlignment.Left
			notePool[noteUsed] = item
		else
			item = pooled
		end
		item.Name = "Note" .. noteUsed
		item.Parent = contentParent
		item.Text = text
		item.Size = UDim2.new(1, -8, 0, height or 48)
		item.LayoutOrder = controls.order()
		item.Visible = true
		item:SetAttribute("FinishAt", nil)
		item:SetAttribute("JobLabel", nil)
		local icon = item:FindFirstChild("ItemIcon")
		if icon then
			(icon :: ImageLabel).Visible = false
		end
		local fallback = item:FindFirstChild("IconFallback")
		if fallback then
			(fallback :: Frame).Visible = false
		end
		for _, childName in { "RowName", "RowCount" } do
			local child = item:FindFirstChild(childName)
			if child then
				(child :: TextLabel).Visible = false
			end
		end
		local padding = item:FindFirstChild("IconPadding")
		if padding then
			(padding :: UIPadding).PaddingLeft = UDim.new(0, 0)
		end
		return item
	end
	local focusId: string? = nil
	local focusBottom: string? = nil
	local function button(id: string, text: string, callback: () -> (), enabled: boolean?)
		return controls.button(id, text, callback, enabled ~= false)
	end
	local function mutation(id: string, text: string, verb: string, callback: () -> ())
		local policy = model.durable
		local enabled = policy and table.find(policy.actions, "survival-coop:" .. verb) ~= nil and model.pending == nil
		return button(id, text, callback, enabled == true)
	end
	local function itemIcon(item: any, icon: any)
		icon = icon or {}
		IconFallback.mount(item, icon.category, UDim2.fromOffset(28, 28), UDim2.fromOffset(4, 6), icon.image)
		local padding = item:FindFirstChild("IconPadding") or Instance.new("UIPadding")
		padding.Name, padding.PaddingLeft, padding.Parent = "IconPadding", UDim.new(0, 40), item
		-- Padding affects child coordinates too; keep the glyph inside the row.
		item:FindFirstChild("IconFallback").Position = UDim2.fromOffset(-36, 6)
	end
	local function materialRow(id: string, available: number?, needed: number, parent: any?): any
		local row = if parent
			then parent:FindFirstChild("Cost-" .. id) or Components.label(
				theme,
				{ text = "", parent = parent, size = UDim2.new(1, -8, 0, 40) }
			)
			else label("", 40)
		if parent then
			row.Name = "Cost-" .. id
		end
		itemIcon(row, if options.icons then options.icons.item(id) else nil)
		local specs: { { any } } = {
			{ "RowName", name(id), UDim2.new(1, -72, 1, 0), UDim2.fromOffset(0, 0) },
			{
				"RowCount",
				(if available then available .. "/" else "") .. needed,
				UDim2.fromOffset(68, 40),
				UDim2.new(1, -68, 0, 0),
			},
		}
		for _, spec in specs do
			local text = row:FindFirstChild(spec[1])
				or Components.label(theme, { text = "", parent = row, textSize = 12, size = spec[3] })
			text.Name, text.Text, text.Size, text.Position, text.Visible = spec[1], spec[2], spec[3], spec[4], true
			text.TextXAlignment = if spec[1] == "RowCount" then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left
			text.TextScaled, text.TextWrapped = true, true
			fitText(text)
			text.TextColor3 = if available and available < needed
				then Color3.fromRGB(255, 155, 132)
				else Color3.fromRGB(127, 224, 156)
		end
		return row
	end
	local function selectedDefinition(): any
		for _, definition in options.content.structures do
			if definition.id == structureId then
				return definition
			end
		end
		return nil
	end
	local placementReason: string? = nil
	local function preview()
		ghost:ClearAllChildren()
		placementReason = nil
		local definition, settlement = selectedDefinition(), model.snapshot.settlement
		if section ~= "build" or not definition or not settlement then
			return
		end
		for _, entry in Model.placements(settlement, model.actor) do
			if entry.placement.definition.id == structureId then
				x, z, rotation = entry.placement.x, entry.placement.z, entry.placement.rotation
				break
			end
		end
		local placement, reason = Model.preview(model.snapshot, model.actor, definition, x, z, rotation)
		placementReason = reason
		local cells: { any } = if placement then table.clone(placement.cells) else {}
		if not placement then
			for dx = 0, definition.footprintX - 1 do
				for dz = 0, definition.footprintZ - 1 do
					local a, b = dx, dz
					for _ = 1, rotation do
						a, b = -b, a
					end
					table.insert(cells, { x = x + a, z = z + b })
				end
			end
		end
		local size = settlement.config.cellStuds
		local lowX, lowZ, highX, highZ = math.huge, math.huge, -math.huge, -math.huge
		for _, cell in cells do
			lowX, lowZ = math.min(lowX, cell.x), math.min(lowZ, cell.z)
			highX, highZ = math.max(highX, cell.x), math.max(highZ, cell.z)
		end
		local at = options.settlementOrigin
			+ Vector3.new((lowX + highX + 1) * size / 2, 0, (lowZ + highZ + 1) * size / 2)
		local params = RaycastParams.new()
		params.FilterType, params.FilterDescendantsInstances = Enum.RaycastFilterType.Include, { world.Terrain }
		local hit = world:Raycast(at + Vector3.new(0, 128, 0), Vector3.new(0, -256, 0), params)
		if hit then
			at = Vector3.new(at.X, hit.Position.Y + 0.2, at.Z)
		end
		local kits = storage:FindFirstChild("ForgeStructureKits")
		local kit = if kits then kits:FindFirstChild(definition.id) else nil
		if kit then
			local visual = kit:Clone()
			for _, item in visual:GetDescendants() do
				if item:IsA("BasePart") then
					item.Color = if reason then Color3.fromRGB(240, 72, 65) else Color3.fromRGB(65, 230, 120)
					item.Transparency, item.Material = 0.45, Enum.Material.Neon
					item.CanCollide, item.CanTouch, item.CanQuery = false, false, false
				elseif item:IsA("Fire") or item:IsA("Light") then
					item:Destroy()
				end
			end
			visual:PivotTo(CFrame.new(at) * CFrame.Angles(0, -rotation * math.pi / 2, 0))
			visual.Parent = ghost
			local outline = Instance.new("Highlight")
			outline.Adornee, outline.FillTransparency, outline.OutlineTransparency = visual, 0.7, 0
			outline.FillColor = if reason then Color3.fromRGB(240, 72, 65) else Color3.fromRGB(65, 230, 120)
			outline.OutlineColor, outline.Parent = outline.FillColor, visual
		end
		local entryX, entryZ = 0, -1
		for _ = 1, rotation do
			entryX, entryZ = -entryZ, entryX
		end
		table.insert(cells, { x = x + entryX, z = z + entryZ, entry = true })
		for _, cell in cells do
			local part = Instance.new("Part")
			part.Name, part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery =
				"Footprint", true, false, false, false
			part.Size = Vector3.new(size - 0.1, 0.15, size - 0.1)
			if cell.entry then
				part.Name = "Entry"
				part.Size *= 0.6
			end
			part.Position = Vector3.new(
				options.settlementOrigin.X + (cell.x + 0.5) * size,
				at.Y + 0.15,
				options.settlementOrigin.Z + (cell.z + 0.5) * size
			)
			part.Color = if reason then Color3.fromRGB(223, 99, 85) else Color3.fromRGB(141, 201, 149)
			part.Transparency, part.Material, part.Parent = 0.4, Enum.Material.Neon, ghost
		end
	end
	-- ZIndex only orders siblings inside one ScreenGui. Placement must also sit
	-- above the dock (DisplayOrder 30) and extension sheets (DisplayOrder 20).
	local placementGui = Instance.new("ScreenGui")
	placementGui.Name, placementGui.ResetOnSpawn, placementGui.DisplayOrder = "ForgePlacementHUD", false, 40
	placementGui.ScreenInsets, placementGui.ZIndexBehavior = gui.ScreenInsets, gui.ZIndexBehavior
	placementGui.Parent = player:WaitForChild("PlayerGui")
	local placementBar = Instance.new("Frame")
	placementBar.Name, placementBar.BackgroundTransparency = "PlacementControls", 1
	-- The placement overlay must win hit testing over the modal sheet (50..52).
	placementBar.ZIndex = sheet.frame.ZIndex + 3
	placementBar.Size, placementBar.Position = UDim2.fromOffset(272, 48), UDim2.new(0.5, -136, 1, -72)
	placementBar.Parent, placementBar.Visible = placementGui, false
	local blocked = Components.label(theme, {
		text = "",
		parent = placementBar,
		size = UDim2.fromOffset(328, 52),
		position = UDim2.fromOffset(0, -60),
		textSize = 14,
	})
	blocked.Name, blocked.TextWrapped = "PlacementReason", true
	local function placeSelected()
		local settlement, warehouse = model.snapshot.settlement, model.snapshot.warehouse
		if not settlement or not warehouse or model.pending then
			return
		end
		for _, entry in Model.placements(settlement, model.actor) do
			if entry.placement.definition.id == structureId then
				command("settlement-place", { entry.id, settlement.version, warehouse.version })
				return
			end
		end
		local definition = selectedDefinition()
		if definition and suppliesAvailable(warehouse, definition.cost) then
			local args = Model.buildArgs(model.snapshot, definition, x, z, rotation)
			if args then
				command("settlement-reserve", args)
			end
		end
	end
	local confirmPlacement = Components.button(theme, {
		text = t("place"),
		parent = placementBar,
		size = UDim2.fromOffset(132, 48),
		onClick = placeSelected,
	})
	confirmPlacement.Name = "ConfirmPlacement"
	local cancelPlacement = Components.button(theme, {
		text = t("cancel"),
		parent = placementBar,
		size = UDim2.fromOffset(132, 48),
		position = UDim2.fromOffset(140, 0),
		onClick = function()
			local settlement, warehouse = model.snapshot.settlement, model.snapshot.warehouse
			if settlement and warehouse and not model.pending then
				for _, entry in Model.placements(settlement, model.actor) do
					if entry.placement.definition.id == structureId then
						command("settlement-cancel", { entry.id, settlement.version, warehouse.version })
					end
				end
			end
			structureId = nil
			preview()
			placementBar.Visible = false
			sheet.frame.Visible = true
			render()
		end,
	})
	cancelPlacement.Name = "CancelPlacement"
	local rotatePlacement = Components.button(theme, {
		text = t("rotate"),
		parent = placementBar,
		size = UDim2.fromOffset(80, 48),
		position = UDim2.fromOffset(0, 0),
		onClick = function()
			rotation = (rotation + 1) % 4
			render()
		end,
	})
	rotatePlacement.Name = "RotatePlacement"
	for _, control in { confirmPlacement, cancelPlacement, rotatePlacement } do
		control.ZIndex = placementBar.ZIndex + 1
	end
	placementBar.Size, placementBar.Position = UDim2.fromOffset(328, 48), UDim2.new(0.5, -164, 1, -72)
	confirmPlacement.Size, confirmPlacement.Position = UDim2.fromOffset(116, 48), UDim2.fromOffset(88, 0)
	cancelPlacement.Size, cancelPlacement.Position = UDim2.fromOffset(116, 48), UDim2.fromOffset(212, 0)
	toast.Size, toast.Position = UDim2.new(1, -24, 0, 52), UDim2.new(0, 12, 1, -184)
	table.insert(
		connections,
		input.InputChanged:Connect(function(event, processed)
			if processed or section ~= "build" or not structureId then
				return
			end
			local p, s = placementBar.AbsolutePosition, placementBar.AbsoluteSize
			if Model.overPlacementBar(event.Position.X, event.Position.Y, p, s) then
				return
			end
			if
				event.UserInputType ~= Enum.UserInputType.MouseMovement
				and event.UserInputType ~= Enum.UserInputType.Touch
			then
				return
			end
			local camera, settlement = world.CurrentCamera, model.snapshot.settlement
			if not camera or not settlement then
				return
			end
			for _, entry in Model.placements(settlement, model.actor) do
				if entry.placement.definition.id == structureId then
					return
				end
			end
			local ray = camera:ScreenPointToRay(event.Position.X, event.Position.Y)
			if math.abs(ray.Direction.Y) < 0.001 then
				return
			end
			local distance = (options.settlementOrigin.Y - ray.Origin.Y) / ray.Direction.Y
			if distance < 0 then
				return
			end
			local hit = ray.Origin + ray.Direction * distance
			local nextX, nextZ = Model.pointerCell(
				hit.X,
				hit.Z,
				options.settlementOrigin.X,
				options.settlementOrigin.Z,
				settlement.config
			)
			if nextX ~= x or nextZ ~= z then
				x, z = nextX, nextZ
				preview()
				blocked.Text = if placementReason then Locale.refusal(locale, placementReason) else ""
			end
		end)
	)
	render = function()
		if disposed then
			return
		end
		placementBar.Visible = section == "build" and structureId ~= nil
		-- Placement is a world interaction, not a control floating over the scrolling
		-- catalog. Remove the catalog from input routing for the entire placement phase.
		if section == "build" then
			sheet.frame.Visible = structureId == nil
		end
		confirmPlacement.Interactable = model.pending == nil
		local reservedPlacement = false
		if model.snapshot.settlement then
			for _, entry in Model.placements(model.snapshot.settlement, model.actor) do
				reservedPlacement = reservedPlacement or entry.placement.definition.id == structureId
			end
		end
		confirmPlacement.Text = t(if reservedPlacement then "place" else "reserve")
		local v = model.snapshot.vitals
		vitals.Visible = v ~= nil
		vitals.Text = ""
		if v then
			for stat, bar in statBars do
				local amount = v[stat .. "Milli"] / 1000
				bar.fill.Size = UDim2.fromScale(math.clamp(amount / 100, 0, 1), 1)
				bar.value.Text = tostring(math.floor(amount))
			end
		end
		status.Text = t(model.status) .. (if model.reason then "\n" .. Locale.refusal(locale, model.reason) else "")
		if contextual then
			status.Visible = model.status == "conflict" or model.status == "pending"
		end
		local scrollPosition = sheet.scroll.CanvasPosition
		controls.begin(section)
		noteUsed = 0
		panes.Visible = section == "bag" or section == "craft"
		buildCards.Visible = section == "build"
		capacityTrack.Visible = section == "bag"
		panes.LayoutOrder = 1
		contentParent = if panes.Visible then listPane else sheet.scroll
		controls.parent = contentParent
		if inventoryGrid then
			inventoryGrid.frame.Visible = section == "bag"
		end
		if model.pending then
			button("Retry", t("retry"), function()
				send(model.retry())
			end, not model.busy)
		end
		if model.reason then
			label(Locale.refusal(locale, model.reason), 100)
		end
		local bag = Model.bag(model.snapshot)
		if section == "bag" then
			if bag then
				local slots, maximum, weight, hard = Model.capacity(bag)
				capacityFill.Size = UDim2.fromScale(
					math.clamp(math.max(slots / math.max(1, maximum), weight / math.max(1, hard)), 0, 1),
					1
				)
				capacityTrack.LayoutOrder = controls.order()
				label(
					string.format(
						"%s %d/%d   %s %.1f/%.1f",
						t("slots"),
						slots,
						maximum,
						t("weight"),
						weight / 1000,
						hard / 1000
					)
				)
				if weight > bag.limits.softWeightMilli then
					label(t("slow"))
				end
				local rows = Model.items(bag)
				if selected == nil or bag.items[selected] == nil then
					selected = if rows[1] then rows[1].item.itemId else nil
				end
				local display = {}
				for _, row in rows do
					table.insert(display, {
						id = row.item.itemId,
						image = if options.icons then options.icons.item(row.item.catalogId).image else nil,
						text = name(row.item.catalogId),
						category = if options.icons then options.icons.item(row.item.catalogId).category else "item",
						quantity = row.item.quantity,
					})
				end
				if not inventoryGrid then
					inventoryGrid = Grid.new(listPane, theme, function(id)
						selected = id
						focusBottom = "Deposit-" .. id
						render()
					end)
				end
				local grid = inventoryGrid
				grid.frame.LayoutOrder = controls.order()
				grid.update(display, selected)
				if #rows == 0 then
					label(t("empty"))
				end
				local item = if selected then bag.items[selected] else nil
				contentParent, controls.parent = detailPane, detailPane
				if item then
					label(
						name(item.catalogId)
							.. "\n"
							.. t("quality")
							.. " "
							.. item.qualityMilli / 1000
							.. "  "
							.. t("durability")
							.. " "
							.. item.durabilityMilli / 1000,
						64
					)
					for _, definition in options.content.items do
						if definition.id == item.catalogId and definition.foodEffects then
							mutation("Eat-" .. item.itemId, t("eat"), "food", function()
								command("food", { item.itemId })
							end)
						end
					end
					mutation("Deposit-" .. item.itemId, t("deposit"), "transfer-deposit", function()
						command("transfer-deposit", { item.itemId, 1 })
					end)
				else
					label(t("select"))
				end
			end
			label(t("warehouse"))
			for _, row in Model.items(model.snapshot.warehouse) do
				mutation(
					"Withdraw-" .. row.item.itemId,
					t("withdraw") .. " - " .. name(row.item.catalogId) .. " x" .. row.available,
					"transfer-withdraw",
					function()
						command("transfer-withdraw", { row.item.itemId, 1 })
					end
				)
			end
		elseif section == "skills" then
			local progression = model.snapshot.progression
			if progression then
				label("Level " .. tostring(progression.level) .. " / SP " .. tostring(progression.sp), 40)
				button("skill-reset", t("skill_reset"), function()
					command("skill-reset", { progression.version })
				end, true)
				for _, node in content.skillNodes or {} do
					local learned = progression.paid[node.id] ~= nil
					button("learn-" .. node.id, node.id .. " / " .. tostring(node.cost) .. " SP", function()
						command("skill-learn", { node.id })
					end, not learned)
				end
			end
		elseif section == "craft" then
			local orderedRecipes = Model.recipeOrder(bag, options.content.recipes, function(station)
				return nearest(station) ~= nil
			end, options.content.items)
			local activeJobs = Model.jobs(model.snapshot, model.actor)
			if recipeId == nil and orderedRecipes[1] then
				recipeId = orderedRecipes[1].recipe.id
			end
			local renderedJobs = false
			local function renderJobs()
				if renderedJobs then
					return
				end
				renderedJobs = true
				label(t("jobs"))
				for _, entry in activeJobs do
					local job = entry.job
					local timer = label(name(job.recipeId) .. " - " .. t(job.state), 64)
					if job.finishAt then
						timer:SetAttribute("FinishAt", job.finishAt)
						timer:SetAttribute("JobLabel", timer.Text)
					end
					local verb = if job.state == "Reserved" then "start" else "complete"
					mutation(verb .. "-" .. entry.id, t(verb), "craft-" .. verb, function()
						command("craft-" .. verb, { entry.id })
					end)
					mutation("cancel-" .. entry.id, t("cancel"), "craft-cancel", function()
						command("craft-cancel", { entry.id })
					end)
				end
			end
			if recipeId == nil and #activeJobs > 0 then
				renderJobs()
			end
			local lastStation = nil
			for _, row in orderedRecipes do
				contentParent, controls.parent = listPane, listPane
				local recipe = row.recipe
				if lastStation ~= row.station then
					lastStation = row.station
					label(if recipe.station then name(recipe.station) else t("hand"), 32)
				end
				local recipeButton = button(
					"Recipe-" .. recipe.id,
					name(recipe.id)
						.. "\n"
						.. (
							if row.ready
								then t("reserve") .. " +"
								elseif not row.stationReady then t("station") .. ": " .. name(row.station)
								else t("missing")
						),
					function()
						recipeId = recipe.id
						focusBottom = "Reserve-" .. recipe.id
						render()
					end
				)
				if options.icons then
					local icon = options.icons.recipe(recipe.id)
					itemIcon(recipeButton, if icon.image then icon else options.icons.item(recipe.outputs[1].item))
				end
				if recipe.id == recipeId then
					contentParent, controls.parent = detailPane, detailPane
					label(name(recipe.id), 36)
					label(t("inputs"))
					for _, ingredient in Model.ingredients(bag, recipe) do
						materialRow(ingredient.id, ingredient.available, ingredient.needed)
					end
					label(t("outputs"), 32)
					for _, item in recipe.outputs do
						materialRow(item.item, nil, item.quantity)
					end
					label(recipe.craftMillis / 1000 .. "s", 24)
					label(
						t("station")
							.. ": "
							.. (if recipe.station then name(recipe.station) else t("hand"))
							.. (
								if recipe.requiredToolTag
									then "\n" .. t("tool") .. ": " .. name(recipe.requiredToolTag)
									else ""
							),
						48
					)
					mutation("Reserve-" .. recipe.id, t("reserve"), "craft-reserve", function()
						if not suppliesAvailable(Model.bag(model.snapshot), recipe.inputs) then
							return
						end
						local station = if recipe.station then nearest(recipe.station) else nil
						if recipe.station and not station then
							model.status, model.reason = "conflict", "STATION_UNAVAILABLE"
							render()
							return
						end
						command(
							"craft-reserve",
							{ recipe.id, if station then station:GetAttribute("ForgeStationId") else "hand" }
						)
					end)
					renderJobs()
				end
			end
			renderJobs()
		elseif section == "build" then
			label(t("buildHint"), 48)
			buildCards.LayoutOrder = controls.order()
			local STRUCTURE_PRIORITY: { [string]: number } = {
				["floor"] = 1,
				["campfire"] = 2,
				["workbench"] = 3,
				["storage"] = 4,
				["roof"] = 5,
			}
			local orderedStructures: { any } = table.clone(options.content.structures)
			table.sort(orderedStructures, function(a: any, b: any)
				local pa = STRUCTURE_PRIORITY[a.id] or 10
				local pb = STRUCTURE_PRIORITY[b.id] or 10
				if pa ~= pb then
					return pa < pb
				end
				return a.id < b.id
			end)
			for _, definition in orderedStructures do
				controls.parent = buildCards
				local card = button("Structure-" .. definition.id, "", function()
					structureId = definition.id
					focusBottom = "BuildReserve-" .. definition.id
					render()
				end, true)
				IconFallback.mount(card, "building", UDim2.fromOffset(28, 28), UDim2.fromOffset(6, 6), nil)
				local title = card:FindFirstChild("StructureName")
					or Components.label(
						theme,
						{ text = "", parent = card, textSize = 12, size = UDim2.new(1, -44, 0, 40) }
					)
				title.Name, title.Text = "StructureName", name(definition.id)
				title.Size, title.Position = UDim2.new(1, -44, 0, 40), UDim2.fromOffset(40, 0)
				title.TextScaled, title.TextWrapped = true, true
				fitText(title)
				for index, cost in Model.ingredients(model.snapshot.warehouse, { inputs = definition.cost }) do
					local chip = materialRow(cost.id, cost.available, cost.needed, card)
					chip.Position = UDim2.fromOffset(4, 42 + (index - 1) * 40)
					chip.BackgroundTransparency = 0.25
				end
			end
			controls.parent = sheet.scroll
			local definition = selectedDefinition()
			if definition then
				label(t("placementHint"))
				local _, reason = Model.preview(model.snapshot, model.actor, definition, x, z, rotation)
				label(
					name(definition.id)
						.. "  ("
						.. x
						.. ", "
						.. z
						.. ")  "
						.. rotation * 90
						.. "\n"
						.. (if reason then Locale.refusal(locale, reason) else t("preview")),
					48
				)
				for _, cost in definition.cost do
					label(name(cost.item) .. " x" .. cost.quantity)
				end
			end
			local settlement, warehouse = model.snapshot.settlement, model.snapshot.warehouse
			if settlement and warehouse then
				for _, entry in Model.placements(settlement, model.actor) do
					local id, placement = entry.id, entry.placement
					label(name(placement.definition.id) .. " - " .. t("Reserved"))
					for _, verb in { "place", "cancel" } do
						mutation(verb .. "-" .. id, t(verb), "settlement-" .. verb, function()
							command("settlement-" .. verb, { id, settlement.version, warehouse.version })
						end)
					end
				end
			end
		end
		if section ~= "bag" then
			button("Refresh", t("refresh"), refresh)
			button("CameraHelp", t("cameraHelp"), function()
				helpVisible = not helpVisible
				render()
			end)
			if helpVisible then
				label(t("cameraHint"), 100)
			end
		end
		fitPanes()
		controls.finish()
		for index = noteUsed + 1, #notePool do
			notePool[index].Visible = false
		end
		sheet.scroll.CanvasPosition = scrollPosition
		local focused = if focusId then sheet.scroll:FindFirstChild(focusId) else nil
		focusId = nil
		if focused and focused:IsA("GuiObject") then
			sheet.scroll.CanvasPosition = Vector2.new(
				0,
				math.max(0, scrollPosition.Y + focused.AbsolutePosition.Y - sheet.scroll.AbsolutePosition.Y - 8)
			)
		end
		local bottom = if focusBottom then sheet.scroll:FindFirstChild(focusBottom) else nil
		focusBottom = nil
		if bottom and bottom:IsA("GuiObject") then
			local overflow = bottom.AbsolutePosition.Y
				+ bottom.AbsoluteSize.Y
				- (sheet.scroll.AbsolutePosition.Y + sheet.scroll.AbsoluteSize.Y)
				+ 8
			if overflow > 0 then
				sheet.scroll.CanvasPosition = sheet.scroll.CanvasPosition + Vector2.new(0, overflow)
			end
		end
		preview()
		blocked.Text = if placementReason then Locale.refusal(locale, placementReason) else ""
	end
	refresh = function()
		if disposed or refreshing then
			return
		end
		refreshing = true
		task.spawn(function()
			local ok, result = pcall(function()
				return action:InvokeServer()
			end)
			refreshing = false
			if disposed then
				return
			end
			if ok and result.ok then
				model.receive(result)
				handshakeRetries = 0
			elseif model.durable == nil and handshakeRetries < 8 then
				handshakeRetries += 1
				task.delay(math.min(8, handshakeRetries), function()
					refresh()
				end)
				return
			else
				model.status, model.reason = "conflict", "HANDSHAKE_FAILED"
			end
			render()
		end)
	end
	local function open(key: string)
		section = if section == key then "" else key
		sheet.frame.Visible = section ~= ""
		local title = sheet.frame:WaitForChild("Header"):WaitForChild("Title") :: TextLabel
		title.Text = t(key)
		sheet.scroll.CanvasPosition = Vector2.zero
		render()
	end
	if content.progressionPolicy and not contextual then
		local skillsButton = Components.button(theme, {
			text = t("skills"),
			parent = root,
			size = UDim2.fromOffset(160, 48),
			position = UDim2.new(1, -168, 0, 240),
			onClick = function()
				open("skills")
			end,
		})
		skillsButton.Name = "Skills"
	end
	local tabs: { [string]: TextButton } = {}
	for index, key in { "bag", "craft", "build" } do
		local tab = Components.button(theme, {
			text = t(key),
			size = UDim2.new(1 / 3, -4, 1, 0),
			position = UDim2.fromScale((index - 1) / 3, 0),
			parent = toolbar,
			onClick = function()
				open(key)
			end,
		})
		tab.Name = "Tab-" .. key
		fitText(tab)
		tabs[key] = tab
	end
	local restButton = Components.button(theme, {
		text = t("rest"),
		size = UDim2.new(1, 0, 0, 48),
		position = UDim2.new(0, 0, 1, -48),
		parent = root,
		onClick = rest,
	})
	restButton.Name, restButton.TextSize = "Rest", 15
	fitText(restButton)
	local attackButton = Components.button(theme, {
		text = t("attack"),
		size = UDim2.fromOffset(320, 48),
		parent = root,
		onClick = attack,
	})
	attackButton.Name, attackButton.AnchorPoint = "Attack", Vector2.new(1, 0)
	fitText(attackButton)
	attackButton.Visible = false
	local defenseButtons: { [string]: TextButton } = {}
	for index, defenseAction in { "dodge", "guard" } do
		local defenseButton = Components.button(theme, {
			text = t(defenseAction),
			size = UDim2.fromOffset(76, 48),
			position = UDim2.new(1, -index * 84, 0, 184),
			parent = root,
			onClick = function()
				command(defenseAction, {})
			end,
		})
		defenseButton.Name = defenseAction
		defenseButton.Visible = content.progressionPolicy ~= nil and content.progressionPolicy.combat ~= nil
		defenseButtons[defenseAction] = defenseButton
	end
	local restPrompt: BillboardGui? = nil
	local combatPrompt: BillboardGui? = nil
	if contextual then
		local restCard = Instance.new("BillboardGui")
		restCard.Name, restCard.Size = "RestInteraction", UDim2.fromOffset(132, 48)
		restCard.Active = true
		restCard.StudsOffset, restCard.AlwaysOnTop = Vector3.new(0, 3, 0), true
		restCard.Parent = gui
		restButton.Parent, restButton.AnchorPoint = restCard, Vector2.zero
		restButton.Position, restButton.Size = UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1)
		restPrompt = restCard
		local combatCard = Instance.new("BillboardGui")
		combatCard.Name, combatCard.Size = "CombatInteraction", UDim2.fromOffset(216, 104)
		combatCard.Active = true
		combatCard.StudsOffset, combatCard.AlwaysOnTop = Vector3.new(0, 4, 0), true
		combatCard.Parent = gui
		attackButton.Parent, attackButton.AnchorPoint = combatCard, Vector2.zero
		attackButton.Position, attackButton.Size = UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 48)
		for index, key in { "dodge", "guard" } do
			local defenseControl = defenseButtons[key]
			defenseControl.Parent = combatCard
			defenseControl.Position, defenseControl.Size =
				UDim2.fromOffset((index - 1) * 112, 56), UDim2.fromOffset(104, 48)
		end
		combatPrompt = combatCard
		toolbar.Visible = false
	end

	local CHAT_RESERVE_WIDTH = 240
	local MIN_STACK_WIDTH = 160
	local function chatRightEdge(): number
		local chat = player.PlayerGui:FindFirstChild("Chat")
		local right = 0
		if chat ~= nil and chat:IsA("ScreenGui") and chat.Enabled then
			for _, item in chat:GetDescendants() do
				if item:IsA("GuiObject") and item.Visible then
					local frameSize = item.AbsoluteSize
					if frameSize.X >= 80 and frameSize.Y >= 16 and frameSize.X <= gui.AbsoluteSize.X * 0.6 then
						right = math.max(right, item.AbsolutePosition.X + frameSize.X - gui.AbsolutePosition.X)
					end
				end
			end
		end
		return if right > 0 then right + 8 else CHAT_RESERVE_WIDTH
	end

	local function resize()
		local size = root.AbsoluteSize
		if contextual then
			local width, height, top, right = Model.contextSheetBounds(size.X, size.Y, input.TouchEnabled)
			local sx, sy, sw, sh = Model.chatSafe(size.X, size.Y, size.X - right - width, top, width, height)
			sheet.frame.AnchorPoint, sheet.frame.Position, sheet.frame.Size =
				Vector2.zero, UDim2.fromOffset(sx, sy), UDim2.fromOffset(sw, sh)
			local bounds = Model.contextHudBounds(size.X + 24, size.Y + 16).vitals
			vitals.AnchorPoint, vitals.Position = Vector2.zero, UDim2.fromOffset(bounds.x - 12, bounds.y - 8)
			vitals.Size = UDim2.fromOffset(bounds.width, bounds.height)
			status.AnchorPoint, status.Position = Vector2.new(1, 0), UDim2.new(1, -80, 0, 0)
			status.Size = UDim2.fromOffset(math.min(312, size.X - 80), 56)
			return
		end
		local portrait = size.Y > size.X
		local chatRight = chatRightEdge()
		local width = if portrait
			then math.max(MIN_STACK_WIDTH, math.floor(size.X - chatRight - 12))
			else math.min(320, math.floor(size.X * 0.45))
		local sheetWidth, sheetHeight, top, right = Model.sheetBounds(size.X, size.Y, if portrait then nil else width)
		sheet.frame.Position = UDim2.new(1, -right, 0, top)
		sheet.frame.Size = UDim2.fromOffset(sheetWidth, sheetHeight)
		vitals.AnchorPoint, status.AnchorPoint, toolbar.AnchorPoint, restButton.AnchorPoint =
			Vector2.new(1, 0), Vector2.new(1, 0), Vector2.new(1, 0), Vector2.new(1, 0)
		vitals.Position, toolbar.Position, status.Position, restButton.Position =
			UDim2.fromScale(1, 0), UDim2.new(1, 0, 0, 40), UDim2.new(1, 0, 0, 92), UDim2.new(1, 0, 0, 132)
		vitals.Size, status.Size, toolbar.Size =
			UDim2.fromOffset(width, 76), UDim2.fromOffset(width, 36), UDim2.fromOffset(width, 48)
		toolbar.Position, status.Position = UDim2.new(1, 0, 0, 80), UDim2.new(1, 0, 0, 132)
		restButton.Size = UDim2.fromOffset(width, 48)
		attackButton.Position, attackButton.Size =
			UDim2.new(1, 0, 0, 132), UDim2.fromOffset(math.floor(width / 2) - 4, 48)
		restButton.Position, restButton.Size =
			UDim2.new(1, -math.floor(width / 2) - 4, 0, 132), UDim2.fromOffset(math.floor(width / 2) - 4, 48)
	end
	table.insert(connections, root:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize))
	local RunService = game:GetService("RunService")
	local lastChatRight: number? = nil
	local function followChat(): ()
		local right = chatRightEdge()
		if right ~= lastChatRight then
			lastChatRight = right
			resize()
		end
	end
	followChat()
	table.insert(connections, RunService.Heartbeat:Connect(followChat))
	table.insert(
		connections,
		sheet.close.Activated:Connect(function()
			section = ""
			sheet.frame.Visible = false
			placementBar.Visible, toast.Visible = false, false
			preview()
		end)
	)
	table.insert(
		connections,
		input.InputBegan:Connect(function(key, processed)
			if processed or input:GetFocusedTextBox() then
				return
			end
			if key.KeyCode == Enum.KeyCode.I then
				open("bag")
			elseif key.KeyCode == Enum.KeyCode.Return and section == "build" then
				local settlement, warehouse = model.snapshot.settlement, model.snapshot.warehouse
				if settlement and warehouse then
					for _, entry in Model.placements(settlement, model.actor) do
						if entry.placement.definition.id == structureId then
							command("settlement-place", { entry.id, settlement.version, warehouse.version })
							break
						end
					end
				end
			elseif key.KeyCode == Enum.KeyCode.C then
				open("craft")
			elseif key.KeyCode == Enum.KeyCode.B then
				open("build")
			elseif key.KeyCode == Enum.KeyCode.R then
				rest()
			elseif key.KeyCode == Enum.KeyCode.F then
				attack()
			elseif key.KeyCode == Enum.KeyCode.Q and content.progressionPolicy and content.progressionPolicy.combat then
				command("dodge", {})
			elseif key.KeyCode == Enum.KeyCode.G and content.progressionPolicy and content.progressionPolicy.combat then
				command("guard", {})
			end
		end)
	)
	table.insert(
		connections,
		state.OnClientEvent:Connect(function(packet)
			if model.receive(packet) then
				render()
			end
		end)
	)
	local promptService = game:GetService("ProximityPromptService")
	local visibleGather: { [ProximityPrompt]: boolean } = {}
	local function nearestGather()
		local character = player.Character
		local origin = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local closest: BasePart? = nil
		local distance = math.huge
		for prompt in visibleGather do
			local anchor = prompt.Parent
			local target = if anchor and anchor:IsA("Attachment") then anchor.Parent else anchor
			if origin and target and target:IsA("BasePart") then
				local d = (target.Position - (origin :: BasePart).Position).Magnitude
				if d < distance then
					closest, distance = target, d
				end
			end
		end
		highlight.Adornee, highlight.Enabled = closest, closest ~= nil
	end
	table.insert(
		connections,
		promptService.PromptShown:Connect(function(prompt: ProximityPrompt)
			if prompt.Name == "ForgeGather" then
				visibleGather[prompt] = true
				nearestGather()
			end
		end)
	)
	table.insert(
		connections,
		promptService.PromptHidden:Connect(function(prompt)
			visibleGather[prompt] = nil
			nearestGather()
		end)
	)
	local receivedAt = os.clock()
	table.insert(
		connections,
		state.OnClientEvent:Connect(function()
			receivedAt = os.clock()
		end)
	)
	table.insert(
		connections,
		run.Heartbeat:Connect(function()
			nearestGather()
			for key, tab in tabs do
				tab.Text = t(key)
			end
			restButton.Text, attackButton.Text = t("rest"), t("attack")
			attackButton.Visible = model.durable ~= nil
				and table.find(model.durable.actions, "survival-coop:attack") ~= nil
			if contextual then
				local modal = sheet.frame.Visible or player:GetAttribute("ForgeExtensionSheetOpen") == true
				vitals.Visible = not modal and model.snapshot.vitals ~= nil
				local restTarget = nearest("campfire")
				local character = player.Character
				local pivot = if character then character:FindFirstChild("HumanoidRootPart") else nil
				local attackTarget: BasePart? = nil
				local distance = 8
				local wildlife = world:FindFirstChild("ForgeWildlife")
				if pivot and pivot:IsA("BasePart") and wildlife then
					for _, animal in wildlife:GetChildren() do
						local anchor = animal:FindFirstChild("HumanoidRootPart")
						local hp = animal:GetAttribute("ForgeWildlifeHealthMilli")
						if anchor and anchor:IsA("BasePart") and type(hp) == "number" and hp > 0 then
							local d = (anchor.Position - pivot.Position).Magnitude
							if d < distance then
								attackTarget, distance = anchor, d
							end
						end
					end
				end
				local actions = Model.contextActions(model.durable, model.pending, modal, restTarget, attackTarget)
				restButton.Visible, attackButton.Visible = actions.rest, actions.attack
				for key, defenseControl in defenseButtons do
					defenseControl.Visible = actions[key]
				end
				if restPrompt then
					restPrompt.Enabled = actions.rest
					if restTarget then
						restPrompt.Adornee = restTarget
					end
				end
				if combatPrompt then
					combatPrompt.Enabled = actions.attack
					if attackTarget then
						combatPrompt.Adornee = attackTarget
					end
				end
				player:SetAttribute("ForgeSurvivalSheetOpen", sheet.frame.Visible)
				local gatherGui = player.PlayerGui:FindFirstChild("ForgeGatherTouch")
				promptService.Enabled = not modal
				if gatherGui and gatherGui:IsA("ScreenGui") then
					gatherGui.Enabled = not modal
				end
			end
			for item, verb in { [restButton] = "rest", [attackButton] = "attack" } do
				local enabled = model.pending == nil
					and model.durable ~= nil
					and table.find(model.durable.actions, "survival-coop:" .. verb) ~= nil
				item.Active, item.Selectable, item.Interactable = enabled, enabled, enabled
				item.BackgroundTransparency = if enabled then 0 else 0.7
			end
			local v = model.snapshot.vitals
			if not v then
				return
			end
			local now = v.clockMillis + (os.clock() - receivedAt) * 1000
			for _, child in sheet.scroll:GetChildren() do
				if child:IsA("TextLabel") and child:GetAttribute("FinishAt") then
					child.Text = tostring(child:GetAttribute("JobLabel"))
						.. "\n"
						.. math.ceil(math.max(0, child:GetAttribute("FinishAt") - now) / 1000)
						.. "s"
				end
			end
		end)
	)
	local function destroy()
		if disposed then
			return
		end
		disposed = true
		if contextual then
			promptService.Enabled = true
			player:SetAttribute("ForgeSurvivalSheetOpen", nil)
		end
		for _, connection in connections do
			connection:Disconnect()
		end
		ghost:Destroy()
		highlight:Destroy()
		resultEvent:Destroy()
		requestEvent:Destroy()
		placementGui:Destroy()
		gui:Destroy()
	end
	table.insert(connections, gui.Destroying:Connect(destroy))
	gui.Parent = player:WaitForChild("PlayerGui")
	resize()
	render()
	refresh()
	return {
		destroy = destroy,
		open = open,
		gui = gui,
		close = function()
			section = ""
			sheet.frame.Visible = false
			placementBar.Visible, toast.Visible = false, false
			preview()
		end,
		isOpen = function(): boolean
			return sheet.frame.Visible or placementBar.Visible
		end,
		opened = sheet.frame:GetPropertyChangedSignal("Visible"),
	}
end
return M
