--!strict
-- Farming / crafting screens: every screen opens from its launcher, sends the real durable
-- command, shows the localized refusal and reflects the snapshot; every row fits the fitted
-- sheet at PC 1280x720, portrait 360x640 and landscape 640x339 in English and Korean.
-- Host-only: needs the robango generated catalog; marker: require("@lune/task")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Panels = require("./FarmCraftPanels")
local Text = require("./FarmCraftText")
local Sheet = require("./FarmCraftSheet")
local HUDModel = require("./SurvivalHUDModel")
local HudFit = require("../../../core/ui-kit/genre/HudFit")
local Content: any = luau.load(fs.readFile("games/robango-island/src/shared/SurvivalContent.luau"))()

local VIEWPORTS: { { any } } = { { 1280, 720, false }, { 360, 640, true }, { 640, 339, true } }

local function harness(locale: string, reply: (string, any) -> any): any
	local sends, docks, roots = {}, {}, {}
	local listener: any = nil
	local function signal(): any
		local value: any = {}
		function value.Connect(_, callback)
			value.callback = callback
			return { Disconnect = function() end }
		end
		return value
	end
	local function node(): any
		local raw: any = {
			Activated = signal(),
			Destroy = function(self)
				self.destroyed = true
			end,
		}
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
	local scrolls: { [string]: any } = {}
	local ctx: any = {
		locale = locale,
		names = {},
		instance = {
			new = function(class: string): any
				local value = node()
				value.ClassName = class
				return value
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
					local scroll = node()
					scrolls[props.name] = scroll
					roots[props.name] = props.title
					return { frame = node(), scroll = scroll, close = { Activated = signal() } }
				end,
				label = widget,
				button = widget,
			},
		},
		dock = function(entry: any): any
			docks[entry.id] = entry
			return {
				open = function()
					for _, other in docks do
						if other ~= entry then
							other.setOpen(false)
						end
					end
					entry.setOpen(true)
				end,
				setAvailable = function(available: boolean)
					entry.available = available
				end,
			}
		end,
		onSnapshot = function(callback)
			listener = callback
			return function() end
		end,
		send = function(action: string, args: any): any
			table.insert(sends, { action = action, args = args })
			return reply(action, args)
		end,
	}
	local now = 0
	local mounted = Panels.mount(ctx, {
		content = Content,
		now = function(): number
			return now
		end,
		actor = function(): string
			return "1"
		end,
		station = function(): string
			return "station-1"
		end,
	})
	local api = { sends = sends, docks = docks, mounted = mounted, titles = roots }
	function api.push(extensions: any, packet: any)
		listener(extensions, packet)
	end
	function api.setNow(value: number)
		now = value
	end
	function api.open(id: string)
		docks[id].setOpen(true)
	end
	-- Live rows of one sheet (destroyed rows dropped), each with its labels/buttons.
	function api.rows(id: string): { any }
		local out = {}
		for _, row in scrolls[id].children or {} do
			if not row.destroyed then
				table.insert(out, row)
			end
		end
		table.sort(out, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		return out
	end
	function api.find(id: string, name: string): any
		for _, row in api.rows(id) do
			for _, child in row.children or {} do
				if child.Name == name then
					return child
				end
			end
		end
		return nil
	end
	function api.press(id: string, name: string)
		local button = assert(api.find(id, name), id .. " missing control " .. name)
		button.onClick()
	end
	function api.texts(id: string): { string }
		local out = {}
		for _, row in api.rows(id) do
			for _, child in row.children or {} do
				table.insert(out, child.Text)
			end
		end
		return out
	end
	function api.has(id: string, text: string): boolean
		for _, value in api.texts(id) do
			if value == text then
				return true
			end
		end
		return false
	end
	return api
end

local function item(id: string, catalogId: string, quantity: number, extra: any?): any
	local value: any = {
		itemId = id,
		catalogId = catalogId,
		quantity = quantity,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = { level = 10 },
	}
	for key, field in extra or {} do
		value[key] = field
	end
	return value
end

local function home(plots: any, storage: any, extra: any?): any
	local value: any = {
		homeId = "home:1",
		structures = {
			a = { kind = "farm-plot", position = { x = 0, y = 2, z = 0 } },
			b = { kind = "farm-plot", position = { x = 8, y = 2, z = 0 } },
		},
		plots = plots,
		storage = { items = storage },
	}
	for key, field in extra or {} do
		value[key] = field
	end
	return value
end

local function packet(items: any, workshop: any?, paid: any?): any
	local bag = { kind = "carried", items = {}, reservations = {} }
	for _, value in items do
		bag.items[value.itemId] = value
	end
	return {
		snapshots = {
			["survival-coop"] = {
				inventory = { bag = bag },
				workshop = workshop,
				progression = { paid = paid or {} },
			},
		},
	}
end

local function refused(reason: string): (string, any) -> any
	return function(): any
		return { ok = false, reason = reason }
	end
end

-- Every rendered row is 48px; its text must fit the row's width at the fitted sheet width.
local function assertFits(ui: any, id: string, locale: string)
	for _, viewport in VIEWPORTS do
		local width, height, touch = viewport[1], viewport[2], viewport[3]
		local x, y, w, h = HUDModel.contextSheet(width, height, touch)
		local at = id .. " " .. locale .. " " .. width .. "x" .. height
		assert(x >= 0 and y >= 0 and x + w <= width and y + h <= height, at .. " sheet clipped")
		assert(h >= 44 + Sheet.ROW, at .. " header plus one row")
		local content = w - 16 - 6
		local title = ui.titles[id]
		assert(HudFit.textWidth(title, 15) <= w - 70, at .. " title overflows: " .. title)
		local rows = ui.rows(id)
		assert(#rows > 0, at .. " blank")
		for _, row in rows do
			local placed: { any } = {}
			for _, child in row.children or {} do
				assert(
					type(child.Text) == "string" and child.Text ~= "",
					at .. " blank control " .. tostring(child.Name)
				)
				local scaleX = child.Size[1]
				local cell: any =
					{ x = (child.Position and child.Position[1] or 0) * content, width = scaleX * content }
				assert(cell.x >= 0 and cell.x + cell.width <= content + 0.01, at .. " control clipped")
				assert(cell.width >= 44, at .. " control under 44px")
				for _, other in placed do
					assert(cell.x >= other.x + other.width or other.x >= cell.x + cell.width, at .. " controls overlap")
				end
				table.insert(placed, cell)
				local fitted = false
				for size = 15, HudFit.MIN_TEXT_SIZE, -1 do
					local lines = math.ceil(HudFit.textWidth(child.Text, size) / math.max(1, cell.width - 8))
					if lines * size * 1.2 <= Sheet.ROW then
						fitted = true
						break
					end
				end
				assert(fitted, at .. " text overflows: " .. child.Text)
			end
		end
	end
end

local function filled(locale: string): any
	local ui = harness(locale, refused("NOT_GROWN"))
	-- Real localized entity names: the longest strings a player sees in these rows.
	local names = require("../../../games/robango-island/PackText.fixture").names(locale)
	ui.mounted.hub.name = function(id: string): string
		return names[id] or Text.text(locale, id)
	end
	ui.push(
		{
			home = home({
				b = { crop = "corn", plantedAt = 0, readyAt = 600, quantity = 3, sequence = 1 },
			}, {
				s = item("s", "corn-seed", 2),
				w = item("w", "water", 3),
			}, { cropBook = { corn = { harvests = 3, effects = { time = true } } } }),
			market = {
				claims = {
					{ id = "x:return:0", value = { item = { catalogId = "wood", quantity = 4 } } :: any },
					{ id = "y:1", value = { coins = 20 } :: any },
				},
			},
		},
		packet({ item("f", "fiber", 3), item("br", "branch", 2) }, {
			actorId = "1",
			entries = {
				job1 = {
					job = {
						recipeId = "dry-fiber",
						state = "Ready",
						inputs = {},
						outputs = { item("o", "dried-fiber", 1) },
					},
				},
			},
		})
	)
	return ui
end

return {
	["farm plot plants with the stored seed, refusal shown and growth reflected"] = function()
		local ui = harness("en-us", function(action: string): any
			return if action == "survival-coop:home-plant" then { ok = true } else { ok = false, reason = "NOT_GROWN" }
		end)
		ui.open("farm")
		ui.push({ home = home({}, { s = item("s", "corn-seed", 1), w = item("w", "water", 1) }) }, packet({}))
		assert(ui.has("farm", Text.text("en-us", "farm_plot", 1, Text.text("en-us", "farm_empty"))), "empty plot row")
		ui.press("farm", "Plant-1")
		local sent = ui.sends[#ui.sends]
		assert(sent.action == "survival-coop:home-plant" and sent.args[1] == "home:1", "home-plant sent")
		assert(
			sent.args[2].plot == "a" and sent.args[2].crop == "apple" and sent.args[2].seedItem == "none",
			"first crop"
		)
		ui.press("farm", "Crop-1")
		local cornIndex = 0
		for index, crop in require("./FarmCraftModel").crops(Content) do
			if crop.id == "corn" then
				cornIndex = index
			end
		end
		for _ = 3, cornIndex do
			ui.press("farm", "Crop-1")
		end
		ui.press("farm", "Plant-1")
		assert(ui.sends[#ui.sends].args[2].crop == "corn" and ui.sends[#ui.sends].args[2].seedItem == "s", "seed stack")
		ui.push({
			home = home({ a = { crop = "corn", plantedAt = 0, readyAt = 600, quantity = 3, sequence = 1 } }, {}),
		}, packet({}))
		ui.setNow(530)
		ui.mounted.sheets.farm.render()
		assert(
			ui.has("farm", Text.text("en-us", "farm_plot", 1, Text.text("en-us", "farm_growing", "corn", "1:10"))),
			"timer"
		)
		ui.press("farm", "Fertilize-1")
		assert(ui.sends[#ui.sends].action == "survival-coop:home-fertilize", "fertilize sent")
		assert(ui.has("farm", Text.refusal("en-us", "NOT_GROWN")), "refusal visible")
		ui.setNow(600)
		ui.mounted.sheets.farm.render()
		ui.press("farm", "Harvest-1")
		assert(ui.sends[#ui.sends].action == "survival-coop:home-harvest", "harvest sent")
	end,
	["sprayer selects plots in radius and shows per-plot results"] = function()
		local ui = harness("ko-kr", function(action: string): any
			return if action == "survival-coop:home-area"
				then { ok = true }
				else { ok = false, reason = "TOOL_REQUIRED" }
		end)
		ui.open("farm")
		ui.push({ home = home({}, {}) }, packet({}))
		ui.press("farm", "Sprayer")
		assert(ui.docks["farm-area"].isOpen() and not ui.docks.farm.isOpen(), "sprayer replaces farm sheet")
		ui.press("farm-area", "Select-1")
		ui.press("farm-area", "Select-2")
		ui.press("farm-area", "Apply")
		local sent = ui.sends[#ui.sends]
		assert(sent.action == "survival-coop:home-area" and sent.args[2].plots == "a,b", "explicit selection sent")
		ui.push({
			home = home({}, {}, {
				areaResults = { { plot = "a", ok = true }, { plot = "b", ok = false, reason = "EMPTY_PLOT" } },
			}),
		}, packet({}))
		assert(ui.has("farm-area", Text.text("ko-kr", "area_ok", 1)), "plot 1 applied")
		assert(
			ui.has("farm-area", Text.text("ko-kr", "area_fail", 2, Text.refusal("ko-kr", "EMPTY_PLOT"))),
			"plot 2 reason"
		)
	end,
	["crop book ranks crops and specialization confirms or refuses duplicates"] = function()
		local ui = harness("en-us", refused("DUPLICATE_EFFECT"))
		ui.open("crop-book")
		ui.push(
			{ home = home({}, {}, { cropBook = { corn = { harvests = 6, effects = { time = true } } } }) },
			packet({})
		)
		assert(
			ui.has("crop-book", Text.text("en-us", "book_rank", "corn", 3, Text.text("en-us", "book_next", 4))),
			"rank 3"
		)
		ui.press("crop-book", "Specialize-corn")
		assert(ui.docks["crop-specialize"].isOpen(), "specialize dialog opens")
		assert(ui.has("crop-specialize", Text.text("en-us", "spec_chosen", Text.text("en-us", "time"))), "chosen shown")
		assert(ui.has("crop-specialize", Text.text("en-us", "spec_preview", "corn", 540, 4, 1000)), "next crop preview")
		ui.press("crop-specialize", "Confirm")
		local sent = ui.sends[#ui.sends]
		assert(sent.action == "survival-coop:home-specialize" and sent.args[2].effect == "yield", "first open effect")
		assert(ui.has("crop-specialize", Text.refusal("en-us", "DUPLICATE_EFFECT")), "refusal visible")
		ui.press("crop-specialize", "Back")
		assert(ui.docks["crop-book"].isOpen(), "back returns to the book")
	end,
	["processing shows budget and deltas and reserves at the station"] = function()
		local ui = harness("en-us", refused("PROCESSING_BUDGET"))
		ui.open("processing")
		ui.push(
			{},
			packet({
				item("f", "fiber", 3, {
					material = {
						level = 10,
						budget = 1,
						attributes = { hardness = 2, flexibility = 3 },
						history = "",
					},
				}),
			})
		)
		local found = false
		for _, value in ui.texts("processing") do
			found = found or (string.find(value, "budget 1>0", 1, true) ~= nil)
		end
		assert(found, "budget before/after")
		local deltas = false
		for _, value in ui.texts("processing") do
			deltas = deltas or (string.find(value, "2>3", 1, true) ~= nil and string.find(value, "3>2", 1, true) ~= nil)
		end
		assert(deltas, "attribute deltas")
		ui.press("processing", "Start-dry-fiber")
		local sent = ui.sends[#ui.sends]
		assert(
			sent.action == "survival-coop:craft-reserve" and sent.args[1] == "dry-fiber" and sent.args[2] == "station-1",
			"reserve"
		)
		assert(ui.has("processing", Text.refusal("en-us", "PROCESSING_BUDGET")), "refusal visible")
	end,
	["processing names attribute deltas in Korean, never the raw attribute id"] = function()
		local ui = harness("ko-kr", refused("PROCESSING_BUDGET"))
		ui.open("processing")
		local attributes = { hardness = 2, flexibility = 3 }
		ui.push(
			{},
			packet({ item("f", "fiber", 3, { material = { level = 10, budget = 1, attributes = attributes } }) })
		)
		local joined = table.concat(ui.texts("processing"), "\n")
		assert(string.find(joined, "유연성 3>2", 1, true), "flexibility in Korean: " .. joined)
		assert(not string.find(joined, "flexibility", 1, true) and not string.find(joined, "hardness", 1, true), joined)
	end,
	["recipe preview assigns stacks and queues count reservations"] = function()
		local calls = 0
		local ui = harness("en-us", function(): any
			calls += 1
			return if calls <= 2 then { ok = true } else { ok = false, reason = "JOB_QUEUE_FULL" }
		end)
		ui.open("craft-preview")
		ui.push({}, packet({ item("b1", "branch", 1), item("b2", "branch", 4) }, nil, { processing_6 = true }))
		local recipe = Content.recipes[1]
		assert(ui.has("craft-preview", Text.text("en-us", "preview_recipe", recipe.id)), "recipe selector")
		for _ = 1, 3 do
			ui.press("craft-preview", "More")
		end
		assert(ui.has("craft-preview", Text.text("en-us", "preview_count", 4)), "count stepper")
		ui.press("craft-preview", "Queue")
		assert(#ui.sends == 3 and ui.sends[1].action == "survival-coop:craft-reserve", "stops at first refusal")
		assert(ui.has("craft-preview", Text.text("en-us", "preview_queued", 2, 4)), "queued count")
		assert(ui.has("craft-preview", Text.refusal("en-us", "JOB_QUEUE_FULL")), "refusal visible")
		local dry = 0
		for index, value in Content.recipes do
			if value.id == "dry-twig" then
				dry = index
			end
		end
		for _ = 2, dry do
			ui.press("craft-preview", "Recipe")
		end
		assert(ui.has("craft-preview", Text.text("en-us", "preview_main", "branch", 1, "b1", 10, 1)), "lowest id stack")
		assert(ui.has("craft-preview", Text.text("en-us", "preview_bonus", 10)), "return bonus")
	end,
	["inbox claims market results and collects crafted output across pages"] = function()
		local ui = harness("en-us", refused("FULL_SLOTS"))
		ui.open("inbox")
		local claims: { any } = {}
		for index = 1, 6 do
			table.insert(claims, { id = "c" .. index, value = { coins = index } })
		end
		ui.push(
			{ market = { claims = claims } },
			packet({}, {
				actorId = "1",
				entries = {
					j = {
						job = {
							recipeId = "dry-fiber",
							state = "Ready",
							inputs = {},
							outputs = { item("o", "dried-fiber", 1) },
						},
					},
				},
			})
		)
		assert(ui.has("inbox", Text.text("en-us", "inbox_coins", 1)), "sale proceeds row")
		assert(ui.has("inbox", Text.text("en-us", "inbox_page", 1, 2)), "paged")
		ui.press("inbox", "Claim-c1")
		assert(
			ui.sends[#ui.sends].action == "survival-coop:market-claim" and ui.sends[#ui.sends].args[1] == "c1",
			"claim"
		)
		assert(ui.has("inbox", Text.refusal("en-us", "FULL_SLOTS")), "full bag refusal visible")
		ui.press("inbox", "NextPage")
		ui.press("inbox", "Collect-j")
		assert(
			ui.sends[#ui.sends].action == "survival-coop:craft-complete" and ui.sends[#ui.sends].args[1] == "j",
			"collect"
		)
	end,
	["every farming and crafting screen fits PC portrait and landscape in English and Korean"] = function()
		for _, locale in { "en-us", "ko-kr" } do
			local ui = filled(locale)
			ui.mounted.hub.specialize = require("./FarmCraftModel").crops(Content)[1]
			for _, id in Panels.ORDER do
				ui.open(id)
				ui.mounted.sheets[id].status = Text.refusal(locale, "FERTILIZER_NOT_APPLICABLE")
				ui.mounted.sheets[id].render()
				assertFits(ui, id, locale)
			end
		end
	end,
	["launchers sit in the menu grid and the farm plot prompt opens the farm sheet"] = function()
		local source = fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")
		for _, id in { "farm", "processing", "inbox" } do
			assert(
				string.find(source, (if string.find(id, "-") then '["' .. id .. '"]' else id) .. " = { 1,", 1, true),
				id .. " category"
			)
		end
		local ui = harness("en-us", refused("x"))
		assert(
			ui.docks["farm-area"].available == false and ui.docks["crop-specialize"].available == false,
			"sub screens hidden"
		)
		assert(
			string.find(
				fs.readFile("games/robango-island/src/server/RoleWorld.luau"),
				'SetAttribute("ForgePanel", "farm")',
				1,
				true
			),
			"plot prompt"
		)
		assert(
			string.find(
				fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau"),
				"FarmCraftPanels",
				1,
				true
			),
			"client mounts"
		)
	end,
}
