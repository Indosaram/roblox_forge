--!strict
-- ui.inbox expedition results: rows render from the durable results ledger (newest first),
-- Claim goes through the expedition claim verb (server-authoritative, once), claimed rows show
-- as received, Korean copy carries no raw ids, and every row fits 360x640 and 1280x720.
-- Host-only: needs the robango generated catalog; marker: require("@lune/task")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Inbox = require("./InboxPanel")
local Text = require("./FarmCraftText")
local Sheet = require("./FarmCraftSheet")
local Extension = require("./ExpeditionExtension")
local Rewards = require("./MissionRewards")
local HUDModel = require("./SurvivalHUDModel")
local HudFit = require("../../../core/ui-kit/genre/HudFit")
local Content: any = luau.load(fs.readFile("games/robango-island/src/shared/SurvivalContent.luau"))()

local function fixture(): any
	return {
		resultsLedger = {
			old = {
				id = "old",
				source = "expedition:rw.a1",
				index = 1,
				stage = 4,
				openedAt = 100,
				items = {},
				coins = 40,
				xp = 30,
				claimed = true,
			},
			new = {
				id = "new",
				source = "expedition:rw.a2",
				index = 2,
				stage = 2,
				openedAt = 900,
				items = { { item = "wood", quantity = 3 } },
				coins = 75,
				xp = 60,
				claimed = false,
			},
		},
	}
end

local function harness(locale: string): any
	local h: any = { documents = { a = fixture() }, sends = {}, claims = 0 }
	h.extension = Extension.new({
		content = Content,
		now = function()
			return 1000
		end,
		facts = function()
			return { level = 1, developmentRank = 0, instabilityAccess = 1 }
		end,
		document = function(actor)
			return h.documents[actor]
		end,
		layoutId = function()
			return nil
		end,
		position = function()
			return nil
		end,
		online = function()
			return true
		end,
		onExpedition = function()
			return false
		end,
		claim = function(actor, id)
			local ok, reason = Rewards.claim(h.documents[actor], id)
			if ok then
				h.claims += 1
			end
			return { ok = ok, reason = reason }
		end,
		travel = function()
			return { ok = true }
		end,
	})
	local function node(): any
		local raw: any = { Activated = {
			Connect = function()
				return { Disconnect = function() end }
			end,
		} }
		function raw.Destroy(self)
			self.destroyed = true
		end
		return setmetatable({}, {
			__index = raw,
			__newindex = function(self, key, value)
				if key == "Parent" and type(value) == "table" then
					value.children = value.children or {}
					table.insert(value.children, self)
				end
				raw[key] = value
			end,
		})
	end
	local function widget(_theme: any, props: any): any
		local value = node()
		value.Text, value.Size, value.Position, value.Parent = props.text, props.size, props.position, props.parent
		value.onClick = props.onClick
		return value
	end
	local scroll = node()
	local hub: any = {
		content = Content,
		state = {},
		name = function(id: string): string
			return require("../../../games/robango-island/PackText.fixture").names(locale)[id] or id
		end,
	}
	local ctx: any = {
		locale = locale,
		names = {},
		-- The pack resolver shape (ItemIcons): one published image per catalog id.
		icons = {
			item = function(id: string): any
				return { image = "rbxassetid://" .. #id, category = "item", text = id }
			end,
		},
		instance = {
			new = function()
				return node()
			end,
		},
		enum = { ZIndexBehavior = { Sibling = "Sibling" } },
		udim2 = {
			new = function(...)
				return { ... }
			end,
			fromScale = function(...)
				return { ... }
			end,
		},
		game = {
			GetService = function()
				return { LocalPlayer = {
					WaitForChild = function()
						return {}
					end,
				} }
			end,
		},
		ui = {
			theme = { default = {} },
			components = {
				modalSheet = function(_theme: any, props: any): any
					h.title = props.title
					return { frame = node(), scroll = scroll, close = { Activated = node().Activated } }
				end,
				label = widget,
				button = widget,
			},
		},
		-- The real wire: the action reaches the expedition extension's command handler.
		send = function(action: string, args: any): any
			table.insert(h.sends, { action = action, args = args })
			local result = h.extension.command("a", action, args, {}, "client", function()
				return { ok = true }
			end)
			hub.state.expedition = h.extension.snapshot("a")
			return result
		end,
	}
	h.hub = hub
	h.sheet = Inbox.mount(ctx, hub)
	function h.refresh()
		hub.state.expedition = h.extension.snapshot("a")
		h.sheet.open()
	end
	function h.rows(): { any }
		local out = {}
		for _, row in scroll.children or {} do
			if not row.destroyed then
				table.insert(out, row)
			end
		end
		table.sort(out, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		return out
	end
	function h.controls(): { any }
		local out = {}
		for _, row in h.rows() do
			for _, child in row.children or {} do
				table.insert(out, child)
			end
		end
		return out
	end
	function h.find(name: string): any
		for _, child in h.controls() do
			if child.Name == name then
				return child
			end
		end
		return nil
	end
	function h.texts(): { string }
		local out = {}
		for _, child in h.controls() do
			table.insert(out, child.Text)
		end
		return out
	end
	return h
end

-- A craft job entry of the workshop snapshot (FarmCraftModel.inbox reads job.state/outputs).
local function job(state: string, catalogId: string, quantity: number): any
	return {
		job = {
			recipeId = catalogId,
			state = state,
			inputs = { { itemId = "in", catalogId = "fiber", quantity = 2 } },
			outputs = { { itemId = "out", catalogId = catalogId, quantity = quantity } },
		},
	}
end

local function workshop(entries: any): any
	return { snapshots = { ["survival-coop"] = { workshop = { actorId = "a", entries = entries } } } }
end

local function route(locale: string, index: number): string
	local ExpeditionText = require("./ExpeditionText")
	local biome = nil
	for _, layout in Content.layouts do
		if layout.id == "rw.a" .. index .. ".s1" then
			biome = layout.biomes[1]
		end
	end
	return ExpeditionText.text(locale, "exp_route", index, ExpeditionText.biome(locale, {}, biome))
end

return {
	["expedition ledger rows render newest first with claimed rows marked received"] = function()
		local h = harness("en-us")
		h.refresh()
		local texts = h.texts()
		local fresh = Text.text("en-us", "inbox_expedition", route("en-us", 2), 75, 60)
		local received = Text.text("en-us", "inbox_expedition_received", route("en-us", 1), 40, 30)
		local first, second = table.find(texts, fresh), table.find(texts, received)
		assert(first and second and first < second, "newest first: " .. table.concat(texts, " | "))
		assert(h.find("ClaimExpedition-new"), "unclaimed row has Claim")
		assert(h.find("ClaimExpedition-old") == nil, "claimed row has no Claim")
		local wood = require("../../../games/robango-island/PackText.fixture").names("en-us").wood
		assert(table.find(texts, Text.text("en-us", "inbox_expedition_items", wood .. " x3")), "items listed")
	end,
	["claim from the inbox goes through the expedition claim verb once"] = function()
		local h = harness("en-us")
		h.refresh()
		h.find("ClaimExpedition-new").onClick()
		local sent = h.sends[#h.sends]
		assert(
			sent.action == "survival-coop:party-action" and sent.args[1] == "claim" and sent.args[2] == "new",
			"verb"
		)
		assert(h.claims == 1 and h.documents.a.resultsLedger.new.claimed, "claimed durably once")
		assert(h.find("ClaimExpedition-new") == nil, "row now received")
		assert(
			table.find(h.texts(), Text.text("en-us", "inbox_expedition_received", route("en-us", 2), 75, 60)),
			"received text"
		)
		local again = h.extension.command("a", Extension.ACTION, { "claim", "new" }, {}, "client", function()
			return { ok = true }
		end)
		assert(not again.ok and again.reason == "ledger_claimed" and h.claims == 1, "second claim refused")
		assert(Text.refusal("ko-kr", "ledger_claimed") == "이미 받았어요", "localized refusal")
	end,
	-- p134 v53 (phone): the inbox listed every finished craft job as plain text, "환불됨: 으깬 딸기죽
	-- x1 (작업 w11:1173)" / "제작 완료: 꼰 끈 x1 (작업 w11:1173)" repeated, with no icon or grouping,
	-- and the U6 empty card never showed. Finished (committed / cancelled) jobs are already in the
	-- bag: they are not inbox rows. Ready output is one icon row per item, summed, without job ids.
	["finished craft jobs leave the empty card; ready output is one grouped icon row without job ids"] = function()
		for _, locale in { "ko-kr", "en-us" } do
			local h = harness(locale)
			h.documents.a.resultsLedger = {}
			h.hub.state.packet = workshop({
				["w11:1173"] = job("Cancelled", "berry-meal", 1),
				["w11:1174"] = job("Committed", "capture-bola", 1),
				["w11:1175"] = job("Committed", "cord", 1),
				["w11:1176"] = job("Committed", "cord", 1),
			})
			h.refresh()
			local texts = table.concat(h.texts(), " | ")
			assert(
				texts == Text.text(locale, "inbox_empty") .. "\n" .. Text.text(locale, "inbox_empty_hint"),
				locale .. " finished jobs show the empty card, got: " .. texts
			)
			h.hub.state.packet = workshop({
				["w11:1175"] = job("Ready", "cord", 1),
				["w11:1176"] = job("Ready", "cord", 2),
				["w11:1177"] = job("Committed", "cord", 1),
				["w11:1178"] = job("Ready", "capture-bola", 1),
			})
			h.refresh()
			local name = require("../../../games/robango-island/PackText.fixture").names(locale)
			local cord = Text.text(locale, "inbox_crafted", name.cord .. " x3")
			local bola = Text.text(locale, "inbox_crafted", name["capture-bola"] .. " x1")
			local rows = h.rows()
			assert(
				#rows == 2,
				locale .. " one row per ready item, got " .. #rows .. ": " .. table.concat(h.texts(), " | ")
			)
			for index, want in { cord, bola } do
				local label = rows[index].children[1]
				assert(label.Text == want, locale .. " row " .. index .. ": " .. tostring(label.Text))
				local icon = label.children and label.children[1]
				assert(icon and icon.Name == "ItemIcon", locale .. " row " .. index .. " has an item icon")
				assert(string.match(icon.Image, "^rbxassetid://%d+$"), "icon art from the pack resolver")
			end
			for _, text in h.texts() do
				assert(not string.find(text, "w11", 1, true), locale .. " raw job id in: " .. text)
			end
			-- Collect completes every ready job of the item.
			local before = #h.sends
			h.find("Collect-w11:1175").onClick()
			local jobs = {}
			for index = before + 1, #h.sends do
				assert(h.sends[index].action == "survival-coop:craft-complete", "collect verb")
				table.insert(jobs, h.sends[index].args[1])
			end
			table.sort(jobs)
			assert(
				table.concat(jobs, ",") == "w11:1175,w11:1176",
				"both cord jobs collected: " .. table.concat(jobs, ",")
			)
		end
	end,
	["korean inbox text carries no raw ids and fits 360x640 and 1280x720"] = function()
		for _, locale in { "ko-kr", "en-us" } do
			local h = harness(locale)
			h.refresh()
			assert(
				table.find(h.texts(), Text.text(locale, "inbox_expedition", route(locale, 2), 75, 60)),
				locale .. " expedition row rendered"
			)
			for _, text in h.texts() do
				for _, raw in { "rw.a", "expedition:", "new", "old", "wood", "ledger" } do
					assert(not string.find(text, raw, 1, true), locale .. " raw id '" .. raw .. "' in: " .. text)
				end
			end
			for _, viewport in { { 360, 640, true }, { 1280, 720, false } } :: { { any } } do
				local _, _, w = HUDModel.contextSheet(viewport[1], viewport[2], viewport[3])
				local content = w - 16 - 6
				assert(HudFit.textWidth(h.title, 15) <= w - 70, "title fits")
				for _, child in h.controls() do
					local width = child.Size[1] * content
					assert(width >= 44, "control under 44px")
					local fitted = false
					for size = 15, HudFit.MIN_TEXT_SIZE, -1 do
						local lines = math.ceil(HudFit.textWidth(child.Text, size) / math.max(1, width - 8))
						if lines * size * 1.2 <= Sheet.ROW then
							fitted = true
							break
						end
					end
					assert(fitted, locale .. " " .. viewport[1] .. "x" .. viewport[2] .. " overflows: " .. child.Text)
				end
			end
		end
	end,
}
