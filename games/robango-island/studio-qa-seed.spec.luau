--!strict
-- Studio-only damaged-item seed: inert on live servers, one damaged repairable copy per player in Studio.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Inventory = require("../../core/domain/inventory/Inventory")
local Job = require("../../core/domain/crafting/Job")
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local content: any = require("./src/shared/SurvivalContent")

local function boot(studio: boolean, marker: string?): (any, () -> any, () -> any)
	local listeners, attributes = {}, {}
	local workspace = {
		GetAttribute = function(_, key)
			return attributes[key]
		end,
		SetAttribute = function(_, key, value)
			if attributes[key] == value then
				return
			end
			attributes[key] = value
			for _, fn in listeners do
				fn()
			end
		end,
		GetAttributeChangedSignal = function()
			return {
				Connect = function(_, fn)
					table.insert(listeners, fn)
				end,
			}
		end,
	}
	local forge = { core = { domain = { inventory = { Inventory = Inventory }, crafting = { Job = Job } } } }
	local source = fs.readFile("games/robango-island/src/server/RobangoIslandServer.server.luau")
	local first = assert(
		string.find(source, "if RunService:IsStudio() then -- QA: " .. (marker or "ForgeQASeedDamaged"), 1, true)
	)
	local last = assert(string.find(source, "\nend\n", first, true))
	local raw: any
	local document: any = {}
	local SkillTree = require("../../core/domain/progression/SkillTree")
	forge.core.domain.progression = { SkillTree = SkillTree }
	luau.load(string.sub(source, first, last + 4), {
		environment = {
			workspace = workspace,
			Forge = forge,
			content = content,
			assert = assert,
			tostring = tostring,
			tonumber = tonumber,
			string = string,
			math = math,
			warn = function() end,
			factory = {
				expeditionStore = {
					transaction = function(actor, transform)
						assert(actor == "7", "seed writes the joined player's expedition document")
						local candidate = table.clone(document)
						local outcome = transform(candidate)
						document = if outcome.ok then candidate else document
						return outcome
					end,
				},
			},
			require = function(value)
				return value
			end,
			RunService = {
				IsStudio = function()
					return studio
				end,
			},
			Players = {
				GetPlayers = function()
					return { { UserId = 7 } }
				end,
			},
			session = {
				personalTransaction = function(actor, transform)
					assert(actor == "7", "seed writes the joined player's profile")
					raw = transform(raw)
					return true, raw
				end,
			},
		},
	})()
	local limits = { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 }
	raw = { envelope = { genres = { ["survival-coop"] = { data = { inventory = {} } } } } }
	raw.envelope.genres["survival-coop"].data.inventory.bag = Inventory.save(Inventory.new("bag", limits))
	return workspace, function()
		return raw
	end, function()
		return document
	end
end

local function repairable(): string
	for _, item in content.items do
		if (item.maxDurabilityMilli or 0) > 0 then
			return item.id
		end
	end
	error("no repairable item")
end

return {
	["damaged-item seed is inert outside Studio"] = function()
		local workspace, raw = boot(false)
		workspace:SetAttribute("ForgeQASeedDamaged", repairable())
		local items = raw().envelope.genres["survival-coop"].data.inventory.bag.items
		assert(next(items) == nil, "live server bag untouched")
	end,
	["Studio seed grants exactly one damaged repairable copy through the bag save"] = function()
		local id = repairable()
		local workspace, raw = boot(true)
		workspace:SetAttribute("ForgeQASeedDamaged", id)
		local saved = raw().envelope.genres["survival-coop"].data.inventory.bag
		local bag = Inventory.fromSave(saved, Job.catalog(content))
		local count, item = 0, nil
		for _, entry in bag.items do
			count += 1
			item = entry
		end
		assert(count == 1 and item.catalogId == id and item.quantity == 1, "exactly one copy")
		assert(Model.repairCost(item, content) ~= nil, "damaged copy shows the Repair button")
	end,
	["progress seed is inert outside Studio"] = function()
		local workspace, raw, doc = boot(false, "ForgeQASeedProgress")
		workspace:SetAttribute("ForgeQASeedProgress", "30:2")
		assert(raw().envelope.genres["survival-coop"].data.progression == nil, "live profile untouched")
		assert(doc().development == nil, "live development untouched")
	end,
	["Studio progress seed raises level and rank through the profile, idempotently"] = function()
		local workspace, raw, doc = boot(true, "ForgeQASeedProgress")
		workspace:SetAttribute("ForgeQASeedProgress", "30:2")
		local tree = raw().envelope.genres["survival-coop"].data.progression
		assert(tree and tree.level == 30, "level 30 saved through personalTransaction")
		assert(doc().development.points == 200, "rank 2 = 200 development points")
		local version = tree.version
		workspace:SetAttribute("ForgeQASeedProgress", "5:0")
		local again = raw().envelope.genres["survival-coop"].data.progression
		assert(again.level == 30 and again.version == version, "raise-only: a lower seed changes nothing")
		assert(doc().development.points == 200, "raise-only rank")
		workspace:SetAttribute("ForgeQASeedProgress", "bogus")
		assert(raw().envelope.genres["survival-coop"].data.progression.level == 30, "malformed seed ignored")
	end,
	["Studio progress seed with a guide id opens that guide"] = function()
		local Guide = require("../../genres/survival-coop/module/GuideEvents")
		local target, index = nil, 0
		for i, guide in content.guides do
			if string.match(guide.id, "^rw%.g12%.") then
				target, index = guide, i
			end
		end
		assert(target, "g12 guide exists")
		local workspace, raw, doc = boot(true, "ForgeQASeedProgress")
		workspace:SetAttribute("ForgeQASeedProgress", "1:0:" .. target.id)
		local level = raw().envelope.genres["survival-coop"].data.progression.level
		local development = doc().development
		local grade = development.points // 100
		for i, guide in content.guides do
			local open = not development.definitions[guide.id] and Guide.open(guide, level, grade)
			if i < index then
				assert(development.definitions[guide.id], "earlier guides marked done")
			elseif i == index then
				assert(open, "the seeded guide is open")
			end
		end
	end,
}
