--!strict
local Adapter = require("./Adapter")
local Fixture = {}
function Fixture.config(): Adapter.Config
	return {
		currency = "Coins",
		startingBalance = 10,
		plotCount = 2,
		crops = { carrot = { growthSeconds = 2, sellPrice = 10 } },
		seedPrice = { carrot = 1 },
		startingSeeds = { carrot = 1 },
	}
end
return Fixture
