--!strict
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local Shared = Forge.games["robango-island"].src.shared
local Server = require(Forge.core.infra.genre.Server)
local RuntimeBackend = require(Forge.core.infra.data.RuntimeBackend)
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Clock = require(Forge.core.infra.genre.Clock)
local content = require(Shared.SurvivalContent)
local source = require(Shared.SurvivalWorldConfig)
local wildlifePolicy = require(Shared.WildlifePolicy)
-- The provisioning policy is guarded by the environment: `studio` is true only for a local Studio
-- place with no published experience id, so a published server can never select the permissive path.
local provision = require(script.Parent.SurvivalProvision)(
	require(script.Parent.SurvivalProvisionConfig),
	source.tribe.config.tribeId,
	{ studio = RunService:IsStudio() and game.PlaceId == 0 }
)
local clock = Clock.new(function()
	return DateTime.now().UnixTimestampMillis / 1000
end)
local backend = RuntimeBackend.new(require(script.Parent.PersistenceConfig), "SurvivalShared")
local world = require(script.Parent.SurvivalWorldBootstrap)(content, source, wildlifePolicy, function()
	return Clock.millis(clock.now())
end)
local factory, err = require(script.Parent.SurvivalFactory)(content, source, world, backend, clock, {
	sessionId = game.JobId .. HttpService:GenerateGUID(false),
	leaseSeconds = 120,
	now = function()
		return math.floor(DateTime.now().UnixTimestampMillis / 1000)
	end,
	budget = {
		encode = function(value)
			return HttpService:JSONEncode(value)
		end,
	},
}, provision, wildlifePolicy)
assert(factory, err)
Server.start({
	backend = backend,
	clock = clock,
	starterWorld = false,
	lifecycle = { bind = factory.bind, close = factory.close },
	services = factory.services,
	durable = require(Shared.GenreDurable),
	packConfig = require(Shared.GenreConfig),
	spec = require(Shared.GenreSpec),
	contracts = require(Shared.GenreRuntime),
	controls = require(Shared.GenreUI),
	hooks = require(script.Parent.GenreHooks),
	storeName = "robango-island-genre-v1",
})
