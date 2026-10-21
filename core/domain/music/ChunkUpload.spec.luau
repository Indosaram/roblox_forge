--!strict
local Upload = require("./ChunkUpload")
local Hash = require("./ChunkHash")
local Rules = require("./TestCatalog")
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local function transfer(module: any, text: string): any
	local receiver = module.new(Rules, 30)
	assert(receiver.begin("a", "id", #text, Hash.digest(text), "", 0).ok, "begin accepted")
	for offset = #text - (#text - 1) % 128, 1, -128 do
		local bytes = string.sub(text, offset, offset + 127)
		assert(receiver.put("a", "id", (offset - 1) / 128 + 1, Upload.hex(bytes), 0).ok, "out of order chunk accepted")
	end
	return receiver.finish("a", "id", 0)
end
return {
	["SHA256 matches standard vectors including binary and multi-block data"] = function()
		for _, text in { "", "abc", string.rep("a", 1000), "\0\255\195\169" } do
			assert(Hash.digest(text) == serde.hash("sha256", text), "SHA256 reference equality")
		end
	end,
	["bounded binary chunks reconstruct the exact cap without splitting UTF8 on wire"] = function()
		local text = string.rep("é", Rules.maxBytes / 2)
		local result = transfer(Upload, text)
		assert(result.ok and result.text == text, "max bytes reconstructed exactly")
		local upload = Upload.new(Rules, 30)
		assert(
			not upload.begin("a", "id", Rules.maxBytes + 1, Hash.digest("x"), "", 0).ok,
			"oversized refused before allocation"
		)
	end,
	["hash mismatch missing duplicate conflict actor isolation expiry and cancel refuse"] = function()
		local upload = Upload.new(Rules, 30)
		assert(upload.begin("a", "id", 1, Hash.digest("a"), "", 0).ok, "begin")
		assert(not upload.begin("a", "other", 1, Hash.digest("a"), "", 0).ok, "active bound")
		assert(not upload.finish("a", "id", 0).ok, "missing")
		assert(not upload.put("b", "id", 1, "61", 0).ok, "actor isolation")
		assert(not upload.put("a", "id", 0, "61", 0).ok, "index")
		assert(not upload.put("a", "id", 1, "6z", 0).ok, "hex")
		assert(upload.put("a", "id", 1, "62", 0).ok, "first")
		assert(upload.put("a", "id", 1, "62", 0).ok, "identical replay")
		assert(not upload.put("a", "id", 1, "61", 0).ok, "conflicting replay")
		assert(not upload.finish("a", "id", 0).ok, "hash protects content")
		assert(not upload.finish("a", "id", 30).ok, "fixed expiry")
		assert(upload.begin("a", "id", 1, Hash.digest("a"), "", 30).ok, "expired slot reusable")
		upload.clear("a")
		assert(not upload.put("a", "id", 1, "61", 30).ok, "disconnect clears")
	end,
	["negative checks kill size and digest guard mutations"] = function()
		local source = fs.readFile("core/domain/music/ChunkUpload.luau")
		local function mutant(old: string, replacement: string): any
			local startAt, endAt = string.find(source, old, 1, true)
			assert(startAt and endAt, "mutation anchor")
			return luau.load(
				string.sub(source, 1, startAt - 1) .. replacement .. string.sub(source, endAt + 1),
				{ environment = {
					require = function()
						return Hash
					end,
				} }
			)()
		end
		local oversized = mutant("size > rules.maxBytes", "false").new(Rules, 30)
		assert(oversized.begin("a", "id", Rules.maxBytes + 1, Hash.digest("a"), "", 0).ok, "size mutant killed")
		local unchecked = mutant("Hash.digest(text) ~= upload.digest", "false").new(Rules, 30)
		assert(unchecked.begin("a", "id", 1, Hash.digest("a"), "", 0).ok, "begin mutant")
		assert(unchecked.put("a", "id", 1, "62", 0).ok, "put mutant")
		assert(unchecked.finish("a", "id", 0).ok, "hash mutant killed")
	end,
}
