--!strict
-- Specs for the sweep command's pure logic: option/genre parsing, the variant
-- matrix, and the report aggregation. No filesystem, no generation, no sleeps.

local sweep = require("./sweep")

--- A registry shape with exactly the fields variants() reads, so the matrix is
--- tested without discovering the real genres directory.
local function fakeRegistry(order: { string }): any
	local packages: { [string]: any } = {}
	for _, id in order do
		packages[id] = { id = id }
	end
	return { root = "genres", order = order, packages = packages }
end

local function report(label: string, steps: { [string]: any }): any
	local ok = true
	for _, name in sweep.STEP_NAMES do
		local step = steps[name]
		if step == nil or not step.ok then
			ok = false
		end
	end
	return {
		genre = label,
		label = label,
		slug = label .. "-sweep",
		mode = nil,
		packDir = "build/sweep/packs/" .. label .. "-sweep",
		steps = steps,
		ok = ok,
	}
end

local function passing(label: string): any
	local steps: { [string]: any } = {}
	for _, name in sweep.STEP_NAMES do
		steps[name] = { ok = true }
	end
	return report(label, steps)
end

local function failing(label: string, step: string, error: string): any
	local steps: { [string]: any } = {}
	for _, name in sweep.STEP_NAMES do
		steps[name] = { ok = name ~= step }
	end
	steps[step] = { ok = false, error = error }
	return report(label, steps)
end

return {
	-- parsing ---------------------------------------------------------------

	["parseGenreList splits and trims a comma list"] = function()
		local genres, err = sweep.parseGenreList("collect-raid, survival-coop ")
		assert(genres ~= nil, "a valid list parses: " .. tostring(err))
		assert(#(genres :: { string }) == 2, "both genres are kept")
		assert((genres :: { string })[2] == "survival-coop", "tokens are trimmed")
	end,

	["parseGenreList rejects a duplicate genre"] = function()
		local genres, err = sweep.parseGenreList("pvp-arena,pvp-arena")
		assert(genres == nil, "a duplicate must not silently shrink the matrix")
		assert(err ~= nil and string.find(err, "pvp-arena", 1, true) ~= nil, "the error names the duplicate")
	end,

	["parseGenreList rejects an empty list"] = function()
		local genres, err = sweep.parseGenreList(",,")
		assert(genres == nil and err ~= nil, "an empty list is a usage error")
	end,

	["parseArgs reads --genres and --out"] = function()
		local options, err = sweep.parseArgs({ "sweep", "--genres", "a,b", "--out", "build/x" })
		assert(options ~= nil, "valid flags parse: " .. tostring(err))
		assert(options.genres ~= nil and #(options.genres :: { string }) == 2, "both genres kept")
		assert(options.out == "build/x", "out dir kept")
	end,

	["parseArgs rejects an unknown flag and a missing value"] = function()
		assert(select(2, sweep.parseArgs({ "sweep", "--bogus" })) ~= nil, "unknown flag rejected")
		assert(select(2, sweep.parseArgs({ "sweep", "--out" })) ~= nil, "missing value rejected")
		assert(select(2, sweep.parseArgs({ "sweep", "--out", "a", "--out", "b" })) ~= nil, "duplicate flag rejected")
	end,

	-- variant matrix --------------------------------------------------------

	["variants adds the crafting variant only for survival-coop"] = function()
		local registry = fakeRegistry({ "collect-raid", "survival-coop" })
		local variants, errors = sweep.variants(registry, nil)
		assert(#errors == 0, "no selection errors")
		assert(#variants == 3, "two genres plus the crafting variant")
		local modes: { string } = {}
		for _, variant in variants do
			if variant.mode ~= nil then
				table.insert(modes, variant.id .. ":" .. variant.mode)
			end
		end
		assert(#modes == 1 and modes[1] == "survival-coop:crafting", "only survival-coop gains crafting")
	end,

	["variants narrows to the selected genres and reports unknown ones"] = function()
		local registry = fakeRegistry({ "collect-raid", "survival-coop" })
		local variants, errors = sweep.variants(registry, { ["collect-raid"] = true })
		assert(#variants == 1 and variants[1].id == "collect-raid", "only the selected genre runs")
		assert(#errors == 0, "a known selection has no errors")
		local _, unknown = sweep.variants(registry, { ["nope"] = true })
		assert(#unknown == 1 and string.find(unknown[1], "nope", 1, true) ~= nil, "an unknown genre is reported")
	end,

	-- aggregation -----------------------------------------------------------

	["summarize counts passing and failing genres"] = function()
		local summary = sweep.summarize({ passing("a"), failing("b", "build", "rojo build failed"), passing("c") })
		assert(summary.total == 3, "all reports counted")
		assert(summary.passed == 2 and summary.failed == 1, "one genre failed")
		assert(summary.stepFailures.build == 1, "the build step is blamed once")
		assert(#summary.failures == 1 and summary.failures[1].error == "rojo build failed", "first error kept")
	end,

	["summarize treats a missing step as a failure"] = function()
		local steps: { [string]: any } = {}
		for _, name in sweep.STEP_NAMES do
			steps[name] = { ok = true }
		end
		steps.surface = nil
		local summary = sweep.summarize({ report("a", steps) })
		assert(summary.failed == 1, "an unrecorded step cannot read as a pass")
		assert(summary.stepFailures.surface == 1, "the missing step is blamed")
		assert(summary.failures[1].error == "step not recorded", "the gap is named")
	end,

	["summarize sorts failures by genre then step"] = function()
		local summary = sweep.summarize({
			failing("b", "inspect", "z"),
			failing("a", "surface", "y"),
			failing("a", "build", "x"),
		})
		assert(#summary.failures == 3, "every failure kept")
		assert(summary.failures[1].genre == "a" and summary.failures[1].step == "build", "sorted by genre then step")
		assert(summary.failures[3].genre == "b", "later genre last")
	end,

	["renderMarkdown names every genre and its verdict"] = function()
		local reports = { passing("a"), failing("b", "nativeQa", "no executable scenarios") }
		local markdown = sweep.renderMarkdown(sweep.summarize(reports), reports, "20261009T000000Z")
		assert(string.find(markdown, "| genre |", 1, true) ~= nil, "table header present")
		assert(string.find(markdown, "| a |", 1, true) ~= nil, "passing genre row present")
		assert(string.find(markdown, "| b |", 1, true) ~= nil, "failing genre row present")
		assert(
			string.find(markdown, "b / nativeQa: no executable scenarios", 1, true) ~= nil,
			"the first failure is listed with its genre and step"
		)
	end,

	["the matrix carries the load and quality columns and requires a profile"] = function()
		assert(table.find(sweep.STEP_NAMES, "load") ~= nil, "the load column exists")
		assert(table.find(sweep.STEP_NAMES, "quality") ~= nil, "the quality column exists")
		assert(table.find(sweep.REQUIRED_FILES, "quality.yml") ~= nil, "a generated pack must carry a quality profile")
		local markdown = sweep.renderMarkdown(sweep.summarize({ passing("a") }), { passing("a") }, "20261009T000000Z")
		assert(
			string.find(markdown, "human-judgment-pending", 1, true) ~= nil,
			"the report says human judgment stays pending"
		)
	end,
}
