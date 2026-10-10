--!strict
local Contract = require("./Contract")
local Executor = require("../../../core/domain/genre/Executor")
local Fixture = require("./Adapter.fixture")
local Schema = require("../../../core/infra/net/Schema")
return {
	["production settlement actions have exact tuples and accepted invite server origin"] = function()
		local expected = {
			["settlement-invite"] = 3,
			["settlement-leave"] = 3,
			["settlement-kick"] = 3,
			["settlement-transfer-owner"] = 3,
			["settlement-rejoin"] = 3,
			["settlement-reserve"] = 7,
			["settlement-place"] = 3,
			["settlement-cancel"] = 3,
			["settlement-demolish"] = 4,
		}
		local count = 0
		for _, action in Contract.actions do
			local arity = expected[action.id]
			if arity then
				count += 1
				assert(#action.args == arity, "exact settlement tuple")
				assert(action.origin == (if action.id == "settlement-invite" then "server" else "client"), "origin")
				assert(not Schema.check(Schema.tuple(action.args), { "" }), "malformed tuple refused")
			end
		end
		assert(count == 9, "all nine actual actions registered")
		local executor = Executor.new(
			{ api = 1, order = { Contract.id }, configs = { [Contract.id] = Fixture.config } },
			{ Contract },
			{
				now = function()
					return 0
				end,
				roll = function()
					return 0
				end,
				emit = function(_) end,
			}
		)
		assert(executor.join("owner").ok, "actual contract joins")
		local invite: { any } = { "member", 0, 0 }
		assert(
			not executor.validateClient("owner", "survival-coop:settlement-invite", invite).ok,
			"unilateral client invite denied"
		)
		assert(
			executor.validateServer("owner", "survival-coop:settlement-invite", invite).ok,
			"accepted server invite schema"
		)
		local invalid: { any } = { "hut", 32, 0, 0, 0, 0, 0 }
		assert(not executor.validateClient("owner", "survival-coop:settlement-reserve", invalid).ok, "coordinate bound")
		invalid[2], invalid[4] = 0, 4
		assert(not executor.validateClient("owner", "survival-coop:settlement-reserve", invalid).ok, "rotation bound")
		invalid[4], invalid[5] = 0, 0 / 0
		assert(not executor.validateClient("owner", "survival-coop:settlement-reserve", invalid).ok, "finite revision")
	end,
}
