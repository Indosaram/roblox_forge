--!strict
-- ui.survival: the camp at a glance, opened from the menu's Survival tile. sheets3 cards (art,
-- bold line, muted detail, progress bar, one action): camp level and facilities, campfire and
-- shelter status, shared storage use, then what is built and the next projects (camp ladder
-- projects first, then the core camp structures not yet built, with storage have/need).
local HudModel = require("./SurvivalHUDModel")
local CampModel = require("./CampPanelModel")
local Text = require("./FarmCraftText")
local Sheet = require("./FarmCraftSheet")
local M = {}

-- Core camp structures in build order; shelter is any of SHELTER built.
M.CORE = { "campfire", "tent", "storage", "workbench", "bed", "well" }
M.SHELTER = { "tent", "bed", "roof", "timber-roof", "stone-roof", "brick-roof" }
M.NEXT_LIMIT = 3

local function counts(settlement: any): { [string]: number }
	local out: { [string]: number } = {}
	for _, placement in if type(settlement) == "table" then settlement.structures or {} else {} do
		local id = placement.definition and placement.definition.id
		if type(id) == "string" then
			out[id] = (out[id] or 0) + 1
		end
	end
	return out
end

--- Pure view model: { level, fire, shelter, storage, built, next } from the camp slice, the
--- survival-coop snapshot and the shared settlement/warehouse. `name` maps ids to display names.
function M.model(locale: string, content: any, camp: any, packet: any, now: number, name: (string) -> string): any
	local t = function(key: string, ...: any): string
		return Text.text(locale, key, ...)
	end
	local snapshots = if type(packet) == "table" and type(packet.snapshots) == "table" then packet.snapshots else {}
	local shared = snapshots.survivalSettlement or {}
	local survival = snapshots["survival-coop"] or {}
	local settlement, warehouse = shared.settlement, shared.warehouse
	local built = counts(settlement)
	local view: any = { built = {}, next = {} }
	-- Camp level: the ladder rung and the facilities it unlocked.
	local ladder = CampModel.model(camp, now, packet)
	if ladder and ladder.rungs > 0 then
		local facilities = {}
		for _, id in ladder.facilities do
			table.insert(facilities, t("facility." .. id))
		end
		view.level = {
			text = t("camp_level", ladder.rung, ladder.rungs),
			detail = if #facilities > 0
				then t("camp_facilities", table.concat(facilities, " · "))
				else t("camp_facilities_none"),
			fraction = ladder.rung / ladder.rungs,
			ready = ladder.rung >= ladder.rungs,
		}
	else
		view.level = { text = t("camp_level_none"), detail = t("camp_facilities_none"), fraction = 0 }
	end
	local vitals = survival.vitals
	local resting = type(vitals) == "table" and vitals.resting == true
	local fires = built.campfire or 0
	view.fire = {
		text = if fires > 0 then t("camp_fire_on", fires) else t("camp_fire_off"),
		detail = if resting then t("camp_fire_resting") else t("camp_fire_hint"),
		fraction = if fires > 0 then 1 else 0,
		ready = fires > 0,
		build = fires == 0,
	}
	local shelters = {}
	for _, id in M.SHELTER do
		if (built[id] or 0) > 0 then
			table.insert(shelters, name(id))
		end
	end
	view.shelter = {
		text = if #shelters > 0 then t("camp_shelter_on", table.concat(shelters, ", ")) else t("camp_shelter_off"),
		detail = t("camp_shelter_hint"),
		fraction = if #shelters > 0 then 1 else 0,
		ready = #shelters > 0,
		build = #shelters == 0,
	}
	if type(warehouse) == "table" and type(warehouse.items) == "table" then
		local used = 0
		for _ in warehouse.items do
			used += 1
		end
		local slots = (warehouse.limits and warehouse.limits.slots) or 0
		view.storage = {
			text = t("camp_storage", used, slots),
			detail = t("camp_storage_hint"),
			fraction = if slots > 0 then used / slots else 0,
		}
	else
		view.storage = { text = t("camp_storage_none"), detail = t("camp_storage_hint"), fraction = 0 }
	end
	local ids = {}
	for id in built do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		table.insert(view.built, { id = id, text = t("camp_count", name(id), built[id]) })
	end
	-- Next projects: open camp ladder projects, then unbuilt core structures.
	local ladderRows: { any } = if ladder then ladder.rows else {}
	for _, row in ladderRows do
		if row.delivered < row.need and not row.locked and #view.next < M.NEXT_LIMIT then
			local parts = {}
			for _, cost in row.costs do
				table.insert(parts, t("camp_have", name(cost.item), cost.delivered, cost.need))
			end
			table.insert(view.next, {
				id = "project-" .. row.id,
				art = row.costs[1] and row.costs[1].item,
				text = t("camp_project", name("camp:" .. row.id), row.delivered, row.need),
				detail = table.concat(parts, " · "),
				fraction = if row.need > 0 then row.delivered / row.need else 0,
				panel = "camp",
				action = t("camp_give"),
			})
		end
	end
	local definitions = {}
	for _, definition in content.structures or {} do
		definitions[definition.id] = definition
	end
	for _, id in M.CORE do
		local definition = definitions[id]
		if definition and (built[id] or 0) == 0 and #view.next < M.NEXT_LIMIT then
			local parts, have, need = {}, 0, 0
			for _, cost in
				HudModel.ingredients(warehouse or { items = {}, reservations = {} }, {
					inputs = definition.cost,
				})
			do
				table.insert(parts, t("camp_have", name(cost.id), math.min(cost.available, cost.needed), cost.needed))
				have += math.min(cost.available, cost.needed)
				need += cost.needed
			end
			table.insert(view.next, {
				id = "build-" .. id,
				art = id .. "-kit",
				text = name(id),
				detail = table.concat(parts, " · "),
				fraction = if need > 0 then have / need else 1,
				ready = have >= need,
				panel = "build",
				action = t("camp_build"),
			})
		end
	end
	return view
end

function M.mount(ctx: any, hub: any): any
	local t = function(key: string, ...: any): string
		return Text.text(ctx.locale, key, ...)
	end
	local sheet = Sheet.new(ctx, { id = "survival", title = t("camp_sheet_title"), order = 2, menu = false })
	local function go(panel: string): () -> ()
		return function()
			if ctx.openPanel then
				ctx.openPanel(panel)
			end
		end
	end
	function sheet.render()
		if not sheet.gui.Enabled then
			return
		end
		sheet.clear()
		local view = M.model(ctx.locale, hub.content, hub.state.camp, hub.state.packet, hub.now(), hub.name)
		local function card(name: string, art: string?, row: any, cells: { any })
			sheet.plot({
				name = name,
				catalogId = art,
				text = row.text,
				detail = row.detail,
				fraction = row.fraction,
				ready = row.ready,
				cells = cells,
			})
		end
		card("CampLevel", "tent-kit", view.level, { { name = "OpenCamp", text = t("camp_open"), click = go("camp") } })
		card(
			"CampFire",
			"campfire-kit",
			view.fire,
			if view.fire.build then { { name = "BuildFire", text = t("camp_build"), click = go("build") } } else {}
		)
		card(
			"CampShelter",
			"tent-kit",
			view.shelter,
			if view.shelter.build
				then { { name = "BuildShelter", text = t("camp_build"), click = go("build") } }
				else {}
		)
		card(
			"CampStorage",
			"storage-kit",
			view.storage,
			{ { name = "OpenStorage", text = t("camp_storage_open"), click = go("storage") } }
		)
		sheet.label(t("camp_built")).Name = "BuiltHeading"
		if #view.built == 0 then
			sheet.label(t("camp_built_none")).Name = "BuiltNone"
		end
		for _, row in view.built do
			sheet.item(row.id .. "-kit", row.text).Name = "Built-" .. row.id
		end
		sheet.label(t("camp_next")).Name = "NextHeading"
		for _, row in view.next do
			card(
				"Next-" .. row.id,
				row.art,
				row,
				{ { name = "Go-" .. row.id, text = row.action, click = go(row.panel) } }
			)
		end
		sheet.footer()
	end
	return sheet
end

return M
