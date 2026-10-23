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
			return require("../../../games/robango-island/src/shared/EntityNames")(locale)[id] or id
		end,
	}
	local ctx: any = {
		locale = locale,
		names = {},
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
		local wood = require("../../../games/robango-island/src/shared/EntityNames")("en-us").wood
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
