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
}
