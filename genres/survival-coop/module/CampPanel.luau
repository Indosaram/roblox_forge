--!strict
-- Client panel for the camp ladder: current rung, project progress bars, an item +
-- quantity picker built from the player's own inventory snapshot, contribute buttons,
-- visit-open (guests) and visit-help (visitors) buttons, and the visitor pass status.
-- State comes from snapshot.survivalExtensions.camp plus the packet's survival-coop
-- inventory; every action is a durable command through `send`. The view model and
-- strings live in CampPanelModel (specced under Lune).
local Model = require("./CampPanelModel")
local M = {}

function M.factory(ctx: any): { destroy: () -> () }?
	local ui = ctx.ui
	local theme, components = ui.theme.default, ui.components
	local players = game:GetService("Players")
	local gui = Instance.new("ScreenGui")
	gui.Name = "CampPanel"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Like every docked sheet, the open camp panel is modal above the HUD (15) and dock (16);
	-- at 0 the HUD stack drew over its quantity picker and contribute buttons.
	gui.DisplayOrder = 20
	gui.Parent = (players.LocalPlayer :: Player):WaitForChild("PlayerGui")
	-- Opened from the shared dock; without a dock (headless) it shows whenever there is a model.
	local wanted = ctx.dock == nil
	local available = false
	local dock = if ctx.dock
		then ctx.dock({
			id = "camp",
			label = Model.text(ctx.locale, "camp_title"),
			order = 4,
			setOpen = function(open: boolean)
				wanted = open
				gui.Enabled = open and available
			end,
			isOpen = function()
				return gui.Enabled
			end,
		})
		else nil
	local sheet = components.modalSheet(theme, {
		name = "Camp",
		title = Model.text(ctx.locale, "camp_title"),
		parent = gui,
	})
	sheet.frame.Visible = true
	if ctx.fitSheet then
		ctx.fitSheet(sheet.frame)
	end
	sheet.close.Activated:Connect(function()
		wanted = false
		gui.Enabled = false
	end)
	local order = 0
	local function line(height: number): Frame
		order += 1
		local holder = Instance.new("Frame")
		holder.Size = UDim2.new(1, 0, 0, height)
		holder.BackgroundTransparency = 1
		holder.LayoutOrder = order
		-- Unique row names keep each control's full path unambiguous for QA drivers.
		holder.Name = "Row" .. order
		holder.Parent = sheet.scroll
		return holder
	end
	local slice: any, packet: any = nil, nil
	local selected: string? = nil
	local quantity = 1
	local shown: { Instance } = {}
	local render: (force: boolean?) -> ()
	local status = ""
	local lastKey: string? = nil
	local function renderKey(model: any, choices: { any }): string
		if not model then
			return "nil"
		end
		local parts = {
			tostring(model.role),
			tostring(model.rung),
			tostring(model.rungs),
			tostring(model.version),
			tostring(model.pass),
			tostring(model.visitors),
			tostring(model.cooldowns),
			tostring(#model.facilities),
			tostring(selected),
			tostring(quantity),
			status,
		}
		for _, h in model.hosts do
			table.insert(parts, h.id .. ":" .. h.name)
		end
		for _, c in choices do
			table.insert(parts, c.itemId .. ":" .. tostring(c.available))
		end
		for _, r in model.rows do
			table.insert(parts, r.id .. ":" .. r.delivered .. "/" .. r.need .. ":" .. tostring(r.locked))
		end
		return table.concat(parts, "|")
	end
	local function act(action: string, args: { any })
		local result = ctx.send(action, args)
		status = if result.ok then "" else Model.refusal(ctx.locale, result.reason)
		render(true)
	end
	function render(force: boolean?)
		local model = Model.model(slice, os.time(), packet)
		available = model ~= nil
		gui.Enabled = available and wanted
		if dock then
			dock.setAvailable(available)
		end
		local choices = Model.choices(ctx.locale, packet)
		if selected == nil then
			for _, c in choices do
				if string.find(c.itemId, "fiber", 1, true) or string.find(c.itemId, "wood", 1, true) then
					selected = c.itemId
					break
				end
			end
		end
		local key = renderKey(model, choices)
		if not force and key == lastKey then
			return
		end
		lastKey = key
		for _, child in shown do
			child:Destroy()
		end
		table.clear(shown)
		order = 1
		if not model then
			return
		end
		local function add(height: number): Frame
			local holder = line(height)
			table.insert(shown, holder)
			return holder
		end
		local head = add(22)
		components.label(theme, {
			text = string.format(
				"%s %d/%d  %s",
				Model.text(ctx.locale, "camp_rung"),
				model.rung,
				model.rungs,
				if model.role == "member"
					then Model.text(ctx.locale, "camp_facility") .. " " .. #model.facilities
					else Model.text(ctx.locale, "camp_visitor") .. ": " .. (if model.pass
						then tostring(model.pass) .. "s"
						else Model.text(ctx.locale, "camp_visitor_none"))
			),
			size = UDim2.fromScale(1, 1),
			parent = head,
		})
		if model.role == "member" and (model.visitors > 0 or model.cooldowns > 0) then
			local info = add(20)
			components.label(theme, {
				text = Model.text(ctx.locale, "camp_visitors") .. " " .. model.visitors .. "  " .. Model.text(
					ctx.locale,
					"camp_cooldown"
				) .. " " .. model.cooldowns,
				size = UDim2.fromScale(1, 1),
				parent = info,
			})
		end
		-- Guests and visitors without a live pass can ask to visit any friend's camp.
		if model.role ~= "member" and model.pass == nil then
			for _, host in model.hosts do
				local visit = add(44)
				components.button(theme, {
					text = Model.text(ctx.locale, "camp_visit") .. " " .. host.name,
					size = UDim2.fromScale(1, 1),
					parent = visit,
					onClick = function()
						act("survival-coop:camp-visit-open", { host.id })
					end,
				})
			end
		end
		local choice = Model.select(choices, selected)
		selected = if choice then choice.itemId else nil
		local canGive = #model.rows > 0 and (model.role == "member" or model.pass ~= nil)
		if canGive then
			local picker = add(44)
			if choice == nil then
				components.label(theme, {
					text = Model.text(ctx.locale, "camp_no_items"),
					size = UDim2.fromScale(1, 1),
					parent = picker,
				})
			else
				quantity = Model.clamp(quantity, choice.available)
				local item: TextButton
				local qtyLabel: TextLabel
				local function refreshPicker()
					local current = Model.select(choices, selected)
					if not current then
						return
					end
					selected = current.itemId
					quantity = Model.clamp(quantity, current.available)
					item.Text = current.label .. " x" .. current.available
					qtyLabel.Text = tostring(quantity)
					lastKey = renderKey(model, choices)
				end
				item = components.button(theme, {
					text = choice.label .. " x" .. choice.available,
					size = UDim2.fromScale(0.52, 1),
					parent = picker,
					onClick = function()
						selected = Model.cycle(choices, selected, 1)
						quantity = 1
						refreshPicker()
					end,
				})
				item.Name = "ItemPicker"
				components.button(theme, {
					text = Model.text(ctx.locale, "camp_less"),
					size = UDim2.fromScale(0.14, 1),
					position = UDim2.fromScale(0.54, 0),
					parent = picker,
					onClick = function()
						local current = Model.select(choices, selected)
						if current then
							quantity = Model.clamp(quantity - 1, current.available)
							refreshPicker()
						end
					end,
				})
				qtyLabel = components.label(theme, {
					text = tostring(quantity),
					size = UDim2.fromScale(0.14, 1),
					position = UDim2.fromScale(0.69, 0),
					parent = picker,
				})
				components.button(theme, {
					text = Model.text(ctx.locale, "camp_more"),
					size = UDim2.fromScale(0.14, 1),
					position = UDim2.fromScale(0.84, 0),
					parent = picker,
					onClick = function()
						local current = Model.select(choices, selected)
						if current then
							quantity = Model.clamp(quantity + 1, current.available)
							refreshPicker()
						end
					end,
				})
			end
		end
		local orderedRows: { any } = {}
		for _, row in model.rows do
			if not row.locked then
				table.insert(orderedRows, row)
			end
		end
		for _, row in model.rows do
			if row.locked then
				table.insert(orderedRows, row)
			end
		end
		for _, row in orderedRows do
			local holder = add(66)
			local label = if ctx.names and ctx.names["camp:" .. row.id] then ctx.names["camp:" .. row.id] else row.label
			components.label(theme, {
				text = label .. "  " .. row.delivered .. "/" .. row.need,
				size = UDim2.new(0.62, 0, 0, 18),
				parent = holder,
			})
			local bar, setProgress = components.progressBar(theme, {
				size = UDim2.new(0.6, 0, 0, 14),
				position = UDim2.fromOffset(0, 24),
				parent = holder,
			})
			setProgress(if row.need > 0 then row.delivered / row.need else 0)
			bar.Name = "Progress_" .. row.id
			components.label(theme, {
				text = Model.costLine(ctx.locale, row, ctx.names),
				size = UDim2.new(1, 0, 0, 18),
				position = UDim2.fromOffset(0, 48),
				parent = holder,
				textSize = 12,
			})
			if canGive and choice and not row.locked then
				local helping = model.role ~= "member"
				components.button(theme, {
					text = Model.text(ctx.locale, if helping then "camp_help" else "camp_contribute"),
					size = UDim2.new(0.35, 0, 0, 44),
					position = UDim2.new(0.65, 0, 0, 2),
					parent = holder,
					onClick = function()
						local current = Model.select(choices, selected) or choice
						if helping then
							act("survival-coop:camp-visit-help", {
								model.passHost,
								row.id,
								current.itemId,
								quantity,
								model.version,
							})
						else
							act("survival-coop:camp-contribute", { row.id, current.itemId, quantity, model.version })
						end
					end,
				})
			end
		end
		if model.role == "member" then
			for _, row in model.rows do
				if row.delivered >= row.need and row.need > 0 then
					local done = add(44)
					components.button(theme, {
						text = Model.text(ctx.locale, "camp_complete") .. " " .. (if ctx.names
								and ctx.names["camp:" .. row.id]
							then ctx.names["camp:" .. row.id]
							else row.label),
						size = UDim2.fromScale(1, 1),
						parent = done,
						onClick = function()
							act("survival-coop:camp-complete", { row.id, model.version })
						end,
					})
				end
			end
		end
		if status ~= "" then
			local note = add(22)
			components.label(theme, { text = status, size = UDim2.fromScale(1, 1), parent = note })
		end
	end
	local unsubscribe = ctx.onSnapshot(function(extensions, whole)
		slice, packet = extensions.camp, whole
		render()
	end)
	return {
		destroy = function()
			unsubscribe()
			gui:Destroy()
		end,
	}
end

return M
