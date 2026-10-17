--!strict
local fs = require("@lune/fs")
local tempdir = require("./tempdir")
local process = require("@lune/process")
local serde = require("@lune/serde")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local engineTypes: any = roblox
local new = require("../commands/new")
local generate = require("./genregenerate")
local publish = require("./genrepublish")
local registryLib = require("./genreregistry")
local crafting = require("./craftinggenerate")
local Content = require("../../../core/domain/survival/Content")
local Gathering = require("../../../genres/survival-coop/module/Gathering")
local Wildlife = require("../../../genres/survival-coop/module/Wildlife")
local Bootstrap = require("../../../genres/survival-coop/module/SurvivalBootstrap")
local Session = require("../../../core/infra/genre/Session")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Clock = require("../../../core/infra/genre/Clock")
local Settlement = require("../../../core/domain/settlement/Settlement")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Job = require("../../../core/domain/crafting/Job")
local Options = require("../../../core/infra/genre/Options")
local Survival = require("../../../genres/survival-coop/module/Contract")
local contract = require("./genrecontract")
local codegen = require("./codegen")
local checkCommand = require("../commands/check")
local qaCommand = require("../commands/qa")
local qaharness = require("./qaharness")
local dynamicRequire = require :: any

-- On POSIX the temp root may be a symlink (/tmp -> /private/tmp, /var -> /private/var); rojo and require()
-- resolve ".." physically, so the relative paths generated for the fixture only work from the real path.
local function physicalRoot(): string
	local root = tempdir.root()
	if process.os == "windows" then
		return root
	end
	local resolved = process.exec("/bin/sh", { "-c", 'cd "$1" && pwd -P', "sh", root })
	assert(resolved.ok, "cannot resolve temp root: " .. resolved.stderr)
	return (string.gsub(resolved.stdout, "%s+$", ""))
end

return {
	["crafting new writes validated runtime data and rejects unsupported input before writes"] = function()
		local root = generate.absolute(
			physicalRoot() .. "/forge-crafting-new-" .. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
		)
		local context = { packsDir = root }
		local ok, reason = xpcall(function()
			for _, args in
				{
					{ "new", "invalid", "--genre", "survival-coop", "--mode", "unknown" },
					{ "new", "invalid", "--genre", "grow-harvest", "--mode", "crafting" },
					{ "new", "invalid", "--genre", "survival-coop,grow-harvest", "--mode", "crafting" },
					{ "new", "invalid", "--genre", "survival-coop", "--mode", "crafting", "--mode", "crafting" },
				}
			do
				assert(not new.run(args, context), "unsupported mode/composition accepted")
				assert(not fs.isDir(root), "rejection must precede every write")
			end
			assert(
				new.run({ "new", "fixture-crafting", "--genre", "survival-coop", "--mode", "crafting" }, context),
				"actual forge new"
			)
			local dir = root .. "/fixture-crafting"
			local raw = serde.decode("yaml", fs.readFile(dir .. "/content.yml"))
			assert(#Content.validate(raw) == 0, "content validates")
			local canonical = assert(Content.canonicalize(raw))
			assert(
				#canonical.nodes == 5
					and #canonical.recipes == 12
					and #canonical.wildlife == 2
					and #canonical.structures == 4,
				"development catalog scope"
			)
			local pack = serde.decode("yaml", fs.readFile(dir .. "/econ.yml")).genre_contract
			local codegenRegistry = assert(registryLib.discover())
			local generatedName, generatedSource =
				codegen.generateDocument(fs.readFile(dir .. "/econ.yml"), codegenRegistry)
			assert(generatedName == "GenreConfig.luau", "same codegen target")
			assert(#generatedSource > 0, "codegen source must not be empty")
			local roundtripPack = luau.load(generatedSource)()
			assert(type(roundtripPack) == "table", "generated config returns a pack")
			local roundtripErrors = Survival.validateConfig(roundtripPack.configs[Survival.id])
			assert(#roundtripErrors == 0, table.concat(roundtripErrors, "; "))
			local shippedSource = fs.readFile(dir .. "/src/shared/GenreConfig.luau")
			assert(generatedSource == shippedSource, "codegen roundtrip bytes")
			local configErrors = Survival.validateConfig(pack.configs[Survival.id])
			assert(#configErrors == 0, table.concat(configErrors, "; "))
			assert(
				contract.serialize(pack.configs[Survival.id].inventory.content) == contract.serialize(raw),
				"same content source"
			)
			local decoded = luau.load(fs.readFile(dir .. "/src/shared/SurvivalContent.luau"))()
			local worldConfig = luau.load(fs.readFile(dir .. "/src/shared/SurvivalWorldConfig.luau"))()
			local wildlifePolicy = luau.load(fs.readFile(dir .. "/src/shared/WildlifePolicy.luau"))()
			local audioAssets = { ["survival-coop-gather"] = "rbxassetid://123" }
			local audioConfig = luau.load(fs.readFile(dir .. "/src/shared/AudioConfig.luau"), {
				environment = {
					require = function(module)
						assert(module == "./Assets", "audio resolves generated asset bindings")
						return audioAssets
					end,
				},
			})()
			assert(audioConfig.assets == audioAssets, "audio uses publication bindings")
			local audioRecipes = serde.decode("yaml", fs.readFile(dir .. "/assets/audio.yml"))
			local audioKeys = {}
			for _, cue in audioRecipes.cues do
				audioKeys[cue.key] = true
			end
			for _, cue in { "gather", "craft", "eat", "hit", "rest", "ambient" } do
				assert(
					string.sub(audioConfig.cues[cue].asset, 1, 14) == "survival-coop-",
					"genre-owned audio namespace"
				)
				assert(audioKeys[audioConfig.cues[cue].asset], "every mounted cue has a generation recipe")
			end
			assert(
				Wildlife.catalog(decoded, wildlifePolicy.catalog).weapons.spear.rangeStuds == 8,
				"canonical generated combat policy"
			)
			local nodes = Gathering.new(worldConfig.worldRevision, decoded, worldConfig.nodes)
			local workspace = roblox.Instance.new("Workspace")
			local registered: { [string]: any } = {}
			local stations = {}
			local occluders = {}
			local bootstrap = luau.load(fs.readFile(dir .. "/src/server/SurvivalWorldBootstrap.luau"), {
				environment = {
					Instance = roblox.Instance,
					Vector3 = engineTypes.Vector3,
					Color3 = engineTypes.Color3,
					Enum = engineTypes.Enum,
					workspace = workspace,
					require = function(value)
						return value
					end,
					game = {
						GetService = function(_, service): any
							if service == "CollectionService" then
								return {
									AddTag = function(_, part, tag)
										occluders[tag] = part
									end,
								}
							end
							return {
								WaitForChild = function()
									return {
										genres = {
											["survival-coop"] = {
												module = {
													SurvivalWorld = {
														new = function(config)
															assert(
																config.reachStuds == 8
																	and config.worldRevision == nodes.worldRevision,
																"world reach and revision"
															)
															return {
																registerStation = function(part, id, kind)
																	stations[id] = { part = part, kind = kind }
																end,
																registerNode = function(
																	part,
																	id,
																	kind,
																	version,
																	revision
																)
																	local node = assert(
																		nodes.nodes[id],
																		"registered source node"
																	)
																	assert(
																		kind == node.catalogId
																			and version == nodes.version
																			and revision == nodes.worldRevision,
																		"registered identity"
																	)
																	assert(
																		part.Anchored and part:IsDescendantOf(workspace),
																		"anchored world geometry"
																	)
																	assert(
																		part.Position
																			== engineTypes.Vector3.new(
																				node.position.x,
																				node.position.y,
																				node.position.z
																			),
																		"exact source position"
																	)
																	assert(
																		next(part:GetAttributes()) == nil,
																		"generator must not put authority on Parts"
																	)
																	registered[id] = part
																end,
															}
														end,
													},
												},
											},
										},
									}
								end,
							}
						end,
					},
				},
			})()
			bootstrap(decoded, worldConfig)
			local geometry = assert(workspace:FindFirstChild("DevelopmentIsland"))
			assert(
				geometry:FindFirstChild("IslandFloor") and geometry:FindFirstChild("SurvivalSpawn"),
				"floor and spawn"
			)
			assert(stations.campfire and stations.workbench and occluders.ForgeCameraOccluder, "stations and roof")
			local wall = assert(geometry:FindFirstChild("GatherLOSWall")) :: any
			assert(wall.CanCollide and wall.CanQuery and wall.Position.Z == 10, "blocking LOS wall")
			local signatures = {}
			for _, node in worldConfig.nodes do
				local part = assert(registered[node.id], "every source node registered")
				local approach = engineTypes.Vector3.new(node.position.x, 2, 8)
				assert((part.Position - approach).Magnitude < 8, "reachable approach")
				local signature = part.ClassName .. tostring(part.Size)
				assert(not signatures[signature], "distinctive node geometry")
				signatures[signature] = true
			end
			assert(
				decoded.vitals.hungerMillisPerUnit == 18000 and decoded.items[1].foodEffects ~= nil,
				"generated vital and food data"
			)
			local game = serde.decode("yaml", fs.readFile(dir .. "/game.yml"))
			assert(
				game.capability_tier == "starter" and game.developmental and #game.qa_scenarios == 1,
				"no wave scenarios or quality claim"
			)
			assert(
				type(game.pending_capabilities) == "table"
					and table.find(game.pending_capabilities, "gathering") == nil
					and table.find(game.pending_capabilities, "crafting-jobs") == nil
					and table.find(game.pending_capabilities, "wildlife") ~= nil,
				"pending capabilities omit implemented gathering and keep wildlife"
			)
			local contractErrors = checkCommand.validatePackContract(game, { genre_contract = pack }, codegenRegistry)
			assert(#contractErrors == 0, table.concat(contractErrors, "; "))
			local entries, selectionErrors = qaCommand.planPack("fixture-crafting", game, codegenRegistry)
			assert(#selectionErrors == 0 and #entries == 1, table.concat(selectionErrors, "; "))
			local selected = entries[1].scenario
			local nativeTarget = assert(qaCommand.loadTarget("fixture-crafting", codegenRegistry, context))
			local outcome = qaharness.runNative(selected, nativeTarget)
			assert(outcome.ok and outcome.assertions >= 7, table.concat(outcome.failures, "; "))
			assert(
				qaCommand.run(
					{ "qa", "run", "--pack", "fixture-crafting", "--scenario", "bootstrap-crafting", "--native" },
					context
				),
				"actual generated pack CLI scenario"
			)
			assert(pack.configs[Survival.id].survivalDeath == true, "generated engine death integration enabled")
			local policy = luau.load(fs.readFile(dir .. "/src/shared/GenreDurable.luau"))()
			for _, action in selected.data.durable.actions do
				assert(table.find(policy.actions, action), "bootstrap QA action remains durable")
			end
			assert(
				table.find(policy.actions, "survival-coop:attack"),
				"wildlife action enabled in generated server policy"
			)
			local controls = luau.load(fs.readFile(dir .. "/src/shared/GenreUI.luau"))()
			Options.validate({
				packConfig = pack,
				contracts = { Survival },
				controls = controls,
				storeName = "fixture",
				durable = policy,
			})
			local captured: any = nil
			local bound = false
			local active: any = nil
			local now = 1000
			local published: any = nil
			local wildlifePublished: any = nil
			local stationReachable = true
			local engine: any = {
				wildlifeAccess = function(actor, _target)
					local state = active.snapshot(actor)[Survival.id]
					local equipped = {}
					for id, item in state.inventory.bag.items do
						if item.catalogId == "spear" then
							equipped[id] = true
						end
					end
					return {
						actorId = actor,
						alive = state.vitals.healthMilli > 0,
						position = { x = 0, y = 0, z = 0 },
						facing = { x = 1, y = 0, z = 0 },
						targetPosition = { x = 4, y = 0, z = 0 },
						lineOfSight = true,
						equipped = equipped,
					}
				end,
				publishWildlife = function(value)
					wildlifePublished = value
				end,
				services = {
					survivalSpatial = {
						campfire = function()
							return nil
						end,
						station = function(_, id)
							return if id == "workbench"
								then { kind = "workbench", reachable = stationReachable }
								else nil
						end,
					},
				},
				bind = function(value)
					active = value
					bound = true
				end,
				destroy = function() end,
				publishNodes = function(value)
					published = value
				end,
				gatheringAccess = function(authorize)
					return function(request, bag)
						assert(authorize(active, request, bag), "actual admission")
						return {
							actorId = request.actorId,
							carriedContainer = bag.id,
							worldRevision = worldConfig.worldRevision,
							equipment = function()
								return {}
							end,
							reachable = function()
								return true
							end,
						}
					end
				end,
			}
			local forge = {
				genres = {
					["survival-coop"] = {
						module = { SurvivalBootstrap = Bootstrap, Gathering = Gathering, Wildlife = Wildlife },
					},
				},
				core = {
					["ui-kit"] = { Components = {}, InventoryGrid = {}, Theme = {} },
					domain = {
						settlement = { Settlement = Settlement },
						inventory = { Inventory = Inventory },
						crafting = {
							Job = Job,
						},
					},
					infra = {
						data = {
							MemoryBackend = Memory,
							DataStoreBackend = {},
							RuntimeBackend = {
								new = function()
									return Memory.new()
								end,
							},
						},
						genre = {
							Clock = Clock,
							Server = {
								start = function(options)
									captured = options
									local services = table.clone(options.services)
									services.now = options.clock.now
									services.encode = function(value)
										return serde.encode("json", value)
									end
									services.roll = function()
										return 0
									end
									services.emit = function() end
									local native = serde.decode("json", serde.encode("json", options.packConfig))
									native.configs[Survival.id].survivalDeath = false
									local settings = table.clone(options)
									settings.packConfig = native
									local session = Session.new(settings, options.backend, {
										sessionId = "personal",
										lockTimeout = 120,
										retries = 0,
										now = options.clock.now,
									}, services, policy)
									options.lifecycle.bind(session)
									return session
								end,
							},
						},
					},
				},
				games = {
					["fixture-crafting"] = {
						src = {
							shared = {
								GenreDurable = policy,
								GenreConfig = pack,
								GenreRuntime = { Survival },
								GenreUI = controls,
								AudioConfig = audioConfig,
								SurvivalContent = decoded,
								SurvivalWorldConfig = worldConfig,
								WildlifePolicy = wildlifePolicy,
							},
						},
					},
				},
			}
			local environment: any = {
				Vector3 = engineTypes.Vector3,
				DateTime = {
					now = function()
						return { UnixTimestampMillis = now * 1000 }
					end,
				},
				game = {
					JobId = "native",
					-- A local Studio place: no published experience id. This is the environment the
					-- provisioning policy's Studio guard reads, so the fixture stands in a Studio place.
					PlaceId = 0,
					GetService = function(_, name): any
						if name == "RunService" then
							return {
								IsStudio = function()
									return true
								end,
							}
						end
						if name == "HttpService" then
							return {
								GenerateGUID = function()
									return "factory"
								end,
								JSONEncode = function(_, value)
									return serde.encode("json", value)
								end,
							}
						end
						return {
							WaitForChild = function()
								return forge
							end,
						}
					end,
				},
				script = {
					Parent = {
						PersistenceConfig = { mode = "memory" },
						GenreHooks = {},
						SurvivalProvisionConfig = {
							provisionId = "local",
							-- The developmental policy: a closed Studio QA allowlist, guarded by the environment the
							-- server passes in (a local Studio place with no published experience id).
							policy = "developmental",
							ownerId = "-1",
							acceptedInvitations = { ["-2"] = true },
							actors = {},
						},
						SurvivalWorldBootstrap = function(content, source)
							assert(content == decoded, "canonical content passed to world")
							assert(source == worldConfig, "node source passed to world")
							return engine
						end,
					},
				},
				require = function(value)
					return value
				end,
			}
			for _, name in { "SurvivalFactory", "SurvivalProvision" } do
				environment.script.Parent[name] =
					luau.load(fs.readFile(dir .. "/src/server/" .. name .. ".luau"), { environment = environment })()
			end
			-- A developmental pack is admitted only in a local Studio place, and there it admits the
			-- actors the server routes; the same record on a published server admits nobody it does
			-- not name. Both halves of that guard are asserted here.
			local localPolicy = environment.script.Parent.SurvivalProvision({
				provisionId = "local",
				policy = "developmental",
				ownerId = "",
				acceptedInvitations = {},
				actors = {},
			}, "camp", { studio = true })
			assert(localPolicy.ownerId == "-1", "the local policy owns the settlement")
			assert(localPolicy.tribeFor("12345") == "camp", "the local policy routes a joining actor in Studio")
			-- Routing grants no membership: the consent record is complete before the settlement runtime
			-- acquires its store, so an actor the record does not name is authorized but not a member.
			-- The previous contract appended arriving actors to a list the settlement had already
			-- consumed, which is why a real user id could gather but never use settlement storage.
			assert(
				table.find(localPolicy.acceptedMembers, "12345") == nil,
				"routing must not mutate the membership the settlement consumed"
			)
			assert(
				localPolicy.authorize("12345", "survival-coop:craft-reserve", {}, "client").ok == true,
				"a routed actor is authorized"
			)
			assert(localPolicy.proof("12345") ~= nil, "a routed actor has a proof")
			assert(
				localPolicy.authorize("12345", "survival-coop:settlement-invite", {}, "client").ok == false,
				"invite stays server-only"
			)
			local publishedPolicy = environment.script.Parent.SurvivalProvision({
				provisionId = "local",
				policy = "developmental",
				ownerId = "",
				acceptedInvitations = {},
				actors = {},
			}, "camp", { studio = false })
			assert(
				publishedPolicy.tribeFor("12345") == nil
					and publishedPolicy.authorize("12345", "survival-coop:craft-reserve", {}, "client").ok == false,
				"a published server admits no actor the record does not name"
			)
			local provisionConfig = environment.script.Parent.SurvivalProvisionConfig
			for _, invalid in { "01", "0", "-0", "1.5", "1e3", "9007199254740992" } do
				local bad = table.clone(provisionConfig)
				bad.policy, bad.ownerId = "staging", invalid
				assert(
					not pcall(environment.script.Parent.SurvivalProvision, bad, "camp", { studio = true }),
					"canonical owner required"
				)
			end
			local badPolicy = table.clone(provisionConfig)
			badPolicy.policy = nil
			assert(
				not pcall(environment.script.Parent.SurvivalProvision, badPolicy, "camp", { studio = true }),
				"an unstated policy is refused rather than inferred"
			)
			local badConsent = table.clone(provisionConfig)
			badConsent.acceptedInvitations = { [1] = true }
			assert(
				not pcall(environment.script.Parent.SurvivalProvision, badConsent, "camp", { studio = true }),
				"consent record keys are user ids"
			)
			local warehouseReachable, placementReachable = true, true
			local settlementPublished
			engine.settlementPorts = function(origin, warehouse)
				assert(
					origin.X == worldConfig.tribe.origin.x and warehouse.Z == -22,
					"origin.X == worldConfig.tribe.origin.x and warehouse.Z == -22"
				)
				return {
					warehouse = function()
						return warehouseReachable
					end,
					verify = function()
						return placementReachable
					end,
					publish = function(value)
						settlementPublished = value
					end,
				}
			end
			local authority = environment.script.Parent.SurvivalProvision(provisionConfig, "camp", { studio = true })
			assert(
				table.find(authority.acceptedMembers, "-2") ~= nil,
				"an accepted invitation is a member before acquisition"
			)
			local proof = serde.decode("json", serde.encode("json", authority.proof("-1")))
			local reopenedAuthority =
				environment.script.Parent.SurvivalProvision(provisionConfig, "camp", { studio = true })
			assert(reopenedAuthority.verifyTransfer("-1", proof), "proof survives serialization and provider restart")
			luau.load(
				fs.readFile(dir .. "/src/server/FixtureCraftingServer.server.luau"),
				{ environment = environment }
			)()
			assert(captured and captured.durable == policy, "server actually forwards durable policy")
			assert(
				bound and captured.services.survivalGathering and captured.starterWorld == false,
				"factory bound before joins without starter collision"
			)
			Options.validate(captured)
			assert(active.join("-1").ok and active.join("-2").ok, "two real actors")
			assert(
				active.commandEpoch("-2", "survival-coop:transfer-deposit") == 0,
				"accepted provisioning activates durable membership"
			)
			assert(active.commandEpoch("-2", "survival-coop:settlement-reserve") == 0, "accepted member can build")
			local function command(actor: string, id: string, action: string, args: { any }, server: boolean?)
				local request = {
					requestId = id,
					sessionEpoch = active.commandEpoch(actor, "survival-coop:" .. action),
					action = "survival-coop:" .. action,
					args = args,
				}
				local result = if server then active.commandServer(actor, request) else active.command(actor, request)
				if not result.ok and not server then
					assert(active.recoverTransfers(actor, 16).ok, "transfer recovery")
					result = active.command(actor, request)
				end
				assert(result.ok, tostring(result.reason))
				return result
			end
			assert(
				captured.services.survivalWildlife and wildlifePublished["hunter-01"],
				"generated runtime bound and published"
			)
			command("-1", "spear-wood", "gather", { "fallen-tree-01", 0 })
			local spearJob = command("-1", "spear-reserve", "craft-reserve", { "spear", "hand" }).data.jobId
			command("-1", "spear-start", "craft-start", { spearJob })
			now += 3
			command("-1", "spear-complete", "craft-complete", { spearJob })
			for hit = 1, 3 do
				command("-1", "attack-" .. hit, "attack", { "hunter-01" })
				now += 2
			end
			assert(wildlifePublished["hunter-01"].healthMilli == 0, "confirmed lethal source published")
			local meat = 0
			for _, item in active.snapshot("-1")[Survival.id].inventory.bag.items do
				if item.catalogId == "meat" then
					meat += item.quantity
				end
			end
			assert(meat == 3, "actual generated Session durable loot")
			local npcState = Wildlife.new("hunter-test", "hunter", { x = 0, y = 0, z = 0 }, wildlifePolicy.catalog)
			local hunterDefinition
			for _, definition in decoded.wildlife do
				if definition.id == "hunter" then
					hunterDefinition = definition
				end
			end
			local observation = {
				position = { x = 0, y = 0, z = 0 },
				actors = { { id = "-2", alive = true, position = { x = 3, y = 0, z = 0 } } },
				pathFailed = false,
				lineOfSight = function()
					return true
				end,
			}
			npcState = Wildlife.step(
				npcState,
				hunterDefinition,
				wildlifePolicy.catalog.species.hunter,
				now * 1000,
				observation
			)
			npcState = Wildlife.step(
				npcState,
				hunterDefinition,
				wildlifePolicy.catalog.species.hunter,
				now * 1000 + 1000,
				observation
			)
			local _, intent = Wildlife.step(
				npcState,
				hunterDefinition,
				wildlifePolicy.catalog.species.hunter,
				now * 1000 + 2000,
				observation
			)
			local strike = assert(intent.damage, "actual wildlife strike intent")
			local before = active.snapshot("-2")[Survival.id].vitals.healthMilli
			command(strike.actorId, "npc:" .. strike.strikeId, "vitals-damage", { strike.damageMilli }, true)
			assert(
				active.snapshot("-2")[Survival.id].vitals.healthMilli == before - 10000,
				"generated actual Session NPC vitals damage"
			)
			for index, actor in { "-1", "-2" } do
				command(actor, "gather", "gather", { "fallen-tree-01", index })
				local itemId
				for id, item in active.snapshot(actor)[Survival.id].inventory.bag.items do
					if item.catalogId == "wood" then
						itemId = id
					end
				end
				warehouseReachable = false
				local refused = active.command(actor, {
					requestId = "far-deposit",
					sessionEpoch = active.commandEpoch(actor, "survival-coop:transfer-deposit"),
					action = "survival-coop:transfer-deposit",
					args = { assert(itemId, "deposit target item id resolves"), 3 },
				})
				assert(not refused.ok and refused.reason == "UNAUTHORIZED", "generated warehouse reach wired")
				warehouseReachable = true
				command(actor, "deposit", "transfer-deposit", { assert(itemId, "gathered wood"), 3 })
			end
			assert(
				published.version == 3 and published.nodes["fallen-tree-01"].charges == 0,
				"confirmed source published"
			)
			local function state()
				return active.snapshot("-1").survivalSettlement
			end
			local function craftArgs(a, b)
				local s = state()
				return { a, b, s.settlement.version, s.warehouse.version, s.settlement.membershipRevision }
			end
			local function deniedStation(id: string, stationId: string)
				local action = "survival-coop:settlement-workshop-reserve"
				local result = active.command("-2", {
					requestId = id,
					sessionEpoch = active.commandEpoch("-2", action),
					action = action,
					args = craftArgs("plank", stationId),
				})
				assert(not result.ok, "invalid station cannot reserve materials")
			end
			stationReachable = false
			deniedStation("far-station", "workbench")
			stationReachable = true
			deniedStation("forged-station", "unregistered-workbench")
			local crafted = command("-2", "reserve", "settlement-workshop-reserve", craftArgs("plank", "workbench"))
			local job = crafted.data.jobId
			command("-2", "start", "settlement-workshop-start", craftArgs(job, "-2"))
			now += 3
			command("-2", "complete", "settlement-workshop-complete", craftArgs(job, "-2"))
			local s = state()
			placementReachable = false
			local reserveArgs: { any } = {
				"campfire",
				4,
				4,
				0,
				s.settlement.version,
				s.warehouse.version,
				s.settlement.membershipRevision,
			}
			local deniedBuild = active.command("-1", {
				requestId = "far-build",
				sessionEpoch = active.commandEpoch("-1", "survival-coop:settlement-reserve"),
				action = "survival-coop:settlement-reserve",
				args = reserveArgs,
			})
			assert(deniedBuild.reason == "PLACEMENT_UNREACHABLE", "generated placement verifier wired")
			placementReachable = true
			local reservation = command(
				"-1",
				"build",
				"settlement-reserve",
				{ "campfire", 4, 4, 0, s.settlement.version, s.warehouse.version, s.settlement.membershipRevision }
			)
			s = state()
			command(
				"-1",
				"place",
				"settlement-place",
				{ reservation.data.reservationId, s.settlement.version, s.warehouse.version }
			)
			s = state()
			assert(
				settlementPublished.structures["camp:" .. reservation.data.reservationId],
				"confirmed building published"
			)
			command("-1", "kick", "settlement-kick", { "-2", s.settlement.version, s.settlement.membershipRevision })
			assert(authority.tribeFor("-2") == "camp", "revoked actor retains trusted recovery route")
			assert(active.commandEpoch("-2", "survival-coop:transfer-deposit") == nil, "revocation denies new deposits")
			assert(active.commandEpoch("-2", "survival-coop:settlement-reserve") == nil, "revocation denies new builds")
			assert(active.recoverTransfers("-2", 16).ok, "revoked actor recovery remains available")
			active.advance(now)
			assert(active.close("-1").ok and active.close("-2").ok, "personal close")
			assert(captured.lifecycle.close().ok, "shared factory release")
			local fresh = Memory.new()
			local prefix = worldConfig.persistencePrefix .. ":local:"
			for _, key in
				{
					"personal:-1",
					"personal:-2",
					prefix .. worldConfig.sourceKey,
					prefix .. worldConfig.tribe.key,
					prefix .. wildlifePolicy.sourceKey,
				}
			do
				local loaded, value = captured.backend.update(key, function(old)
					return old
				end)
				assert(loaded and value, "persisted generated owner")
				local encoded = serde.decode("json", serde.encode("json", value))
				fresh.update(key, function()
					return encoded
				end)
			end
			local rebuilt =
				assert(environment.script.Parent.SurvivalFactory(decoded, worldConfig, engine, fresh, captured.clock, {
					sessionId = "rejoin",
					leaseSeconds = 120,
					now = function()
						return math.floor(now)
					end,
					budget = {
						encode = function(value)
							return serde.encode("json", value)
						end,
					},
				}, authority, wildlifePolicy))
			local rejoinOptions = table.clone(captured)
			rejoinOptions.backend, rejoinOptions.lifecycle, rejoinOptions.services =
				fresh, { bind = rebuilt.bind, close = rebuilt.close }, rebuilt.services
			local reopened = forge.core.infra.genre.Server.start(rejoinOptions)
			assert(reopened.join("-1").ok and reopened.join("-2").ok, "two actual Session JSON rejoins")
			assert(
				reopened.commandEpoch("-2", "survival-coop:transfer-deposit") == nil,
				"restart does not reinvite kicked member"
			)
			assert(wildlifePublished["hunter-01"].healthMilli == 0, "durable NPC death survives JSON restart")
			local restoredMeat = 0
			for _, item in reopened.snapshot("-1")[Survival.id].inventory.bag.items do
				if item.catalogId == "meat" then
					restoredMeat += item.quantity
				end
			end
			assert(
				restoredMeat == 3 and reopened.snapshot("-2")[Survival.id].vitals.healthMilli == before - 10000,
				"loot and NPC damage survive JSON rejoin"
			)
			assert(
				reopened.close("-1").ok and reopened.close("-2").ok and rebuilt.close().ok,
				"rejoined owners released"
			)
			print("GENERATED_WILDLIFE_ATTACK_LOOT_VITALS_JSON_REJOIN=PASS")
			print("GENERATED_FACTORY_TWO_ACTOR_GATHER_DEPOSIT_CRAFT_BUILD=PASS")
			local smoke = dynamicRequire("./" .. generate.relative("cli/forge/lib", dir .. "/smoke/smoke"))
			for _, check in smoke.run(nil) do
				assert(check.ok, check.name)
			end
			fs.writeFile(root .. "/.luaurc", fs.readFile(".luaurc"))
			local analyzed = process.exec("luau-lsp", {
				"analyze",
				"--platform=standard",
				dir .. "/src/shared/GenreConfig.luau",
				dir .. "/src/shared/SurvivalContent.luau",
				dir .. "/src/shared/SurvivalWorldConfig.luau",
				dir .. "/src/shared/GenreDurable.luau",
				dir .. "/smoke/smoke.luau",
			})
			if not analyzed.ok then
				print(analyzed.stdout .. analyzed.stderr)
			end
			assert(analyzed.ok, "generated module typecheck failed")
			local output = root .. "/fixture.rbxl"
			local built = process.exec("rojo", { "build", dir .. "/default.project.json", "-o", output })
			assert(built.ok, built.stdout .. built.stderr)
			local place = roblox.deserializePlace(fs.readFile(output))
			local server = assert(place:FindFirstChild("ServerScriptService"))
			assert(server:FindFirstChild("FixtureCraftingServer"), "built bootstrap")
			assert(server:FindFirstChild("SurvivalWorldBootstrap"), "world bootstrap mounted")
			assert(
				server:FindFirstChild("SurvivalFactory")
					and server:FindFirstChild("SurvivalProvision")
					and server:FindFirstChild("SurvivalProvisionConfig"),
				"factory and server-only provisioning mounted"
			)
			for _, instance in place:GetDescendants() do
				if instance:IsA("LuaSourceContainer") then
					luau.compile((instance :: any).Source)
				end
			end
			local shared: roblox.Instance = place
			for _, name in { "ReplicatedStorage", "Forge", "games", "fixture-crafting", "src", "shared" } do
				shared = assert(shared:FindFirstChild(name), name)
			end
			assert(
				shared:FindFirstChild("GenreDurable")
					and shared:FindFirstChild("SurvivalContent")
					and shared:FindFirstChild("SurvivalWorldConfig"),
				"built runtime data"
			)
			print("CRAFTING_GENERATOR_NATIVE_SMOKE_TYPECHECK_ROJO_INSPECT=PASS")
			local sourcemapPath = root .. "/sourcemap.json"
			local mapped = process.exec("rojo", { "sourcemap", dir .. "/default.project.json", "-o", sourcemapPath })
			assert(mapped.ok, mapped.stdout .. mapped.stderr)
			local sourcemap = serde.decode("json", fs.readFile(sourcemapPath))
			type SourceNode = { filePaths: { string }?, children: { SourceNode }? }
			local function absolutePaths(node: SourceNode)
				local paths = node.filePaths
				if paths then
					for index, path in ipairs(paths) do
						paths[index] = generate.absolute(dir .. "/" .. path)
					end
				end
				if node.children then
					for _, child in ipairs(node.children) do
						absolutePaths(child)
					end
				end
			end
			absolutePaths(sourcemap)
			fs.writeFile(sourcemapPath, serde.encode("json", sourcemap))
			for _, commandArgs in
				{
					{ "selene", dir .. "/src" },
					{ "stylua", "--check", "--config-path", "stylua.toml", dir },
					{
						"luau-lsp",
						"analyze",
						"--definitions",
						"@roblox=" .. generate.absolute("build/cache/globalTypes.d.luau"),
						"--sourcemap",
						sourcemapPath,
						dir .. "/src",
					},
				}
			do
				local executable = assert(table.remove(commandArgs, 1), "executable")
				local checked = process.exec(executable, commandArgs)
				if not checked.ok then
					print(checked.stdout .. checked.stderr)
				end
				assert(checked.ok, executable .. " generated surface\n" .. checked.stdout .. checked.stderr)
			end
			print("GENERATED_ROBLOX_LINT_STYLE_ANALYSIS=PASS")
			local provisionPath = dir .. "/src/server/SurvivalProvisionConfig.luau"
			fs.writeFile(provisionPath, "return " .. contract.serialize(provisionConfig) .. "\n")
			local preserved = fs.readFile(provisionPath)
			local authored = {}
			for _, relative in
				{
					"src/server/FixtureCraftingServer.server.luau",
					"src/client/FixtureCraftingClient.client.luau",
					"src/server/SurvivalWorldBootstrap.luau",
					"src/shared/AudioConfig.luau",
				}
			do
				local text = fs.readFile(dir .. "/" .. relative) .. "-- AUTHORED_PRESENTATION_SENTINEL\n"
				fs.writeFile(dir .. "/" .. relative, text)
				authored[relative] = text
			end
			audioRecipes.cues[1].seed = 923
			fs.writeFile(dir .. "/assets/audio.yml", serde.encode("yaml", audioRecipes))
			authored["assets/audio.yml"] = fs.readFile(dir .. "/assets/audio.yml")
			fs.writeFile(dir .. "/src/shared/GenreDurable.luau", "return { actions = {} }\n")
			local input = {
				mode = "new" :: "new",
				slug = "fixture-crafting",
				pascal = "FixtureCrafting",
				title = "Fixture Crafting",
				concept = "",
				seed = 0,
				teams = { "Red", "Blue" },
				debugName = "FixtureCraftingDebug",
				guiName = "FixtureCraftingGui",
			}
			local regenerated = generate.assemble(codegenRegistry, { "survival-coop" }, input, dir, "crafting")
			for relative, text in authored do
				assert(regenerated.files[relative] == text, "authored assembly bytes retained: " .. relative)
			end
			local refreshedPolicy = luau.load(regenerated.files["src/shared/GenreDurable.luau"])()
			assert(
				table.find(refreshedPolicy.actions, "survival-coop:attack"),
				"generated authority is not preserved as art"
			)
			assert(
				regenerated.files["src/server/SurvivalProvisionConfig.luau"] == preserved,
				"provision preserved in assembly"
			)
			assert(publish.write(regenerated, dir, "fixture-crafting", context), "actual regeneration publication")
			for relative, text in authored do
				assert(fs.readFile(dir .. "/" .. relative) == text, "authored publication bytes retained: " .. relative)
			end
			local restored = luau.load(fs.readFile(provisionPath))()
			assert(
				restored.ownerId == "-1" and restored.acceptedInvitations["-2"] == true,
				"owner and accepted consent survive publication"
			)
			print("GENERATED_PROVISION_PUBLICATION_PRESERVATION=PASS")
			local cleanup: { () -> () } = {}
			local clientStarted = false
			local craftingStarted = false
			local coreGui = {
				Enabled = true,
				Destroying = {
					Connect = function(_, callback)
						table.insert(cleanup, callback)
					end,
				},
			}
			local gatheringDestroyed = false
			local cameraStopped = false
			local audioStarted, audioDestroyed = false, false
			forge.genres["survival-coop"].module.SurvivalAudio = {
				start = function(config)
					assert(not clientStarted and config == audioConfig, "audio subscribes before initial handshake")
					audioStarted = true
					return {
						destroy = function()
							audioDestroyed = true
						end,
					}
				end,
			}
			forge.core.infra.camera = {
				QuarterView = {
					start = function()
						return {
							stop = function()
								cameraStopped = true
							end,
						}
					end,
				},
			}
			environment.script.Destroying = {
				Connect = function(_, callback)
					assert(type(callback) == "function", "script cleanup callback")
				end,
			}
			forge.core.infra.genre.Client = {
				start = function(options)
					assert(audioStarted, "initial snapshots have an audio subscriber")
					assert(options.controls == controls, "core client controls retained")
					clientStarted = true
					return coreGui
				end,
			}
			forge.genres["survival-coop"].module.GatheringClient = {
				start = function()
					assert(clientStarted, "gathering starts after core GUI")
					return {
						destroy = function()
							gatheringDestroyed = true
						end,
					}
				end,
			}
			local hudDestroyed = false
			forge.genres["survival-coop"].module.SurvivalHUD = {
				start = function(options)
					assert(clientStarted and coreGui.Enabled == false, "starter GUI hidden without destroying owner")
					assert(options.content == decoded, "HUD receives canonical content")
					craftingStarted = true
					return {
						destroy = function()
							hudDestroyed = true
						end,
					}
				end,
			}
			local panelsDestroyed = false
			forge.genres["survival-coop"].module.ExtensionPanels = {
				start = function(options)
					assert(craftingStarted, "extension panels start after the HUD")
					assert(options.ui and options.ui.components, "panels receive ui-kit components")
					return {
						destroy = function()
							panelsDestroyed = true
						end,
					}
				end,
			}
			luau.load(
				fs.readFile(dir .. "/src/client/FixtureCraftingClient.client.luau"),
				{ environment = environment }
			)()
			assert(#cleanup == 5, "GUI owns audio gathering HUD panels and camera cleanup")
			for _, callback in cleanup do
				callback()
			end
			assert(panelsDestroyed, "extension panels destroyed with GUI")
			assert(gatheringDestroyed, "gathering destroyed with GUI")
			assert(cameraStopped, "camera stopped with GUI")
			assert(hudDestroyed, "HUD destroyed with GUI")
			assert(audioDestroyed, "audio destroyed with GUI")
			assert(craftingStarted, "crafting client started")
		end, debug.traceback)
		if fs.isDir(root) then
			fs.removeDir(root)
		end
		assert(ok, tostring(reason))
	end,
	["crafting assembly is deterministic and invalid content fails before publication"] = function()
		local registry = assert(registryLib.discover())
		local input = {
			mode = "new" :: "new",
			slug = "fixture",
			pascal = "Fixture",
			title = "Fixture",
			concept = "",
			seed = 0,
			teams = { "Red", "Blue" },
			debugName = "FixtureDebug",
			guiName = "FixtureGui",
		}
		local a = generate.assemble(registry, { "survival-coop" }, input, ".omo/fixtures/crafting", "crafting")
		local b = generate.assemble(registry, { "survival-coop" }, input, ".omo/fixtures/crafting", "crafting")
		for path, text in a.files do
			assert(b.files[path] == text, path)
		end
		local original = crafting.content
		crafting.content = function()
			local raw = original()
			raw.recipes[1].inputs[1].item = "missing"
			return raw
		end
		local accepted =
			pcall(generate.assemble, registry, { "survival-coop" }, input, ".omo/fixtures/crafting", "crafting")
		crafting.content = original
		assert(not accepted and not fs.isDir(".omo/fixtures/crafting"), "bad content rejected before files")
	end,
}
