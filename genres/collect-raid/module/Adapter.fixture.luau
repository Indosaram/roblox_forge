--!strict
local LoopFixture = require("./runtime/Loop.fixture")
local Executor = require("../../../core/domain/genre/Executor")
local Fixture = {}
function Fixture.config(): { [string]: any }
	local config = Executor.clone(LoopFixture) :: { [string]: any }
	config.profile = { version = 1 }
	config.teams = { "red", "blue" }
	config.siege = { period = 10, duration = 2, maxTake = 3 }
	return config
end
return Fixture
