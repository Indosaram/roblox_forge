--!strict
-- ui.storage (p101): camp warehouse screen. Pure rows in EN/KO with empty states, capacity,
-- permission, category filter, quantity selection and the existing transfer commands; rows fit the
-- contextual sheet at 1280x720 and 360x640; the warehouse prompt and the HUD bag sheet open it.
local fs = require("@lune/fs")
local Storage = require("./StoragePanel")
local L = require("./ScreenText")
L.use(require("../../../games/robango-island/PackText.fixture").screenText)
local Sheet = require("./SocialSheet")
local HUDModel = require("./SurvivalHUDModel")

local LOCALES = { "en-us", "ko-kr" }
local VIEWPORTS: { { any } } = { { 1280, 720, false }, { 360, 640, true } }
local CONTENT = {
	items = {
		{ id = "wood", weightMilli = 500 },
		{ id = "berry", weightMilli = 100, foodEffects = {} },
	},
}
local NAMES = { wood = "Wood", berry = "Berry" }

local function noop() end

local function check(rows: { any }, label: string)
	assert(#rows > 0, label .. ": blank screen")
	for _, row in rows do
		assert(type(row.text) == "string" and row.text ~= "", label .. ": empty row")
		assert(
			not string.find(row.text, "scr%.") and not string.find(row.text, "%%[ds]"),
			label .. ": raw " .. row.text
		)
		for _, viewport in VIEWPORTS do
			local _, _, w, h = HUDModel.contextSheet(viewport[1], viewport[2], viewport[3])
			local height = Sheet.rowHeight(row.text, Sheet.contentWidth(w))
			assert(height >= 48 and height <= h - 56, label .. ": row does not fit " .. row.text)
		end
	end
end

local function texts(rows: { any }): string
	local out = {}
	for _, row in rows do
		table.insert(out, row.text)
	end
	return table.concat(out, "\n")
end

local function press(rows: { any }, text: string)
	for _, row in rows do
		if row.text == text and row.onClick then
			row.onClick()
			return
		end
	end
	error("no button " .. text .. " in\n" .. texts(rows))
end

local function inventory(items: any, slots: number): any
	return { items = items, reservations = {}, limits = { slots = slots, hardWeightMilli = 20000 } }
end

local function state(extra: any?): any
	local base: any = {
		actorId = "1",
		content = CONTENT,
		names = NAMES,
		settlement = { roles = { ["1"] = "member" } },
		bag = inventory({ b1 = { itemId = "b1", catalogId = "wood", quantity = 12 } }, 30),
		warehouse = inventory({ w1 = { itemId = "w1", catalogId = "berry", quantity = 3 } }, 40),
		mode = "deposit",
		filter = "all",
		quantity = 1,
	}
	for key, value in extra or {} do
		base[key] = value
	end
	return base
end

return {
	["storage empty states fit both viewports in both languages"] = function()
		for _, locale in LOCALES do
			local missing = Storage.rows(locale, { actorId = "1", content = CONTENT }, {})
			check(missing, "no storage " .. locale)
			assert(string.find(texts(missing), L.text(locale, "scr.storage.unavailable"), 1, true), "unavailable copy")
			local empty = Storage.rows(locale, state({ mode = "withdraw", warehouse = inventory({}, 40) }), {})
			check(empty, "empty storage " .. locale)
			assert(string.find(texts(empty), L.text(locale, "scr.storage.empty_storage"), 1, true), "empty copy")
			local bag = Storage.rows(locale, state({ bag = inventory({}, 30) }), {})
			assert(string.find(texts(bag), L.text(locale, "scr.storage.empty_bag"), 1, true), "empty bag copy")
		end
	end,
	["storage shows capacity, permission and filters by category"] = function()
		for _, locale in LOCALES do
			local rows = Storage.rows(locale, state(), {})
			check(rows, "storage " .. locale)
			local copy = texts(rows)
			assert(
				string.find(copy, L.text(locale, "scr.storage.capacity", 1, 40, "0.3", "20.0"), 1, true),
				"storage cap"
			)
			assert(string.find(copy, L.text(locale, "scr.storage.bag", 1, 30, "6.0", "20.0"), 1, true), "bag cap")
			assert(string.find(copy, L.text(locale, "scr.storage.member"), 1, true), "member permission")
			local food = texts(Storage.rows(locale, state({ filter = "food" }), {}))
			assert(not string.find(food, "Wood", 1, true), "food filter hides wood")
			local visitor = Storage.rows(locale, state({ settlement = { roles = {} } }), { mode = noop, filter = noop })
			check(visitor, "visitor " .. locale)
			assert(string.find(texts(visitor), L.text(locale, "scr.storage.visitor"), 1, true), "read-only reason")
			local buttons = 0
			for _, row in visitor do
				buttons += if row.onClick then 1 else 0
			end
			assert(buttons == 2, "visitors only switch view and filter")
		end
	end,
	["storage selects an item, steps the quantity and sends the transfer"] = function()
		for _, locale in LOCALES do
			local sent: any = nil
			local selected: any, quantity: number = nil, 1
			local act = {
				select = function(id: string)
					selected = id
				end,
				quantity = function()
					quantity = Storage.nextQuantity(quantity, 12)
				end,
				move = function(action: string, id: string, amount: number)
					sent = { action, id, amount } :: { any }
				end,
				mode = noop,
				filter = noop,
			}
			press(Storage.rows(locale, state(), act), L.text(locale, "scr.storage.item", "Wood", 12, 0))
			assert(selected == "b1", "row selects the bag item")
			local picked = Storage.rows(locale, state({ selected = "b1", quantity = 1 }), act)
			press(picked, L.text(locale, "scr.storage.quantity", 1, 12))
			assert(quantity == 5, "quantity steps 1 -> 5")
			press(
				Storage.rows(locale, state({ selected = "b1", quantity = 5 }), act),
				L.text(locale, "scr.storage.deposit", 5, "Wood")
			)
			assert(sent[1] == "transfer-deposit" and sent[2] == "b1" and sent[3] == 5, "deposit args")
			local take = Storage.rows(locale, state({ mode = "withdraw", selected = "w1", quantity = 3 }), act)
			press(take, L.text(locale, "scr.storage.withdraw", 3, "Berry"))
			assert(sent[1] == "transfer-withdraw" and sent[2] == "w1" and sent[3] == 3, "withdraw args")
		end
		assert(Storage.nextQuantity(10, 12) == 12 and Storage.nextQuantity(12, 12) == 1, "all, then wraps")
		assert(Storage.nextQuantity(100, 2000) == 1000, "transfer cap 1000")
	end,
	["reserved items cannot move and refusals are localized"] = function()
		for _, locale in LOCALES do
			local bag = inventory({ b1 = { itemId = "b1", catalogId = "wood", quantity = 4 } }, 30)
			bag.reservations = { job = { b1 = 4 } }
			local rows = Storage.rows(locale, state({ bag = bag, selected = "b1" }), {})
			check(rows, "reserved " .. locale)
			assert(string.find(texts(rows), L.text(locale, "scr.storage.locked"), 1, true), "reservation lock")
			assert(
				L.refusal(locale, "WAREHOUSE_UNREACHABLE") ~= L.text(locale, "scr.refuse.unknown"),
				"walk-to-warehouse copy"
			)
		end
	end,
	["warehouse prompt and HUD bag sheet open the storage screen"] = function()
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(string.find(client, "module.StoragePanel", 1, true), "client registers ui.storage")
		local hud = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		assert(string.find(hud, 'options.openPanel("storage")', 1, true), "bag sheet opens ui.storage")
		local source = fs.readFile("genres/survival-coop/module/StoragePanel.luau")
		for key in string.gmatch(source, '"(scr%.[%w_%.%-]+)"') do
			if string.sub(key, -1) ~= "." and string.sub(key, -1) ~= "_" then
				assert(L.text("en-us", key) ~= "" and L.text("ko-kr", key) ~= "", key .. ": missing locale row")
			end
		end
	end,
}
