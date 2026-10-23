--!strict
-- ui.craft-catalog favorite/to-do toggles and the ui.recipe-tracker deficit rows (C03).
local Marks = require("./RecipeMarks")
local Model = require("./SurvivalHUDModel")
local Contract = require("./Contract")

local RECIPES: { any } = {
	{
		id = "starter-axe",
		station = "workbench",
		inputs = { { item = "branch", quantity = 3 }, { item = "stone", quantity = 2 } },
	},
	{ id = "berry-meal", inputs = { { item = "berry", quantity = 2 } } },
	{ id = "rope", inputs = { { item = "fiber", quantity = 4 } } },
}

local function bag(items: { [string]: number }): any
	local out = { kind = "carried", items = {}, reservations = {} }
	for id, quantity in items do
		out.items[id] = { itemId = id, catalogId = id, quantity = quantity }
	end
	return out
end

return {
	["favorite and to-do toggles validate the recipe and persist as sorted id sets"] = function()
		local state = Marks.new()
		local nextState, reason = Marks.apply(state, RECIPES, "starter-axe", "favorite", true)
		assert(nextState and reason == nil, "favorite accepted")
		assert(state.favorites["starter-axe"] == nil, "apply never mutates its input")
		nextState = assert(Marks.apply(nextState, RECIPES, "rope", "todo", true))
		assert(nextState.favorites["starter-axe"] and nextState.todo.rope, "both marks held")
		local again = assert(Marks.apply(nextState, RECIPES, "rope", "todo", true))
		assert(Marks.count(again.todo) == 1, "re-marking is idempotent")
		local cleared = assert(Marks.apply(again, RECIPES, "rope", "todo", false))
		assert(cleared.todo.rope == nil, "untrack clears")
		local _, unknown = Marks.apply(state, RECIPES, "missing", "favorite", true)
		assert(unknown == "UNKNOWN_RECIPE", "unknown recipe refused")
		local _, kind = Marks.apply(state, RECIPES, "rope", "pin", true)
		assert(kind == "INVALID_MARK", "unknown mark kind refused")
		local full = Marks.new()
		for index = 1, Marks.TODO_LIMIT do
			full.todo["r" .. index] = true
		end
		local _, limit = Marks.apply(full, RECIPES, "rope", "todo", true)
		assert(limit == "TODO_LIMIT", "tracker capacity refused")
		assert(#Marks.validate(nextState) == 0, "valid save")
		assert(#Marks.validate({ favorites = { rope = 1 }, todo = {} }) > 0, "malformed save rejected")
	end,
	["a tracked recipe shows deficits by source and updates after a gather"] = function()
		local marks = assert(Marks.apply(Marks.new(), RECIPES, "starter-axe", "todo", true))
		local warehouse = bag({ stone = 1 })
		local rows = Marks.tracker(bag({ branch = 1 }), warehouse, RECIPES, marks)
		assert(#rows == 1 and rows[1].recipeId == "starter-axe" and not rows[1].ready, "one tracked row")
		local branch, stone = rows[1].inputs[1], rows[1].inputs[2]
		assert(
			branch.id == "branch" and branch.bag == 1 and branch.needed == 3 and branch.deficit == 2,
			"branch deficit"
		)
		assert(stone.bag == 0 and stone.warehouse == 1 and stone.deficit == 1, "warehouse counts toward the target")
		rows = Marks.tracker(bag({ branch = 3, stone = 1 }), warehouse, RECIPES, marks)
		assert(rows[1].inputs[1].deficit == 0 and rows[1].inputs[2].deficit == 0 and rows[1].ready, "gather closes it")
		local reserved = bag({ branch = 3, stone = 2 })
		reserved.reservations.job = { branch = 2 }
		rows = Marks.tracker(reserved, nil, RECIPES, marks)
		assert(rows[1].inputs[1].bag == 1 and rows[1].inputs[1].deficit == 2, "reserved stock is not available")
	end,
	["favorites list first in the craft catalog and the HUD model receives marks"] = function()
		local marks = assert(Marks.apply(Marks.new(), RECIPES, "rope", "favorite", true))
		local order = Model.recipeOrder(bag({ berry = 2 }), RECIPES, function()
			return false
		end, nil, { favorites = marks.favorites })
		assert(order[1].recipe.id == "rope" and order[1].favorite, "favorite listed first even without materials")
		local model = Model.new("alice", function()
			return "r"
		end)
		model.receive({
			revision = 1,
			snapshots = { ["survival-coop"] = {}, survivalExtensions = { ["recipe-marks"] = marks } },
		})
		assert(model.snapshot.recipeMarks and model.snapshot.recipeMarks.favorites.rope, "marks reach the HUD")
	end,
	["recipe-mark is a client contract action appended after every existing index"] = function()
		local declared = false
		for _, action in Contract.actions do
			declared = declared or (action.id == "recipe-mark" and action.origin == "client")
		end
		assert(declared and table.find(Contract.extensionActions :: { string }, "recipe-mark"), "contract")
		-- Appended after every pre-existing action, so earlier durable indices stay
		-- put; later extensions (operation-run) append after it.
		local extensionActions = Contract.extensionActions :: { string }
		local mark = table.find(extensionActions, "recipe-mark") :: number
		for index = mark + 1, #extensionActions do
			assert(
				extensionActions[index] == "operation-run"
					or extensionActions[index] == "attack-ranged"
					or extensionActions[index] == "stance-set",
				"only later extensions follow recipe-mark: " .. extensionActions[index]
			)
		end
	end,
	["tracker rows clear the HUD and mobile controls on PC and portrait"] = function()
		local function overlaps(a: any, b: any): boolean
			return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
		end
		for _, size in { { 1280, 664 }, { 1920, 1024 }, { 360, 584 }, { 390, 788 }, { 640, 304 } } do
			local width, height = size[1], size[2]
			local hud = Model.contextHudBounds(width, height)
			for _, rows in { 1, Marks.TODO_LIMIT } do
				local tracker = Model.trackerBounds(width, height, rows)
				assert(tracker.height >= 28 and tracker.y >= 0 and tracker.x >= 0, "tracker on screen")
				assert(tracker.x + tracker.width <= width, "tracker within width")
				for _, key in { "vitals", "objective", "menu", "biome" } do
					assert(not overlaps(tracker, hud[key]), width .. "x" .. height .. " tracker overlaps " .. key)
				end
				local jump = { x = width - 128, y = height - 128, width = 128, height = 128 }
				assert(not overlaps(tracker, jump), width .. "x" .. height .. " tracker overlaps jump")
				assert(
					tracker.y + tracker.height <= height - 128 or tracker.x + tracker.width <= width - 128,
					"jump zone"
				)
			end
		end
	end,
}
