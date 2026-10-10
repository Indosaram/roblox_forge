--!strict
-- Matchmaking: a waiting queue that greedily pairs the oldest compatible entries.

local Matchmaking = {}
Matchmaking.__index = Matchmaking

export type Id = string | number

export type Entry = {
	id: Id,
	rating: number,
	now: number,
}

export type Queue = typeof(setmetatable({} :: { entries: { Entry } }, Matchmaking))

export type Pair = { Id }

function Matchmaking.new(): Queue
	return setmetatable({ entries = {} :: { Entry } }, Matchmaking)
end

-- Appends a new player in insertion order. Re-enqueue refreshes only the rating,
-- preserving the original waiting timestamp and queue position.
function Matchmaking.enqueue(self: Queue, id: Id, rating: number, now: number): ()
	if type(id) ~= "string" and type(id) ~= "number" then
		error("invalid id")
	end
	if type(rating) ~= "number" or rating ~= rating then
		error("invalid rating")
	end
	if type(now) ~= "number" or now ~= now then
		error("invalid now")
	end
	for _, entry in self.entries do
		if entry.id == id then
			entry.rating = rating
			return
		end
	end
	table.insert(self.entries, { id = id, rating = rating, now = now })
end

-- Greedily matches the oldest waiting entry with the oldest still-waiting entry
-- whose rating is within `maxDelta`. Matched entries are removed from the queue.
-- Returns an ordered list of {idA, idB} pairs.
function Matchmaking.pair(self: Queue, maxDelta: number): { Pair }
	local pairs: { Pair } = {}
	local i = 1
	while i <= #self.entries do
		local a = self.entries[i]
		local matchIndex: number? = nil
		local j = i + 1
		while j <= #self.entries do
			local b = self.entries[j]
			if a.id ~= b.id and math.abs(a.rating - b.rating) <= maxDelta then
				matchIndex = j
				break
			end
			j += 1
		end
		if matchIndex == nil then
			i += 1
		else
			local b = table.remove(self.entries, matchIndex)
			assert(b ~= nil, "matchIndex must reference an existing entry")
			table.remove(self.entries, i)
			table.insert(pairs, { a.id, b.id })
		end
	end
	return pairs
end

-- Cancel a waiting entry without affecting already paired players.
function Matchmaking.remove(self: Queue, id: Id): boolean
	for index, entry in self.entries do
		if entry.id == id then
			table.remove(self.entries, index)
			return true
		end
	end
	return false
end

return Matchmaking
