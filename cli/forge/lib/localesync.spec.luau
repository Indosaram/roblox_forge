--!strict
-- Specs for LocaleSync: payload entry count, per-locale translations, quoted
-- CSV fields, and refusal of a header missing a required column.

local LocaleSync = require("./localesync")

return {
	["a two-locale csv becomes one entry per non-blank row"] = function()
		local csv = "Key,Source,Context,en-us,ko-kr\n"
			.. "hud.coins,Coins: 0,Initial coins counter label,Coins: 0,코인: 0\n"
			.. "button.store,Store,Store button and store panel title,Store,상점\n"
		local payload, err = LocaleSync.buildPayload(csv)
		assert(err == nil, "unexpected error: " .. tostring(err))
		local built = payload :: LocaleSync.Payload
		assert(#built.entries == 2, "expected 2 entries, got " .. tostring(#built.entries))
		assert(#built.locales == 2, "expected 2 locales, got " .. tostring(#built.locales))
		assert(built.locales[1] == "en-us" and built.locales[2] == "ko-kr", "locale order follows the header")
		assert(built.entries[1].key == "hud.coins", "key is read from the Key column")
		assert(built.entries[1].source == "Coins: 0", "source is read from the Source column")
		assert(built.entries[1].context == "Initial coins counter label", "context is read from the Context column")
		assert(built.entries[1].translations["en-us"] == "Coins: 0", "en-us translation")
		assert(built.entries[1].translations["ko-kr"] == "코인: 0", "ko-kr translation")
	end,

	["quoted fields keep embedded commas and quotes"] = function()
		local csv = "Key,Source,Context,en-us,ko-kr\n"
			.. 'greet,"Hello, friend",Greeting,"Hello, friend","안녕, 친구"\n'
			.. 'quote,"He said ""hi""",Quoted,"He said ""hi""","그가 ""안녕""이라고 했다"\n'
		local payload, err = LocaleSync.buildPayload(csv)
		assert(err == nil, "unexpected error: " .. tostring(err))
		local built = payload :: LocaleSync.Payload
		assert(#built.entries == 2, "expected 2 entries, got " .. tostring(#built.entries))
		assert(built.entries[1].source == "Hello, friend", "embedded comma is preserved")
		assert(built.entries[2].source == 'He said "hi"', "doubled quotes collapse to one")
	end,

	["blank rows are skipped"] = function()
		local csv = "Key,Source,Context,en-us,ko-kr\n"
			.. "hud.coins,Coins: 0,Label,Coins: 0,코인: 0\n"
			.. ",,,\n"
			.. "\n"
			.. "button.store,Store,Title,Store,상점\n"
		local payload, err = LocaleSync.buildPayload(csv)
		assert(err == nil, "unexpected error: " .. tostring(err))
		local built = payload :: LocaleSync.Payload
		assert(#built.entries == 2, "blank rows must be skipped, got " .. tostring(#built.entries))
	end,

	["a header missing Context is refused"] = function()
		local payload, err = LocaleSync.buildPayload("Key,Source,en-us,ko-kr\na,b,c,d\n")
		assert(payload == nil, "a missing column must not produce a payload")
		assert(err == "missing column: Context", "reason: " .. tostring(err))
	end,

	["F8: a leading UTF-8 BOM is stripped before the header is parsed"] = function()
		local csv = "\239\187\191Key,Source,Context,en-us\nk,s,c,t\n"
		local payload, err = LocaleSync.buildPayload(csv)
		assert(err == nil, "a BOM-prefixed header must still parse: " .. tostring(err))
		local built = payload :: LocaleSync.Payload
		assert(#built.entries == 1, "expected 1 entry, got " .. tostring(#built.entries))
		assert(built.entries[1].key == "k", "the Key column must resolve to 'k', not '\239\187\191Key'")
		assert(built.entries[1].translations["en-us"] == "t", "the en-us translation must still be read")
	end,
}
