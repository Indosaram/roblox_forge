--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local Observed = require("./ObservedBackend")
local serde = require("@lune/serde")
local Ledger = require("../../domain/command/Ledger")
return {
	["persistent Studio mode isolates stable store and never falls back after backend refusal"] = function()
		local stores, memoryCalls = {}, 0
		local storage = roblox.Instance.new("Folder")
		-- Lune's native Instance cannot model callback/event properties; this
		-- mock keeps the exact BindableFunction/BindableEvent contract the
		-- loaded source assigns and asserts on (OnInvoke slot + invoke, Event
		-- connections, Fire fan-out, Disconnect, Destroy), while real Folder
		-- instances stay native for FindFirstChild assertions.
		local function newInstance(className: string): any
			if className == "BindableFunction" then
				return {
					Invoke = function(self: any, ...: any): any
						assert(type(self.OnInvoke) == "function", "BINDABLE_FUNCTION_UNBOUND")
						return self.OnInvoke(...)
					end,
				}
			end
			if className == "BindableEvent" then
				local handlers: { (...any) -> () } = {}
				local event: any = {
					Fire = function(_: any, ...: any)
						for _, handler in handlers do
							handler(...)
						end
					end,
					Event = {
						Connect = function(_: any, handler: (...any) -> ())
							table.insert(handlers, handler)
							return {
								Disconnect = function()
									local at = table.find(handlers, handler)
									if at then
										table.remove(handlers, at)
									end
								end,
							}
						end,
					},
					Destroy = function()
						table.clear(handlers)
					end,
				}
				return event
			end
			return roblox.Instance.new(className)
		end
		local module = luau.load(fs.readFile("core/infra/data/RuntimeBackend.luau"), {
			environment = {
				Enum = { DataStoreRequestType = { UpdateAsync = "UpdateAsync" } },
				require = function(name: string): any
					if name == "../../domain/command/Ledger" then
						return Ledger
					end
					if name == "./ObservedBackend" then
						return Observed
					end
					if name == "./MemoryBackend" then
						return {
							new = function()
								memoryCalls += 1
								return {}
							end,
						}
					end
					return {
						new = function(storeName)
							table.insert(stores, storeName)
							return {
								update = function()
									return false, "API_ACCESS_DENIED"
								end,
							}
						end,
					}
				end,
				Instance = { new = newInstance },
				DateTime = {
					now = function()
						return { UnixTimestampMillis = 1000 }
					end,
				},
				game = {
					GameId = 12,
					PlaceId = 34,
					JobId = "epoch-a",
					GetService = function(_, name): any
						if name == "DataStoreService" then
							return {
								GetRequestBudgetForRequestType = function(_, requestType)
									assert(requestType == "UpdateAsync", "actual datastore budget type")
									return 17
								end,
							}
						end
						if name == "ServerStorage" then
							return storage
						end
						if name == "RunService" then
							return {
								IsStudio = function()
									return true
								end,
							}
						end
						return {
							GenerateGUID = function()
								return "backend-epoch"
							end,
							JSONEncode = function(_, value)
								return serde.encode("json", value)
							end,
						}
					end,
				},
			},
		})()
		assert(
			not pcall(module.new, { mode = "studio-datastore", namespace = "../production" }, "production"),
			'not pcall(module.new, { mode = "studio-datastore", namespace = "../production" }, "production")'
		)
		local invalidLaunch = roblox.Instance.new("Folder")
		invalidLaunch.Name = "ForgeOwnedPersistenceConfig"
		invalidLaunch:SetAttribute("Mode", "studio-local")
		invalidLaunch:SetAttribute("Namespace", "owned")
		invalidLaunch:SetAttribute("Port", 43123)
		invalidLaunch:SetAttribute("Token", string.rep("a", 64))
		invalidLaunch:SetAttribute("LeaseAcquireKey", "")
		invalidLaunch.Parent = storage
		assert(
			not pcall(module.new, { mode = "memory" }, "production"),
			"empty owned startup selector rejects before backend acquisition"
		)
		local backend = module.new({ mode = "studio-datastore", namespace = "owned" }, "production")
		assert(stores[1] == "forge-qa-owned" and memoryCalls == 0, 'stores[1] == "forge-qa-owned" and memoryCalls == 0')
		local ok, reason = backend.update("personal:1", function()
			return {}
		end)
		assert(
			not ok and reason == "API_ACCESS_DENIED" and backend.observation().sequence == 0,
			'not ok and reason == "API_ACCESS_DENIED" and backend.observation().sequence == 0'
		)
		assert(
			backend.observation().identity.storeName == "forge-qa-owned",
			'backend.observation().identity.storeName == "forge-qa-owned"'
		)
		local observed = backend.observation()
		assert(observed.backendObservation.backend == "roblox-datastore", "service backend identity")
		assert(observed.backendObservation.availableRequests == 17, "sample actual service budget")
		assert(
			not observed.coverageComplete and observed.handledThrottleCount == nil,
			"opaque failures stay unclassified"
		)
		storage:Destroy()
	end,
}
