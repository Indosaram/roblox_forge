--!strict
-- Specs for liveopsplan: PublishMessage URL and body construction, the
-- positive-integer universe id rule, and the 1024-byte message limit.

local serde = require("@lune/serde")

local liveopsplan = require("./liveopsplan")

local function decodeBody(body: string): any
	return serde.decode("json", body)
end

return {
	["buildPublish refuses nonfinite targets and invalid topic boundaries"] = function()
		assert(
			liveopsplan.buildPublish(math.huge, "topic", "hi") == nil,
			'liveopsplan.buildPublish(math.huge, "topic", "hi") == nil'
		)
		assert(
			liveopsplan.buildPublish(0 / 0, "topic", "hi") == nil,
			'liveopsplan.buildPublish(0 / 0, "topic", "hi") == nil'
		)
		assert(liveopsplan.buildPublish(42, "", "hi") == nil, 'liveopsplan.buildPublish(42, "", "hi") == nil')
		assert(
			liveopsplan.buildPublish(42, string.rep("x", 81), "hi") == nil,
			'liveopsplan.buildPublish(42, string.rep("x", 81), "hi") == nil'
		)
		assert(
			liveopsplan.buildPublish(42, string.rep("x", 80), "hi") ~= nil,
			'liveopsplan.buildPublish(42, string.rep("x", 80), "hi") ~= nil'
		)
	end,
	["buildPublish targets the PublishMessage endpoint"] = function()
		local publish = liveopsplan.buildPublish(42, "forge-liveops", "hello")
		assert(publish ~= nil, "a valid plan is returned")
		local plan = publish :: liveopsplan.Publish
		assert(
			plan.url == "https://apis.roblox.com/cloud/v2/universes/42/:publishMessage",
			"unexpected url: " .. plan.url
		)
	end,

	["buildPublish wraps topic and message in a JSON body"] = function()
		local publish = liveopsplan.buildPublish(7, "forge-liveops", '{"v":1}')
		assert(publish ~= nil, "a valid plan is returned")
		local decoded = decodeBody((publish :: liveopsplan.Publish).body)
		assert(decoded.topic == "forge-liveops", "topic is serialized")
		assert(decoded.message == '{"v":1}', "message is serialized")
	end,

	["buildPublish rejects a non-positive universe id"] = function()
		local plan, zeroReason = liveopsplan.buildPublish(0, "forge-liveops", "hi")
		assert(plan == nil, "universe id 0 is unset and must be refused")
		assert(zeroReason ~= nil, "a reason is returned for 0")
		local nilPlan = liveopsplan.buildPublish(-3, "forge-liveops", "hi")
		assert(nilPlan == nil, "a negative universe id is refused")
	end,

	["buildPublish rejects a message over 1024 bytes"] = function()
		local plan, reason = liveopsplan.buildPublish(1, "forge-liveops", string.rep("x", 1025))
		assert(plan == nil, "an oversized message must be refused")
		assert(reason == "message exceeds 1024 bytes", "expected the size reason, got " .. tostring(reason))
		local boundary = liveopsplan.buildPublish(1, "forge-liveops", string.rep("x", 1024))
		assert(boundary ~= nil, "exactly 1024 bytes is allowed")
	end,

	["publishUrl renders even when the universe id is unset"] = function()
		assert(
			liveopsplan.publishUrl(0) == "https://apis.roblox.com/cloud/v2/universes/0/:publishMessage",
			"dry-run url must render for universe id 0"
		)
	end,
}
