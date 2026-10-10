--!strict
local Types = require("../../../lib/genrecontract")
local Runtime = require("./module/Contract")
local generator: Types.Generator = {
	api = 1,
	id = "fixture-counter",
	configVersion = 1,
	runtime = Runtime,
	generate = function(input)
		return {
			config = { target = 2 },
			controls = {
				{
					id = "increment",
					action = "fixture-counter:increment",
					args = {},
					label = "Increment",
					kind = "button",
				},
			},
			assetKeys = { "fixture-counter-starter-prop", "fixture-counter-action" },
			generation = { "procedural", "audio" },
			artifacts = {
				{ path = "design/fixture-counter/overview.md", content = "# Counter\n" },
				{
					path = "assets/fixture-counter/procgen.yml",
					content = "assets:\n  - key: fixture-counter-starter-prop\n    kind: prop\n    archetype: crate\n    scale: 1\n    body: [120, 80, 40]\n    accent: [80, 190, 80]\n    seed: "
						.. tostring(input.seed)
						.. "\n",
				},
				{
					path = "assets/fixture-counter/audio.yml",
					content = "cues:\n  - key: fixture-counter-action\n    kind: sfx\n    type: click\n    duration: 0.1\n    seed: "
						.. tostring(input.seed)
						.. "\n",
				},
			},
		}
	end,
	driver = {
		run = function(executor, _input)
			assert(executor.join("counter-proof").ok, "join failed")
			assert(executor.dispatchClient("counter-proof", "fixture-counter:increment", {}).ok, "increment failed")
			assert(executor.dispatchClient("counter-proof", "fixture-counter:increment", {}).ok, "increment failed")
			local target = executor.snapshot("counter-proof")["fixture-counter"].count == 2
			local save = executor.save("counter-proof")
			executor.leave("counter-proof")
			return {
				{ name = "counter target", ok = target },
				{
					name = "counter rejoin",
					ok = executor.join("counter-proof", save).ok
						and executor.snapshot("counter-proof")["fixture-counter"].count == 2,
				},
			}
		end,
		simulate = function(executor, _input, players, _days)
			local balances = {}
			for i = 1, players do
				local player = tostring(i)
				assert(executor.join(player).ok, "join failed")
				assert(executor.dispatchClient(player, "fixture-counter:increment", {}).ok, "increment failed")
				balances[player] = executor.snapshot(player)["fixture-counter"].count
			end
			return {
				balances = balances,
				sourceTotal = players,
				sinkTotal = 0,
				acceptedActions = players,
				rejectedActions = 0,
			}
		end,
	},
	qa = {
		scenarios = { "contract-loop", "contract-rejoin" },
		operations = { "dispatch", "snapshot", "advanceTo", "save", "restore" },
		targets = { "fixture-counter:increment" },
	},
}
return generator
