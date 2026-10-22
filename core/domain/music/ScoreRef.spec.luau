--!strict
local ScoreRef = require("./ScoreRef")

return {
	["a score reference round trips its id and revision"] = function()
		local text = ScoreRef.format("123:score:4", 2)
		assert(text == "123:score:4#2", text)
		local id, revision, reason = ScoreRef.parse("  " .. text .. " ")
		assert(id == "123:score:4" and revision == 2 and reason == nil, "parsed")
	end,
	["a link is refused as a lookup and never treated as an id"] = function()
		for _, link in
			{
				"https://example.com/123:score:4#2",
				"www.roblox.com/123:score:4#2",
				"roblox://123:score:4#2",
				"a/123:score:4#2",
			}
		do
			local id, revision, reason = ScoreRef.parse(link)
			assert(id == nil and revision == nil and reason == "score.ref_url", link .. " -> " .. tostring(reason))
		end
	end,
	["malformed references are refused"] = function()
		for _, text in { "", "123:score:4", "123:score:4#0", "123:score:x#1", "123#1", string.rep("a", 200) } do
			local id, _, reason = ScoreRef.parse(text)
			assert(id == nil and reason == "score.ref", text)
		end
		local id, _, reason = ScoreRef.parse(42)
		assert(id == nil and reason == "score.ref", "non-string")
	end,
	["a share recipient must be another player's numeric user id"] = function()
		assert(ScoreRef.recipient("1", " 42 ") == "42", "trimmed id")
		local id, reason = ScoreRef.recipient("1", "1")
		assert(id == nil and reason == "score.self", "self share refused")
		for _, bad in { "", "abc", "12a", string.rep("9", 21), 42 :: any } do
			local none, why = ScoreRef.recipient("1", bad)
			assert(none == nil and why == "score.recipient", tostring(bad))
		end
	end,
}
