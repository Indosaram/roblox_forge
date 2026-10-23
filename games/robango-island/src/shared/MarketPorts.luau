--!strict
-- Robango Island Market ports (genres/survival-coop/module/MarketExtension). Pure: the server
-- script injects the Players facts, so this module never reads engine
-- globals or a wall clock and runs under Lune specs.
--
-- What is real:
--   * catalogIds: every content.yml item (raw, processed, food, gear, kits) except the ones tagged
--     quest-bound (mission ledger tokens), bound (practice receipts) or retired (reed/samphire
--     aliases); derived from the generated content, never a hand list. Robux grants are cosmetic
--     sets, not items, and the escrow still refuses robuxPurchased/equipped stacks.
--   * account: Player.AccountAge (createdAt), play seconds of the CURRENT session only (no durable
--     cumulative play-time source exists; this under-reports, never over-reports) and the
--     Contracts tutorial completion.
-- The escrow, the bag reads and the Coins wallet are owned by the genre MarketExtension over the
-- live personal aggregate (see its header for the durability model and scope); the pack only
-- configures which goods trade and who may trade. Fee and caps are core Market defaults.
local Market = require("../../../../core/domain/market/Market")
local content: any = require("./SurvivalContent")

local M = {}

M.CURRENCY = "Coins"
local DAY = 86400

-- Item tags that keep an item out of the market (content.yml `tags`).
M.UNTRADEABLE_TAGS = table.freeze({ ["quest-bound"] = true, bound = true, retired = true })

local tradeable: { string } = {}
for _, item in content.items do
	local blocked = false
	for _, tag in item.tags or {} do
		blocked = blocked or M.UNTRADEABLE_TAGS[tag] == true
	end
	if not blocked then
		table.insert(tradeable, item.id)
	end
end
M.CATALOG_IDS = table.freeze(tradeable)

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
