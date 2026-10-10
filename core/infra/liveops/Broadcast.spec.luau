--!strict
-- Specs for Broadcast: cross-server delivery over a shared memory transport,
-- own-message suppression, drop accounting, size limits, unsubscription, and
-- nested payload round-tripping. No Roblox runtime and no network.

local Broadcast = require("./Broadcast")

local function newPair(): (Broadcast.Broadcast, Broadcast.Broadcast, Broadcast.Transport)
	local transport = Broadcast.memoryTransport()
	return Broadcast.new(transport, "A"), Broadcast.new(transport, "B"), transport
end

return {
	["announce on A delivers to B exactly once and never to A"] = function()
		local a, b = newPair()
		local deliveredA = 0
		local deliveredB = 0
		a:on("rareHatch", function()
			deliveredA += 1
		end)
		b:on("rareHatch", function()
			deliveredB += 1
		end)

		local ok = a:announce("rareHatch", { player = "Zed", kaiju = "k_epic" })
		assert(ok, "announce should succeed")
		assert(deliveredB == 1, "B must receive exactly one delivery, got " .. tostring(deliveredB))
		assert(deliveredA == 0, "A must not receive its own announcement")
		assert(a.dropped == 0, "an own-message must not count as dropped")
		assert(b.dropped == 0, "a known kind must not count as dropped")
	end,

	["malformed payloads are dropped and counted"] = function()
		local _, b, transport = newPair()
		transport.publish("forge-liveops", "{not json")
		assert(b.dropped == 1, "malformed json increments dropped, got " .. tostring(b.dropped))
	end,

	["payloads over 1000 bytes are refused before publishing"] = function()
		local a, b = newPair()
		local seen = 0
		b:on("rareHatch", function()
			seen += 1
		end)
		local ok, err = a:announce("rareHatch", { blob = string.rep("x", 1200) })
		assert(not ok, "an oversized payload must be refused")
		assert(err == "payload too large", "expected the size reason, got " .. tostring(err))
		assert(seen == 0, "an oversized payload must never reach subscribers")
	end,

	["unknown kinds are dropped and counted"] = function()
		local a, b = newPair()
		local ok = a:announce("notARegisteredKind", { anything = true })
		assert(ok, "publishing an unknown kind still succeeds")
		assert(b.dropped == 1, "unknown kind increments dropped, got " .. tostring(b.dropped))
	end,

	["wrong envelope versions are dropped and counted"] = function()
		local _, b, transport = newPair()
		transport.publish("forge-liveops", '{"v":2,"kind":"rareHatch","from":"A","data":{}}')
		assert(b.dropped == 1, "a non-v1 envelope increments dropped, got " .. tostring(b.dropped))
	end,

	["unsubscribing a handler stops further delivery"] = function()
		local a, b = newPair()
		local seen = 0
		local unsubscribe = b:on("rareHatch", function()
			seen += 1
		end)

		a:announce("rareHatch", { player = "Zed", kaiju = "k_epic" })
		assert(seen == 1, "the handler fires while registered")
		unsubscribe()
		a:announce("rareHatch", { player = "Zed", kaiju = "k_epic" })
		assert(seen == 1, "the handler must not fire after unsubscribing")
	end,

	["a handler that unsubscribes itself during dispatch does not skip the next handler"] = function()
		local a, b = newPair()
		local unsubscribeFirst: (() -> ())? = nil
		local firstFired = 0
		local secondFired = 0

		unsubscribeFirst = b:on("rareHatch", function()
			firstFired += 1
			if unsubscribeFirst ~= nil then
				unsubscribeFirst()
			end
		end)
		b:on("rareHatch", function()
			secondFired += 1
		end)

		a:announce("rareHatch", { player = "Zed", kaiju = "k_epic" })
		assert(firstFired == 1, "the self-unsubscribing handler still fires once")
		assert(secondFired == 1, "the second handler must fire even though the first shifted the array")

		a:announce("rareHatch", { player = "Zed", kaiju = "k_epic" })
		assert(firstFired == 1, "the unsubscribed handler must not fire again")
		assert(secondFired == 2, "the remaining handler keeps firing on later messages")
	end,

	["nested data round-trips through the wire format"] = function()
		local a, b = newPair()
		local received: { [string]: any }? = nil
		b:on("nested", function(data)
			received = data
		end)

		a:announce("nested", {
			title = "double coins",
			meta = { level = 3, tags = { "a", "b" }, active = true },
		})
		assert(received ~= nil, "the nested announcement must arrive")
		local data = received :: { [string]: any }
		assert(data.title == "double coins", "top-level string round-trips")
		assert(data.meta.level == 3, "nested number round-trips")
		assert(data.meta.tags[2] == "b", "nested array round-trips in order")
		assert(data.meta.active == true, "nested boolean round-trips")
	end,

	["encodeEnvelope and decodeEnvelope round-trip the exact shape"] = function()
		local payload = Broadcast.encodeEnvelope("rareHatch", "forge-cli", { player = "Zed", kaiju = "k_epic" })
		local envelope = Broadcast.decodeEnvelope(payload)
		assert(envelope ~= nil, "the encoded envelope must decode")
		local decoded = envelope :: Broadcast.Envelope
		assert(decoded.v == 1, "version is 1")
		assert(decoded.kind == "rareHatch", "kind round-trips")
		assert(decoded.from == "forge-cli", "from round-trips")
		assert(decoded.data.kaiju == "k_epic", "data round-trips")

		local malformed = Broadcast.decodeEnvelope("not json")
		assert(malformed == nil, "garbage decodes to nil")
	end,

	["every handler registered for a kind fires"] = function()
		local a, b = newPair()
		local first = 0
		local second = 0
		b:on("rareHatch", function()
			first += 1
		end)
		b:on("rareHatch", function()
			second += 1
		end)

		a:announce("rareHatch", { player = "Zed", kaiju = "k_epic" })
		assert(first == 1, "the first handler fires")
		assert(second == 1, "the second handler fires")
	end,

	["a failing publish surfaces the transport error"] = function()
		local failing: Broadcast.Transport = {
			publish = function(): (boolean, string?)
				return false, "boom"
			end,
			subscribe = function(): () -> ()
				return function() end
			end,
		}
		local broadcast = Broadcast.new(failing, "A")
		local ok, err = broadcast:announce("rareHatch", { player = "Zed" })
		assert(not ok, "a failing publish must report failure")
		assert(err == "boom", "the transport error is surfaced, got " .. tostring(err))
	end,
}
