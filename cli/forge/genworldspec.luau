--!strict
-- Regenerates a hand-written pack's `src/shared/WorldSpec.luau` from its genre's
-- declared `world:` section.
--
-- A pack produced by `forge gen` gets this module for free. A hand-written pack
-- (grow-and-defend-garden is one) never runs that generator, so without this it
-- ships no WorldSpec and its place is a bare Baseplate with only a HUD on top --
-- exactly the defect this script was written to fix. Run it after editing the
-- genre's `world:` block:
--
--   lune run cli/forge/genworldspec games/grow-and-defend-garden grow-harvest

local fs = require("@lune/fs")
local luneProcess = require("@lune/process")

local genrespec = require("./lib/genrespec")

local packSlug = luneProcess.args[1] or ""
local genreId = luneProcess.args[2] or ""
if packSlug == "" or genreId == "" then
	print("usage: lune run cli/forge/genworldspec <pack-slug> <genre-id>")
	luneProcess.exit(2)
end

local specPath = "genres/" .. genreId .. "/genre-spec.yml"
local spec, errors = genrespec.load(specPath)
if spec == nil then
	error("genre spec failed to load: " .. table.concat(errors, "; "))
end
if type(spec.world) ~= "table" or type(spec.world.zones) ~= "table" or #spec.world.zones == 0 then
	error(genreId .. " declares no world zones; nothing to serialize")
end

local source = genrespec.stabilize(genrespec.serializeWorld(spec.world), "WorldSpec.luau")
local out = "games/" .. packSlug .. "/src/shared/WorldSpec.luau"
fs.writeFile(out, source)
print(
	string.format("wrote %s (%d bytes, %d zones, %d nodes)", out, #source, #spec.world.zones, #(spec.world.nodes or {}))
)
