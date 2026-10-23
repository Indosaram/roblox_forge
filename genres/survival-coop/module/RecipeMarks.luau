--!strict
-- Recipe favorites and to-do tracking (ui.craft-catalog toggles, ui.recipe-tracker, C03).
-- Marks are id sets persisted in the personal survival-coop envelope (`recipeMarks`); the
-- tracker derives available/needed per input from the bag and the warehouse on every
-- snapshot, so it updates after any gather, consume, deposit or withdraw.
local Schema = require("../../../core/infra/net/Schema")
local M = {}

M.TODO_LIMIT = 5
M.FAVORITE_LIMIT = 256
local KINDS = { favorite = "favorites", todo = "todo" }

export type State = { favorites: { [string]: boolean }, todo: { [string]: boolean } }

function M.new(): State
	return { favorites = {}, todo = {} }
end

function M.count(set: { [string]: boolean }): number
	local count = 0
	for _ in set do
		count += 1
	end
	return count
end

function M.validate(raw: any): { string }
	local errors = {}
	if type(raw) ~= "table" then
		return { "recipeMarks: expected table" }
	end
	for _, field in { "favorites", "todo" } do
		local set = raw[field]
		if type(set) ~= "table" then
			table.insert(errors, "recipeMarks." .. field .. ": expected set")
			continue
		end
		for id, value in set do
			if type(id) ~= "string" or #id == 0 or #id > 128 or value ~= true then
				table.insert(errors, "recipeMarks." .. field .. ": invalid entry")
				break
			end
		end
		local limit = if field == "todo" then M.TODO_LIMIT else M.FAVORITE_LIMIT
		if M.count(set) > limit then
			table.insert(errors, "recipeMarks." .. field .. ": limit")
		end
	end
	return errors
end

--- Pure toggle: returns a new state, or nil plus a stable refusal code.
function M.apply(state: State, recipes: { any }, recipeId: string, kind: string, on: boolean): (State?, string?)
	local field = KINDS[kind]
	if field == nil then
		return nil, "INVALID_MARK"
	end
	local known = false
	for _, recipe in recipes do
		known = known or recipe.id == recipeId
	end
	if not known then
		return nil, "UNKNOWN_RECIPE"
	end
	local out: State = { favorites = table.clone(state.favorites), todo = table.clone(state.todo) }
	local set = (out :: any)[field]
	if on and not set[recipeId] then
		if M.count(set) >= (if field == "todo" then M.TODO_LIMIT else M.FAVORITE_LIMIT) then
			return nil, if field == "todo" then "TODO_LIMIT" else "FAVORITE_LIMIT"
		end
		set[recipeId] = true
	elseif not on then
		set[recipeId] = nil
	end
	return out, nil
end

local function available(container: any, catalogId: string): number
	local total = 0
	if not container then
		return 0
	end
	for id, item in container.items or {} do
		if item.catalogId == catalogId then
			local reserved = 0
			for _, amounts in container.reservations or {} do
				reserved += amounts[id] or 0
			end
			total += item.quantity - reserved
		end
	end
	return math.max(0, total)
end

--- Tracker rows for every to-do recipe, in recipe catalog order.
function M.tracker(bag: any, warehouse: any, recipes: { any }, marks: State?): { any }
	local rows = {}
	if not marks then
		return rows
	end
	for _, recipe in recipes do
		if not marks.todo[recipe.id] then
			continue
		end
		local inputs, ready = {}, true
		for _, input in recipe.inputs do
			local carried, stored = available(bag, input.item), available(warehouse, input.item)
			local deficit = math.max(0, input.quantity - carried - stored)
			ready = ready and deficit == 0
			table.insert(inputs, {
				id = input.item,
				bag = carried,
				warehouse = stored,
				needed = input.quantity,
				deficit = deficit,
			})
		end
		table.insert(rows, { recipeId = recipe.id, inputs = inputs, ready = ready, outputs = recipe.outputs })
	end
	return rows
end

function M.actions(): { any }
	local id = Schema.string({ maxLen = 128, pattern = ".+" })
	return {
		{
			id = "recipe-mark",
			args = { id, Schema.string({ maxLen = 16, pattern = "^%l+$" }), Schema.boolean() },
			origin = "client",
			rate = { capacity = 8, refillPerSecond = 4 },
		},
	}
end

--- Extension over a personal-document port: update(actor, transform) -> (ok, reason) and
--- read(actor) -> document?. The document key `recipeMarks` is owned here.
function M.factory(port: any, recipes: { any }): any
	return {
		id = "recipe-marks",
		handles = function(action: string): boolean
			return action == "survival-coop:recipe-mark"
		end,
		command = function(actor: string, _action: string, args: { any }, _context: any, _origin: any, admit: any): any
			local admission = admit()
			if not admission.ok then
				return admission
			end
			local result: any = nil
			local saved, err = port.update(actor, function(document)
				local current = document.recipeMarks or M.new()
				local nextState, reason = M.apply(current, recipes, args[1], args[2], args[3])
				if not nextState then
					result = { ok = false, reason = reason }
					return document
				end
				document.recipeMarks = nextState
				result = { ok = true, data = nextState }
				return document
			end)
			if not saved then
				return { ok = false, reason = err }
			end
			return result
		end,
		snapshot = function(actor)
			local document = port.read(actor)
			return if document then document.recipeMarks or M.new() else nil
		end,
	}
end

return M
