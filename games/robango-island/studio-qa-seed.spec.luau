--!strict
-- Studio-only damaged-item seed: inert on live servers, one damaged repairable copy per player in Studio.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Inventory = require("../../core/domain/inventory/Inventory")
local Job = require("../../core/domain/crafting/Job")
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local content: any = require("./src/shared/SurvivalContent")

local function boot(studio: boolean): (any, () -> any)
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
	local first = assert(string.find(source, "if RunService:IsStudio() then -- QA: ForgeQASeedDamaged", 1, true))
	local last = assert(string.find(source, "\nend\n", first, true))
	local raw: any
	luau.load(string.sub(source, first, last + 4), {
		environment = {
			workspace = workspace,
			Forge = forge,
			content = content,
			assert = assert,
			tostring = tostring,
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
}
