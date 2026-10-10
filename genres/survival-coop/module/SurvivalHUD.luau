--!strict
local Model = require("./SurvivalHUDModel")
local Locale = require("./SurvivalHUDLocale")
local M = {}

-- Keep the input object alive across snapshots, but dispatch its current action.
--
-- `fit` is the constraint factory the runtime supplies (see `fitText` in
-- `M.start`). It is injected rather than called here so this module still names
-- no engine global and its specs run under Lune with the kit's own fakes.
function M.controls(components: any, theme: any, parent: any, fit: ((Instance) -> ())?): any
	local entries: { [string]: any } = {}
	local present: { [string]: boolean } = {}
	local order, scope = 0, ""
	local controls = {}
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
		-- A label scales inside its control rather than running past it: the navigation
		-- tabs are a third of a phone-width bar, and the same string is longer in one
		-- language than another. A scaled label must be capped, or it grows to fill the
		-- whole control: the bag sheet's "Refresh supplies" and "Camera controls" buttons
		-- rendered their text at the full 48px button height before `fit` existed.
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
	locale: string?,
	-- Replicated settlement origin from the same config used by the world owner.
	settlementOrigin: Vector3,
	-- Pack translations keyed by catalog ID; genre copy is supplied in en/ko here.
	names: { [string]: string }?,
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
	local function t(key: string): string
		return Locale.text(locale, key)
	end
	local function name(id: string): string
		return if options.names and options.names[id] then options.names[id] else t(id)
	end
	local theme = Theme.merge(Theme.default, {
		font = "Gotham",
		colors = { panel = { r = 27, g = 43, b = 40 }, accent = { r = 67, g = 112, b = 93 } },
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
	-- Sibling names must stay unique: capture validation reads GetFullName paths.
	vitals.Name = "Vitals"
	vitals.BackgroundColor3, vitals.BackgroundTransparency = Color3.fromRGB(27, 43, 40), 0.12
	local status = Components.label(theme, {
		text = t("loading"),
		size = UDim2.new(1, 0, 0, 64),
		position = UDim2.fromOffset(0, 56),
		parent = root,
		textSize = 14,
	})
	status.Name = "Status"
	status.BackgroundColor3, status.BackgroundTransparency = Color3.fromRGB(27, 43, 40), 0.12
	local toolbar = Instance.new("Frame")
	toolbar.Name, toolbar.BackgroundTransparency = "Navigation", 1
	toolbar.Position, toolbar.Size, toolbar.Parent = UDim2.fromOffset(0, 124), UDim2.new(1, 0, 0, 48), root
	local sheet = Components.modalSheet(theme, { name = "SurvivalSheet", title = "", parent = root })
	-- A control's label scales inside it, down to a readable floor: the navigation
	-- tabs are a third of a phone-width bar, and English copy is longer than Korean.
	-- `MaxTextSize` is what stops a scaled label filling its control: without it the
	-- text grows to the button's own height, which is the bag-sheet defect this
	-- constraint fixes. One factory, shared by the tabs and the sheet's controls, so
	-- every scaled label in this module is capped by the same numbers.
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
	-- The sheet is a modal a player opens, never a panel that covers the world at
	-- spawn: it is created hidden and only `open` (a tab, or a keyboard shortcut)
	-- shows it. A capture that opens it is driving the bag, not showing the start.
	sheet.frame.Visible = false
	local controls = M.controls(Components, theme, sheet.scroll, fitText)
	sheet.frame.AnchorPoint, sheet.frame.Position = Vector2.new(1, 0), UDim2.new(1, 0, 0, 178)
	sheet.close.Text = "X"
	local section, selected, recipeId, structureId = "", nil, nil, nil
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
	local resultEvent = Instance.new("BindableEvent")
	resultEvent.Name, resultEvent.Parent = "ForgeHUDResult", player
	local requestEvent = Instance.new("BindableEvent")
	requestEvent.Name, requestEvent.Parent = "ForgeHUDRequested", player
	local render: () -> ()
	local refresh: () -> ()
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
			-- Refusals do not broadcast. Refresh to expose Ready/full-bag and conflicts.
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
		local distance = 8
		for _, instance in world:GetDescendants() do
			local id = instance:GetAttribute("ForgeWildlifeId")
			if instance:IsA("Model") and type(id) == "string" then
				local rootPart = instance:FindFirstChild("HumanoidRootPart")
				if rootPart and rootPart:IsA("BasePart") then
					local offset = rootPart.Position - pivot.Position
					local d = offset.Magnitude
					if d < distance and (d == 0 or pivot.CFrame.LookVector:Dot(offset.Unit) > 0) then
						target, distance = id, d
					end
				end
			end
		end
		if target then
			command("attack", { target })
		else
			model.status, model.reason = "conflict", "WILDLIFE_UNREACHABLE"
			render()
		end
	end
	-- Note labels are pooled by slot so a re-render reuses the same instances under
	-- the same names. Destroying and recreating them gave every render a fresh name,
	-- so the HUD's instance identities churned on each server push and a capture
	-- spanning a push could not observe a stable geometry.
	local notePool: { TextLabel } = {}
	local noteUsed = 0
	local function label(text: string, height: number?): TextLabel
		noteUsed += 1
		-- `notePool[slot]` is typed `TextLabel` by the array indexer even when the slot
		-- is empty, so the pooled read is taken as optional and the two branches
		-- produce one non-optional value: the strict `item == nil` guard cannot narrow
		-- a value the indexer already calls non-nil.
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
		item.Text = text
		item.Size = UDim2.new(1, -8, 0, height or 48)
		item.LayoutOrder = controls.order()
		item.Visible = true
		-- A reused slot must not keep the previous render's job-timer bindings: the
		-- heartbeat loop rewrites the text of any label carrying FinishAt.
		item:SetAttribute("FinishAt", nil)
		item:SetAttribute("JobLabel", nil)
		return item
	end
	local function button(id: string, text: string, callback: () -> (), enabled: boolean?)
		return controls.button(id, text, callback, enabled ~= false)
	end
	local function mutation(id: string, text: string, verb: string, callback: () -> ())
		local policy = model.durable
		local enabled = policy and table.find(policy.actions, "survival-coop:" .. verb) ~= nil and model.pending == nil
		return button(id, text, callback, enabled == true)
	end
	local function selectedDefinition(): any
		for _, definition in options.content.structures do
			if definition.id == structureId then
				return definition
			end
		end
		return nil
	end
	local function preview()
		ghost:ClearAllChildren()
		local definition, settlement = selectedDefinition(), model.snapshot.settlement
		if section ~= "build" or not definition or not settlement then
			return
		end
		local placement, reason = Model.preview(model.snapshot, model.actor, definition, x, z, rotation)
		local cells = if placement then placement.cells else {}
		-- Invalid previews still show the exact rotated footprint in red.
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
			part.Position = options.settlementOrigin + Vector3.new((cell.x + 0.5) * size, 0.15, (cell.z + 0.5) * size)
			part.Color = if reason then Color3.fromRGB(223, 99, 85) else Color3.fromRGB(141, 201, 149)
			part.Transparency, part.Material, part.Parent = 0.4, Enum.Material.Neon, ghost
		end
	end
	render = function()
		if disposed then
			return
		end
		local v = model.snapshot.vitals
		-- A pack whose snapshot carries no vitals - the generic survival pack's adapter
		-- publishes balance and upgrade state, not vitals - must not sit on the loading
		-- line forever: the row is hidden and the status line carries the state. A live
		-- capture of the generic pack showed "보급품을 불러오는 중..." stuck above a HUD
		-- that had already handshaked.
		vitals.Visible = v ~= nil
		vitals.Text = if v
			then string.format(
				"%s %d   %s %d   %s %d\n%s",
				t("health"),
				v.healthMilli / 1000,
				t("hunger"),
				v.hungerMilli / 1000,
				t("fatigue"),
				v.fatigueMilli / 1000,
				if v.resting then t("resting") else t("ready")
			)
			else ""
		status.Text = t(model.status) .. (if model.reason then "\n" .. Locale.refusal(locale, model.reason) else "")
		local scrollPosition = sheet.scroll.CanvasPosition
		controls.begin(section)
		noteUsed = 0
		if inventoryGrid then
			-- Hidden, not destroyed. Destroying it on every section change replaced every inventory
			-- button instance, so a click subscribed before the switch fired on a dead button while the
			-- injected mouse click hit the new one. Keeping the frame alive keeps the instances stable.
			inventoryGrid.frame.Visible = section == "bag"
		end
		if model.pending then
			button("Retry", t("retry"), function()
				send(model.retry())
			end, not model.busy)
		end
		button("Refresh", t("refresh"), refresh)
		button("CameraHelp", t("cameraHelp"), function()
			helpVisible = not helpVisible
			render()
		end)
		if helpVisible then
			label(t("cameraHint"), 100)
		end
		if model.reason then
			label(Locale.refusal(locale, model.reason), 100)
		end
		local bag = Model.bag(model.snapshot)
		if section == "bag" then
			if bag then
				local slots, maximum, weight, hard = Model.capacity(bag)
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
				local display = {}
				for _, row in rows do
					table.insert(display, {
						id = row.item.itemId,
						text = name(row.item.catalogId)
							.. " x"
							.. row.item.quantity
							.. "\n"
							.. t("reserved")
							.. " "
							.. row.reserved,
					})
				end
				if not inventoryGrid then
					inventoryGrid = Grid.new(sheet.scroll, theme, function(id)
						selected = id
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
		elseif section == "craft" then
			for _, recipe in options.content.recipes do
				button("Recipe-" .. recipe.id, name(recipe.id), function()
					recipeId = recipe.id
					render()
				end)
				if recipe.id == recipeId then
					label(t("inputs"))
					for _, ingredient in Model.ingredients(bag, recipe) do
						label(name(ingredient.id) .. " " .. ingredient.available .. "/" .. ingredient.needed)
					end
					local output = {}
					for _, item in recipe.outputs do
						table.insert(output, name(item.item) .. " x" .. item.quantity)
					end
					label(
						t("outputs") .. ": " .. table.concat(output, ", ") .. "\n" .. recipe.craftMillis / 1000 .. "s",
						64
					)
					label(
						t("station")
							.. ": "
							.. (if recipe.station then name(recipe.station) else t("hand"))
							.. (
								if recipe.requiredToolTag
									then "\n" .. t("tool") .. ": " .. name(recipe.requiredToolTag)
									else ""
							),
						64
					)
					mutation("Reserve-" .. recipe.id, t("reserve"), "craft-reserve", function()
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
				end
			end
			label(t("jobs"))
			for _, entry in Model.jobs(model.snapshot, model.actor) do
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
		elseif section == "build" then
			label(t("buildHint"), 80)
			for _, definition in options.content.structures do
				button("Structure-" .. definition.id, name(definition.id), function()
					structureId = definition.id
					render()
				end)
			end
			local definition = selectedDefinition()
			if definition then
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
					96
				)
				for _, cost in definition.cost do
					label(name(cost.item) .. " x" .. cost.quantity)
				end
				for _, move in
					{
						{ id = "X-", dx = -1, dz = 0 },
						{ id = "X+", dx = 1, dz = 0 },
						{ id = "Z-", dx = 0, dz = -1 },
						{ id = "Z+", dx = 0, dz = 1 },
					}
				do
					button(move.id, t(move.id), function()
						local settlement = model.snapshot.settlement
						if not settlement then
							return
						end
						x, z =
							math.clamp(x + move.dx, 0, settlement.config.width - 1),
							math.clamp(z + move.dz, 0, settlement.config.depth - 1)
						render()
					end)
				end
				button("Rotate", t("rotate"), function()
					rotation = (rotation + 1) % 4
					render()
				end)
				mutation("BuildReserve-" .. definition.id, t("reserve"), "settlement-reserve", function()
					local args, err = Model.buildArgs(model.snapshot, definition, x, z, rotation)
					if args then
						command("settlement-reserve", args)
					else
						model.status, model.reason = "conflict", err
						render()
					end
				end)
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
		controls.finish()
		for index = noteUsed + 1, #notePool do
			notePool[index].Visible = false
		end
		sheet.scroll.CanvasPosition = scrollPosition
		preview()
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

	-- The chat window's live right edge in screen space, or the documented reserve when the
	-- chat is absent. Recomputed on demand and on every chat layout change, never guessed
	-- once: the chat's message area appears only after the first measure.
	local CHAT_RESERVE_WIDTH = 240
	-- Never squeeze the top stack below a usable width, even if the chat is unusually wide.
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
		local portrait = size.Y > size.X
		-- The Roblox chat window owns the top-left corner on every surface. These elements
		-- are top-anchored and right-aligned, so on a portrait phone the stack must not run
		-- the full width: it is capped to the room right of the chat's live footprint (and a
		-- documented reserve when the chat is absent). A live 390x844 capture caught the
		-- navigation tabs under the chat.
		local chatRight = chatRightEdge()
		local width = if portrait
			then math.max(MIN_STACK_WIDTH, math.floor(size.X - chatRight - 12))
			else math.min(320, math.floor(size.X * 0.45))
		local sheetWidth, sheetHeight, top = Model.sheetBounds(size.X, size.Y)
		sheet.frame.Position = UDim2.new(1, 0, 0, top)
		sheet.frame.Size = UDim2.fromOffset(sheetWidth, sheetHeight)
		vitals.AnchorPoint, status.AnchorPoint, toolbar.AnchorPoint, restButton.AnchorPoint =
			Vector2.new(1, 0), Vector2.new(1, 0), Vector2.new(1, 0), Vector2.new(1, 0)
		vitals.Position, toolbar.Position, status.Position, restButton.Position =
			UDim2.fromScale(1, 0), UDim2.new(1, 0, 0, 40), UDim2.new(1, 0, 0, 92), UDim2.new(1, 0, 0, 132)
		vitals.Size, status.Size, toolbar.Size =
			UDim2.fromOffset(width, 36), UDim2.fromOffset(width, 36), UDim2.fromOffset(width, 48)
		restButton.Size = UDim2.fromOffset(width, 48)
		attackButton.Position, attackButton.Size =
			UDim2.new(1, 0, 0, 132), UDim2.fromOffset(math.floor(width / 2) - 4, 48)
		restButton.Position, restButton.Size =
			UDim2.new(1, -math.floor(width / 2) - 4, 0, 132), UDim2.fromOffset(math.floor(width / 2) - 4, 48)
	end
	table.insert(connections, root:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize))
	-- The stack's width depends on the chat's footprint, and the chat's layout settles over the
	-- first seconds and can change at any time. The measured right edge is compared each frame
	-- and the stack re-laid-out only when it changes.
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
			elseif key.KeyCode == Enum.KeyCode.C then
				open("craft")
			elseif key.KeyCode == Enum.KeyCode.B then
				open("build")
			elseif key.KeyCode == Enum.KeyCode.R then
				rest()
			elseif key.KeyCode == Enum.KeyCode.F then
				attack()
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
	table.insert(
		connections,
		promptService.PromptShown:Connect(function(prompt: ProximityPrompt)
			if prompt.Name == "ForgeGather" then
				local anchor = prompt.Parent
				highlight.Adornee = if anchor and anchor:IsA("Attachment") then anchor.Parent else anchor
			end
		end)
	)
	table.insert(
		connections,
		promptService.PromptHidden:Connect(function(prompt)
			local anchor = prompt.Parent
			local target = if anchor and anchor:IsA("Attachment") then anchor.Parent else anchor
			if highlight.Adornee == target then
				highlight.Adornee = nil
			end
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
			attackButton.Visible = model.durable ~= nil
				and table.find(model.durable.actions, "survival-coop:attack") ~= nil
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
		for _, connection in connections do
			connection:Disconnect()
		end
		ghost:Destroy()
		highlight:Destroy()
		resultEvent:Destroy()
		requestEvent:Destroy()
		gui:Destroy()
	end
	table.insert(connections, gui.Destroying:Connect(destroy))
	gui.Parent = player:WaitForChild("PlayerGui")
	resize()
	render()
	refresh()
	return { destroy = destroy, open = open, gui = gui }
end
return M
