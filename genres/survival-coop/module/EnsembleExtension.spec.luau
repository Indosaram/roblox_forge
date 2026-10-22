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
