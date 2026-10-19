--!strict
-- Robango Island Market ports (genres/survival-coop/module/MarketExtension). Pure: the server
-- script injects the Players facts, so this module never reads engine
-- globals or a wall clock and runs under Lune specs.
--
-- What is real:
--   * catalogIds: raw gathered materials and foods from content.yml (no tools, kits or anything a
--     Robux product grants; MarketPorts.spec.luau asserts every id exists in content.yml).
--   * account: Player.AccountAge (createdAt), play seconds of the CURRENT session only (no durable
--     cumulative play-time source exists; this under-reports, never over-reports) and the
--     Contracts tutorial completion.
-- The escrow, the bag reads and the Coins wallet are owned by the genre MarketExtension over the
-- live personal aggregate (see its header for the durability model and scope); the pack only
-- configures which goods trade and who may trade. Fee and caps are core Market defaults.
local Market = require("../../../../core/domain/market/Market")

local M = {}

M.CURRENCY = "Coins"
local DAY = 86400

-- Tradeable: gathered raw materials and raw foods only.
M.CATALOG_IDS = table.freeze({
	"wood",
	"fiber",
	"flint",
	"fieldstone",
	"birch-bark",
	"reed",
	"marsh-clay",
	"hide",
	"shell-fragment",
	"meat",
	"berry",
	"hazelnut",
	"chanterelle",
	"clam",
	"samphire",
	"cattail-root",
})

export type Deps = {
	-- Player.AccountAge in days; nil when the player is not in this server.
	accountAgeDays: (actor: string) -> number?,
	-- Seconds played in the current server session at `now`; nil when unknown.
	sessionSeconds: (actor: string, now: number) -> number?,
	tutorialComplete: (actor: string) -> boolean,
}

function M.account(deps: Deps, actor: string, now: number): Market.Account?
	local age = deps.accountAgeDays(actor)
	if type(age) ~= "number" or age < 0 then
		return nil
	end
	local played = deps.sessionSeconds(actor, now) or 0
	return {
		id = actor,
		createdAt = now - math.floor(age) * DAY,
		playSeconds = math.max(0, math.floor(played)),
		tutorialComplete = deps.tutorialComplete(actor) == true,
	}
end

--- MarketExtension.Config for this pack.
function M.config(deps: Deps): any
	return {
		catalogIds = table.clone(M.CATALOG_IDS),
		account = function(actor: string, now: number)
			return M.account(deps, actor, now)
		end,
		market = { currency = M.CURRENCY },
	}
end

return M
