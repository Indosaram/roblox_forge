--!strict
-- Real Roblox GUI; the injected view ports also permit deterministic interaction specs.
local Score = require("../../../core/domain/music/Score")
local Transport = require("./ScoreTransport")
-- Roblox globals are read from the environment so this module also type-checks under lune.
local env: any = getfenv()
local game: any = env.game
local Instance: any = env.Instance
local UDim2: any = env.UDim2
local M = {}
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

function M.factory(ctx: any): any
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
	local connections = {}
	local gui = ports.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "ScoreEditorPanel", false, 24
	gui.Parent = ctx.playerGui or game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local sheet = ports.new("Frame")
	sheet.Name = "Workspace"
	sheet.Size = ports.size(1, 1, -32, -96)
	sheet.Position = ports.position(0, 0, 16, 56)
	sheet.Parent = gui
	local scroll = ports.new("ScrollingFrame")
	scroll.Name = "Controls"
	scroll.Size = ports.size(1, 1, 0, 0)
	scroll.CanvasSize = ports.size(0, 0, 0, 1500)
	scroll.Parent = sheet
	local row = 0
	local api: any
	local status: any
	local function control(class: string, name: string, text: string, action: (() -> ())?): any
		local item = ports.new(class)
		item.Name, item.Text = name, text
		item.TextSize = 16
		item.Size = ports.size(1, 0, -16, 48)
		item.Position = ports.position(0, 0, 8, row * 56)
		item.Parent = scroll
		row += 1
		if action then
			table.insert(connections, item.Activated:Connect(action))
		end
		return item
	end
	local function result(value: any)
		status.Text = if value.ok then "Saved" else tostring(value.reason)
	end
	local tempo = control("TextBox", "Tempo", tostring(ctx.rules.tempoMin), nil)
	table.insert(
		connections,
		tempo.FocusLost:Connect(function()
			local ok, reason = api.tempo(tonumber(tempo.Text) or 0)
			if not ok then
				status.Text = tostring(reason)
			end
		end)
	)
	control("TextButton", "Instrument", "Next instrument", function()
		api.nextInstrument()
	end)
	for index = 1, ctx.rules.maxParts do
		control("TextButton", "Part" .. index, "Part " .. index, function()
			api.selectPart(index)
		end)
	end
	local step = ctx.rules.ticksPerQuarter
	local firstPitch = math.max(ctx.rules.pitchMin, 60)
	local cells: { any } = {}
	-- Horizontal scrolling preserves 48px note targets on a narrow phone rather than shrinking.
	local grid = ports.new("ScrollingFrame")
	grid.Name = "NoteGrid"
	grid.Size = ports.size(1, 0, -16, 224)
	grid.Position = ports.position(0, 0, 8, row * 56)
	grid.CanvasSize = ports.size(0, 0, 8 * 56, 4 * 56)
	grid.Parent = scroll
	row += 4
	for pitchOffset = 0, 3 do
		for beat = 0, 7 do
			local cell = ports.new("TextButton")
			cell.Name = "Note_" .. pitchOffset .. "_" .. beat
			cell.Text = tostring(firstPitch + pitchOffset)
			cell.TextSize = 16
			cell.Size = ports.size(0, 0, 48, 48)
			cell.Position = ports.position(0, 0, beat * 56, pitchOffset * 56)
			cell.Parent = grid
			table.insert(cells, { ui = cell, tick = beat * step, pitch = firstPitch + pitchOffset })
			table.insert(
				connections,
				cell.Activated:Connect(function()
					local ok, reason = api.toggle(beat * step, firstPitch + pitchOffset, step, ctx.rules.velocityMax)
					if not ok then
						status.Text = tostring(reason)
					end
				end)
			)
		end
	end
	local json = control("TextBox", "ImportText", "", nil)
	control("TextButton", "Import", "Import JSON", function()
		local ok, reason = api.import(json.Text)
		status.Text = if ok then "Imported" else tostring(reason)
	end)
	control("TextButton", "Save", "Save revision", function()
		result(api.save())
	end)
	control("TextButton", "Play", "Play", function()
		api.play()
	end)
	control("TextButton", "Stop", "Stop", function()
		api.stop()
	end)
	local recipient = control("TextBox", "Recipient", "", nil)
	control("TextButton", "Share", "Share saved revision", function()
		result(api.share(recipient.Text))
	end)
	control("TextButton", "Close", "Close", function()
		if api.close() then
			gui.Enabled = false
		end
	end)
	status = control("TextLabel", "Status", "", nil)
	scroll.CanvasSize = ports.size(0, 0, 0, row * 56)
	local model = table.clone(ctx)
	model.render = function(value: any)
		local current = value.score.parts[value.part]
		status.Text = current.instrumentId .. " / part " .. value.part .. (if value.dirty then " *" else "")
		for _, cell in cells do
			local selected = false
			for _, note in current.notes do
				if note.startTick == cell.tick and note.pitch == cell.pitch then
					selected = true
				end
			end
			cell.ui.Text = (if selected then "[x] " else "[ ] ") .. cell.pitch
		end
	end
	api = M.new(model)
	local dock = if ctx.dock
		then ctx.dock({
			id = "music",
			label = "Music",
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
