--!strict
-- Specs for new.luau's genre-list parsing. parseGenres is exported so this
-- can drive the real predicate M.run uses without scaffolding a pack
-- directory under games/.

local newCommand = require("./new")

return {
	-- finding 6 ------------------------------------------------------------
	["old parseGenres logic let a repeated genre through"] = function()
		-- new.luau's old parseGenres just appended every non-empty comma token,
		-- with no de-duplication check.
		local genres: { string } = {}
		for token in string.gmatch("grow-harvest,grow-harvest", "[^,]+") do
			table.insert(genres, token)
		end
		assert(#genres == 2, "the old parser keeps both occurrences")
		assert(genres[1] == genres[2], "which is a duplicate the caller never rejects")
	end,

	["parseGenres rejects a repeated genre"] = function()
		local genres, err = newCommand.parseGenres("grow-harvest,grow-harvest")
		assert(genres == nil, "a duplicate genre list must be rejected")
		assert(err ~= nil and string.find(err, "grow-harvest", 1, true) ~= nil, "the error names the duplicate")
	end,

	["parseGenres accepts a normal distinct genre list"] = function()
		local genres, err = newCommand.parseGenres("collect-raid,survival-coop")
		assert(genres ~= nil, "a distinct genre list is valid: " .. tostring(err))
		assert(#(genres :: { string }) == 2, "both genres are kept")
	end,

	["parseGenres trims whitespace before checking for duplicates"] = function()
		local genres, err = newCommand.parseGenres("collect-raid, collect-raid ")
		assert(genres == nil, "whitespace around a duplicate must not hide it")
		assert(err ~= nil, "an error is reported: " .. tostring(err))
	end,

	["parseGenres returns nil with no error for an empty list"] = function()
		local genres, err = newCommand.parseGenres(nil)
		assert(genres == nil, "no genres given returns nil")
		assert(err == nil, "an empty list is not itself an error")
	end,
}
