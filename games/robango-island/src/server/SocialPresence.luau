--!strict
-- Social presence (plan C5b, G22). Two server facts that make other players visible:
--   * population: every server writes "<listing key>|<jobId>" = { key, players } into one
--     MemoryStore sorted map with a short TTL, and sums the live rows per listing key. The sum is
--     published as workspace attribute ForgePopulation (JSON { [key] = players }), which the docks,
--     departure posts and route cards read. A crashed server's row expires after TTL seconds.
--   * clan tag: each player's clan id (ClanStore membership, the same directory the clan panels
--     use) is text-filtered for broadcast and set as player attribute ForgeClan; other clients
--     draw it under the name tag. No clan clears the attribute.
-- Display only: neither value is ever authority for routing, capacity or membership.
-- Engine ports are injected so Lune specs run the same code.
local M = {}

M.MAP = "robango-presence-v1"
M.PERIOD = 30
M.TTL = 90
M.PAGE = 200
M.PAGES = 5
M.ATTRIBUTE = "ForgePopulation"
M.CLAN_ATTRIBUTE = "ForgeClan"

--- Listing key of a server: its world role, or "archipelago.<route>" on an expedition island so
--- each route card can show its own count. Personal homes and the onboarding beach are private.
function M.listingKey(role: string, route: number?): string?
	if role == "home" or role == "onboarding" then
		return nil
	elseif role == "archipelago" then
		return if route then "archipelago." .. tostring(route) else nil
	end
	return role
end

--- Sums live rows ({ key, value = { key, players } }) per listing key.
function M.sum(rows: { any }): { [string]: number }
	local out: { [string]: number } = {}
	for _, row in rows do
		local value = row.value
		if
			type(value) == "table"
			and type(value.key) == "string"
			and type(value.players) == "number"
			and value.players >= 0
			and value.players % 1 == 0
		then
			out[value.key] = (out[value.key] or 0) + value.players
		end
	end
	return out
end

-- env: { map, enum, players, workspace, role, route?, jobId, encode, log, membership?, filter?, every? }
--   map: a MemoryStoreSortedMap (SetAsync/GetRangeAsync/RemoveAsync)
--   membership(actor) -> clanId?; filter(text, userId) -> broadcast-safe text (may error)
--   every(seconds, fn) -> stop; omitted means the caller drives tick() itself
function M.start(env: any): any
	local key = M.listingKey(env.role, env.route)
	local rowKey = if key then key .. "|" .. env.jobId else nil
	local filtered: { [string]: string } = {}
	-- api.counts: the last successful sum (nil until the first read).
	local api: any = {}
	local counts: { [string]: number }

	function api.publish(): boolean
		if not rowKey then
			return true
		end
		local ok, err = pcall(function()
			env.map:SetAsync(rowKey, { key = key, players = #env.players:GetPlayers() }, M.TTL)
		end)
		if not ok then
			env.log("PRESENCE_PUBLISH:" .. tostring(err))
		end
		return ok
	end

	function api.refresh(): { [string]: number }?
		local rows: { any } = {}
		local lower: any = nil
		for _ = 1, M.PAGES do
			local ok, page = pcall(function()
				return env.map:GetRangeAsync(env.enum.SortDirection.Ascending, M.PAGE, lower)
			end)
			if not ok then
				env.log("PRESENCE_READ:" .. tostring(page))
				return nil
			end
			for _, row in page do
				table.insert(rows, row)
			end
			if #page < M.PAGE then
				break
			end
			lower = { key = page[#page].key }
		end
		counts = M.sum(rows)
		api.counts = counts
		env.workspace:SetAttribute(M.ATTRIBUTE, env.encode(counts))
		return counts
	end

	function api.tagPlayer(player: any)
		if not env.membership then
			return
		end
		local clanId = env.membership(tostring(player.UserId))
		if type(clanId) ~= "string" or clanId == "" then
			player:SetAttribute(M.CLAN_ATTRIBUTE, nil)
			return
		end
		local text = filtered[clanId]
		if text == nil then
			if not env.filter then
				env.log("PRESENCE_CLAN_FILTER:unavailable")
				return
			end
			local ok, result = pcall(env.filter, clanId, player.UserId)
			if not ok or type(result) ~= "string" then
				-- Unfiltered user text is never broadcast; the tag stays off until a later tick.
				env.log("PRESENCE_CLAN_FILTER:" .. tostring(result))
				return
			end
			filtered[clanId] = result
			text = result
		end
		player:SetAttribute(M.CLAN_ATTRIBUTE, if text ~= "" then text else nil)
	end

	function api.tick()
		api.publish()
		api.refresh()
		for _, player in env.players:GetPlayers() do
			api.tagPlayer(player)
		end
	end

	function api.stop()
		if api.cancel then
			api.cancel()
		end
		if rowKey then
			pcall(function()
				env.map:RemoveAsync(rowKey)
			end)
		end
	end

	if env.every then
		api.cancel = env.every(M.PERIOD, api.tick)
	end
	return api
end

return M
