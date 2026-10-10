--!strict
-- Specs for trends: parse normalization, per-genre medians, unknown-genre
-- detection, and report headings. No network access.

local trends = require("./trends")

local function experience(
	name: string,
	genre: string,
	playing: number,
	visits: number,
	prices: { number }
): trends.Experience
	return { name = name, genre = genre, playing = playing, visits = visits, gamepassPrices = prices }
end

local function rowFor(rows: { trends.GenreRow }, genre: string): trends.GenreRow
	for _, row in rows do
		if row.genre == genre then
			return row
		end
	end
	error("missing genre row: " .. genre)
end

local function contains(haystack: string, needle: string): boolean
	return string.find(haystack, needle, 1, true) ~= nil
end

return {
	["summarize groups by genre, sums ccu, and takes the median pass price"] = function()
		local rows = trends.summarize({
			experience("a", "collect-raid", 1000, 10, { 100, 200, 300 }),
			experience("b", "collect-raid", 500, 20, { 500 }),
			experience("c", "grow-harvest", 200, 30, { 100, 300 }),
			experience("d", "grow-harvest", 50, 40, {}),
		})

		local collectRaid = rowFor(rows, "collect-raid")
		assert(collectRaid.count == 2, "collect-raid should have 2 experiences")
		assert(collectRaid.totalCcu == 1500, "collect-raid ccu should be 1500, got " .. collectRaid.totalCcu)
		assert(collectRaid.medianPassPrice == 250, "even median of 100/200/300/500 is 250")

		local growHarvest = rowFor(rows, "grow-harvest")
		assert(growHarvest.count == 2, "grow-harvest should have 2 experiences")
		assert(growHarvest.medianPassPrice == 200, "median of 100/300 is 200")
	end,

	["summarize sorts rows by total ccu descending"] = function()
		local rows = trends.summarize({
			experience("a", "pvp-arena", 100, 0, {}),
			experience("b", "collect-raid", 900, 0, {}),
			experience("c", "grow-harvest", 500, 0, {}),
		})
		assert(rows[1].genre == "collect-raid", "highest ccu genre sorts first")
		assert(rows[2].genre == "grow-harvest", "second highest sorts second")
		assert(rows[3].genre == "pvp-arena", "lowest sorts last")
	end,

	["median handles an odd count and an empty set"] = function()
		assert(trends.median({ 300, 100, 200 }) == 200, "odd median is the middle value")
		assert(trends.median({}) == 0, "empty median is 0")
	end,

	["summarize reports median 0 for a genre with no gamepass prices"] = function()
		local rows = trends.summarize({ experience("a", "grow-harvest", 10, 0, {}) })
		assert(rowFor(rows, "grow-harvest").medianPassPrice == 0, "no prices means median 0")
	end,

	["unknownGenres flags genres with no matching module"] = function()
		local rows = trends.summarize({
			experience("a", "collect-raid", 10, 0, {}),
			experience("b", "tower-defense", 20, 0, {}),
			experience("c", "tower-defense", 5, 0, {}),
		})
		local unknown = trends.unknownGenres(rows, { "collect-raid", "grow-harvest", "pvp-arena" })
		assert(#unknown == 1, "only tower-defense is unknown, got " .. #unknown)
		assert(unknown[1] == "tower-defense", "unknown genre is tower-defense")
	end,

	["unknownGenres is empty when every genre has a module"] = function()
		local rows = trends.summarize({ experience("a", "collect-raid", 10, 0, {}) })
		local unknown = trends.unknownGenres(rows, { "collect-raid" })
		assert(#unknown == 0, "a known genre is not flagged")
	end,

	["render emits the genre and module-candidate headings"] = function()
		local rows = trends.summarize({
			experience("a", "collect-raid", 1000, 0, { 100, 300 }),
			experience("b", "tower-defense", 500, 0, { 200 }),
		})
		local markdown = trends.render(rows, trends.unknownGenres(rows, { "collect-raid" }))
		assert(contains(markdown, "# Roblox Trends"), "report has a title")
		assert(contains(markdown, "## Genre Summary"), "report has a genre summary heading")
		assert(contains(markdown, "## New Module Candidates"), "report has a module-candidate heading")
		assert(contains(markdown, "collect-raid"), "report lists the genre")
		assert(contains(markdown, "tower-defense"), "report lists the unknown genre")
	end,

	["render keeps the candidate heading when nothing is unknown"] = function()
		local rows = trends.summarize({ experience("a", "collect-raid", 1, 0, {}) })
		local markdown = trends.render(rows, trends.unknownGenres(rows, { "collect-raid" }))
		assert(contains(markdown, "## New Module Candidates"), "heading is always present")
		assert(contains(markdown, "(none)"), "empty candidate list is explicit")
	end,

	["parse normalizes fields and skips non-table entries"] = function()
		local input: { any } = {
			{ name = "x", genre = "collect-raid", playing = 10, visits = 20, gamepassPrices = { 5, 10 } },
			{ name = "y", genre = "pvp-arena", playerCount = 30, totalVisits = 40, gamepasses = { { price = 7 } } },
			"not-an-experience",
		}
		local list = trends.parse(input)
		assert(#list == 2, "non-table entries are skipped, got " .. #list)
		assert(list[1].name == "x", "name is kept")
		assert(list[1].playing == 10 and list[1].visits == 20, "canonical fields are kept")
		assert(#list[1].gamepassPrices == 2 and list[1].gamepassPrices[2] == 10, "numeric prices are kept")
		assert(list[2].playing == 30, "playerCount aliases to playing")
		assert(list[2].visits == 40, "totalVisits aliases to visits")
		assert(#list[2].gamepassPrices == 1 and list[2].gamepassPrices[1] == 7, "gamepass objects expose price")
	end,

	["parse reads a games wrapper or a bare array"] = function()
		local wrapped = trends.parse({
			games = { { name = "wrapped", genre = "collect-raid", playing = 1 } },
		})
		assert(#wrapped == 1 and wrapped[1].name == "wrapped", "reads the games wrapper")

		local bare = trends.parse({ { name = "bare", genre = "grow-harvest", playing = 2 } })
		assert(#bare == 1 and bare[1].name == "bare", "reads a bare array")
	end,
}
