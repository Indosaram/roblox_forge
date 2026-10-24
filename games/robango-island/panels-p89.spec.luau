--!strict
-- p89: the tamed-animals sheet always shows its companions or a how-to-tame empty state, and
-- every expedition stage objective in content renders as a localized line with no raw id/verb.
local fs = require("@lune/fs")
local Content = require("./src/shared/SurvivalContent")
local PackText = require("./PackText.fixture")
local Strings = require("../../core/infra/localization/Strings")
local Taming = require("../../genres/survival-coop/module/TamingPanel")
local ExpeditionText = require("../../genres/survival-coop/module/ExpeditionText")
local Models = require("../../genres/survival-coop/module/ExpeditionModels")

local LOCALES = { "en-us", "ko-kr" }

local function csvRows(): { [string]: { string } }
	local rows = {}
	for _, row in Strings.parseCsv(fs.readFile("games/robango-island/locale/strings.csv")).rows do
		rows[row[1]] = row
	end
	return rows
end

-- A minimal fake engine: enough Instance/UDim2/Color3 for TamingPanel.factory to render.
local function mount(locale: string, content: any): (any, (any) -> ())
	local nodes: { any } = {}
	local methods: any = {}
	methods.__index = methods
	function methods:IsA(kind)
		return self.ClassName == kind or (kind == "Frame" and self.ClassName == "Frame")
	end
	function methods:Destroy()
		self.Parent = nil
	end
	function methods:GetChildren()
		local out = {}
		for _, item in nodes do
			if item.Parent == self then
				table.insert(out, item)
			end
		end
		return out
	end
	function methods:WaitForChild()
		return self
	end
	local function signal()
		return {
			Connect = function()
				return { Disconnect = function() end }
			end,
		}
	end
	local function node(class: string?): any
		local item = setmetatable({ ClassName = class or "Frame", Name = class or "Frame" }, methods)
		item.Activated = signal()
		table.insert(nodes, item)
		return item
	end
	local playerGui = node("PlayerGui")
	local env: any = table.clone(getfenv())
	env.game = {
		GetService = function(_self, name)
			if name == "Players" then
				return { LocalPlayer = {
					WaitForChild = function()
						return playerGui
					end,
				} }
			end
			return { InputBegan = signal() }
		end,
	}
	env.workspace = {
		GetServerTimeNow = function()
			return 1000
		end,
	}
	env.task = { spawn = function() end, wait = function() end }
	env.require = function(path: string)
		if path == "./PackLocale" then
			return require("../../genres/survival-coop/module/PackLocale")
		end
		assert(path == "./WildlifeNames", "unexpected require " .. path)
		return require("../../genres/survival-coop/module/WildlifeNames")
	end
	env.Instance = { new = node }
	env.Enum = { ZIndexBehavior = { Sibling = 1 }, AutomaticSize = { Y = 1 } }
	env.UDim2 = { new = function() end, fromOffset = function() end, fromScale = function() end }
	env.UDim = { new = function() end }
	env.Color3 = {
		fromRGB = function(r, g, b)
			return { r = r, g = g, b = b }
		end,
	}
	local chunk = assert(loadstring(fs.readFile("genres/survival-coop/module/TamingPanel.luau")))
	setfenv(chunk, env)
	local panel = chunk()
	local listener: any = nil
	local function make(props: any, class: string): any
		local item = node(class)
		item.Text, item.Parent = props.text, props.parent
		return item
	end
	local scroll = node("ScrollingFrame")
	panel.factory({
		locale = locale,
		content = content,
		send = function()
			return { ok = true }
		end,
		onSnapshot = function(callback)
			listener = callback
			return function() end
		end,
		ui = {
			theme = { default = {} },
			components = {
				modalSheet = function()
					return { frame = node(), close = node(), scroll = scroll }
				end,
				label = function(_theme, props)
					return make(props, "TextLabel")
				end,
				button = function(_theme, props)
					return make(props, "TextButton")
				end,
				progressBar = function()
					return node(), function() end
				end,
			},
		},
	})
	local function texts(): { [string]: string }
		local out = {}
		for _, item in nodes do
			local parent = item.Parent
			while parent and parent ~= scroll do
				parent = parent.Parent
			end
			if parent == scroll and item.Text then
				out[item.Name] = item.Text
			end
		end
		return out
	end
	return texts, function(snapshot)
		listener(snapshot)
	end
end

return {
	["the tamed-animals sheet shows a how-to-tame empty state for an empty or missing snapshot"] = function()
		for _, locale in LOCALES do
			local texts, push = mount(locale, Content)
			for _, snapshot in { {}, { taming = { companions = { pets = {}, receipts = {} }, animals = {} } } } do
				push(snapshot)
				local shown = texts()
				assert(shown.CompanionEmpty == Taming.text(locale, "companion_empty"), "empty state " .. locale)
				assert(string.find(shown.CompanionSummary, "0/8", 1, true), "summary shows capacity")
			end
		end
	end,
	["each owned companion shows species, phase, level, fullness, colour chip and its actions"] = function()
		local pets = {
			a = {
				id = "a",
				species = "boar",
				phase = "Deployed",
				satiety = 70,
				feeds = 0,
				readyAt = 0,
				injuredUntil = 0,
				saddle = true,
			},
			b = {
				id = "b",
				species = "deer",
				phase = "Taming",
				satiety = 100,
				feeds = 1,
				readyAt = 1000 * 1000 + 90000,
				injuredUntil = 0,
				saddle = false,
			},
			c = {
				id = "c",
				species = "dodo",
				phase = "Stored",
				satiety = 100,
				feeds = 0,
				readyAt = 0,
				injuredUntil = 0,
				saddle = false,
			},
		}
		local state = { companions = { pets = pets, deployed = "a", ride = nil } }
		local summary, rows = Taming.companions("ko-kr", state, Content, 1000 * 1000)
		assert(summary == "보유 3/8 · 함께 다니는 중 1/1", summary)
		assert(#rows == 3 and rows[1].id == "a" and rows[2].id == "b", "sorted rows")
		assert(rows[1].title == "멧돼지 · 함께 다니는 중", rows[1].title)
		assert(string.find(rows[1].detail, "포만감 70/100", 1, true), rows[1].detail)
		assert(rows[1].color ~= nil, "species colour chip")
		assert(table.find(rows[1].actions, "mount") and table.find(rows[1].actions, "recall"), "deployed actions")
		assert(
			string.find(rows[2].detail, "먹이 1/3", 1, true) and string.find(rows[2].detail, "1:30", 1, true),
			rows[2].detail
		)
		assert(table.find(rows[3].actions, "release:c") and table.find(rows[3].actions, "saddle"), "stored actions")
		local _, en = Taming.companions("en-us", state, Content, 1000 * 1000)
		assert(en[1].title == "Boar · Out with you", en[1].title)
		local texts, push = mount("en-us", Content)
		push({ taming = state })
		local shown = texts()
		assert(shown.CompanionEmpty == nil and shown["mount-a"] == "Mount", "rendered pet actions")
		assert(shown.CompanionDetail ~= nil and not string.find(shown.CompanionDetail, "%%"), "stats line")
	end,
	["every stage objective in content renders localized with no raw id or verb"] = function()
		local count = 0
		for _, locale in LOCALES do
			local names = PackText.names(locale)
			for _, stage in Content.stages do
				for _, objective in stage.objectives do
					count += 1
					local row = table.clone(objective) :: any
					row.progress = 0
					local line = ExpeditionText.objective(locale, names, row)
					local where = locale .. " " .. objective.id .. ": " .. line
					assert(not string.find(line, objective.target, 1, true), "raw target " .. where)
					assert(not string.find(line, "rw.", 1, true) and not string.find(line, "%%"), where)
					assert(not string.find(line, objective.action, 1, true), "raw verb " .. where)
					assert(string.find(line, "0/" .. objective.quantity, 1, true), "progress " .. where)
					local thing = ExpeditionText.text(locale, "exp_obj_thing")
					local fallback = ExpeditionText.objective(
						locale,
						{},
						{ action = objective.action, target = "?", quantity = objective.quantity }
					)
					fallback = if string.find(fallback, thing, 1, true) then fallback else nil :: any
					assert(line ~= fallback, "unnamed target " .. where)
					assert(
						line ~= ExpeditionText.text(locale, "exp_obj_other", 0, objective.quantity),
						"unknown kind " .. where
					)
					if locale == "ko-kr" then
						assert(not string.find(line, "%a"), "English in KO " .. where)
					end
				end
			end
		end
		assert(count >= 80, "every stage objective checked")
		local wood = { id = "o", action = "gather", target = "wood", progress = 3, quantity = 5 }
		assert(
			ExpeditionText.objective("ko-kr", PackText.names("ko-kr"), wood) == "쓰러진 통나무 모으기 3/5",
			"ko gather"
		)
		local survey = { id = "s", action = "survey", target = "rw.a1.s1.survey", progress = 0, quantity = 1 }
		assert(ExpeditionText.objective("ko-kr", {}, survey) == "조사 지점 살펴보기 0/1", "ko survey")
		local tracker = { route = 1, stage = 1, expiresAt = 100, unlocked = false, objectives = { wood, survey } }
		local _, items = Models.expedition(
			"en-us",
			{ now = 0, tracker = tracker },
			PackText.names("en-us"),
			function() end
		)
		local lines = {}
		for _, item in items do
			if item.name and string.sub(item.name, 1, 10) == "Objective-" then
				table.insert(lines, item.text)
			end
		end
		assert(lines[1] == "Gather Wood 3/5" and lines[2] == "Survey the marked spot 0/1", table.concat(lines, " | "))
	end,
	["new taming and objective strings match strings.csv in both locales"] = function()
		local rows = csvRows()
		for key, entry in ExpeditionText.strings do
			if string.sub(key, 1, 8) == "exp_obj_" then
				local row = assert(rows[key], "csv row " .. key)
				assert(row[4] == entry[1] and row[5] == entry[2], "csv mismatch " .. key)
			end
		end
		for _, key in { "companion_empty", "companion_summary", "companion_stats", "companion_phase_Deployed" } do
			local row = assert(rows[key], "csv row " .. key)
			assert(row[4] == Taming.text("en-us", key) and row[5] == Taming.text("ko-kr", key), "csv mismatch " .. key)
		end
	end,
}
