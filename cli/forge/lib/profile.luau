--!strict

-- Text profiling helper: named spans accumulate count / total / max durations.
-- The clock is injectable (seconds) so specs are deterministic; it defaults to os.clock.

export type Options = {
	clock: (() -> number)?,
}

export type Row = {
	name: string,
	count: number,
	totalMs: number,
	maxMs: number,
}

export type Json = {
	schemaVersion: number,
	spans: { Row },
}

type Stat = { count: number, totalMs: number, maxMs: number }

local Profile = {}
Profile.__index = Profile

export type Profile = typeof(setmetatable(
	{} :: {
		_clock: () -> number,
		_stats: { [string]: Stat },
		_open: { [string]: { number } },
	},
	Profile
))

function Profile.new(options: Options?): Profile
	local clock = if options and options.clock then options.clock else os.clock
	return setmetatable({
		_clock = clock,
		_stats = {},
		_open = {},
	}, Profile)
end

function Profile._record(self: Profile, name: string, startedAt: number)
	local ms = (self._clock() - startedAt) * 1000
	local stat = self._stats[name]
	if not stat then
		stat = { count = 0, totalMs = 0, maxMs = 0 }
		self._stats[name] = stat
	end
	stat.count += 1
	stat.totalMs += ms
	if ms > stat.maxMs then
		stat.maxMs = ms
	end
end

-- Runs fn, records its duration under name (also when fn errors) and returns fn's results.
function Profile.span<T...>(self: Profile, name: string, fn: () -> T...): T...
	local startedAt = self._clock()
	local packed = table.pack(pcall(fn))
	self:_record(name, startedAt)
	if not packed[1] then
		error(packed[2], 0)
	end
	return table.unpack(packed :: any, 2, packed.n)
end

function Profile.start(self: Profile, name: string)
	local stack = self._open[name]
	if not stack then
		stack = {}
		self._open[name] = stack
	end
	table.insert(stack, self._clock())
end

function Profile.stop(self: Profile, name: string)
	local stack = self._open[name]
	if not stack or #stack == 0 then
		error(string.format("profile: stop(%q) without a matching start", name), 2)
	end
	local startedAt = table.remove(stack) :: number
	self:_record(name, startedAt)
end

-- Rows sorted by totalMs descending; ties break by name for a stable order.
function Profile.report(self: Profile): { Row }
	local rows: { Row } = {}
	for name, stat in self._stats do
		table.insert(rows, { name = name, count = stat.count, totalMs = stat.totalMs, maxMs = stat.maxMs })
	end
	table.sort(rows, function(a, b)
		if a.totalMs ~= b.totalMs then
			return a.totalMs > b.totalMs
		end
		return a.name < b.name
	end)
	return rows
end

function Profile.text(self: Profile, limit: number?): string
	local rows = self:report()
	local shown = rows
	if limit and limit < #rows then
		shown = table.move(rows, 1, math.max(limit, 0), 1, {})
	end
	local nameWidth = #"name"
	for _, row in shown do
		nameWidth = math.max(nameWidth, #row.name)
	end
	local function line(name: string, count: string, total: string, max: string): string
		return string.format("%-" .. nameWidth .. "s  %7s  %12s  %12s", name, count, total, max)
	end
	local lines = { line("name", "count", "totalMs", "maxMs") }
	for _, row in shown do
		table.insert(
			lines,
			line(row.name, tostring(row.count), string.format("%.3f", row.totalMs), string.format("%.3f", row.maxMs))
		)
	end
	return table.concat(lines, "\n")
end

function Profile.json(self: Profile): Json
	return { schemaVersion = 1, spans = self:report() }
end

return Profile
