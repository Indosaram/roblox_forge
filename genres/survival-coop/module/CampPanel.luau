--!strict
-- Client panel for the camp ladder: current rung, project progress bars, contribute
-- buttons (item + quantity) and the visitor pass status. All state comes from
-- snapshot.survivalExtensions.camp; every action is a durable command through `send`.
-- Strings mirror games/robango-island/locale/strings.csv (camp_* keys).
local M = {}

export type Row = { id: string, label: string, delivered: number, need: number, locked: boolean }
export type Model = {
	role: string,
	rung: number,
	rungs: number,
	version: number,
	rows: { Row },
	pass: number?,
	cooldowns: number,
	facilities: { string },
}

local STRINGS: { [string]: { string } } = {
	camp_title = { "Camp", "캠프" },
	camp_rung = { "Rung", "단계" },
	camp_contribute = { "Give", "기부" },
	camp_complete = { "Finish project", "프로젝트 완료" },
	camp_locked = { "Locked", "잠김" },
	camp_visitor = { "Visitor pass", "방문 허가" },
	camp_visitor_none = { "No pass", "허가 없음" },
	camp_cooldown = { "Rejoin wait", "재가입 대기" },
	camp_facility = { "Facility", "시설" },
}

function M.text(locale: string, key: string): string
	local entry = STRINGS[key]
	assert(entry, "UNKNOWN_CAMP_STRING")
	return if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
end
M.keys = function(): { string }
	local keys = {}
	for key in STRINGS do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- Pure view model over a snapshot slice; `now` only decides pass status.
function M.model(slice: any, now: number): Model?
	if type(slice) ~= "table" or type(slice.ladder) ~= "table" then
		return nil
	end
	local rows: { Row } = {}
	local projects: { any } = {}
	for _, project in slice.ladder.projects do
		table.insert(projects, project)
	end
	table.sort(projects, function(left, right)
		return left.id < right.id
	end)
	for _, project in projects do
		local progress = slice.active[project.id]
		local delivered, need = 0, 0
		for _, cost in project.cost do
			need += cost.quantity
			delivered += if progress then math.min(progress.delivered[cost.item] or 0, cost.quantity) else 0
		end
		table.insert(rows, {
			id = project.id,
			label = project.id,
			delivered = delivered,
			need = need,
			locked = slice.rung < project.rung - 1,
		})
	end
	local facilities: { string } = {}
	for facility in slice.facilities do
		table.insert(facilities, facility)
	end
	table.sort(facilities)
	local cooldowns = 0
	for _ in slice.cooldowns or {} do
		cooldowns += 1
	end
	local pass: number? = nil
	if slice.pass and slice.pass.expiresAt > now then
		pass = slice.pass.expiresAt - now
	end
	return {
		role = slice.role,
		rung = slice.rung,
		rungs = #slice.ladder.rungs,
		version = slice.version,
		rows = rows,
		pass = pass,
		cooldowns = cooldowns,
		facilities = facilities,
	}
end

function M.factory(ctx: any): { destroy: () -> () }?
	local ui = ctx.ui
	local theme, components = ui.theme, ui.components
	local players = game:GetService("Players")
	local gui = Instance.new("ScreenGui")
	gui.Name = "CampPanel"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.Parent = (players.LocalPlayer :: Player):WaitForChild("PlayerGui")
	local frame = components.panel(theme, {
		name = "Camp",
		size = UDim2.fromOffset(300, 260),
		position = UDim2.new(1, -316, 0, 16),
		parent = gui,
		header = M.text(ctx.locale, "camp_title"),
	})
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 6)
	list.Parent = frame
	local summary = components.label(theme, { text = "", size = UDim2.new(1, 0, 0, 22), parent = frame })
	local rows: { Instance } = {}
	local latest: Model? = nil
	local function render(slice: any)
		local model = M.model(slice, os.time())
		latest = model
		gui.Enabled = model ~= nil
		for _, row in rows do
			row:Destroy()
		end
		table.clear(rows)
		if not model then
			return
		end
		summary.Text = string.format(
			"%s %d/%d  %s",
			M.text(ctx.locale, "camp_rung"),
			model.rung,
			model.rungs,
			if model.role == "visitor"
				then M.text(ctx.locale, "camp_visitor") .. ": " .. (if model.pass
					then tostring(model.pass) .. "s"
					else M.text(ctx.locale, "camp_visitor_none"))
				else M.text(ctx.locale, "camp_facility") .. " " .. #model.facilities
		)
		for _, row in model.rows do
			local holder = Instance.new("Frame")
			holder.Size = UDim2.new(1, 0, 0, 52)
			holder.BackgroundTransparency = 1
			holder.Parent = frame
			table.insert(rows, holder)
			components.label(theme, { text = row.label, size = UDim2.new(1, 0, 0, 18), parent = holder })
			local bar, setProgress = components.progressBar(theme, {
				size = UDim2.new(0.6, 0, 0, 14),
				position = UDim2.fromOffset(0, 24),
				parent = holder,
			})
			setProgress(if row.need > 0 then row.delivered / row.need else 0)
			bar.Name = "Progress_" .. row.id
			if not row.locked then
				components.button(theme, {
					text = M.text(ctx.locale, "camp_contribute"),
					size = UDim2.new(0.35, 0, 0, 44),
					position = UDim2.new(0.65, 0, 0, 4),
					parent = holder,
					onClick = function()
						local slot = (latest :: Model).version
						ctx.send("survival-coop:camp-contribute", { row.id, "starter-fiber", 1, slot })
					end,
				})
			end
		end
	end
	local unsubscribe = ctx.onSnapshot(function(snapshot)
		render(snapshot.camp)
	end)
	return {
		destroy = function()
			unsubscribe()
			gui:Destroy()
		end,
	}
end

return M
