--!strict
-- p134 v75 phone acceptance (SM-N981N, ko-kr, touch, 2400x1080 landscape) defects.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local Scene = require("./src/shared/OpeningScene")
local PackText = require("./PackText.fixture")

local function ko(key: string): string
	return assert(PackText.packText("ko-kr", key), key)
end

-- HudShell's runtime half on the Lune roblox globals (no `game`: the TextService measure is skipped
-- and the row estimate is what sizes the card).
local function shell(): any
	return luau.load(fs.readFile("genres/survival-coop/module/HudShell.luau"), {
		environment = table.clone(roblox),
	})()
end

-- A quest-card TextLabel double: the properties fitQuestText / fitQuestHeight touch.
local function card(width: number, text: string): any
	local pad = {
		PaddingLeft = roblox.UDim.new(0, 8),
		PaddingRight = roblox.UDim.new(0, 8),
		PaddingTop = roblox.UDim.new(),
		PaddingBottom = roblox.UDim.new(),
	}
	local cap: any = { Name = "QuestCap", ClassName = "UISizeConstraint" }
	local label: any = {
		Text = text,
		TextSize = 8,
		Size = roblox.UDim2.fromScale(1, 1),
		AbsoluteSize = roblox.Vector2.new(width, 0),
	}
	function label:FindFirstChildOfClass(class: string): any
		return if class == "UIPadding" then pad else nil
	end
	function label:FindFirstChild(name: string): any
		return if name == "QuestCap" then cap else nil
	end
	function label:GetChildren(): { any }
		return { cap }
	end
	return label
end

-- Rows `text` wraps to at `size` px in `inner` px, breaking at spaces (Hangul ~1 em, else ~0.55 em).
local function wrapped(text: string, size: number, inner: number): number
	local rows = 0
	for _, line in string.split(text, "\n") do
		local row, count = 0, 1
		for word in string.gmatch(line, "%S+") do
			local w = 0
			for _, code in utf8.codes(word) do
				w += if code >= 0x1100 then size else size * 0.55
			end
			local gap = if row > 0 then size * 0.3 else 0
			if row > 0 and row + gap + w > inner then
				count, row, gap = count + 1, 0, 0
			end
			while w > inner do
				count, w = count + 1, w - inner
			end
			row += gap + w
		end
		rows += count
	end
	return rows
end

return {
	-- B2: v74 #3 let the card grow to the action cluster, but long last lines still ended in '...'
	-- ('■ 섬유 3개...', '■ 마리트의 의뢰 수락...', '■ 봉화 켜기...', the drift isle's '(다가가서 버튼').
	-- The card's height came from AutomaticSize alone, and on the phone it came out one wrapped row
	-- short of what the padded (8 px each side) text drew, so the last row was truncated with
	-- TextTruncate.AtEnd. fitQuestText now sets a fixed height from the rows at the padded width
	-- (AutomaticSize still grows it).
	-- Fails on 87898fe6 (the height stayed 0 + AutomaticSize).
	["v75 B2: the quest card reserves a row for every wrapped line at phone widths"] = function()
		local Shell = shell()
		local size = Shell.QUEST_TEXT.touch
		local cases: { string } = {}
		for _, index in { Scene.INDEX.fiber, Scene.INDEX.accept, Scene.INDEX.beacon } do
			local state = Scene.new(0)
			state.index = index
			local title, lines = Scene.tracker(Scene.view(state, { items = {} } :: any), ko)
			table.insert(cases, assert(title, "card title") .. "\n" .. table.concat(lines, "\n"))
		end
		-- The drift-isle / village HUD card (genre ObjectiveTracker, same sizing).
		table.insert(
			cases,
			"목표: 쓰러진 통나무 0/5 · 조사 0/1\n첫 채집: 고사리 섬유 채집 (다가가서 버튼 누르기) 0/3"
		)
		-- Card widths: the SM-N981N landscape quest slot with and without the top bar, a wider phone.
		for _, screen in { { 914, 411, 58 }, { 914, 411, 0 }, { 1000, 450, 58 } } do
			local regions = Shell.regions(screen[1], screen[2], screen[3], true)
			local width = regions.quest.width
			for _, text in cases do
				local label = card(width, text)
				local limit = math.max(regions.quest.height, regions.cluster.y - 4 - regions.quest.y)
				Shell.fitQuestText(label, limit, true)
				local inner = width - 16
				-- Every row the padded text wraps to (a Hangul glyph ~1 em, so this never undercounts).
				local rows = wrapped(text, size, inner)
				assert(Shell.questRows == nil or Shell.questRows(text, size, inner) >= rows, "the card's own count")
				local lineCount = select(2, string.gsub(text, "\n", "")) + 1
				assert(rows >= lineCount, "at least one row per line")
				local need = math.min(rows * size + 12, limit)
				local where = string.format("%dx%d/%d %q", screen[1], screen[2], screen[3], text)
				assert(label.Size.Y.Scale == 0, "a fixed card height, " .. where)
				assert(
					label.Size.Y.Offset >= need,
					string.format("%d px for %d rows (%d), %s", label.Size.Y.Offset, rows, need, where)
				)
				assert(label.Size.Y.Offset <= limit, "still capped above the action cluster, " .. where)
			end
		end
		-- The live trackers use it: the opening card through fitQuestText, the HUD card every frame.
		local panels = fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")
		assert(string.find(panels, "HudShell.fitQuestHeight(tracker, nil)", 1, true), "HUD card")
	end,
}
