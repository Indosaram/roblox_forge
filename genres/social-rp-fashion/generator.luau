--!strict
local Types = require("../../cli/forge/lib/genrecontract")
local Executor = require("../../core/domain/genre/Executor")
local Runtime = require("./module/Contract")
local Fixture = require("./module/Adapter.fixture")
local function state(executor: Executor.Executor, playerId: string): { [string]: any }
	return executor.snapshot(playerId)["social-rp-fashion"]
end
local function loop(executor: Executor.Executor, a: string, b: string, epoch: number): (number, number)
	executor.advance(epoch)
	assert(executor.dispatchClient(a, "social-rp-fashion:equip", { "starter-hat" }).ok, "fashion invariant failed")
	assert(not executor.dispatchClient(a, "social-rp-fashion:vote", { b, 5 }).ok, "fashion invariant failed")
	executor.advance(epoch + 2)
	assert(executor.dispatchClient(a, "social-rp-fashion:vote", { b, 5 }).ok, "fashion invariant failed")
	assert(executor.dispatchClient(b, "social-rp-fashion:vote", { a, 5 }).ok, "fashion invariant failed")
	assert(not executor.dispatchClient(a, "social-rp-fashion:vote", { b, 1 }).ok, "fashion invariant failed")
	executor.advance(epoch + 4)
	assert(state(executor, a).ranking[1].target == a, "fashion invariant failed")
	executor.advance(epoch + 4)
	executor.advance(epoch + 5)
	return 3, 2
end
local generator: Types.Generator = {
	api = 1,
	id = "social-rp-fashion",
	configVersion = 1,
	runtime = Runtime,
	generate = function(input)
		local config = Executor.clone(Fixture)
		if input.seed % 2 == 1 then
			config.themes = { "space", "garden" }
		end
		return {
			config = config,
			artifacts = {
				{
					path = "design/social-rp-fashion/loop.md",
					content = "# "
						.. input.title
						.. "\nEquip owned clothing, vote on the frozen roster, and earn the round prize.\n",
				},
				{
					path = "assets/social-rp-fashion/procgen.yml",
					content = "assets:\n  - key: social-rp-fashion-starter-prop\n    kind: prop\n    archetype: crystal\n    scale: 1\n    body: [180, 100, 220]\n    accent: [240, 210, 255]\n    seed: "
						.. tostring(input.seed)
						.. "\n",
				},
				{
					path = "assets/social-rp-fashion/audio.yml",
					content = string.format(
						"cues:\n  - key: social-rp-fashion-equip\n    kind: sfx\n    type: click\n    duration: 0.1\n    sampleRate: 8000\n    seed: %d\n"
							.. "  - key: social-rp-fashion-vote\n    kind: sfx\n    type: click\n    duration: 0.12\n    sampleRate: 8000\n    seed: %d\n",
						input.seed,
						input.seed + 1
					),
				},
			},
			controls = {
				{
					id = "equip-hat",
					action = "social-rp-fashion:equip",
					args = { "starter-hat" },
					label = "Equip hat",
					kind = "button",
				},
				{
					id = "equip-top",
					action = "social-rp-fashion:equip",
					args = { "starter-top" },
					label = "Equip top",
					kind = "button",
				},
				{
					id = "vote",
					action = "social-rp-fashion:vote",
					args = { 5 },
					label = "Vote 5 stars",
					kind = "player-button",
				},
			},
			assetKeys = { "social-rp-fashion-starter-prop", "social-rp-fashion-equip", "social-rp-fashion-vote" },
			generation = { "procedural", "audio" },
		}
	end,
	driver = {
		run = function(executor, _input)
			assert(executor.join("fashion-a").ok and executor.join("fashion-b").ok, "fashion invariant failed")
			loop(executor, "fashion-a", "fashion-b", 0)
			local saved = executor.save("fashion-a")
			executor.leave("fashion-a")
			assert(executor.join("fashion-a", saved).ok, "fashion invariant failed")
			local restored = state(executor, "fashion-a")
			return {
				{ name = "native stable winner and reward", ok = restored.balance == 5 },
				{ name = "outfit persistence", ok = restored.equipped.hat == "starter-hat" },
				{ name = "votes are ephemeral", ok = restored.phase == "lobby" and #restored.ranking == 0 },
			}
		end,
		simulate = function(executor, _input, playerCount, days)
			assert(
				playerCount >= 2 and playerCount <= 32 and playerCount % 1 == 0 and days >= 0 and days % 1 == 0,
				"fashion invariant failed"
			)
			local ids: { string } = {}
			for i = 1, playerCount do
				local playerId = string.format("fashion-%02d", i)
				ids[i] = playerId
				assert(executor.join(playerId).ok, "fashion invariant failed")
			end
			local accepted, rejected = 0, 0
			for day = 1, days do
				local a, r = loop(executor, ids[1], ids[2], (day - 1) * 6)
				accepted += a
				rejected += r
			end
			local balances: { [string]: number } = {}
			local total = 0
			for _, playerId in ids do
				balances[playerId] = state(executor, playerId).balance
				total += balances[playerId]
			end
			return {
				balances = balances,
				sourceTotal = total,
				sinkTotal = 0,
				acceptedActions = accepted,
				rejectedActions = rejected,
			}
		end,
	},
	qa = {
		scenarios = { "contract-loop", "contract-rejoin" },
		operations = { "dispatch", "snapshot", "advanceTo", "beginClock", "advanceElapsed", "save", "restore" },
		targets = { "social-rp-fashion:equip-hat", "social-rp-fashion:equip-top", "social-rp-fashion:vote" },
	},
}
return generator
