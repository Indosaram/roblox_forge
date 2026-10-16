--!strict
local Visit = require("./Visit")

local function island(): Visit.Island
	return { hostId = "host", version = 3, items = { wood = 5, berry = 2 }, data = { crops = { a = "dry" } } }
end

local function visit(): Visit.Visit
	return Visit.new({
		durationSeconds = 600,
		isFriend = function(host, visitor)
			return host == "host" and visitor == "friend"
		end,
		help = {
			water = function(state, _visitor, args)
				if state.data.crops[args[1]] ~= "dry" then
					return nil, "NOTHING_TO_HELP"
				end
				state.data.crops[args[1]] = "watered"
				return state, nil
			end,
			-- Hostile handler: a help action that tries to move items out.
			smuggle = function(state, _visitor, _args)
				state.items.wood -= 1
				return state, nil
			end,
			erase = function(state, _visitor, _args)
				local items: { [string]: number? } = state.items
				items.berry = nil
				return state, nil
			end,
		},
	})
end

return {
	["friend reads a detached copy and helps without changing host items"] = function()
		local v, host = visit(), island()
		local pass = assert(v.open("host", "friend", 100))
		local view = assert(v.read(pass, host, 100))
		view.items.wood = 0
		assert(host.items.wood == 5, "read copy is detached")
		local helped = assert(v.help(pass, host, "water", { "a" }, 101))
		assert(helped.data.crops.a == "watered" and helped.version == 4, "help applied")
		assert(helped.items.wood == 5 and helped.items.berry == 2, "items unchanged")
		assert(host.data.crops.a == "dry", "candidate only")
	end,
	["visitor can never take items from the host island"] = function()
		local v, host = visit(), island()
		local pass = assert(v.open("host", "friend", 0))
		for _, action in { "take", "withdraw", "pickup" } do
			local taken, err = v.help(pass, host, action, { "wood", 1 }, 1)
			assert(taken == nil and err == "ACTION_NOT_ALLOWED", action .. " is not an action")
		end
		local smuggled, smuggleError = v.help(pass, host, "smuggle", {}, 1)
		assert(smuggled == nil and smuggleError == "TAKE_FORBIDDEN", "item decrease refused")
		local erased, eraseError = v.help(pass, host, "erase", {}, 1)
		assert(erased == nil and eraseError == "TAKE_FORBIDDEN", "item removal refused")
		assert(host.items.wood == 5 and host.items.berry == 2, "host island untouched")
	end,
	["only friends within the visit window may enter"] = function()
		local v, host = visit(), island()
		local stranger, strangerError = v.open("host", "stranger", 0)
		assert(stranger == nil and strangerError == "NOT_FRIEND", "stranger refused")
		local own, ownError = v.open("host", "host", 0)
		assert(own == nil and ownError == "OWN_ISLAND", "own island is not a visit")
		local pass = assert(v.open("host", "friend", 0))
		local late, lateError = v.read(pass, host, 600)
		assert(late == nil and lateError == "VISIT_EXPIRED", "expired pass")
		local other = island()
		other.hostId = "someone"
		local wrong, wrongError = v.read(pass, other, 1)
		assert(wrong == nil and wrongError == "WRONG_ISLAND", "pass bound to host")
		local bad, badError = v.open("host", "friend", -1)
		assert(bad == nil and badError == "INVALID_CLOCK", "clock validated")
	end,
}
