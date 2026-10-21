--!strict
local Homes = require("./HomeReservation")
local Memory = require("../data/MemoryBackend")
return {
	["unacknowledged reservation is never sent to TeleportService and recovery reuses durable result"] = function()
		local memory = Memory.new()
		local ambiguous = true
		local backend = {
			update = function(key, transform)
				local ok, record = memory.update(key, transform)
				if ambiguous and ok and record.data.reservation then
					ambiguous = false
					return false, "lost_ack"
				end
				return ok, record
			end,
		}
		local calls = 0
		local homes = Homes.new(
			backend,
			{
				sessionId = "a",
				leaseSeconds = 30,
				now = function()
					return 0
				end,
			},
			100,
			function()
				calls += 1
				return "code", "private"
			end
		)
		local reservation = homes.resolve("123")
		assert(reservation == nil, "lost acknowledgment cannot authorize teleport")
		ambiguous = false
		local recovered = assert(homes.resolve("123"), "confirmed persisted reservation recovered")
		assert(recovered.accessCode == "code" and calls == 1, "recovery reuses original access code")
	end,
	["stable reservation survives owner release and server reload without another reservation"] = function()
		local backend = Memory.new()
		local calls = 0
		local function owner(id: string): any
			return Homes.new(
				backend,
				{
					sessionId = id,
					leaseSeconds = 30,
					now = function()
						return 0
					end,
				},
				100,
				function(placeId)
					assert(placeId == 100, "configured home place used")
					calls += 1
					return "code", "private"
				end
			)
		end
		local a = owner("a")
		local first = assert(a.resolve("123"), "first home allocated")
		assert(first.owner == "123" and first.accessCode == "code", "server allocated actor home")
		assert(a.resolve("123").accessCode == "code", "repeated resolution is stable")
		local b = owner("b")
		assert(b.resolve("123").privateServerId == "private", "fresh server loads original reservation")
		assert(calls == 1, "reconnect never creates a replacement home")
	end,
}
