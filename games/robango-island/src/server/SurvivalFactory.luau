--!strict
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local Bootstrap = require(Forge.genres["survival-coop"].module.SurvivalBootstrap)
local Gathering = require(Forge.genres["survival-coop"].module.Gathering)
local Settlement = require(Forge.core.domain.settlement.Settlement)
local Inventory = require(Forge.core.domain.inventory.Inventory)
local Job = require(Forge.core.domain.crafting.Job)
local Clock = require(Forge.core.infra.genre.Clock)
local Wildlife = require(Forge.genres["survival-coop"].module.Wildlife)
return function(content, source, world, backend, clock, options, provision, wildlifePolicy)
	-- The rendered module also carries capability metadata, not domain content.
	content = table.clone(content)
	content.capability = nil
	local definitions = {}
	for _, definition in content.structures do
		definitions[definition.id] = {
			id = definition.id,
			footprintX = definition.footprintX,
			footprintZ = definition.footprintZ,
			cost = definition.cost,
		}
	end
	local function seconds()
		return math.floor(clock.now())
	end
	local tribe = source.tribe
	local origin = tribe.origin
	local warehouse = tribe.warehousePosition
	local ports = world.settlementPorts(
		Vector3.new(origin.x, origin.y, origin.z),
		Vector3.new(warehouse.x, warehouse.y, warehouse.z)
	)
	local prefix = (source.persistencePrefix :: string) .. ":" .. (provision.id :: string)
	local wildlifeConfig = nil
	if wildlifePolicy then
		assert(wildlifePolicy.version == 1, "WILDLIFE_POLICY_VERSION")
		local catalog = Wildlife.catalog(content, wildlifePolicy.catalog)
		local initial: { [string]: Wildlife.State } = {}
		for _, spawn in wildlifePolicy.spawns do
			assert(not initial[spawn.id], "DUPLICATE_WILDLIFE_SPAWN")
			initial[spawn.id] = Wildlife.new(spawn.id, spawn.catalogId, spawn.position, catalog)
		end
		wildlifeConfig = {
			key = prefix .. ":" .. wildlifePolicy.sourceKey,
			catalog = catalog,
			initial = initial,
			carriedContainer = "bag",
			maxReceipts = wildlifePolicy.maxReceipts,
		}
	end
	return Bootstrap.new({
		sourceKey = prefix .. ":" .. source.sourceKey,
		initial = Gathering.new(source.worldRevision, content, source.nodes),
		content = content,
		now = seconds,
		nowMillis = function()
			return Clock.millis(clock.now())
		end,
		wildlife = wildlifeConfig,
		settlements = {
			maxServerPlayers = 8,
			maxPlots = 1,
			maxReceipts = 4096,
			tribeFor = provision.tribeFor,
			authorize = provision.authorize,
			consent = provision.consent,
			proof = provision.proof,
			tribes = {
				{
					key = prefix .. ":" .. tribe.key,
					now = seconds,
					catalog = Job.catalog(content),
					definitions = definitions,
					acceptedMembers = provision.acceptedMembers,
					verifyPlacement = ports.verify,
					publish = ports.publish,
					initial = {
						settlement = Settlement.new(tribe.config, provision.ownerId),
						warehouse = Inventory.new(
							tribe.warehouseId,
							{ slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 }
						),
					},
					verifyTransfer = function(actor, proof)
						if provision.verifyTransfer(actor, proof) and ports.warehouse(actor) then
							return true
						end
						return false
					end,
					workshop = {
						content = content,
						revision = tribe.workshopRevision,
						verifyStation = function(actor, id, state)
							local spatial = world.services.survivalSpatial
							local station = if spatial then spatial.station(actor, id) else nil
							if not station or not station.reachable then
								return nil
							end
							return {
								carriedContainer = state.warehouse.id,
								stationId = id,
								stationKind = station.kind,
								inReach = true,
							}
						end,
					},
				},
			},
		},
	}, world, backend, options)
end
