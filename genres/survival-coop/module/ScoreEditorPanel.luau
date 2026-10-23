--!strict
-- Real Roblox GUI; the injected view ports also permit deterministic interaction specs.
local Score = require("../../../core/domain/music/Score")
local Transport = require("./ScoreTransport")
local Selection = require("./MusicSelection")
local Text = require("./MusicText")
-- Roblox globals are read from the environment so this module also type-checks under lune.
local env: any = getfenv()
local game: any = env.game
local Instance: any = env.Instance
local UDim2: any = env.UDim2
local Color3: any = env.Color3
local M = {}
function M.bounds(width: number, height: number): any
	local phone = width < 700
	local w = if phone then width else math.min(720, width - 32)
	local h = math.min(560, math.floor(height * 0.75))
	return {
		x = math.floor((width - w) / 2),
		y = if phone then height - h else math.floor((height - h) / 2),
		width = w,
		height = h,
	}
end

function M.new(ctx: any): any
	local instruments = {}
	for id in ctx.rules.instruments do
		table.insert(instruments, id)
	end
	table.sort(instruments)
	local draft: any =
		{ version = 1, tempo = ctx.rules.tempoMin, parts = { { instrumentId = instruments[1], notes = {} } } }
	local part, instrument = 1, 1
	local dirty, playing = false, false
	local saved: any = nil
	local pendingId: string? = nil
	local api = {}
	local function render()
		ctx.render({
			score = Score.copy(draft),
			part = part,
			dirty = dirty,
			playing = playing,
			saved = Score.copy(saved),
		})
	end
	local function accept(nextScore: any): (boolean, string?)
		local valid, reason = Score.validate(nextScore, ctx.rules)
		if not valid then
			return false, reason
		end
		draft, dirty, pendingId = valid, true, nil
		render()
		return true, nil
	end
	function api.import(text: string): (boolean, string?)
		local value, reason = Score.import(text, ctx.rules, ctx.decode)
		if not value then
			return false, reason
		end
		part = 1
		return accept(value)
	end
	function api.selectPart(index: number): boolean
		if index % 1 ~= 0 or index < 1 or index > ctx.rules.maxParts then
			return false
		end
		if not draft.parts[index] then
			if index ~= #draft.parts + 1 then
				return false
			end
			local changed = Score.copy(draft)
			table.insert(changed.parts, { instrumentId = instruments[instrument], notes = {} })
			accept(changed)
		end
		part = index
		render()
		return true
	end
	function api.nextInstrument()
		instrument = instrument % #instruments + 1
		local changed = Score.copy(draft)
		changed.parts[part].instrumentId = instruments[instrument]
		accept(changed)
	end
	function api.tempo(value: number): (boolean, string?)
		local changed = Score.copy(draft)
		changed.tempo = value
		return accept(changed)
	end
	function api.toggle(tick: number, pitch: number, duration: number, velocity: number): (boolean, string?)
		local changed = Score.copy(draft)
		local notes = changed.parts[part].notes
		for index, note in notes do
			if note.startTick == tick and note.pitch == pitch then
				table.remove(notes, index)
				return accept(changed)
			end
		end
		table.insert(notes, { startTick = tick, pitch = pitch, durationTicks = duration, velocity = velocity })
		return accept(changed)
	end
	function api.save(): any
		pendingId = pendingId or ctx.requestId()
		local result = Transport.send(ctx, ctx.encode(draft), if saved then saved.scoreId else nil, pendingId :: string)
		if result.ok then
			saved, dirty, pendingId = result.data, false, nil
			Selection.set({ scoreId = saved.scoreId, revision = saved.revision, parts = #draft.parts, owned = true })
			render()
		end
		return result
	end
	function api.share(recipient: string): any
		if dirty or not saved then
			return { ok = false, reason = "score.unsaved" }
		end
		return ctx.send("survival-coop:score-share", { saved.scoreId, saved.revision, recipient })
	end
	function api.join(): any
		if dirty or not saved then
			return { ok = false, reason = "score.unsaved" }
		end
		return ctx.send("survival-coop:ensemble-join", { saved.scoreId, saved.revision, part })
	end
	function api.play()
		ctx.stop()
		playing = true
		for _, event in Score.schedule(draft, ctx.rules, ctx.serverNow()) do
			ctx.playAt(event, ctx.rules.instruments[event.instrumentId])
		end
		render()
	end
	function api.stop()
		ctx.stop()
		playing = false
		render()
	end
	function api.close(): boolean
		if dirty and not ctx.confirmDiscard() then
			return false
		end
		api.stop()
		return true
	end
	render()
	return api
end

--- Note label: pitch class plus octave (MIDI 60 = C4), a filled dot when selected.
local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
function M.noteLabel(pitch: number, selected: boolean): string
	local name = NOTE_NAMES[pitch % 12 + 1] .. tostring(pitch // 12 - 1)
	return if selected then "● " .. name else name
end

function M.factory(ctx: any): any
	local locale = ctx.locale or "en"
	local ports = ctx.view
		or {
			new = function(class: string)
				return Instance.new(class)
			end,
			size = function(x: number, y: number, dx: number, dy: number)
				return UDim2.new(x, dx, y, dy)
			end,
			position = function(x: number, y: number, dx: number, dy: number)
				return UDim2.new(x, dx, y, dy)
			end,
		}
	-- Docked under ExtensionPanels the editor is the shared themed sheet (dark panel, accent
	-- header, red close) fitted by ctx.fitSheet like every other menu sheet.
	local ui = ctx.ui
	local theme = if ui then ui.theme.default else nil
	local connections = {}
	local gui = ports.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "ScoreEditorPanel", false, 24
	gui.Parent = ctx.playerGui or game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local sheet: any, scroll: any, close: any
	local unfit: any = nil
	if ui then
		local mounted = ui.components.modalSheet(theme, {
			name = "ScoreEditor",
			title = Text.text(locale, "editor_title"),
			parent = gui,
		})
		sheet, scroll, close = mounted.frame, mounted.scroll, mounted.close
		sheet.Visible = true
		if ctx.fitSheet then
			ctx.fitSheet(sheet)
		end
	else
		sheet = ports.new("Frame")
		sheet.Name = "Workspace"
		sheet.Parent = gui
		local function resize(width: number, height: number)
			local bounds = M.bounds(width, height)
			sheet.Size = ports.size(0, 0, bounds.width, bounds.height)
			sheet.Position = ports.position(0, 0, bounds.x, bounds.y)
		end
		if ctx.onViewport then
			unfit = ctx.onViewport(resize)
		elseif not ctx.view then
			local function fit()
				resize(gui.AbsoluteSize.X, gui.AbsoluteSize.Y)
			end
			table.insert(connections, gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit))
			fit()
		else
			resize(800, 600)
		end
		scroll = ports.new("ScrollingFrame")
		scroll.Name = "Controls"
		scroll.Size = ports.size(1, 1, 0, -48)
		scroll.Position = ports.position(0, 0, 0, 48)
		scroll.CanvasSize = ports.size(0, 0, 0, 1500)
		scroll.Parent = sheet
		close = ports.new("TextButton")
		close.Name, close.Text = "Close", Text.text(locale, "editor_close")
		close.Size, close.Position = ports.size(0, 0, 88, 44), ports.position(1, 0, -92, 2)
		close.Parent = sheet
	end
	local row = 0
	local api: any
	local status: any
	table.insert(
		connections,
		close.Activated:Connect(function()
			-- Hiding preserves the draft, so closing never requires discarding unsaved notes.
			api.stop()
			gui.Enabled = false
		end)
	)
	local function place(item: any, name: string, height: number)
		item.Name = name
		item.LayoutOrder = row
		if not ui then
			item.Size = ports.size(1, 0, -16, height)
			item.Position = ports.position(0, 0, 8, row * 56)
		end
		item.Parent = scroll
		row += 1
	end
	local function control(class: string, name: string, text: string, action: (() -> ())?): any
		local item: any
		if ui and class == "TextButton" then
			item = ui.components.button(theme, { text = text, size = UDim2.new(1, 0, 0, 48), onClick = action })
		elseif ui and class == "TextLabel" then
			item = ui.components.label(theme, { text = text, size = UDim2.new(1, 0, 0, 48) })
		else
			item = ports.new(class)
			item.Text = text
			item.TextSize = 16
			if ui then
				-- Same dark input box as MusicSheet.box.
				item.Size = UDim2.new(1, 0, 0, 48)
				item.ClearTextOnFocus, item.TextWrapped = false, true
				item.BackgroundColor3, item.TextColor3 = Color3.fromRGB(18, 28, 26), Color3.fromRGB(240, 244, 240)
			end
			if action then
				table.insert(connections, item.Activated:Connect(action))
			end
		end
		place(item, name, 48)
		return item
	end
	local function result(value: any)
		status.Text = if value.ok then Text.text(locale, "editor_saved") else Text.refusal(locale, value.reason)
	end
	local tempoLabel = control("TextLabel", "TempoLabel", Text.text(locale, "editor_tempo_label"), nil)
	if not ui then
		tempoLabel.BackgroundTransparency = 1
	end
	local tempo = control("TextBox", "Tempo", tostring(ctx.rules.tempoMin), nil)
	tempo.PlaceholderText = Text.text(locale, "editor_tempo")
	table.insert(
		connections,
		tempo.FocusLost:Connect(function()
			local ok, reason = api.tempo(tonumber(tempo.Text) or 0)
			if not ok then
				status.Text = Text.refusal(locale, reason)
			end
		end)
	)
	control("TextButton", "Instrument", Text.text(locale, "editor_instrument"), function()
		api.nextInstrument()
	end)
	for index = 1, ctx.rules.maxParts do
		control("TextButton", "Part" .. index, Text.text(locale, "lobby_part", index), function()
			api.selectPart(index)
		end)
	end
	local step = ctx.rules.ticksPerQuarter
	local firstPitch = math.max(ctx.rules.pitchMin, 60)
	local cells: { any } = {}
	-- Horizontal scrolling preserves 48px note targets on a narrow phone rather than shrinking.
	local grid = ports.new("ScrollingFrame")
	grid.CanvasSize = ports.size(0, 0, 8 * 56, 4 * 56)
	if ui then
		grid.Size = UDim2.new(1, 0, 0, 224)
		grid.BackgroundTransparency, grid.BorderSizePixel = 1, 0
	end
	place(grid, "NoteGrid", 224)
	row += 3
	for pitchOffset = 0, 3 do
		for beat = 0, 7 do
			local pitch = firstPitch + pitchOffset
			local cell = ports.new("TextButton")
			cell.Name = "Note_" .. pitchOffset .. "_" .. beat
			cell.Text = M.noteLabel(pitch, false)
			cell.TextSize = 16
			cell.Size = ports.size(0, 0, 48, 48)
			cell.Position = ports.position(0, 0, beat * 56, pitchOffset * 56)
			if ui then
				cell.BackgroundColor3, cell.TextColor3 = Color3.fromRGB(18, 28, 26), Color3.fromRGB(240, 244, 240)
				cell.BorderSizePixel = 0
			end
			cell.Parent = grid
			table.insert(cells, { ui = cell, tick = beat * step, pitch = pitch })
			table.insert(
				connections,
				cell.Activated:Connect(function()
					local ok, reason = api.toggle(beat * step, pitch, step, ctx.rules.velocityMax)
					if not ok then
						status.Text = Text.refusal(locale, reason)
					end
				end)
			)
		end
	end
	local json = control("TextBox", "ImportText", "", nil)
	json.PlaceholderText = "{ }"
	control("TextButton", "Import", Text.text(locale, "import_check"), function()
		local ok, reason = api.import(json.Text)
		status.Text = if ok then Text.text(locale, "editor_imported") else Text.refusal(locale, reason)
	end)
	control("TextButton", "Save", Text.text(locale, "import_save"), function()
		result(api.save())
	end)
	control("TextButton", "Play", Text.text(locale, "editor_play"), function()
		api.play()
	end)
	control("TextButton", "Stop", Text.text(locale, "editor_stop"), function()
		api.stop()
	end)
	local recipient = control("TextBox", "Recipient", "", nil)
	recipient.PlaceholderText = Text.text(locale, "share_recipient")
	control("TextButton", "Share", Text.text(locale, "share_send"), function()
		result(api.share(recipient.Text))
	end)
	control("TextButton", "Join", Text.text(locale, "editor_join"), function()
		result(api.join())
	end)
	control("TextButton", "Ready", Text.text(locale, "lobby_ready"), function()
		result(ctx.send("survival-coop:ensemble-ready", { true }))
	end)
	control("TextButton", "Start", Text.text(locale, "lobby_start"), function()
		result(ctx.send("survival-coop:ensemble-start", {}))
	end)
	control("TextButton", "Leave", Text.text(locale, "play_leave"), function()
		result(ctx.send("survival-coop:ensemble-leave", {}))
	end)
	status = control("TextLabel", "Status", "", nil)
	if not ui then
		scroll.CanvasSize = ports.size(0, 0, 0, row * 56)
	end
	local model = table.clone(ctx)
	model.render = function(value: any)
		local current = value.score.parts[value.part]
		status.Text = Text.text(
			locale,
			"editor_status",
			Text.instrument(locale, current.instrumentId),
			value.part,
			if value.dirty then " *" else ""
		)
		for _, cell in cells do
			local selected = false
			for _, note in current.notes do
				if note.startTick == cell.tick and note.pitch == cell.pitch then
					selected = true
				end
			end
			cell.ui.Text = M.noteLabel(cell.pitch, selected)
		end
	end
	api = M.new(model)
	local dock = if ctx.dock
		then ctx.dock({
			id = "music",
			label = Text.text(locale, "nav_music"),
			order = 9,
			setOpen = function(open: boolean)
				gui.Enabled = open
			end,
			isOpen = function()
				return gui.Enabled
			end,
		})
		else nil
	gui.Enabled = ctx.dock == nil
	return {
		controller = api,
		gui = gui,
		destroy = function()
			api.stop()
			if unfit then
				unfit()
			end
			for _, connection in connections do
				connection:Disconnect()
			end
			if dock then
				dock.setAvailable(false)
			end
			gui:Destroy()
		end,
	}
end
return M
