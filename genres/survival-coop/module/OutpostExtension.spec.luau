--!strict
local Fixture = require("../../../cli/forge/fixtures/clan-governance/scenario")
local Memory = require("../../../core/infra/data/MemoryBackend")
return {
	["outpost Session settles once then survives reconnect"] = function()
		local fixture = Fixture.new({
			backend = Memory.new(),
			now = function(): number
				return 10
			end,
		})
		fixture.joinAll()
		assert(fixture.command("owner", "outpost", "start", { matchId = "siege" }).ok, "clan invariant: 8")
		fixture.advance(180, { "owner" })
		assert(fixture.command("owner", "outpost", "advance", { matchId = "siege" }, "win").ok, "clan invariant: 10")
		local first = fixture.snapshot().outpost
		assert(first.owner == "alpha" and first.expiresAt == 190 + 86400, "clan invariant: 12")
		fixture.advance(30, {})
		assert(fixture.command("owner", "outpost", "advance", { matchId = "siege" }, "win").ok, "clan invariant: 14")
		assert(fixture.snapshot().outpost.expiresAt == first.expiresAt, "clan invariant: 15")
		assert(fixture.reconnect() == nil, "clan invariant: 16")
		assert(
			fixture.command("owner", "outpost", "advance", { matchId = "siege" }).reason == "MATCH_SETTLED",
			"clan invariant: 17"
		)
		assert(fixture.snapshot().outpost.expiresAt == first.expiresAt, "clan invariant: 18")
		assert(fixture.close().ok, "clan invariant: 19")
	end,
}
