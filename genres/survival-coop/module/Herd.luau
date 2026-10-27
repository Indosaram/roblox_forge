--!strict
-- Herd: leader + members alarm propagation. Pure and clock-free: the caller
-- passes positions and receives which members join the fight, then feeds each
-- one `Observation.provokedBy` on its next Wildlife.step.
--
-- An alarm starts at the struck creature and spreads to members within the
-- alarm radius of an already-alarmed creature. Two caps bound it: `maxJoin`
-- (total members recruited per alarm) and `maxChain` (hops from the struck
-- creature), so one hit can never cascade through an entire island.
local Wildlife = require("./Wildlife")
local M = {}
export type Config = { alarmStuds: number, maxJoin: number, maxChain: number }
export type Herd = { id: string, leader: string, members: { string }, config: Config }
export type Join = { id: string, hop: number }

local function integer(n: any, low: number, high: number): boolean
	return type(n) == "number" and n == n and n % 1 == 0 and n >= low and n <= high
end

--- Builds a herd. `members` excludes the leader; ids must be unique.
function M.new(id: string, leader: string, members: { string }, config: Config): Herd
	assert(#id > 0 and #id <= 64 and #leader > 0, "INVALID_HERD")
	assert(integer(config.alarmStuds, 1, 512), "INVALID_ALARM_RADIUS")
	assert(integer(config.maxJoin, 0, 31), "INVALID_JOIN_CAP")
	assert(integer(config.maxChain, 1, 8), "INVALID_CHAIN_CAP")
	local seen: { [string]: boolean } = { [leader] = true }
	local list: { string } = {}
	for _, member in members do
		assert(type(member) == "string" and #member > 0 and not seen[member], "DUPLICATE_HERD_MEMBER")
		seen[member] = true
		table.insert(list, member)
	end
	table.sort(list)
	return table.freeze({
		id = id,
		leader = leader,
		members = table.freeze(list),
		config = table.freeze(table.clone(config)),
	})
end

export type Point = { x: number, y: number, z: number }
export type Member = { id: string, position: Point }

--- Spawn -> `count` members (leader `<spawn>.1` on the point) ringed inside `radius`; `unit` is
--- a seeded [0, 1) stream.
function M.place(spawnId: string, at: Point, count: number, radius: number, unit: () -> number): { Member }
	assert(#spawnId > 0 and integer(count, 1, 31), "INVALID_HERD_SPAWN")
	local ring = math.max(radius, 0)
	local members: { Member } = {}
	local turn = unit() * 2 * math.pi
	for index = 1, count do
		local position = { x = at.x, y = at.y, z = at.z }
		if index > 1 then
			local angle = turn + (index - 2) / (count - 1) * 2 * math.pi + (unit() - 0.5) * 0.6
			local distance = ring * (0.55 + unit() * 0.45)
			position.x += math.cos(angle) * distance
			position.z += math.sin(angle) * distance
		end
		table.insert(members, { id = spawnId .. "." .. tostring(index), position = position })
	end
	return members
end

--- A follower's goal: its home offset from the leader, applied at the leader's position.
function M.follow(leaderHome: Point, leaderNow: Point, memberHome: Point): Point
	return {
		x = leaderNow.x + (memberHome.x - leaderHome.x),
		y = leaderNow.y,
		z = leaderNow.z + (memberHome.z - leaderHome.z),
	}
end

function M.contains(herd: Herd, id: string): boolean
	return herd.leader == id or table.find(herd.members, id) ~= nil
end

--- Returns the creatures (leader included) recruited by an alarm at `struck`,
--- nearest first per hop with id as tiebreak. `positions` holds every living
--- herd creature; dead or absent ones are skipped and never relay. `engaged`
--- names creatures already fighting: they are not recruited again and do not
--- consume the join cap.
function M.alarm(
	herd: Herd,
	struck: string,
	positions: { [string]: Wildlife.Position },
	engaged: { [string]: boolean }?
): { Join }
	local joins: { Join } = {}
	if not M.contains(herd, struck) or positions[struck] == nil then
		return joins
	end
	local busy = engaged or {}
	local reached: { [string]: boolean } = { [struck] = true }
	local frontier: { string } = { struck }
	local everyone: { string } = table.clone(herd.members)
	table.insert(everyone, herd.leader)
	table.sort(everyone)
	for hop = 1, herd.config.maxChain do
		local found: { { id: string, d: number } } = {}
		for _, id in everyone do
			local here = positions[id]
			if reached[id] or here == nil then
				continue
			end
			local best = math.huge
			for _, source in frontier do
				best = math.min(best, Wildlife.distance(here, positions[source]))
			end
			if best <= herd.config.alarmStuds then
				table.insert(found, { id = id, d = best })
			end
		end
		if #found == 0 then
			break
		end
		table.sort(found, function(a, b)
			return if a.d == b.d then a.id < b.id else a.d < b.d
		end)
		local nextFrontier: { string } = {}
		for _, entry in found do
			reached[entry.id] = true
			if busy[entry.id] then
				table.insert(nextFrontier, entry.id)
			elseif #joins < herd.config.maxJoin then
				table.insert(joins, { id = entry.id, hop = hop })
				table.insert(nextFrontier, entry.id)
			end
		end
		if #joins >= herd.config.maxJoin or #nextFrontier == 0 then
			break
		end
		frontier = nextFrontier
	end
	return joins
end

return M
