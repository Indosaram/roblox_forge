--!strict
-- Guide objective feed: maps a settled survival-coop command to the guide event it satisfies
-- ({ action, target, quantity }) and applies events to the development document. Pure: the
-- server passes `facts` read BEFORE the command ran (bag items, home state, market claim pages,
-- the craft recipe, content) because the command consumes or moves what the event names.
--
-- Guide objective actions with no game command behind them are listed in M.UNSUPPORTED with the
-- reason; they never progress (nothing is faked).
local M = {}

M.UNSUPPORTED = {
	visit = "no demonstration home exists; the visitor portal only travels to the player's own home",
	water = "there is no watering command; water is consumed as a plant input",
	practice = "practice operations have no command handler (gap G2)",
	["preview-refund"] = "skill reset previews are client-only; only the committing skill-reset is a command",
	["cancel-preview"] = "skill reset previews are client-only",
	["invite-training"] = "route-share training invitations do not exist",
	revoke = "route-share training invitations do not exist",
	inspect = "inspecting a station or item is not a command",
	["place-training"] = "there is no training pen placement command",
	["preview-role"] = "clan role previews are client-only",
	["draft-membership"] = "clan membership drafts do not exist",
	["cancel-draft"] = "clan membership drafts do not exist",
	["inspect-rate"] = "refrigerator rates are not a command",
	["equip-loan"] = "there is no equipment loan system",
	["return-loan"] = "there is no equipment loan system",
	preview = "technical-support previews are client-only",
	["acknowledge-level-gate"] = "technical-support previews are client-only",
	assemble = "no recipe or command assembles bandages",
	-- Event targets: craft -> recipe id (also the output's tool family, e.g. "axe"); deliver ->
	-- contract id (also "contract"); donate -> item catalog id (also "camp").
	activate = "the rescue beacon only opens the journal; there is no activate command",
}

--- The tool family (content.toolPolicy) of a recipe's first output, e.g. "axe", or nil.
function M.family(content: any, recipeId: string?): string?
	for _, recipe in if content and recipeId then content.recipes else {} do
		if recipe.id == recipeId and recipe.outputs[1] then
			for _, family in if content.toolPolicy then content.toolPolicy.families else {} do
				for _, member in family.members do
					if member.item == recipe.outputs[1].item then
						return family.id
					end
				end
			end
		end
	end
	return nil
end

local function catalogOf(items: any, itemId: any): string?
	local item = if type(items) == "table" and type(itemId) == "string" then items[itemId] else nil
	return if item then item.catalogId else nil
end

local function claimOf(facts: any, id: any): any
	local market = facts.market
	for _, page in if market then market.pages or {} else {} do
		for _, row in page do
			if row.id == id then
				return row.value
			end
		end
	end
	return nil
end

--- The guide event a command satisfies, or nil. `action` has no genre prefix. `result` is the
--- command result; an event is only produced for an ok result.
function M.event(action: string, args: { any }, facts: any, result: any): any?
	if type(result) ~= "table" or not result.ok then
		return nil
	end
	local data = if type(result.data) == "table" then result.data else {}
	local bag = facts.bag
	local function event(kind: string, target: string?, quantity: number?, also: string?): any?
		return if target then { action = kind, target = target, quantity = quantity or 1, also = also } else nil
	end
	if action == "craft-complete" then
		return event("craft", facts.recipe, 1, M.family(facts.content, facts.recipe))
	elseif action == "rest" then
		return event("rest", "rw.onboarding.rest-mat")
	elseif action == "home-place" then
		return event("place", type(args[2]) == "table" and args[2].kind or nil)
	elseif action == "home-expand" then
		return event("expand", "rw.home")
	elseif action == "food" then
		return event("eat", catalogOf(bag, args[1]))
	elseif action == "skill-learn" then
		return event("purchase", args[1])
	elseif action == "home-plant" then
		return event("plant", type(args[2]) == "table" and args[2].crop or nil)
	elseif action == "home-harvest" then
		local plot = if type(args[2]) == "table" and facts.home then facts.home.plots[args[2].plot] else nil
		return event("harvest", if plot then plot.crop else nil)
	elseif action == "home-deposit" then
		local body = if type(args[2]) == "table" then args[2] else {}
		return event("deposit", catalogOf(bag, body.itemId), body.quantity)
	elseif action == "home-withdraw" then
		local body = if type(args[2]) == "table" then args[2] else {}
		local storage = if facts.home then facts.home.storage else nil
		return event("retrieve", catalogOf(storage and storage.items, body.itemId), body.quantity)
	elseif action == "tame-feed" then
		return event("feed", args[2])
	elseif action == "tame-capture" then
		return if data.captured then event("tame", data.species) else nil
	elseif action == "market-list" then
		-- Cross-server listings name a bag item id; the local market names the catalog id.
		return event("list", catalogOf(bag, args[1]) or args[1], args[2])
	elseif action == "contract-deliver" then
		return event("deliver", args[1], 1, "contract")
	elseif action == "gear-equip" then
		return event("equip", catalogOf(bag, args[1]))
	elseif action == "camp-contribute" then
		return event("donate", catalogOf(bag, args[2]), args[3], "camp")
	elseif action == "market-claim" then
		-- A returned listing comes back as its item; a sale pays coins and names no item.
		local claim = claimOf(facts, args[1])
		local item = if claim then claim.item else nil
		return event("settle-return-or-sale", if item then item.catalogId else nil)
	end
	return nil
end

-- Actions the personal command executor commits to the personal ledger (receipt-checkable).
local LEDGERED = { ["craft-complete"] = true, rest = true, food = true, ["skill-learn"] = true }
function M.ledgered(action: string): boolean
	return LEDGERED[action] == true
end

--- True when the actor's level and development grade open the guide.
function M.open(guide: any, level: number, grade: number): boolean
	local gates = guide.gates or {}
	return (gates.characterLevel or 1) <= level and (gates.developmentRank or 0) <= grade
end

--- Applies one event to `development` (mutated: progress, definitions, points) and returns the
--- guides it completed. Grade is re-read per guide so a completion can open the next band.
function M.apply(content: any, development: any, level: number, grade: (number) -> number, event: any): { any }
	local completed = {}
	for _, guide in content.guides or {} do
		if not development.definitions[guide.id] and M.open(guide, level, grade(development.points)) then
			local complete = true
			for _, objective in guide.objectives do
				if
					objective.action == event.action
					and (objective.target == event.target or (event.also ~= nil and objective.target == event.also))
				then
					development.progress[objective.id] =
						math.min(objective.quantity, (development.progress[objective.id] or 0) + event.quantity)
				end
				complete = complete and (development.progress[objective.id] or 0) >= objective.quantity
			end
			if complete then
				development.definitions[guide.id] = true
				development.points += guide.rewards.development or 0
				table.insert(completed, guide)
			end
		end
	end
	return completed
end

return M
