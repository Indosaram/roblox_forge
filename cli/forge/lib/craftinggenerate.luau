--!strict
-- Explicit developmental opt-in; the default six genre generators never enter here.
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local Content = require("../../../core/domain/survival/Content")
local Capability = require("../../../core/domain/survival/Capability")
local Ledger = require("../../../core/domain/command/Ledger")
local contract = require("./genrecontract")
local registryLib = require("./genreregistry")
local genrespec = require("./genrespec")
local project = require("./genreproject")
local contentrender = require("./contentrender")
local M = {}

function M.content(): any
	local raw: any = {
		survival_content = 1,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		vitals = {},
		tags = { "tool" },
		items = {},
		recipes = {},
		nodes = {},
		structures = {},
		wildlife = { { id = "grazer", behavior = "grazer" }, { id = "hunter", behavior = "hunter" } },
	}
	for _, id in
		{
			"wood",
			"flint",
			"fiber",
			"berry",
			"meat",
			"cord",
			"stone-axe",
			"stone-pick",
			"spear",
			"cooked-meat",
			"berry-meal",
			"plank",
			"campfire-kit",
			"workbench-kit",
			"storage-kit",
			"floor-kit",
			"roof-kit",
		}
	do
		local tool = id == "stone-axe" or id == "stone-pick" or id == "spear"
		table.insert(raw.items, {
			id = id,
			name = id,
			stackMax = if tool then 1 else 50,
			weightMilli = if tool then 2500 else 500,
			maxDurabilityMilli = if tool then 100000 else nil,
			tags = if tool then { "tool" } else {},
			foodEffects = if id == "berry"
				then { hungerMilli = 5000, healthMilli = 0, fatigueMilli = 0 }
				elseif id == "cooked-meat" then { hungerMilli = 20000, healthMilli = 0, fatigueMilli = 0 }
				elseif id == "berry-meal" then { hungerMilli = 15000, healthMilli = 0, fatigueMilli = 0 }
				else nil,
		})
	end
	local recipes: { { any } } = {
		{ "cord", "fiber", 3, false },
		{ "stone-axe", "flint", 2, false },
		{ "stone-pick", "flint", 3, false },
		{ "spear", "wood", 3, false },
		{ "cooked-meat", "meat", 1, "campfire" },
		{ "berry-meal", "berry", 3, "campfire" },
		{ "plank", "wood", 2, "workbench" },
		{ "campfire-kit", "wood", 4, false },
		{ "workbench-kit", "wood", 6, false },
		{ "storage-kit", "plank", 4, "workbench" },
		{ "floor-kit", "plank", 2, "workbench" },
		{ "roof-kit", "plank", 3, "workbench" },
	}
	for _, recipe in recipes do
		table.insert(raw.recipes, {
			id = recipe[1],
			craftMillis = 3000,
			inputs = { { item = recipe[2], quantity = recipe[3] } },
			outputs = { { item = recipe[1], quantity = 1 } },
			station = if recipe[4] then recipe[4] else nil,
		})
	end
	for _, pair in
		{
			{ "fallen-tree", "wood" },
			{ "flint-outcrop", "flint" },
			{ "fiber-bush", "fiber" },
			{ "berry-bush", "berry" },
			{ "meat-cache", "meat" },
		}
	do
		table.insert(
			raw.nodes,
			{ id = pair[1], harvest = { { item = pair[2], quantity = 3 } }, respawnMillis = 120000 }
		)
	end
	for _, id in { "campfire", "workbench", "storage", "floor" } do
		table.insert(raw.structures, {
			id = id,
			footprintX = 2,
			footprintZ = 2,
			station = id == "campfire" or id == "workbench",
			cost = { { item = "wood", quantity = 4 } },
		})
	end
	local canonical, errors = Content.canonicalize(raw)
	assert(canonical, table.concat(errors, "; "))
	local result: any = canonical
	result.survival_content = result.version
	result.version = nil
	return result
end

function M.policy(): Ledger.Policy
	return {
		actions = {
			"survival-coop:attack",
			"survival-coop:gather",
			"survival-coop:transfer-deposit",
			"survival-coop:transfer-withdraw",
			"survival-coop:settlement-leave",
			"survival-coop:settlement-kick",
			"survival-coop:settlement-transfer-owner",
			"survival-coop:settlement-rejoin",
			"survival-coop:settlement-reserve",
			"survival-coop:settlement-place",
			"survival-coop:settlement-cancel",
			"survival-coop:settlement-demolish",
			"survival-coop:settlement-workshop-reserve",
			"survival-coop:settlement-workshop-start",
			"survival-coop:settlement-workshop-complete",
			"survival-coop:settlement-workshop-cancel",
			"survival-coop:craft-reserve",
			"survival-coop:craft-start",
			"survival-coop:craft-complete",
			"survival-coop:craft-cancel",
			"survival-coop:food",
			"survival-coop:rest",
			"survival-coop:inventory-move",
			"survival-coop:inventory-split",
			"survival-coop:inventory-merge",
		},
		serverActions = {
			"survival-coop:settlement-invite",
			"survival-coop:server-vitals-tick",
			"survival-coop:vitals-damage",
			"survival-coop:rest-stop",
			"survival-coop:respawn",
		},
		tickAction = "survival-coop:server-vitals-tick",
		personal = { namespace = "personal", inventoryPath = { "genres", "survival-coop", "data", "inventory", "bag" } },
	}
end

function M.worldConfig(): any
	local nodes = {}
	for index, kind in { "fallen-tree", "flint-outcrop", "fiber-bush", "berry-bush", "meat-cache" } do
		table.insert(nodes, {
			id = kind .. "-01",
			catalogId = kind,
			position = { x = (index - 3) * 10, y = 2, z = 14 },
			charges = 3,
			qualityMilli = 1000,
		})
	end
	return {
		worldRevision = "development-island-v1",
		sourceKey = "nodes-v1",
		tribe = {
			key = "camp-v1",
			config = { tribeId = "camp", width = 16, depth = 12, cellStuds = 4, maxMembers = 4 },
			warehouseId = "warehouse",
			warehousePosition = { x = 0, y = 2, z = -22 },
			workshopRevision = "development-workshop-v1",
			origin = { x = -32, y = 0, z = -16 },
		},
		nodes = nodes,
	}
end

function M.wildlifePolicy(): any
	return {
		version = 1,
		sourceKey = "wildlife-v1",
		maximum = 8,
		maxReceipts = 512,
		catalog = {
			species = {
				grazer = { healthMilli = 40000, damageMilli = 0, drops = { { item = "meat", quantity = 2 } } },
				hunter = { healthMilli = 60000, damageMilli = 10000, drops = { { item = "meat", quantity = 3 } } },
			},
			weapons = {
				spear = {
					damageMilli = 20000,
					wearMilli = 1000,
					rangeStuds = 8,
					facingDot = 0.5,
					cooldownMillis = 2000,
				},
			},
		},
		spawns = {
			{ id = "grazer-01", catalogId = "grazer", position = { x = -20, y = 4, z = 24 } },
			{ id = "hunter-01", catalogId = "hunter", position = { x = 22, y = 4, z = 24 } },
		},
	}
end

function M.generate(base: contract.Generated): contract.Generated
	local generated = table.clone(base)
	generated.config = {
		mode = "crafting",
		currency = "Coins",
		startingBalance = 0,
		contentVersion = Content.VERSION,
		survivalDeath = true,
		inventory = {
			content = M.content(),
			carriedContainer = "bag",
			speedPenaltyMilli = 300,
			containers = {
				bag = {
					{
						itemId = "starter-fiber",
						catalogId = "fiber",
						quantity = 12,
						qualityMilli = 1000,
						durabilityMilli = 0,
						attributes = { origin = "starter" },
					},
					{
						itemId = "starter-berry",
						catalogId = "berry",
						quantity = 3,
						qualityMilli = 1000,
						durabilityMilli = 0,
						attributes = { origin = "starter" },
					},
				},
			},
		},
	}
	generated.controls = {
		{
			id = "survival-coop:reserve-cord",
			action = "survival-coop:craft-reserve",
			args = { "cord", "hand" },
			label = "Reserve cord",
			kind = "button",
		},
		{
			id = "survival-coop:eat-berry",
			action = "survival-coop:food",
			args = { "starter-berry" },
			label = "Eat berry",
			kind = "button",
		},
	}
	generated.artifacts = table.clone(base.artifacts)
	generated.assetKeys = table.clone(base.assetKeys)
	for index, artifact in generated.artifacts do
		if artifact.path == "assets/survival-coop/audio.yml" then
			local document = serde.decode("yaml", artifact.content)
			local seed = document.cues[1].seed
			for offset, cue in
				{
					{ key = "survival-coop-gather", kind = "sfx", type = "click", duration = 0.2 },
					{ key = "survival-coop-craft", kind = "sfx", type = "hatch", duration = 0.4 },
					{ key = "survival-coop-eat", kind = "sfx", type = "click", duration = 0.15 },
					{ key = "survival-coop-rest", kind = "ambience", type = "wind", duration = 4 },
					{ key = "survival-coop-ambient", kind = "ambience", type = "birds", duration = 6 },
				}
			do
				local recipe: any = table.clone(cue)
				recipe.seed = seed + offset
				table.insert(document.cues, recipe)
				table.insert(generated.assetKeys, cue.key)
			end
			generated.artifacts[index] = { path = artifact.path, content = serde.encode("yaml", document) }
		end
	end
	generated.artifacts[1] = {
		path = "design/survival-coop/loop.md",
		content = "# Developmental crafting bootstrap\nThe generated factory binds gathering, wildlife, vitals, consent-based settlements, warehouse transfers, station crafting and construction. Reusable gathering controls, survival HUD, quarter-view camera and event-driven audio are mounted by the client. Engine startup requires explicit server-only owner/consent provisioning. Audio requires published, experience-permitted Roblox asset IDs; local WAV files are not playback IDs. Catalog numbers and asset quality are provisional. Studio spatial, audio and visual approval are not claimed. Existing authored world/server/client entry points and audio configuration are retained on regeneration; fresh generation supplies starter geometry, not game-specific art.\n",
	}
	return generated
end

function M.render(
	files: { [string]: string },
	registry: registryLib.Registry,
	input: contract.GenerateInput,
	destination: string,
	pack: any,
	existingWorld: any?
)
	local raw = pack.configs["survival-coop"].inventory.content
	-- The staging owner and the closed QA allowlist come from the pack's own publication inputs,
	-- never from core: `FORGE_STAGING_OWNER_USER_ID` names the real owner a generated staging config
	-- is published for, and `FORGE_QA_ACTOR_IDS` is the closed developmental allowlist.
	local stagingOwner = process.env["FORGE_STAGING_OWNER_USER_ID"]
	if type(stagingOwner) ~= "string" or string.match(stagingOwner, "^[1-9][0-9]*$") == nil then
		stagingOwner = nil
	end
	local qaActors: { string } = {}
	local qaRaw = process.env["FORGE_QA_ACTOR_IDS"]
	if type(qaRaw) == "string" then
		for token in string.gmatch(qaRaw, "[^,]+") do
			local trimmed = string.gsub(string.gsub(token, "^%s+", ""), "%s+$", "")
			if string.match(trimmed, "^[1-9][0-9]*$") ~= nil then
				table.insert(qaActors, trimmed)
			end
		end
	end
	local provisionId = "development"
	local policy = "developmental"
	local ownerId = ""
	local acceptedInvitations: { [string]: boolean } = {}
	if stagingOwner ~= nil then
		provisionId, policy, ownerId = "staging", "staging", stagingOwner
		acceptedInvitations[stagingOwner] = true
	end
	assert(#pack.order == 1 and pack.order[1] == "survival-coop", "WILDLIFE_COMPOSITION_UNSUPPORTED")
	-- The pack's one rendered language, from its spec, so the survival HUD and the
	-- kit HUDs of every other genre render the same language.
	local locale = genrespec.localeDefault(registry.packages["survival-coop"].spec)
	local rendered, errors = contentrender.build(raw, "crafting")
	assert(rendered, table.concat(errors, "; "))
	files[rendered.path] = rendered.content
	files["content.yml"] = serde.encode("yaml", raw)
	files["src/shared/WildlifePolicy.luau"] = "--!strict\nexport type Spawn = {id:string,catalogId:string,position:{x:number,y:number,z:number}}\nexport type Species={healthMilli:number,damageMilli:number,drops:{{item:string,quantity:number}}}\nexport type Weapon={damageMilli:number,wearMilli:number,rangeStuds:number,facingDot:number,cooldownMillis:number}\nlocal policy: {version:number,sourceKey:string,maximum:number,maxReceipts:number,catalog:{species:{[string]:Species},weapons:{[string]:Weapon}},spawns:{Spawn}} = "
		.. contract.serialize(M.wildlifePolicy())
		.. "\nreturn policy\n"
	local worldConfig = existingWorld or M.worldConfig()
	for _ = 1, 3 do
		local formatter = process.create("stylua", { "--config-path", "stylua.toml", "-" })
		formatter.stdin:write(files["src/shared/WildlifePolicy.luau"])
		formatter.stdin:close()
		files["src/shared/WildlifePolicy.luau"] = formatter.stdout:readToEnd()
		local formatErrors = formatter.stderr:readToEnd()
		assert(formatter:status().ok, formatErrors)
	end
	worldConfig.persistencePrefix = "s:" .. serde.hash("sha256", input.slug):sub(1, 16)
	local nodeSource = contract.serialize(worldConfig.nodes)
	local worldSource = contract.serialize(worldConfig)
	local startAt, endAt = string.find(worldSource, '["nodes"]=' .. nodeSource, 1, true)
	assert(startAt and endAt, "world nodes field")
	worldSource = string.sub(worldSource, 1, startAt - 1) .. '["nodes"]=nodes' .. string.sub(worldSource, endAt + 1)
	files["src/shared/SurvivalWorldConfig.luau"] = "--!strict\nexport type Node = {id:string,catalogId:string,position:{x:number,y:number,z:number},charges:number,qualityMilli:number,requiredToolTag:string?}\nlocal nodes: {Node} = "
		.. nodeSource
		.. "\nreturn "
		.. worldSource
		.. "\n"
	files["src/shared/GenreDurable.luau"] = "--!strict\nexport type Policy = {personal:{namespace:string,inventoryPath:{string}}?,actions:{string},serverActions:{string}?,tickAction:string?,windowSeconds:number?,maxOutcomes:number?}\nlocal policy: Policy = "
		.. contract.serialize(M.policy())
		.. "\nreturn policy\n"
	local path = "src/server/" .. input.pascal .. "Server.server.luau"
	local clientPath = "src/client/" .. input.pascal .. "Client.client.luau"
	files["src/shared/AudioConfig.luau"] = [[--!strict
-- Publication supplies Assets; local WAV paths are not Roblox playback IDs.
return {
assets=require("./Assets"),
cues={
gather={asset="survival-coop-gather",volume=0.4},
craft={asset="survival-coop-craft",volume=0.4},
eat={asset="survival-coop-eat",volume=0.3},
hit={asset="survival-coop-action",volume=0.45},
rest={asset="survival-coop-rest",volume=0.15},
ambient={asset="survival-coop-ambient",volume=0.12},
},
}
]]
	-- The crafting client is generated whole. The base client for this genre binds
	-- the declared SurvivalHUD override, and the crafting bootstrap layers the real
	-- HUD, gathering and camera on top of the generic core client. The sequence is a
	-- contract: audio subscribes before the first handshake, the starter GUI is
	-- hidden without being destroyed, and every owner gets one cleanup.
	files[clientPath] = table.concat({
		"--!strict",
		'local ReplicatedStorage = game:GetService("ReplicatedStorage")',
		'local Forge = ReplicatedStorage:WaitForChild("Forge")',
		"local Shared = Forge.games[" .. string.format("%q", input.slug) .. "].src.shared",
		"",
		'local SurvivalAudio = require(Forge.genres["survival-coop"].module.SurvivalAudio)',
		"local audio = SurvivalAudio.start(require(Shared.AudioConfig))",
		"script.Destroying:Connect(audio.destroy)",
		"",
		"local Client = require(Forge.core.infra.genre.Client)",
		"local gui = Client.start({ controls = require(Shared.GenreUI) })",
		"gui.Destroying:Connect(audio.destroy)",
		"",
		'local GatheringClient = require(Forge.genres["survival-coop"].module.GatheringClient)',
		"local gathering = GatheringClient.start()",
		"gui.Destroying:Connect(gathering.destroy)",
		"",
		'local SurvivalHUD = require(Forge.genres["survival-coop"].module.SurvivalHUD)',
		"local content = require(Shared.SurvivalContent)",
		"local worldConfig = require(Shared.SurvivalWorldConfig)",
		"local origin = worldConfig.tribe.origin",
		"gui.Enabled = false",
		"local hud = SurvivalHUD.start({",
		"\tcontent = content,",
		"\tui = {",
		'\t\tcomponents = require(Forge.core["ui-kit"].Components),',
		'\t\tgrid = require(Forge.core["ui-kit"].InventoryGrid),',
		'\t\ttheme = require(Forge.core["ui-kit"].Theme),',
		"\t},",
		"\tsettlementOrigin = Vector3.new(origin.x, origin.y, origin.z),",
		"\tlocale = " .. string.format("%q", locale) .. ",",
		"})",
		"gui.Destroying:Connect(hud.destroy)",
		"script.Destroying:Connect(hud.destroy)",
		"",
		"local QuarterView = require(Forge.core.infra.camera.QuarterView)",
		"local camera = QuarterView.start()",
		"gui.Destroying:Connect(camera.stop)",
		"script.Destroying:Connect(camera.stop)",
		"",
	}, "\n")
	files["src/server/SurvivalProvisionConfig.luau"] = table.concat({
		"--!strict",
		"-- Server-only owner/consent provisioning. Membership is granted from THIS record before the",
		"-- settlement runtime acquires its store: routing grants no membership, and an actor the record",
		"-- does not name is refused rather than admitted.",
		"--",
		"-- `policy` is explicit and is never inferred from an empty owner id:",
		"--   staging        - a real owner and its accepted invitations (a published experience).",
		"--   developmental  - the closed Studio QA allowlist below, and only in a local Studio place.",
		"--   unprovisioned  - nothing is provisioned, so the server refuses to start.",
		"--",
		"-- `actors` is the closed developmental allowlist. It is read only in a local Studio place",
		"-- (`studio`), never in a published server.",
		"return {",
		"\tprovisionId = " .. string.format("%q", provisionId) .. ",",
		"\tpolicy = " .. string.format("%q", policy) .. ",",
		"\townerId = " .. string.format("%q", ownerId) .. ",",
		"\tacceptedInvitations = " .. contract.serialize(acceptedInvitations) .. ",",
		"\tactors = " .. contract.serialize(qaActors) .. ",",
		"}",
		"",
	}, "\n")
	files["src/server/SurvivalProvision.luau"] = [[--!strict
type Result = {ok:boolean,reason:string?,data:{[string]:any}?,stateVersion:number?}
-- Owner/consent provisioning. The membership record is complete BEFORE the settlement runtime
-- acquires its store, so what it consumes at acquisition is exactly what an actor is authorized
-- against. Nothing is appended later: a mutable "arriving actor" list never reached the settlement,
-- which is why a real positive user id could gather but not use settlement storage.
--
-- The policy is explicit; it is never inferred from an empty owner id. The permissive Studio path is
-- guarded by the ENVIRONMENT the caller passes in: `studio` is true only for a local Studio place
-- with no published experience id, so a published server can never select it.
local LOCAL_OWNER="-1"
local POLICIES={staging=true,developmental=true,unprovisioned=true}
return function(config: any, tribeId: string, environment: any)
local function userId(value: any): boolean
if type(value)~="string" or not string.match(value,"^%-?[1-9][0-9]*$") then return false end
local number=tonumber(value)
return number~=nil and math.abs(number)<=9007199254740991 and string.format("%.0f",number)==value
end
assert(type(config)=="table","SURVIVAL_PROVISION_REQUIRED")
assert(POLICIES[config.policy]==true,"SURVIVAL_PROVISION_POLICY_REQUIRED")
assert(type(config.provisionId)=="string" and #config.provisionId<=16 and string.match(config.provisionId,"^[a-z][a-z0-9%-]*$"),"SURVIVAL_PROVISION_ID_REQUIRED")
assert(type(config.acceptedInvitations)=="table","SURVIVAL_CONSENT_RECORD_REQUIRED")
for actor,accepted in config.acceptedInvitations do
assert(userId(actor) and type(accepted)=="boolean","SURVIVAL_INVALID_CONSENT_RECORD")
end
local actors: {string} = config.actors or {}
assert(type(actors)=="table","SURVIVAL_QA_ALLOWLIST_REQUIRED")
for _,actor in actors do
assert(userId(actor),"SURVIVAL_INVALID_QA_ACTOR")
end
local studio=type(environment)=="table" and environment.studio==true
if config.policy=="unprovisioned" then
error("SURVIVAL_OWNER_PROVISION_REQUIRED")
end
assert(config.policy~="staging" or userId(config.ownerId),"SURVIVAL_OWNER_PROVISION_REQUIRED")
local owner: string = if config.policy=="staging" then tostring(config.ownerId) else LOCAL_OWNER
local accepted: {[string]: boolean} = table.clone(config.acceptedInvitations)
local allowed: {[string]:boolean}={}
for _,actor in actors do allowed[actor]=true end
local members: {string}={}
local function addMember(actor: any)
local id=tostring(actor)
if id==owner or table.find(members,id) then return end
table.insert(members,id)
end
for actor,consented in accepted do
if consented then addMember(actor) end
end
if studio then
for _,actor in actors do addMember(actor) end
end
-- Membership is the record above and nothing else. An empty allowlist in a local Studio place
-- admits the routed QA actor; a published server admits only the owner and the consented members.
local function routed(actor: string): boolean
if actor==owner or accepted[actor]==true then return true end
if not studio then return false end
if next(allowed)==nil then return true end
return allowed[actor]==true
end
local proof="provision:"..config.provisionId..":"..tribeId
return {
ownerId=owner,
id=config.provisionId,
acceptedMembers=members,
tribeFor=function(actor) return if routed(actor) then tribeId else nil end,
authorize=function(actor,action,_args,origin): Result
if not routed(actor) then return {ok=false,reason="PROVISION_REQUIRED"} end
if action=="survival-coop:settlement-invite" and (actor~=owner or origin~="server") then return {ok=false,reason="FORBIDDEN"} end
return {ok=true}
end,
consent=function(actor,target) return actor==owner and accepted[target]==true end,
proof=function(actor) return if routed(actor) then proof else nil end,
verifyTransfer=function(actor,value) return routed(actor) and value==proof end,
}
end
]]
	local provisionPath = "src/server/SurvivalProvisionConfig.luau"
	local provisionModule = luau.load(files["src/server/SurvivalProvision.luau"])()
	-- The generated default must never admit an arbitrary actor on a published server: with the
	-- environment's Studio guard off, an actor the record does not name is refused. An unprovisioned
	-- default refuses to start at all.
	local generatedSettings = luau.load(files[provisionPath])()
	local defaultOk, defaultResult = pcall(function()
		return provisionModule(generatedSettings, worldConfig.tribe.config.tribeId, { studio = false })
	end)
	if generatedSettings.policy == "unprovisioned" then
		assert(
			not defaultOk and string.find(tostring(defaultResult), "SURVIVAL_OWNER_PROVISION_REQUIRED", 1, true) ~= nil,
			"an unprovisioned default must refuse to start"
		)
	else
		assert(defaultOk, tostring(defaultResult))
		assert(
			defaultResult.tribeFor("1234567") == nil
				and defaultResult.authorize("1234567", "survival-coop:attack", {}, "client").ok == false,
			"the generated default must not admit an actor it does not name off Studio"
		)
	end
	if fs.isFile(destination .. "/" .. provisionPath) then
		local existing = fs.readFile(destination .. "/" .. provisionPath)
		local settings = luau.load(existing)()
		-- A preserved authored record validates for real in a local Studio place: a provisioned record
		-- builds, and an unprovisioned one refuses.
		local ok, result = pcall(function()
			return provisionModule(settings, worldConfig.tribe.config.tribeId, { studio = true })
		end)
		if settings.policy == "unprovisioned" then
			assert(
				not ok and string.find(tostring(result), "SURVIVAL_OWNER_PROVISION_REQUIRED", 1, true) ~= nil,
				"an unprovisioned record must refuse to start"
			)
		else
			assert(ok, tostring(result))
		end
		files[provisionPath] = existing
	end
	files["src/server/SurvivalFactory.luau"] = [[--!strict
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
content=table.clone(content)
content.capability=nil
local definitions = {}
for _, definition in content.structures do
definitions[definition.id] = {id=definition.id,footprintX=definition.footprintX,footprintZ=definition.footprintZ,cost=definition.cost}
end
local function seconds() return math.floor(clock.now()) end
local tribe=source.tribe
local origin=tribe.origin
local warehouse=tribe.warehousePosition
local ports=world.settlementPorts(Vector3.new(origin.x,origin.y,origin.z),Vector3.new(warehouse.x,warehouse.y,warehouse.z))
local prefix=(source.persistencePrefix :: string)..":"..(provision.id :: string)
local wildlifeConfig=nil
if wildlifePolicy then
assert(wildlifePolicy.version==1,"WILDLIFE_POLICY_VERSION")
local catalog=Wildlife.catalog(content,wildlifePolicy.catalog)
local initial: {[string]: Wildlife.State}={}
for _, spawn in wildlifePolicy.spawns do
assert(not initial[spawn.id],"DUPLICATE_WILDLIFE_SPAWN")
initial[spawn.id]=Wildlife.new(spawn.id,spawn.catalogId,spawn.position,catalog)
end
wildlifeConfig={key=prefix..":"..wildlifePolicy.sourceKey,catalog=catalog,initial=initial,carriedContainer="bag",maxReceipts=wildlifePolicy.maxReceipts}
end
return Bootstrap.new({
sourceKey=prefix..":"..source.sourceKey, initial=Gathering.new(source.worldRevision,content,source.nodes), content=content,
now=seconds, nowMillis=function() return Clock.millis(clock.now()) end,
wildlife=wildlifeConfig,
settlements={maxServerPlayers=8,maxPlots=1,maxReceipts=4096,
tribeFor=provision.tribeFor, authorize=provision.authorize, consent=provision.consent, proof=provision.proof,
tribes={{key=prefix..":"..tribe.key,now=seconds,catalog=Job.catalog(content),definitions=definitions,
acceptedMembers=provision.acceptedMembers,verifyPlacement=ports.verify,publish=ports.publish,
initial={settlement=Settlement.new(tribe.config,provision.ownerId),
warehouse=Inventory.new(tribe.warehouseId,{slots=20,softWeightMilli=60000,hardWeightMilli=90000})},
verifyTransfer=function(actor,proof) if provision.verifyTransfer(actor,proof) and ports.warehouse(actor) then return true end return false end,
workshop={content=content,revision=tribe.workshopRevision,verifyStation=function(actor,id,state)
local spatial=world.services.survivalSpatial
local station=if spatial then spatial.station(actor,id) else nil
if not station or not station.reachable then return nil end
return {carriedContainer=state.warehouse.id,stationId=id,stationKind=station.kind,inReach=true}
end}}}}},world,backend,options)
end
]]
	files["src/server/SurvivalWorldBootstrap.luau"] = [[--!strict
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local CollectionService = game:GetService("CollectionService")
local World = require(Forge.genres["survival-coop"].module.SurvivalWorld)
return function(content, source, wildlifePolicy, epochMillis)
local geometry = Instance.new("Folder")
geometry.Name, geometry.Parent = "DevelopmentIsland", workspace
local function part(name: string, size: Vector3, position: Vector3, color: Color3, className: string?): BasePart
local value: BasePart = if className=="WedgePart" then Instance.new("WedgePart") else Instance.new("Part")
value.Name, value.Anchored, value.Size, value.Position = name, true, size, position
value.Color, value.TopSurface, value.BottomSurface = color, Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
value.Parent = geometry
return value
end
part("IslandFloor",Vector3.new(64,2,48),Vector3.new(0,-1,8),Color3.fromRGB(90,112,72))
local warehouse:{x:number,y:number,z:number}=source.tribe.warehousePosition
part("WarehouseApproach",Vector3.new(12,2,16),Vector3.new(warehouse.x,-1,warehouse.z+4),Color3.fromRGB(90,112,72))
local marker=part("Warehouse",Vector3.new(3,2,2),Vector3.new(warehouse.x+3,1,warehouse.z),Color3.fromRGB(116,77,45))
marker:SetAttribute("ForgeWarehouseTribe",source.tribe.config.tribeId)
local spawn = Instance.new("SpawnLocation")
spawn.Name, spawn.Anchored, spawn.Position, spawn.Size = "SurvivalSpawn", true, Vector3.new(0,0.5,0), Vector3.new(4,1,4)
spawn.Neutral, spawn.Duration, spawn.Parent = true, 0, geometry
local world = World.new({content=content,worldRevision=source.worldRevision,spawn=spawn,carriedContainer="bag",reachStuds=8,baseWalkSpeed=16,
wildlife=if wildlifePolicy then {catalog=wildlifePolicy.catalog,spawns=wildlifePolicy.spawns,maximum=wildlifePolicy.maximum,nowMillis=assert(epochMillis,"WILDLIFE_CLOCK_REQUIRED")} else nil,
respawnValues={healthMilli=100000,hungerMilli=50000,fatigueMilli=0}})
local campfire=part("campfire",Vector3.new(3,1,3),Vector3.new(-6,0.5,0),Color3.fromRGB(185,89,39))
local bench=part("workbench",Vector3.new(4,2,2),Vector3.new(6,1,0),Color3.fromRGB(116,77,45))
world.registerStation(campfire,"campfire","campfire")
world.registerStation(bench,"workbench","workbench")
for _, node in source.nodes do
local position=Vector3.new(node.position.x,node.position.y,node.position.z)
local shape
if node.catalogId=="fallen-tree" then
shape=part(node.id,Vector3.new(6,2,2),position,Color3.fromRGB(105,70,42))
local log=shape :: Part
log.Shape=Enum.PartType.Cylinder
elseif node.catalogId=="flint-outcrop" then
shape=part(node.id,Vector3.new(4,4,3),position,Color3.fromRGB(88,96,110),"WedgePart")
elseif node.catalogId=="fiber-bush" then
shape=part(node.id,Vector3.new(1,4,2),position,Color3.fromRGB(154,163,80))
part(node.id.."-blade",Vector3.new(3,3,0.5),position,Color3.fromRGB(130,147,63))
elseif node.catalogId=="berry-bush" then
shape=part(node.id,Vector3.new(4,4,4),position,Color3.fromRGB(49,112,59))
local bush=shape :: Part
bush.Shape=Enum.PartType.Ball
local berries=part(node.id.."-berries",Vector3.new(1.5,1.5,1.5),position+Vector3.new(0,1,-1.5),Color3.fromRGB(145,45,81))
local fruit=berries :: Part
fruit.Shape,fruit.CanCollide,fruit.CanQuery=Enum.PartType.Ball,false,false
else
shape=part(node.id,Vector3.new(3,2,3),position,Color3.fromRGB(155,75,62))
part(node.id.."-bone",Vector3.new(4,0.5,0.5),position+Vector3.new(0,1.25,0),Color3.fromRGB(229,219,185))
end
world.registerNode(shape,node.id,node.catalogId,0,source.worldRevision)
end
-- Approach the nodes from z=8 for clear reach; the wall blocks the berry lane.
part("GatherLOSWall",Vector3.new(6,7,1),Vector3.new(10,3.5,10),Color3.fromRGB(111,112,105))
local roof=part("CameraTestRoof",Vector3.new(12,1,8),Vector3.new(-16,9,0),Color3.fromRGB(116,77,45))
CollectionService:AddTag(roof,"ForgeCameraOccluder")
return world
end
]]
	local source, count = string.gsub(
		files[path],
		"Server%.start%({",
		[[local HttpService=game:GetService("HttpService")
local RunService=game:GetService("RunService")
local Clock=require(Forge.core.infra.genre.Clock)
local content=require(Shared.SurvivalContent)
local source=require(Shared.SurvivalWorldConfig)
local wildlifePolicy=require(Shared.WildlifePolicy)
-- The provisioning policy is guarded by the environment: `studio` is true only for a local Studio
-- place with no published experience id, so a published server can never select the permissive path.
local provision=require(script.Parent.SurvivalProvision)(require(script.Parent.SurvivalProvisionConfig),source.tribe.config.tribeId,{studio=RunService:IsStudio() and game.PlaceId==0})
local clock=Clock.new(function() return DateTime.now().UnixTimestampMillis/1000 end)
local backend=RuntimeBackend.new(require(script.Parent.PersistenceConfig),"SurvivalShared")
local world=require(script.Parent.SurvivalWorldBootstrap)(content,source,wildlifePolicy,function() return Clock.millis(clock.now()) end)
local factory,err=require(script.Parent.SurvivalFactory)(content,source,world,backend,clock,{
sessionId=game.JobId..HttpService:GenerateGUID(false),leaseSeconds=120,
now=function() return math.floor(DateTime.now().UnixTimestampMillis/1000) end,
budget={encode=function(value) return HttpService:JSONEncode(value) end}},provision,wildlifePolicy)
assert(factory,err)
Server.start({backend=backend,clock=clock,starterWorld=false,lifecycle={bind=factory.bind,close=factory.close},services=factory.services,durable=require(Shared.GenreDurable),]],
		1
	)
	assert(count == 1, "crafting server bootstrap binding missing")
	-- The generic bootstrap backend must not allocate a second owner/store.
	source = string.gsub(
		source,
		'backend=RuntimeBackend%.new%(require%(script%.Parent%.PersistenceConfig%),"[^"\n]+"%),',
		"",
		1
	)
	files[path] = source
	local game = serde.decode("yaml", files["game.yml"])
	game.generated_by ..= " --mode crafting"
	game.runtime_mode = "crafting"
	game.qa_scenarios = { "survival-coop:bootstrap-crafting" }
	game.capability_tier = "starter"
	game.developmental = true
	game.pending_capabilities = Capability.missingFeatures("crafting")
	files["game.yml"] = serde.encode("yaml", game)
	-- The real owner is recorded in the pack's own staging publication record, so the deployed
	-- staging place carries the same owner the runtime provision names. Core never hardcodes it.
	if stagingOwner ~= nil and files["deploy.yml"] ~= nil then
		local deploy = serde.decode("yaml", files["deploy.yml"])
		if
			type(deploy) == "table"
			and type(deploy.environments) == "table"
			and type(deploy.environments.staging) == "table"
		then
			deploy.environments.staging.ownerUserId = stagingOwner
			files["deploy.yml"] = serde.encode("yaml", deploy)
		end
	end
	local core = project.relative(destination .. "/smoke", project.coreRoot(registry))
	local genre = project.relative(destination .. "/smoke", registry.packages["survival-coop"].path)
	files["smoke/smoke.luau"] = string.format(
		[[--!strict
local Session = require(%q)
local MemoryBackend = require(%q)
local Contract = require(%q)
local serde = require("@lune/serde")
local pack = require("../src/shared/GenreConfig")
local policy = require("../src/shared/GenreDurable")
return { run = function(_fixture: string?)
-- Native smoke has no character Instances; keep engine-only death disabled here.
local nativePack = serde.decode("json",serde.encode("json",pack))
nativePack.configs["survival-coop"].survivalDeath = false
local now = 1000
local session = Session.new({
packConfig=nativePack,
contracts={Contract},
controls={},
storeName="crafting-smoke",
durable=policy,
}, MemoryBackend.new(),
{sessionId="smoke",lockTimeout=120,retries=0,now=function() return now end},
{now=function() return now end,roll=function() return 0 end,emit=function() end,encode=function(value) return serde.encode("json",value) end},policy)
assert(session.join("1").ok,"join")
local function command(request, action, args)
return session.command("1",{
requestId=request,
sessionEpoch=session.commandEpoch("1"),
action="survival-coop:"..action,
args=args,
})
end
local reserved=command("reserve","craft-reserve",{"cord","hand"})
assert(reserved.ok,tostring(reserved.reason))
local job=assert(reserved.data).jobId
assert(command("start","craft-start",{job}).ok,"start")
now+=4
assert(command("complete","craft-complete",{job}).ok,"complete")
local state=session.snapshot("1")["survival-coop"]
assert(state.workshop.entries[job].job.state=="Committed","committed job")
assert(state.inventory.bag.items["starter-fiber"].quantity==9,"single ingredient debit")
assert(state.vitals~=nil,"configured vitals")
assert(session.close("1").ok,"close")
return {{name="native personal crafting commit",ok=true}}
end }
]],
		core .. "/infra/genre/Session",
		core .. "/infra/data/MemoryBackend",
		genre .. "/module/Contract"
	)
	-- Match provisioning's assembly-time preservation semantics. Publication
	-- writes these bytes and formats them; it does not replace authored behavior.
	-- Factory, durable policy and canonical content remain generated contracts.
	for _, authoredPath in
		{
			path,
			clientPath,
			"src/server/SurvivalWorldBootstrap.luau",
			"src/shared/AudioConfig.luau",
			"assets/audio.yml",
		}
	do
		if fs.isFile(destination .. "/" .. authoredPath) then
			files[authoredPath] = fs.readFile(destination .. "/" .. authoredPath)
		end
	end
end
return M
