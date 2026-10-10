--!strict
-- Trends: pure logic behind `forge trends`. Parses Roblox Explore sort content
-- (or a saved fixture) into normalized experience rows, aggregates them per
-- genre, flags genres that have no module under genres/, and renders markdown.
-- No file system or network access happens here; the command owns that.

local Trends = {}

export type Experience = {
	name: string,
	genre: string,
	playing: number,
	visits: number,
	gamepassPrices: { number },
}

export type GenreRow = {
	genre: string,
	count: number,
	totalCcu: number,
	medianPassPrice: number,
}

type Bucket = {
	count: number,
	totalCcu: number,
	prices: { number },
}

local function firstString(...: any): string?
	for _, value in { ... } do
		if typeof(value) == "string" and value ~= "" then
			return value
		end
	end
	return nil
end

local function firstNumber(...: any): number?
	for _, value in { ... } do
		if typeof(value) == "number" then
			return value
		end
	end
	return nil
end

local function normalizePrices(node: any): { number }
	local prices: { number } = {}
	local raw = node.gamepassPrices
	if typeof(raw) ~= "table" then
		raw = node.gamepasses
	end
	if typeof(raw) ~= "table" then
		raw = node.gamePasses
	end
	if typeof(raw) == "table" then
		for _, entry in raw do
			local price = firstNumber(entry)
			if price == nil and typeof(entry) == "table" then
				price = firstNumber(entry.price)
			end
			if price ~= nil then
				table.insert(prices, price)
			end
		end
	end
	return prices
end

local function normalizeNode(node: any): Experience?
	if typeof(node) ~= "table" then
		return nil
	end
	return {
		name = firstString(node.name) or "",
		genre = firstString(node.genre, node.genreL1, node.genre_l1) or "unknown",
		playing = firstNumber(node.playing, node.playerCount, node.ccu) or 0,
		visits = firstNumber(node.visits, node.visitCount, node.totalVisits) or 0,
		gamepassPrices = normalizePrices(node),
	}
end

local function extractGames(json: any): { any }
	if typeof(json) ~= "table" then
		return {}
	end
	if typeof(json.games) == "table" then
		return json.games
	end
	if typeof(json.sorts) == "table" then
		local flattened: { any } = {}
		for _, sort in json.sorts do
			if typeof(sort) == "table" and typeof(sort.games) == "table" then
				for _, game in sort.games do
					table.insert(flattened, game)
				end
			end
		end
		if #flattened > 0 then
			return flattened
		end
	end
	if #json > 0 then
		return json
	end
	return {}
end

--- Normalizes decoded Explore JSON (object with `games`, object with `sorts`,
--- or a bare array) into experience rows, skipping entries that are not tables.
function Trends.parse(json: any): { Experience }
	local list: { Experience } = {}
	for _, node in extractGames(json) do
		local experience = normalizeNode(node)
		if experience ~= nil then
			table.insert(list, experience)
		end
	end
	return list
end

--- Median of a number list; 0 for an empty list, the mean of the two middle
--- values for an even count (so a genre with no pass prices reports 0).
function Trends.median(values: { number }): number
	if #values == 0 then
		return 0
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	local count = #sorted
	local mid = math.floor(count / 2)
	if count % 2 == 1 then
		return sorted[mid + 1]
	end
	return (sorted[mid] + sorted[mid + 1]) / 2
end

--- One row per genre, sorted by total concurrent players (descending) then by
--- genre name, with the median of every gamepass price in the genre.
function Trends.summarize(list: { Experience }): { GenreRow }
	local byGenre: { [string]: Bucket } = {}
	for _, experience in list do
		local bucket = byGenre[experience.genre]
		if bucket == nil then
			bucket = { count = 0, totalCcu = 0, prices = {} }
			byGenre[experience.genre] = bucket
		end
		bucket.count += 1
		bucket.totalCcu += experience.playing
		for _, price in experience.gamepassPrices do
			table.insert(bucket.prices, price)
		end
	end

	local rows: { GenreRow } = {}
	for genre, bucket in byGenre do
		table.insert(rows, {
			genre = genre,
			count = bucket.count,
			totalCcu = bucket.totalCcu,
			medianPassPrice = Trends.median(bucket.prices),
		})
	end
	table.sort(rows, function(a, b)
		if a.totalCcu ~= b.totalCcu then
			return a.totalCcu > b.totalCcu
		end
		return a.genre < b.genre
	end)
	return rows
end

--- Genres present in the rows but with no directory under genres/. These are
--- candidate new Genre Modules (plan section 11.4). Sorted and de-duplicated.
function Trends.unknownGenres(rows: { GenreRow }, knownGenres: { string }): { string }
	local known: { [string]: boolean } = {}
	for _, genre in knownGenres do
		known[genre] = true
	end
	local unknown: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, row in rows do
		if not known[row.genre] and not seen[row.genre] then
			seen[row.genre] = true
			table.insert(unknown, row.genre)
		end
	end
	table.sort(unknown)
	return unknown
end

--- Markdown report: genre summary table plus a new-module-candidates section.
function Trends.render(rows: { GenreRow }, unknown: { string }): string
	local lines: { string } = {
		"# Roblox Trends",
		"",
		"## Genre Summary",
		"",
		"| Genre | Experiences | Total CCU | Median Pass Price (R$) |",
		"| --- | ---: | ---: | ---: |",
	}
	for _, row in rows do
		table.insert(
			lines,
			string.format("| %s | %d | %d | %.0f |", row.genre, row.count, row.totalCcu, row.medianPassPrice)
		)
	end
	table.insert(lines, "")
	table.insert(lines, "## New Module Candidates")
	table.insert(lines, "")
	if #unknown == 0 then
		table.insert(lines, "- (none)")
	else
		for _, genre in unknown do
			table.insert(lines, "- `" .. genre .. "` (no genre module under genres/)")
		end
	end
	table.insert(lines, "")
	return table.concat(lines, "\n")
end

return Trends
