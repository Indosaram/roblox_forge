--!strict
local Friends = require("./Friends")

local function players(friends: { [number]: { [number]: boolean } }, calls: { number }, failing: boolean?): any
	return {
		GetPlayerByUserId = function(_, userId: number): any
			if friends[userId] == nil then
				return nil
			end
			return {
				IsFriendsWith = function(_, other: number): boolean
					table.insert(calls, other)
					if failing then
						error("HTTP 503")
					end
					return friends[userId][other] == true
				end,
			}
		end,
	}
end

return {
	["studio, placeId 0 and a missing Players service answer false for everyone"] = function()
		local calls: { number } = {}
		local live = players({ [2] = { [1] = true } }, calls)
		for _, env in
			{
				{
					players = live,
					isStudio = true,
					placeId = 7,
					now = function()
						return 0
					end,
				},
				{
					players = live,
					isStudio = false,
					placeId = 0,
					now = function()
						return 0
					end,
				},
				{
					players = nil,
					isStudio = false,
					placeId = 7,
					now = function()
						return 0
					end,
				},
			}
		do
			assert(Friends.source(env :: any)("1", "2") == false, "guarded source is closed")
		end
		assert(#calls == 0, "the engine is never consulted behind the guard")
	end,
	["a live source answers from Player:IsFriendsWith and caches within the ttl"] = function()
		local calls: { number } = {}
		local clock = 0
		local source = Friends.source({
			players = players({ [2] = { [1] = true }, [3] = {} }, calls),
			isStudio = false,
			placeId = 7,
			now = function()
				return clock
			end,
			ttlSeconds = 30,
		})
		assert(source("1", "2") == true, "friend")
		assert(source("1", "2") == true, "friend again")
		assert(#calls == 1, "second answer served from cache")
		assert(source("1", "3") == false, "not a friend")
		clock = 31
		assert(source("1", "2") == true and #calls == 3, "expired entry asks the engine again")
		assert(source("1", "9") == false, "visitor not on this server")
		assert(source("2", "2") == false and source("x", "2") == false and source("-1", "2") == false, "bad identities")
	end,
	["an engine error answers false for that call and is not cached"] = function()
		local calls: { number } = {}
		local flaky = true
		local roster = {
			GetPlayerByUserId = function(_, _userId: number): any
				return {
					IsFriendsWith = function(_, other: number): boolean
						table.insert(calls, other)
						if flaky then
							error("HTTP 503")
						end
						return true
					end,
				}
			end,
		}
		local source = Friends.source({
			players = roster,
			isStudio = false,
			placeId = 7,
			now = function()
				return 0
			end,
		})
		assert(source("1", "2") == false, "error is a refusal")
		flaky = false
		assert(source("1", "2") == true and #calls == 2, "the failure was not remembered")
	end,
}
