--!strict
-- Run only at the consolidated generation barrier, from repository root.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local luau = require("@lune/luau")
local crafting = require("../forge/lib/craftinggenerate")
local registry = require("../forge/lib/genreregistry")
local publish = require("../forge/lib/genrepublish")
local destination = "games/primal-isles"
local worldPath = "src/shared/SurvivalWorldConfig.luau"
local selected = {
	["src/server/SurvivalProvision.luau"] = true,
	["src/server/SurvivalFactory.luau"] = true,
	[worldPath] = true,
}
local world = luau.load(fs.readFile(destination .. "/" .. worldPath))()
-- Preserve existing nodes, origin, plot policy and durable keys. Only the new
-- required warehouse target is filled from the maintained generator default.
world.tribe.warehousePosition = world.tribe.warehousePosition or crafting.worldConfig().tribe.warehousePosition
local pack = serde.decode("yaml", fs.readFile(destination .. "/econ.yml")).genre_contract
assert(pack.configs["survival-coop"].mode == "crafting", "CRAFTING_PACK_REQUIRED")
local files = {
	["game.yml"] = fs.readFile(destination .. "/game.yml"),
	["src/server/PrimalIslesServer.server.luau"] = "Server.start({})\n",
	["src/client/PrimalIslesClient.client.luau"] = "Client.start({})\n",
}
crafting.render(
	files,
	assert(registry.discover()),
	{ slug = "primal-isles", pascal = "PrimalIsles" } :: any,
	destination,
	pack,
	world
)
local output = {}
for path in selected do
	output[path] = assert(files[path], "MISSING_RENDERED_CONSUMER")
end
-- Existing hooks are a publication ownership guard, not a refresh target.
local hooks = "src/server/GenreHooks.luau"
output[hooks] = fs.readFile(destination .. "/" .. hooks)
selected[hooks] = true
local ok, err = publish.write(
	{ files = output, order = { "survival-coop" }, generation = {}, legacy = false },
	destination,
	"primal-isles",
	nil,
	nil,
	selected
)
assert(ok, err)
print("Primal consumer refresh published; only three generated consumer files may differ.")
