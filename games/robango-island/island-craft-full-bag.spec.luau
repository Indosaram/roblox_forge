--!strict
-- journey6h @136.7 min (12df9def): on rw.a1.s2 the stage craft (dry-twig at the island campfire)
-- never finished. With the 40-slot bag full, every Complete press answered FULL_SLOTS even though
-- the output folds into a dried-wood stack the bag already holds, so the rw.a1.s2.craft objective
-- stayed 0/1 and the trip soft-locked. Driven through the real archipelago server (Journey.fixture)
-- and the shipped craft sheet: the collect fits when its output stacks, and when it truly needs a
-- slot, the bag sheet's Drop frees one and the same job finishes. The stage objective follows the
-- player's job in both cases.
local Journey = require("./Journey.fixture")
local Archipelago = require("../../core/domain/island/Archipelago")
local Content: any = require("./src/shared/SurvivalContent")

local ACTOR = Journey.ACTOR
local OBJECTIVE = "rw.a1.s2.craft"

local function stack(id: string, catalogId: string, quantity: number): any
	return {
		itemId = id,
		catalogId = catalogId,
		quantity = quantity,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = {},
	}
end

-- The rw.a1 trip at stage 2 (s1 cleared), the player at the rw.a1.s2 campfire, the bag full.
local function island(heldDriedWood: boolean): any
	local host = Journey.new({ locale = "en-us" })
	host.enter("home")
	local opened = host.factory.expeditionStore.transaction(ACTOR, function(document)
		local state = assert(Archipelago.open(Content, {
			id = "trip-full-bag",
			index = 1,
			seed = 79,
			revision = "robango-route-v1",
			ttl = 1800,
			entryBuffer = 0,
			actor = ACTOR,
		}, { level = 99, developmentRank = 99, instabilityAccess = 5 }, host.at.value))
		state.stage = 2
		state.completed["rw.a1.s1.gather"], state.completed["rw.a1.s1.survey"] = true, true
		document.archipelago = state
		return { ok = true }
	end)
	assert(opened.ok, tostring(opened.reason))
	local campfire = nil
	for _, layout in Content.layouts do
		for _, anchor in (if layout.id == "rw.a1.s2" then layout.anchors else {}) :: { any } do
			campfire = if anchor.id == "station.campfire.t1" then anchor.position else campfire
		end
	end
	host.enter("archipelago", { x = campfire.x, y = campfire.y + 3, z = campfire.z + 2 })
	assert(host.layoutId == "rw.a1.s2", "on rw.a1.s2: " .. tostring(host.layoutId))
	local filled = host.session.personalTransaction(ACTOR, function(raw)
		local data = raw.envelope.genres["survival-coop"].data
		local bag = data.inventory.bag
		bag.items, bag.reservations = {}, {}
		local slots = 0
		local function put(item: any)
			bag.items[item.itemId] = item
			slots += 1
		end
		put(stack("a-branch", "branch", 4))
		if heldDriedWood then
			put(stack("a-dried-wood", "dried-wood", 3))
		end
		-- Plain one-unit stacks (no tool, no food, nothing the recipe makes) fill every other slot.
		for _, item in Content.items do
			if slots >= bag.limits.slots then
				break
			end
			if
				not item.maxDurabilityMilli
				and not item.foodEffects
				and item.id ~= "branch"
				and item.id ~= "dried-wood"
			then
				put(stack("fill-" .. item.id, item.id, 1))
			end
		end
		assert(slots == bag.limits.slots, "bag filled to its " .. bag.limits.slots .. " slots")
		return raw
	end)
	assert(filled, "bag filled")
	return host
end

-- The player's view: the shipped craft and bag sheets on the real Session packets.
local function player(host: any): any
	local h = host.render()
	local p: any = { h = h, commands = {} }
	host.onCommand = function(request: any, result: any)
		table.insert(p.commands, { action = request.action, ok = result.ok, reason = result.reason })
	end
	local function shown(item: any): boolean
		local current = item
		while current and current ~= h.playerGui do
			if current.Visible == false or current.Enabled == false then
				return false
			end
			current = current.Parent
		end
		return current == h.playerGui
	end
	function p.find(name: string, prefix: boolean?): any
		for _, item in h.playerGui:GetDescendants() do
			local match = if prefix then string.sub(item.Name, 1, #name) == name else item.Name == name
			if match and shown(item) then
				return item
			end
		end
		return nil
	end
	function p.click(button: any)
		h.click(button)
		host.render()
	end
	function p.wait(seconds: number)
		for _ = 1, seconds do
			host.tick(1)
			host.pump()
			host.render()
		end
	end
	function p.open(section: string)
		for _ = 1, 4 do
			local open = h.sheets()
			if #open == 0 then
				break
			end
			h.click(open[1].close)
		end
		pcall(function()
			h.hud.close()
		end)
		h.hud.open(section)
		host.render()
	end
	function p.recipe(id: string)
		p.open("craft")
		if not p.find("Recipe-" .. id) then
			p.click(assert(p.find("RecipeFilter"), "craft sheet filter"))
		end
		p.click(assert(p.find("Recipe-" .. id), "recipe row " .. id))
	end
	function p.bag(): any
		return host.personal(ACTOR).inventory.bag
	end
	function p.held(catalogId: string): number
		local total = 0
		for _, item in p.bag().items do
			total += if item.catalogId == catalogId then item.quantity else 0
		end
		return total
	end
	function p.progress(): number
		local trip = host.factory.expeditionStore.snapshot(ACTOR).archipelago
		return trip.progress[OBJECTIVE] or 0
	end
	function p.last(action: string): any
		for index = #p.commands, 1, -1 do
			if p.commands[index].action == "survival-coop:" .. action then
				return p.commands[index]
			end
		end
		return nil
	end
	-- Reserve at the island campfire, Start, wait out craftMillis, then press Complete once.
	function p.craftOnce(recipeId: string)
		p.recipe(recipeId)
		p.click(assert(p.find("Reserve-" .. recipeId), "Reserve on the recipe card"))
		p.wait(1)
		local reserved = assert(p.last("craft-reserve"), "reserve sent")
		assert(reserved.ok, "reserve: " .. tostring(reserved.reason))
		p.click(assert(p.find("start-", true), "the job card shows Start"))
		local started = assert(p.last("craft-start"), "start sent")
		assert(started.ok, "start: " .. tostring(started.reason))
		p.wait(6)
		p.click(assert(p.find("complete-", true), "the job card shows Complete"))
		p.wait(1)
	end
	return p
end

return {
	["rw.a1.s2 stage craft collects into a full bag when dried-wood stacks, and the objective counts it"] = function()
		local host = island(true)
		local p = player(host)
		assert(p.progress() == 0, "stage craft open")
		p.craftOnce("dry-twig")
		local collected = assert(p.last("craft-complete"), "Complete sent")
		assert(collected.ok, "full-bag collect refused: " .. tostring(collected.reason))
		assert(p.held("dried-wood") == 4, "output folded into the held stack: " .. p.held("dried-wood"))
		local slots = 0
		for _ in p.bag().items do
			slots += 1
		end
		assert(slots == p.bag().limits.slots, "the bag stays within its slots: " .. slots)
		assert(p.progress() == 1, OBJECTIVE .. " progress " .. p.progress())
		host.factory.close()
	end,
	["rw.a1.s2 stage craft that needs a slot stays Ready until Drop frees one, then counts once"] = function()
		local host = island(false)
		local p = player(host)
		p.craftOnce("dry-twig")
		local refused = assert(p.last("craft-complete"), "Complete sent")
		assert(not refused.ok and refused.reason == "FULL_SLOTS", "no slot, no collect: " .. tostring(refused.reason))
		assert(p.held("dried-wood") == 0 and p.progress() == 0, "nothing made, nothing counted")
		local jobId = nil
		for id, entry in host.personal(ACTOR).workshop.entries do
			jobId = if entry.job.recipeId == "dry-twig" and entry.job.state == "Ready" then id else jobId
		end
		assert(jobId, "the finished job waits Ready with its inputs held")
		-- FULL_SLOTS pressure: the bag sheet's Drop (then its confirm) frees the smallest plain stack.
		p.open("bag")
		p.click(assert(p.find("fill-cord"), "a plain stack in the bag grid"))
		p.click(assert(p.find("Drop-fill-cord"), "Drop on the selected stack"))
		p.click(assert(p.find("DropConfirm-fill-cord"), "Drop asks to confirm"))
		p.wait(1)
		local dropped = assert(p.last("item-drop"), "drop sent")
		assert(dropped.ok, "drop: " .. tostring(dropped.reason))
		p.recipe("dry-twig")
		p.click(assert(p.find("complete-" .. jobId), "the same job's Complete"))
		p.wait(1)
		local collected = assert(p.last("craft-complete"), "Complete sent again")
		assert(collected.ok, "collect after Drop: " .. tostring(collected.reason))
		assert(p.held("dried-wood") == 1, "the job's output is in the bag")
		assert(host.personal(ACTOR).workshop.entries[jobId].job.state == "Committed", "the player's job finished")
		assert(p.progress() == 1, OBJECTIVE .. " progress " .. p.progress())
		host.factory.close()
	end,
}
