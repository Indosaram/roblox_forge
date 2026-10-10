--!strict

export type EventSpec = {
	id: string,
	startsAt: number,
	endsAt: number,
	multipliers: { [string]: number }?,
}

export type Event = {
	id: string,
	startsAt: number,
	endsAt: number,
	multipliers: { [string]: number },
}

local Schedule = {}
Schedule.__index = Schedule

export type Schedule = typeof(setmetatable({} :: { events: { Event } }, Schedule))

local function normalize(events: { EventSpec }): { Event }
	local seen: { [string]: boolean } = {}
	local normalized: { Event } = {}
	for _, event in events do
		if event.endsAt <= event.startsAt then
			error(`Schedule event "{event.id}": endsAt must be greater than startsAt`)
		end
		if seen[event.id] then
			error(`Schedule event "{event.id}": duplicate id`)
		end
		seen[event.id] = true
		table.insert(normalized, {
			id = event.id,
			startsAt = event.startsAt,
			endsAt = event.endsAt,
			multipliers = event.multipliers or {},
		})
	end
	return normalized
end

function Schedule.new(events: { EventSpec }): Schedule
	return setmetatable({ events = normalize(events) }, Schedule)
end

function Schedule.active(self: Schedule, now: number): { Event }
	local active: { Event } = {}
	for _, event in self.events do
		if now >= event.startsAt and now < event.endsAt then
			table.insert(active, event)
		end
	end
	table.sort(active, function(a, b)
		return a.startsAt < b.startsAt
	end)
	return active
end

function Schedule.multiplier(self: Schedule, key: string, now: number): number
	local product = 1
	for _, event in self:active(now) do
		local value = event.multipliers[key]
		if value ~= nil then
			product *= value
		end
	end
	return product
end

function Schedule.next(self: Schedule, now: number): Event?
	local soonest: Event? = nil
	for _, event in self.events do
		if event.startsAt > now then
			if soonest == nil or event.startsAt < soonest.startsAt then
				soonest = event
			end
		end
	end
	return soonest
end

return Schedule
