--!strict
local Chapters = require("../../../core/domain/journal/Chapters")
local M = {}

function M.model(content: any, state: any, level: number): any
	local rows = {}
	for _, chapter in content.chapters do
		local candidate, reason = Chapters.open(state, content.chapters, chapter.id, level)
		local objectives = {}
		local complete = true
		for _, objective in chapter.objectives do
			local count = if state.completed[chapter.id] then objective.quantity else state.counts[objective.id] or 0
			complete = complete and count >= objective.quantity
			table.insert(objectives, {
				id = objective.id,
				textKey = objective.id .. ".text",
				action = objective.action,
				target = objective.target,
				count = count,
				quantity = objective.quantity,
			})
		end
		table.insert(rows, {
			id = chapter.id,
			titleKey = chapter.id .. ".title",
			summaryKey = chapter.id .. ".summary",
			textKey = chapter.dialogueKeys[1],
			objectives = objectives,
			rewards = Chapters.copy(chapter.rewards),
			reason = reason,
			canOpen = candidate ~= nil and state.active ~= chapter.id,
			canClaim = state.active == chapter.id and complete,
			completed = state.completed[chapter.id] == true,
		})
	end
	return rows
end

function M.factory(ctx: any): any
	local components, theme = ctx.ui.components, ctx.ui.theme.default
	local gui = ctx.createGui("JournalPanel")
	local sheet = components.modalSheet(theme, { name = "Journal", title = ctx.text("journal_open") })
	sheet.frame.Parent = gui
	ctx.fitSheet(sheet.frame)
	local connections = {}
	local rowConnections = {}
	local rows = {}
	local state = Chapters.new()
	local level = 1
	local pending = false
	local errorReason: string? = nil
	local function clear()
		for _, connection in rowConnections do
			connection:Disconnect()
		end
		for _, row in rows do
			row:Destroy()
		end
		rowConnections, rows = {}, {}
	end
	local render: () -> ()
	-- p134 v58/v59 memory: the server pushes a snapshot every second, and a full rebuild of every
	-- chapter card per push (~450 instances/s while closed) grew the client heap all session. A
	-- closed sheet only marks itself stale; it renders when it opens.
	local stale = true
	render = function()
		if not sheet.frame.Visible then
			stale = true
			return
		end
		stale = false
		clear()
		for index, chapter in M.model(ctx.content, state, level) do
			if ctx.cards then
				-- U7: a chapter card (seal art, title, completed / level badge, summary, checked
				-- objectives, the gate or refusal in red) above its action button.
				local lines = {}
				for _, objective in chapter.objectives do
					local done = objective.count >= objective.quantity
					table.insert(lines, {
						icon = ctx.icons.ui(if done then "success" else "todo"),
						text = string.format(
							"%s  %d/%d",
							ctx.text(objective.textKey),
							objective.count,
							objective.quantity
						),
						done = done,
					})
				end
				local notes = {}
				for _, reason in { chapter.reason, errorReason } do
					if reason and not chapter.completed then
						table.insert(notes, ctx.text(reason))
					end
				end
				local card = ctx.cards.section(sheet.scroll, {
					name = "Chapter" .. index,
					order = index * 2,
					icon = ctx.icons.item("rw-journal-seal-" .. index),
					title = ctx.text(chapter.titleKey),
					badge = if chapter.completed then ctx.text("ALREADY_COMPLETED") else nil,
					caption = ctx.text(chapter.summaryKey),
					lines = lines,
					note = table.concat(notes, "\n"),
					size = ctx.sheetText("body"),
				})
				table.insert(rows, card)
				if not (chapter.canOpen or chapter.canClaim) then
					continue
				end
			end
			local lines = { ctx.text(chapter.titleKey), ctx.text(chapter.summaryKey) }
			for _, objective in chapter.objectives do
				table.insert(
					lines,
					string.format("%s %d/%d", ctx.text(objective.textKey), objective.count, objective.quantity)
				)
			end
			if chapter.reason then
				table.insert(lines, ctx.text(chapter.reason))
			end
			if errorReason then
				table.insert(lines, ctx.text(errorReason))
			end
			local label = components.label(theme, { text = table.concat(lines, "\n"), size = ctx.rowSize(#lines) })
			label.Parent = if ctx.cards then nil else sheet.scroll
			label.LayoutOrder = index * 2
			label.ZIndex = 52
			if ctx.fitRow then
				ctx.fitRow(label)
			end
			table.insert(rows, label)
			local button = components.button(theme, {
				text = ctx.text(if chapter.canClaim then "journal_claim" else "journal_open"),
				size = ctx.buttonSize,
			})
			button.Parent = sheet.scroll
			button.LayoutOrder = index * 2 + 1
			button.ZIndex = 52
			button.Active = not pending and (chapter.canOpen or chapter.canClaim)
			table.insert(rows, button)
			table.insert(
				rowConnections,
				button.Activated:Connect(function()
					if pending or not (chapter.canOpen or chapter.canClaim) then
						return
					end
					pending = true
					render()
					local result = ctx.send(
						if chapter.canClaim then "survival-coop:journal-claim" else "survival-coop:journal-open",
						if chapter.canClaim then {} else { chapter.id }
					)
					pending = false
					errorReason = if result.ok then nil else result.reason
					if result.ok and result.data then
						state = result.data
					end
					render()
				end)
			)
		end
	end
	table.insert(
		connections,
		sheet.close.Activated:Connect(function()
			sheet.frame.Visible = false
		end)
	)
	sheet.frame.Visible = false
	render()
	return {
		open = function()
			sheet.frame.Visible = true
			if stale then
				render()
			end
		end,
		isOpen = function()
			return sheet.frame.Visible
		end,
		snapshot = function(snapshot)
			local data = snapshot.survivalExtensions
			if data and data.journal then
				state = data.journal
			end
			level = ctx.level(snapshot)
			render()
		end,
		destroy = function()
			clear()
			for _, connection in connections do
				connection:Disconnect()
			end
			gui:Destroy()
		end,
	}
end

return M
