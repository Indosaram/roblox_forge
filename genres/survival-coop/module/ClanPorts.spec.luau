--!strict
local Ports = require("./ClanPorts")
local Clan = require("../../../core/domain/settlement/Clan")
local Panel = require("./ClanPanel")
local OutpostPanel = require("./OutpostPanel")
return {
	["occupancy transitions settle old occupants before publishing new occupancy"] = function()
		local ports: any = nil
		local counted = {}
		local portsConfig: any = {
			directory = {
				store = {},
				membership = function(): string
					return "a"
				end,
				read = function(): any
					return { matches = { m = { status = "active" } } }
				end,
			},
			content = { operations = {} },
			outpostId = "o",
			role = "team-outpost",
			inZone = function(): boolean
				return true
			end,
			teams = function(): any
				return {}
			end,
			dispatch = function(action: string): any
				if action == "outpost-advance" then
					table.insert(counted, #ports.outpost.facts("s", "o", "advance", {}, "server").occupants)
				end
				return { ok = true }
			end,
		}
		ports = Ports.new(portsConfig)
		assert(ports.start("m").ok, "match started by server dispatch")
		ports.occupancy("owner", true)
		ports.occupancy("owner", false)
		assert(counted[1] == 0 and counted[2] == 1, "old occupancy owns elapsed interval")
		assert(ports.tick().ok and counted[3] == 0, "periodic advance uses current empty zone")
	end,
	["authoritative membership expiry occupancy and origin control eligibility"] = function()
		local now, joined, inZone = 10, true, true
		local state = Clan.new("a", "owner")
		state.research["advanced-capture"] = 1
		local ports = Ports.new({
			directory = {
				store = {},
				membership = function(): string?
					return if joined then "a" else nil
				end,
				read = function(key: string): any
					return if key == "clan:a" then state else { owner = "a", expiresAt = 20 }
				end,
			},
			content = { operations = {}, clanPolicy = {}, outpostPolicy = {} },
			outpostId = "o",
			role = "team-outpost",
			now = function(): number
				return now
			end,
			teams = function(): any
				return {}
			end,
			inZone = function(): boolean
				return inZone
			end,
			optedIn = function(): boolean
				return true
			end,
		})
		assert(ports.captureEligibility("owner"), "live ownership enables research")
		now = 20
		assert(not ports.captureEligibility("owner"), "strict expiry boundary")
		now, joined = 10, false
		assert(not ports.captureEligibility("owner"), "departed member cannot use research")
		joined = true
		ports.occupancy("owner", true)
		local function facts(origin: string): any
			return ports.outpost.facts("owner", "o", "advance", {}, origin)
		end
		assert(#facts("server").occupants == 1 and not facts("client").server, "client cannot advance occupancy")
		inZone = false
		assert(#facts("server").occupants == 0, "server position supersedes entry event")
		ports.releaseActor("owner")
		inZone = true
		assert(#facts("server").occupants == 0, "disconnect clears occupancy")
		assert(ports.outpost.identity("owner", "foreign") == nil, "foreign outpost rejected")
	end,
	["panel authority and mobile bounds retain readable touch rows"] = function()
		local state = Clan.new("a", "owner")
		state.members.visitor = { role = "visitor", withdraw = false }
		assert(Panel.model(state, "owner", {}).govern, "owner sees governance")
		assert(not Panel.model(state, "visitor", {}).canInvite, "visitor cannot invite")
		for _, size in { { 360, 640 }, { 1280, 720 } } do
			local b = Panel.bounds(size[1], size[2])
			assert(
				b.x >= 0 and b.y >= 48 and b.x + b.width <= size[1] and b.y + b.height <= size[2],
				"sheet inside viewport"
			)
			assert(b.rowHeight >= 48, "touch target at least 48")
		end
		local model = OutpostPanel.model({ owner = "a", expiresAt = 20, matches = {} }, 20)
		assert(model.owner == "" and model.remaining == 0, "expired outpost hidden")
	end,
}
