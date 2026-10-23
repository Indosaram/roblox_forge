--!strict
-- G5: every paid cosmetic must change what players see. The gold mount skin is granted through a
-- real receipt, selected with skin-select, then the rider mounts: the published ride carries the
-- skin and the rig built from it differs from the species default. The monthly subscription set
-- renders a cloak and back banner on the character, and both vanish when access ends.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local serde = require("@lune/serde")
local Memory = require("../../core/infra/data/MemoryBackend")
local Fenced = require("../../core/infra/data/FencedStore")
local MarketplacePort = require("../../core/infra/monetization/MarketplacePort")
local PolicyPort = require("../../core/infra/monetization/PolicyPort")
local Inventory = require("../../core/domain/inventory/Inventory")
local Data = require("../../core/domain/genre/SerializedData")
local Monetization = require("../../genres/survival-coop/module/MonetizationExtension")
local Companion = require("../../genres/survival-coop/module/CombatCompanion")
local TamingExtension = require("../../genres/survival-coop/module/TamingExtension")
local CosmeticVisual = require("../../genres/survival-coop/module/CosmeticVisual")
local Catalog = require("./src/shared/MonetizationCatalog")
local Cosmetics = require("./src/shared/CosmeticConfig")
local TamingConfig = require("./src/shared/TamingConfig")
local content: any = require("./src/shared/SurvivalContent")

local env = {
	Instance = roblox.Instance,
	Vector3 = roblox.Vector3,
	CFrame = roblox.CFrame,
	Color3 = roblox.Color3,
	Enum = roblox.Enum,
}
local function engineModule(path: string): any
	return luau.load(fs.readFile(path), { environment = env })()
end
local Rig = engineModule("genres/survival-coop/module/DinosaurRig.luau")
local Dress = engineModule("genres/survival-coop/module/CosmeticVisual.luau")

local GOLD = Catalog.products[1].grant.cosmeticSetId
local MONTHLY = Catalog.subscriptions[1].grant.cosmeticSetId

local function shop()
	local fake = MarketplacePort.fake()
	Monetization.configure({
		catalog = Catalog :: any,
		marketplace = fake.port,
		policy = PolicyPort.fake({ ["7"] = true }),
		hooks = {
			warehouseSlots = function() end,
			skinSupported = function(skin)
				return CosmeticVisual.supported(Cosmetics, skin)
			end,
		},
	})
	local store = Memory.new()
	local extension: any = assert(Monetization.factory({
		store = function()
			return Fenced.new(store, {
				sessionId = "g5",
				leaseSeconds = 120,
				now = function()
					return 0
				end,
				budget = {
					encode = function(value)
						return serde.encode("json", value)
					end,
				},
			})
		end,
		now = function()
			return 0
		end,
	}))
	return extension, fake
end
local function send(extension: any, id: string, action: string, args: { any }): any
	return extension.command(
		"7",
		action,
		args,
		{ actorId = "7", requestId = id, sessionEpoch = 1 },
		"client",
		function()
			return { ok = true }
		end
	)
end
local function detail(species: string): any
	for _, row in content.wildlifeDetails do
		if row.id == species then
			return row
		end
	end
	error("species " .. species)
end
local function rider(appearance: (string) -> any, species: string): any
	local rules = content.progressionPolicy.companion
	local pets = assert(Companion.capture(Companion.new({}, 0), "pet", species, rules))
	pets.pets.pet.phase, pets.pets.pet.saddle = "Deployed", true
	pets.deployed = "pet"
	local bag =
		Inventory.new("bag", { contentVersion = 2, slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
	local profile: any = {
		data = {
			stateRevision = 0,
			envelope = {
				genres = {
					["survival-coop"] = { data = { inventory = { bag = Inventory.save(bag) }, companions = pets } },
				},
			},
		},
	}
	local port: any = {
		profile = function()
			return profile
		end,
		install = function(nextProfile)
			profile = nextProfile
		end,
		personal = {
			commit = function(_: any, _token: any, expected: number, envelope: any): (any?, string?)
				return { data = { stateRevision = expected + 1, envelope = Data.clone(envelope) } }, nil
			end,
		},
	}
	TamingExtension.configure(TamingConfig :: any)
	local taming = TamingExtension.factory({
		content = content,
		nowMillis = function()
			return 0
		end,
		personalTransfer = function()
			return port
		end,
		appearance = appearance,
	})
	TamingExtension.configure(nil)
	local mounted = taming.command(
		"7",
		"survival-coop:companion-action",
		{ "mount", "pet" },
		{ sessionEpoch = 1, requestId = "ride" },
		"client",
		function()
			return { ok = true }
		end
	)
	assert(mounted.ok, "mount: " .. tostring(mounted.reason))
	return taming
end
local function signature(model: any): { [string]: string }
	local out = {}
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			out[part.Name] = tostring(part.Color) .. "/" .. tostring(part.Material) .. "/" .. tostring(part.Reflectance)
		end
	end
	return out
end

return {
	["every sold cosmetic set has a visible renderer and the mount skin targets one of the 24 rideables"] = function()
		local listings = {}
		for _, list in { Catalog.products, Catalog.subscriptions } do
			for _, listing in list do
				table.insert(listings, listing)
			end
		end
		assert(#listings == 2, "catalog cosmetic listings changed: list them in p45/g5.md")
		for _, listing in listings do
			assert(CosmeticVisual.supported(Cosmetics, listing.grant.cosmeticSetId), listing.key .. " has no renderer")
		end
		local skin = (TamingConfig.mounts.skins :: any)[GOLD]
		local row = detail(skin.species)
		assert(row.mount.enabled and row.captureClass ~= "never", "gold skin species is a rideable of the 24")
		assert(Cosmetics.mountSkins[GOLD] and Cosmetics.wear[GOLD] == nil, "gold is a mount skin")
		assert(Cosmetics.wear[MONTHLY] and Cosmetics.mountSkins[MONTHLY] == nil, "monthly is worn")
	end,
	["granted selected gold skin rides published and builds a visibly different rig"] = function()
		local extension, fake = shop()
		assert(send(extension, "pre", "survival-coop:skin-select", { GOLD }).reason == "SKIN_NOT_OWNED", "unowned")
		assert(send(extension, "buy", "survival-coop:shop-prompt", { "skinRidgeStriderGold" }).ok, "prompt")
		assert(#fake.decisions == 1 and extension.snapshot("7").skins[GOLD], "receipt granted")
		assert(Monetization.appearance(extension, "7")[GOLD] == nil, "owning alone does not dress")
		local selected = send(extension, "pick", "survival-coop:skin-select", { GOLD })
		assert(selected.ok, "select: " .. tostring(selected.reason))
		assert(Monetization.appearance(extension, "7")[GOLD] == true, "selection published")
		local species = (TamingConfig.mounts.skins :: any)[GOLD].species
		local taming = rider(function(actor)
			return Monetization.appearance(extension, actor)
		end, species)
		local ride = assert(taming.snapshot("7").ride, "riding")
		assert(
			ride.species == species and ride.skin == GOLD,
			"published ride carries the skin: " .. tostring(ride.skin)
		)
		local plain = rider(function()
			return {}
		end, species)
		assert(plain.snapshot("7").ride.skin == nil, "no selection rides the default look")
		local row = detail(species)
		local size = roblox.Vector3.new(row.renderEnvelope.x, row.renderEnvelope.y, row.renderEnvelope.z)
		local world = roblox.Instance.new("Folder")
		local base = Rig.new(species, "base", roblox.Vector3.zero, world, size, row.visual)
		local skinned = Rig.new(
			species,
			"gold",
			roblox.Vector3.zero,
			world,
			size,
			CosmeticVisual.mount(row.visual, Cosmetics.mountSkins[ride.skin])
		)
		local a, b = signature(base), signature(skinned)
		assert(a.Torso ~= b.Torso, "torso look differs")
		local added = 0
		for name in b do
			if a[name] == nil then
				added += 1
			end
		end
		assert(added > 0, "skin adds visible trim parts")
		assert(skinned:GetAttribute("PartCount") <= 48, "part budget")
		assert(skinned.Torso.Reflectance > 0 and base.Torso.Reflectance == 0, "gold sheen")
		assert(extension.close().ok, "close")
		Monetization.configure(nil)
	end,
	["monthly set dresses a cloak and banner only while subscribed"] = function()
		local extension, fake = shop()
		assert(send(extension, "sub", "survival-coop:shop-prompt", { "routeGuildMonthly" }).ok, "subscribe")
		assert(send(extension, "sync", "survival-coop:shop-sync", {}).ok, "sync")
		assert(send(extension, "wear", "survival-coop:skin-select", { MONTHLY }).ok, "select monthly")
		local appearance = Monetization.appearance(extension, "7")
		assert(appearance[MONTHLY], "monthly selected")
		local plan = CosmeticVisual.wear(Cosmetics, appearance)
		assert(#plan > 0, "worn pieces")
		local character = roblox.Instance.new("Model")
		for _, name in { "UpperTorso", "Head" } do
			local part = roblox.Instance.new("Part")
			part.Name, part.Size, part.Parent = name, roblox.Vector3.new(2, 1.6, 1), character
		end
		assert(Dress.dressWear(character, plan), "built")
		local folder = character:FindFirstChild(CosmeticVisual.FOLDER)
		assert(
			folder and folder:FindFirstChild("Cosmetic-cloak") and folder:FindFirstChild("Cosmetic-banner"),
			"cloak and banner"
		)
		assert(not Dress.dressWear(character, plan), "unchanged signature is a no-op")
		fake.subscribed = {}
		assert(send(extension, "lapse", "survival-coop:shop-sync", {}).ok, "lapse sync")
		assert(Monetization.appearance(extension, "7")[MONTHLY] == nil, "expired set no longer worn")
		assert(
			Dress.dressWear(character, CosmeticVisual.wear(Cosmetics, Monetization.appearance(extension, "7"))),
			"rebuilt"
		)
		assert(character:FindFirstChild(CosmeticVisual.FOLDER) == nil, "cloak removed after expiry")
		assert(extension.close().ok, "close")
		Monetization.configure(nil)
	end,
}
