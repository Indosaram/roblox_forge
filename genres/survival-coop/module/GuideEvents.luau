--!strict
-- Guide objective feed: maps a settled survival-coop command to the guide event it satisfies
-- ({ action, target, quantity }) and applies events to the development document. Pure: the
-- server passes `facts` read BEFORE the command ran (bag items, home state, market claim pages,
-- the craft recipe, content) because the command consumes or moves what the event names.
--
-- Guide objective actions with no game command behind them are listed in M.UNSUPPORTED with the
-- reason; they never progress (nothing is faked).
local M = {}

-- Every authored guide action now has a command; acknowledgement steps run through guide-act
-- (GuideActExtension). Event targets: craft -> recipe id (also the output's tool family, e.g.
-- "axe"); deliver -> contract id (also "contract"); donate -> item catalog id (also "camp").
M.UNSUPPORTED = {} :: { [string]: string }

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
	elseif action == "operation-run" then
		-- OperationExtension runs practice drills (target: operation id) and guide-gated assembly
		-- (target: the assembled item).
		for _, row in if facts.content then facts.content.operations else {} do
			if row.id == data.operationId then
				if row.kind == "practice" then
					return event("practice", row.id)
				end
				local output = row.outputs[1]
				return if output then event("assemble", output.item, output.quantity) else nil
			end
		end
		return nil
	elseif action == "guide-act" then
		return event(data.action, data.target)
	elseif action == "party-action" then
		-- Route sharing (S7): any real invite or revoke of a party member is the training step.
		local verb = if args[1] == "route-invite"
			then "invite-training"
			elseif args[1] == "route-revoke" then "revoke"
			else nil
		return if verb then event(verb, args[2], 1, "rw.training-recipient") else nil
	elseif action == "clan-preview" or action == "clan-draft" or action == "clan-draft-cancel" then
		local verbs = { ["clan-preview"] = "preview-role", ["clan-draft"] = "draft-membership" }
		return event(verbs[action] or "cancel-draft", "clan")
	elseif action == "equipment-quote" then
		return event(if args[2] == "acknowledge" then "acknowledge-level-gate" else "preview", args[1])
	elseif action == "camp-loan" and (args[1] == "take" or args[1] == "return") then
		return event(if args[1] == "take" then "equip-loan" else "return-loan", data.catalogId)
	elseif action == "home-area" then
		-- The sprayer waters each selected plot it could apply to.
		local crop, count = nil, 0
		for _, row in data.areaResults or {} do
			local plot = if row.ok and facts.home then facts.home.plots[row.plot] else nil
			if plot and (crop == nil or plot.crop == crop) then
				crop, count = plot.crop, count + 1
			end
		end
		return event("water", crop, count)
	elseif action == "companion-action" then
		local pet = if facts.companions then facts.companions.pets[args[2]] else nil
		local rules = facts.content and facts.content.progressionPolicy and facts.content.progressionPolicy.companion
		if not pet or not rules then
			return nil
		elseif args[1] == "place" then
			return event("place-training", pet.species)
		elseif args[1] == "feed" then
			return event("feed", rules.feedItem)
		end
		return if args[1] == "claim" then event("tame", pet.species) else nil
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

-- guide-act: the acknowledgement steps of development guides that change no game state (open a
-- preview, inspect a facility, visit the demonstration home, ring the practice beacon). Route
-- invites, clan drafts, equipment loans and the support quote are real commands (party-action,
-- clan-*, camp-loan, equipment-quote). The server accepts one only when it is the next
-- unfinished objective of an open guide and, when the target names a world anchor, only within
-- reach of it. The settled result names { action, target }, which M.event turns into the guide
-- event. Nothing is granted here: rewards settle through the guide outbox.
local RANK_POINTS, MAX_RANK = 100, 10 -- CharacterRules.RANK_POINTS / MAX_RANK (no require cycle)
local function rank(points: number): number
	return math.clamp(math.floor(points / RANK_POINTS), 0, MAX_RANK)
end
M.ACT = "survival-coop:guide-act"
M.VERBS = table.freeze({
	"visit",
	"preview-refund",
	"cancel-preview",
	"inspect",
	"inspect-rate",
	"activate",
})
-- Verbs performed at a facility whose anchor is not named by the target.
local VERB_ANCHOR = { visit = "visitor-portal" }

function M.actions(): { any }
	local Schema = require("../../../core/infra/net/Schema")
	return {
		{
			id = "guide-act",
			args = { Schema.enum(M.VERBS :: any), Schema.string({ maxLen = 128, pattern = "^[%w%.%-_]+$" }) },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
	}
end

-- Anchor ids the target can name: "<layout>.<anchor>", "station.<target>.t1", the station of an
-- operation row, or the verb's facility. Only ids some layout defines are returned.
local function anchors(content: any, verb: string, target: string): { [string]: boolean }
	local wanted = { [VERB_ANCHOR[verb] or ""] = true, ["station." .. target .. ".t1"] = true }
	for _, row in content.operations or {} do
		if row.id == target and row.station then
			wanted["station." .. row.station .. ".t1"] = true
		end
	end
	local out = {}
	for _, layout in content.layouts or {} do
		local prefix = layout.id .. "."
		if string.sub(target, 1, #prefix) == prefix then
			wanted[string.sub(target, #prefix + 1)] = true
		end
	end
	for _, layout in content.layouts or {} do
		for _, anchor in layout.anchors or {} do
			if wanted[anchor.id] then
				out[anchor.id] = true
			end
		end
	end
	return out
end

--- The guide whose next unfinished objective is (verb, target), or nil with the refusal.
function M.nextStep(content: any, development: any, level: number, verb: string, target: string): (any?, string?)
	local grade = rank(development.points or 0)
	local reason = "GUIDE_NOT_OPEN"
	for _, guide in content.guides or {} do
		if not (development.definitions or {})[guide.id] and M.open(guide, level, grade) then
			for _, objective in guide.objectives do
				if ((development.progress or {})[objective.id] or 0) < objective.quantity then
					if objective.action == verb and objective.target == target then
						return guide, nil
					end
					break
				end
			end
			for _, objective in guide.objectives do
				if objective.action == verb and objective.target == target then
					reason = "GUIDE_STEP_ORDER"
				end
			end
		end
	end
	return nil, reason
end

function M.factory(ctx: any): any
	if not ctx.content.guides or not ctx.world or not ctx.world.development then
		return nil
	end
	return {
		id = "guide-act",
		handles = function(action: string): boolean
			return action == M.ACT
		end,
		command = function(actor: string, _action: string, args: any, _context: any, _origin: string, admit: any): any
			local verb, target = args[1], args[2]
			local port = ctx.personalTransfer(actor)
			local slice = if port then port.profile().data.envelope.genres["survival-coop"].data else nil
			if not slice or not slice.progression then
				return { ok = false, reason = "PROGRESSION_UNAVAILABLE" }
			end
			local _, refused =
				M.nextStep(ctx.content, ctx.world.development(actor, true), slice.progression.level, verb, target)
			if refused then
				return { ok = false, reason = refused }
			end
			local places = anchors(ctx.content, verb, target)
			if next(places) then
				local spatial = ctx.world.services and ctx.world.services.survivalDeath
				local here = false
				for _, anchor in if ctx.world.layout then ctx.world.layout.anchors else {} do
					here = here
						or (places[anchor.id] == true and spatial ~= nil and spatial.reachable(actor, anchor.position))
				end
				if not here then
					return { ok = false, reason = "OUT_OF_RANGE" }
				end
			end
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			return { ok = true, data = { action = verb, target = target } }
		end,
		snapshot = function(): (any?, string?)
			return nil, nil
		end,
	}
end

return M
