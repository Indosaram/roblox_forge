--!strict
local Range = require("./EnsembleRange")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local function vector(x: number): any
	return setmetatable({
		x = x,
		Dot = function(self: any, other: any)
			return self.x * other.x
		end,
	}, {
		__sub = function(a: any, b: any)
			return vector(a.x - b.x)
		end,
	})
end
return {
	["range negative kills bypassed distance authority"] = function()
		local source = fs.readFile("genres/survival-coop/module/EnsembleRange.luau")
		local first, last = string.find(source, "squared <= radius * radius", 1, true)
		assert(first and last, "range mutation anchor")
		local bypass = luau.load(string.sub(source, 1, first - 1) .. "true" .. string.sub(source, last + 1))()
		local root = {
			Position = vector(17),
			IsDescendantOf = function()
				return true
			end,
		}
		local player = {
			Character = {
				FindFirstChild = function()
					return root
				end,
				FindFirstChildOfClass = function()
					return { Health = 100 }
				end,
			},
		}
		local config = {
			workspace = {},
			players = {
				GetPlayerByUserId = function()
					return player
				end,
			},
			hasInstrument = function()
				return true
			end,
			venues = function()
				return {
					{
						enabled = true,
						part = {
							Position = vector(0),
							IsDescendantOf = function()
								return true
							end,
						},
					},
				}
			end,
		}
		assert(not Range.new(config).inRange("1", 16) and bypass.new(config).inRange("1", 16), "distance mutant killed")
	end,
	["server venue requires living rooted performer instrument and trusted radius"] = function()
		local live, equipped = true, true
		local root: any = {
			Position = vector(16),
			IsDescendantOf = function()
				return live
			end,
		}
		local humanoid = { Health = 100 }
		local player: any = {
			Character = {
				FindFirstChild = function(_self: any, name: string)
					assert(name == "HumanoidRootPart", "root only")
					return root
				end,
				FindFirstChildOfClass = function()
					return humanoid
				end,
			},
		}
		local venue = {
			enabled = true,
			part = {
				Position = vector(0),
				IsDescendantOf = function()
					return true
				end,
			},
		}
		local range = Range.new({
			players = {
				GetPlayerByUserId = function(_self: any, id: number)
					return if id == 1 then player else nil
				end,
			},
			workspace = {},
			venues = function()
				return { venue }
			end,
			hasInstrument = function()
				return equipped
			end,
		})
		assert(range.inRange("1", 16) and not range.inRange("2", 16), "inclusive radius and missing player")
		root.Position = vector(16.01)
		assert(not range.inRange("1", 16), "outside radius")
		root.Position = vector(0)
		equipped = false
		assert(not range.inRange("1", 16), "instrument required")
		equipped = true
		humanoid.Health = 0
		assert(not range.inRange("1", 16), "dead performer")
		humanoid.Health = 100
		live = false
		assert(not range.inRange("1", 16), "removed character")
		live = true
		venue.enabled = false
		assert(not range.inRange("1", 16), "disabled venue")
		venue.enabled = true
		root.Position = vector(0 / 0)
		assert(not range.inRange("1", 16), "NaN position")
		local removed = {}
		range.enforce({ members = { ["1"] = {}, ["2"] = {} } }, function(actor)
			removed[actor] = true
		end, 16)
		assert(removed["1"] and removed["2"], "live membership rechecked")
	end,
}
