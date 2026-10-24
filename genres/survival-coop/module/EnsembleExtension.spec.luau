--!strict
local Extension = require("./EnsembleExtension")
local Rules = require("../../../core/domain/music/TestCatalog")
local serde = require("@lune/serde")
return {
	["malformed and oversized imports cannot fence save share or change room"] = function()
		local mutations = 0
		local extension = Extension.new({
			rules = Rules,
			decode = function(text)
				return serde.decode("json", text)
			end,
			now = function()
				return 0
			end,
			inRange = function()
				return true
			end,
			repository = {
				save = function()
					mutations += 1
					return { ok = true }
				end,
				load = function()
					return nil
				end,
			},
		})
		for _, text in { "{", string.rep("x", Rules.maxBytes + 1), '{"version":1,"tempo":999,"parts":[]}' } do
			local result = extension.command("owner", "survival-coop:score-import", { text }, {}, "client", function()
				mutations += 1
				return { ok = true }
			end)
			assert(
				not result.ok and mutations == 0 and extension.snapshot("owner").room == nil,
				"EnsembleExtension.spec.luau: invariant failed"
			)
		end
	end,
	["ensemble join is refused unless the actor owns the part's instrument"] = function()
		local owned: { [string]: boolean } = {}
		local score = { version = 1, tempo = 120, parts = { { instrumentId = "flute", notes = {} } } }
		local extension = Extension.new({
			rules = Rules,
			decode = function(text)
				return serde.decode("json", text)
			end,
			now = function()
				return 0
			end,
			inRange = function()
				return true
			end,
			owns = function(actor: string, instrumentId: string): boolean
				return owned[actor .. ":" .. instrumentId] == true
			end,
			repository = {
				canRead = function()
					return true
				end,
				load = function()
					return score
				end,
			},
		})
		local function join(actor: string): any
			return extension.command(
				actor,
				"survival-coop:ensemble-join",
				{ "s", 1, 1 } :: { any },
				{},
				"client",
				function()
					return { ok = true }
				end
			)
		end
		local refused = join("7")
		assert(not refused.ok and refused.reason == "ensemble.instrument", "no flute: " .. tostring(refused.reason))
		assert(extension.snapshot("7").room == nil, "a refused join opens no room")
		owned["7:piano"] = true
		assert(join("7").reason == "ensemble.instrument", "another instrument does not play the flute part")
		owned["7:flute"] = true
		assert(join("7").ok and extension.snapshot("7").room.members["7"], "the flute owner joins")
	end,
	["a solo performer hosts, readies, starts and finishes a multi-part score alone"] = function()
		local at = 100
		local score = {
			version = 1,
			tempo = 120,
			parts = {
				{
					instrumentId = "flute",
					notes = { { startTick = 0, durationTicks = 480, pitch = 60, velocity = 100 } },
				},
				{
					instrumentId = "drums",
					notes = { { startTick = 480, durationTicks = 480, pitch = 40, velocity = 90 } },
				},
			},
		}
		local extension = Extension.new({
			rules = Rules,
			decode = function(text)
				return serde.decode("json", text)
			end,
			now = function()
				return at
			end,
			inRange = function()
				return true
			end,
			owns = function(_actor: string, instrumentId: string): boolean
				return instrumentId == "flute"
			end,
			repository = {
				canRead = function()
					return true
				end,
				load = function()
					return score
				end,
			},
		})
		local function send(action: string, args: { any }): any
			return extension.command("7", "survival-coop:" .. action, args, {}, "client", function()
				return { ok = true }
			end)
		end
		assert(send("ensemble-join", { "s", 1, 1 }).ok, "solo join opens the room")
		assert(send("ensemble-start", {}).reason == "ensemble.not_ready", "start names the missing ready")
		assert(send("ensemble-ready", { true }).ok, "solo ready")
		assert(send("ensemble-start", {}).ok, "one ready host starts without waiting for others")
		local room = extension.snapshot("7").room
		assert(room.host == "7" and room.startAt == at + Rules.countdownSeconds, "host and +2 s start")
		assert(#room.events == 2, "the unclaimed part still plays as backing")
		extension.recover("7", room.startAt + 0.6)
		assert(extension.snapshot("7").room ~= nil, "still performing")
		extension.recover("7", room.startAt + 1)
		assert(extension.snapshot("7").room == nil, "the performance finishes and frees the fire")
		assert(send("ensemble-join", { "s", 1, 1 }).ok, "the soloist can play again")
	end,
	["score share refuses a non-numeric or self recipient before the fence and repository"] = function()
		local calls = 0
		local extension = Extension.new({
			rules = Rules,
			decode = function(text)
				return serde.decode("json", text)
			end,
			now = function()
				return 0
			end,
			inRange = function()
				return true
			end,
			repository = {
				share = function(_actor, _id, _revision, recipient)
					calls += 1
					return { ok = true, data = { recipient = recipient } }
				end,
				load = function()
					return nil
				end,
			},
		})
		local function fence()
			calls += 1
			return { ok = true }
		end
		for _, case in { { "abc", "score.recipient" }, { "7", "score.self" }, { "", "score.recipient" } } do
			local result = extension.command(
				"7",
				"survival-coop:score-share",
				{ "7:score:1", 1 :: any, case[1] },
				{},
				"client",
				fence
			)
			assert(not result.ok and result.reason == case[2] and calls == 0, case[1] .. " refused")
		end
		local shared = extension.command(
			"7",
			"survival-coop:score-share",
			{ "7:score:1", 1 :: any, " 42 " },
			{},
			"client",
			fence
		)
		assert(shared.ok and shared.data.recipient == "42" and calls == 2, "trimmed numeric recipient shared")
	end,
}
