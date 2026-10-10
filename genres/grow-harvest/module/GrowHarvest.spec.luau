--!strict
-- Specs for GrowHarvest: planting, timed growth, harvest hooks, and sale.

local GrowHarvest = require("./GrowHarvest")

local CONFIG: GrowHarvest.Config = {
	currency = "Coins",
	plotCount = 2,
	crops = {
		carrot = { growthSeconds = 10, sellPrice = 5 },
		pumpkin = { growthSeconds = 20, sellPrice = 20 },
	},
}

local function newGarden(hooks: GrowHarvest.Hooks?)
	return GrowHarvest.new(CONFIG, hooks)
end

return {
	["plant occupies a plot and starts a growth timer"] = function()
		local garden = newGarden()
		assert(garden:plant(1, "carrot", 100) == true, "plant should succeed")
		assert(garden:cropAt(1) == "carrot", "plot holds the crop")
		assert(garden:isReady(1, 100) == false, "not ready at plant time")
		assert(garden:remaining(1, 100) == 10, "full growth time remains")
	end,

	["growth completes at growthSeconds"] = function()
		local garden = newGarden()
		garden:plant(1, "carrot", 100)
		assert(garden:isReady(1, 109.9) == false, "not ready just before")
		assert(garden:isReady(1, 110) == true, "ready exactly at growthSeconds")
		assert(garden:remaining(1, 110) == 0, "no time remains")
		assert(garden:remaining(1, 200) == 0, "remaining clamps at zero")
	end,

	["harvest before growth completes returns nil and keeps the plot"] = function()
		local garden = newGarden()
		garden:plant(1, "carrot", 100)
		assert(garden:harvest(1, 105) == nil, "early harvest fails")
		assert(garden:cropAt(1) == "carrot", "crop still planted")
	end,

	["harvest when ready returns the crop and clears the plot"] = function()
		local garden = newGarden()
		garden:plant(1, "pumpkin", 0)
		assert(garden:harvest(1, 20) == "pumpkin", "harvest returns crop id")
		assert(garden:cropAt(1) == nil, "plot is empty after harvest")
		assert(garden:harvest(1, 25) == nil, "second harvest fails")
	end,

	["plant rejects occupied plots, unknown crops, and invalid indices"] = function()
		local garden = newGarden()
		assert(garden:plant(1, "carrot", 0) == true, "first plant ok")
		assert(garden:plant(1, "pumpkin", 0) == false, "occupied plot rejected")
		assert(garden:plant(2, "turnip", 0) == false, "unknown crop rejected")
		assert(garden:plant(0, "carrot", 0) == false, "plot 0 rejected")
		assert(garden:plant(3, "carrot", 0) == false, "plot beyond plotCount rejected")
		assert(garden:plant(1.5, "carrot", 0) == false, "fractional plot rejected")
	end,

	["a plot can be replanted after harvest"] = function()
		local garden = newGarden()
		garden:plant(2, "carrot", 0)
		garden:harvest(2, 10)
		assert(garden:plant(2, "pumpkin", 10) == true, "replant succeeds")
		assert(garden:cropAt(2) == "pumpkin", "new crop occupies the plot")
	end,

	["sell credits the wallet with the crop price"] = function()
		local garden = newGarden()
		assert(garden:balance() == 0, "empty wallet")
		assert(garden:sell("pumpkin") == 20, "sell returns price")
		assert(garden:balance() == 20, "wallet credited")
	end,

	["sell rejects unknown crops"] = function()
		local garden = newGarden()
		local ok = pcall(function()
			garden:sell("turnip")
		end)
		assert(not ok, "unknown crop should error")
	end,

	["selling a crop with sellPrice 0 returns 0 without error"] = function()
		local garden = GrowHarvest.new({
			currency = "Coins",
			plotCount = 1,
			crops = { weed = { growthSeconds = 1, sellPrice = 0 } },
		})
		assert(garden:sell("weed") == 0, "sell returns 0")
		assert(garden:balance() == 0, "balance unchanged")
	end,

	["startingBalance seeds the wallet"] = function()
		local garden = GrowHarvest.new({
			currency = "Coins",
			plotCount = 1,
			startingBalance = 40,
			crops = { carrot = { growthSeconds = 1, sellPrice = 5 } },
		})
		assert(garden:balance() == 40, "seeded balance")
	end,

	["startingBalance of zero does not error"] = function()
		local garden = GrowHarvest.new({
			currency = "Coins",
			plotCount = 1,
			startingBalance = 0,
			crops = { carrot = { growthSeconds = 1, sellPrice = 5 } },
		})
		assert(garden:balance() == 0, "zero starting balance is valid")
	end,

	["OnPlant is called with plot, cropId, and now"] = function()
		local calls = {}
		local garden = newGarden({
			OnPlant = function(context)
				table.insert(calls, context)
			end,
		})
		garden:plant(2, "pumpkin", 500)
		assert(#calls == 1, "hook called once")
		assert(calls[1].plot == 2, "hook plot")
		assert(calls[1].cropId == "pumpkin", "hook crop")
		assert(calls[1].now == 500, "hook now")
	end,

	["OnPlant is not called when planting fails"] = function()
		local calls = 0
		local garden = newGarden({
			OnPlant = function()
				calls += 1
			end,
		})
		garden:plant(9, "carrot", 0)
		assert(calls == 0, "no hook on failed plant")
	end,

	["OnHarvest is called with plot, cropId, and now and not before ready"] = function()
		local calls = {}
		local garden = newGarden({
			OnHarvest = function(context)
				table.insert(calls, context)
			end,
		})
		garden:plant(1, "carrot", 100)
		garden:harvest(1, 105)
		assert(#calls == 0, "no hook before ready")
		garden:harvest(1, 110)
		assert(#calls == 1, "hook after ready")
		assert(calls[1].plot == 1, "hook plot")
		assert(calls[1].cropId == "carrot", "hook crop")
		assert(calls[1].now == 110, "hook now")
	end,

	["readyAll makes every planted plot harvestable"] = function()
		local garden = newGarden()
		garden:plant(1, "carrot", 0)
		garden:plant(2, "pumpkin", 0)
		garden:readyAll(5)
		assert(garden:isReady(1, 5) == true, "plot 1 ready")
		assert(garden:isReady(2, 5) == true, "plot 2 ready")
		assert(garden:harvest(1, 5) == "carrot", "harvest after readyAll")
	end,
}
