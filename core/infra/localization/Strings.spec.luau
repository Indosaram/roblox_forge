--!strict
-- Specs for Strings: CSV parsing (quotes/CRLF/newlines), locale fallback,
-- formatting, locale discovery and missing-key reporting.

local Strings = require("./Strings")

local CSV = table.concat({
	"Key,Source,Context,en-us,ko-kr",
	'GREETING,Hello greeting,menu,"Hello, friend","안녕, 친구"',
	'PLURAL,You have items,menu,"You have ""many"" items",당신은 항목이 있습니다',
	"SCORE,Score,menu,Score: %d,점수: %d",
	"ONLY_EN,English only,menu,Only English,",
}, "\n")

return {
	["parseCsv handles quoted commas"] = function()
		local parsed = Strings.parseCsv(CSV)
		assert(parsed.header[1] == "Key", "first header column is Key")
		assert(parsed.header[5] == "ko-kr", "last header column is ko-kr")
		assert(parsed.rows[1][4] == "Hello, friend", "quoted comma stays in the field")
		assert(parsed.rows[1][5] == "안녕, 친구", "quoted comma in the ko column")
	end,

	["parseCsv handles escaped quotes"] = function()
		local parsed = Strings.parseCsv(CSV)
		assert(parsed.rows[2][4] == 'You have "many" items', "doubled quotes collapse to one")
	end,

	["parseCsv handles CRLF and trailing newline"] = function()
		local parsed = Strings.parseCsv("A,B,Context,en-us\r\nK,V,ctx,V\r\n")
		assert(#parsed.header == 4, "header splits on CRLF")
		assert(parsed.header[4] == "en-us", "header keeps its last column")
		assert(#parsed.rows == 1, "trailing newline adds no blank row")
		assert(parsed.rows[1][1] == "K", "row key survives CRLF")
		assert(parsed.rows[1][4] == "V", "row value survives CRLF")
	end,

	["parseCsv handles a quoted field containing newlines"] = function()
		local text = 'Key,Source,Context,en-us,ko-kr\nK,S,ctx,"line1\nline2",ko\n'
		local parsed = Strings.parseCsv(text)
		assert(#parsed.rows == 1, "embedded newline stays inside one record")
		assert(parsed.rows[1][4] == "line1\nline2", "embedded newline kept in the field")
		local t = Strings.fromCsv(text)
		assert(t:get("K", "en-us") == "line1\nline2", "get returns the multiline value")
	end,

	["get falls back locale then en-us then Source then key"] = function()
		local t = Strings.fromCsv(CSV)
		assert(t:get("GREETING", "ko-kr") == "안녕, 친구", "exact locale hit wins")
		assert(t:get("ONLY_EN", "ko-kr") == "Only English", "empty locale cell falls back to en-us")
		assert(t:get("NOPE", "en-us") == "NOPE", "unknown key returns the key itself")
		local fallback = Strings.fromCsv("Key,Source,Context,en-us,ko-kr\nX,The source,ctx,,")
		assert(fallback:get("X", "ko-kr") == "The source", "no en-us value falls back to Source")
	end,

	["format substitutes %d"] = function()
		local t = Strings.fromCsv(CSV)
		assert(t:format("SCORE", "en-us", 42) == "Score: 42", "en-us template formats")
		assert(t:format("SCORE", "ko-kr", 7) == "점수: 7", "ko-kr template formats")
	end,

	["format falls back to raw string on bad format"] = function()
		local t = Strings.fromCsv(CSV)
		assert(t:format("SCORE", "en-us") == "Score: %d", "missing argument returns the template")
	end,

	["locales returns locale columns after Context"] = function()
		local t = Strings.fromCsv(CSV)
		local locales = t:locales()
		assert(#locales == 2, "two locale columns")
		assert(locales[1] == "en-us", "first locale is en-us")
		assert(locales[2] == "ko-kr", "second locale is ko-kr")
	end,

	["missing lists keys with empty locale cells sorted"] = function()
		local t = Strings.fromCsv(CSV)
		local missing = t:missing("ko-kr")
		assert(#missing == 1, "exactly one empty ko-kr cell")
		assert(missing[1] == "ONLY_EN", "the empty key is reported")
		assert(#t:missing("en-us") == 0, "no empty en-us cells")
	end,

	["real locale file is complete"] = function()
		local ok, fs = pcall(function()
			return (require :: any)("@lune/fs")
		end)
		if not ok or fs == nil then
			return
		end

		-- Unlike the missing-module case above, a read failure here is not a
		-- reason to skip: it means the real CSV could not be checked at all, and
		-- silently passing would let missing translations slip through whenever
		-- this spec runs from an unexpected working directory.
		local readOk, text = pcall(fs.readFile, "games/kaiju-egg-raiders/locale/strings.csv")
		assert(
			readOk,
			"could not read games/kaiju-egg-raiders/locale/strings.csv (check the working directory the spec runner uses): "
				.. tostring(text)
		)

		local t = Strings.fromCsv(text)
		assert(#t:missing("ko-kr") == 0, "real file has no empty ko-kr cells")

		local parsed = Strings.parseCsv(text)
		local enColumn = nil
		for index, name in parsed.header do
			if name == "en-us" then
				enColumn = index
			end
		end
		assert(enColumn ~= nil, "real file has an en-us column")
		for _, row in parsed.rows do
			local value = row[enColumn :: number]
			assert(value ~= nil and value ~= "", "missing en-us for " .. tostring(row[1]))
		end
	end,
}
