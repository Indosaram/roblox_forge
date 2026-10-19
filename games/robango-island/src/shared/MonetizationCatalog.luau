--!strict
-- Robango Island monetization catalog: the runtime mirror of game.yml `monetization` (the source
-- of truth that `forge deploy` and `forge econ` read). MonetizationCatalog.spec.luau asserts this
-- table equals game.yml, so edit game.yml first and keep this mirror identical.
-- Deterministic items only (design.md section 8, ADR-07): no pools, odds or soft-currency sales.
-- `id = 0` means not yet registered on Roblox; MonetizationExtension lists it but never prompts.
-- Untyped on purpose: grant `kind` literals widen to string; configure() validates the shape at start.

local catalog = {
	gamepasses = {
		{
			key = "routeGuildPatron",
			name = "Route Guild Patron Pass",
			price = 299,
			id = 0,
			grant = { kind = "storageSlots", amount = 10 },
		},
		{
			key = "wideWarehouse",
			name = "Wide Warehouse",
			price = 199,
			id = 0,
			grant = { kind = "storageSlots", amount = 10 },
		},
	},
	products = {
		{
			key = "skinRidgeStriderGold",
			name = "Ridge Strider Gold Skin",
			price = 199,
			id = 0,
			grant = { kind = "cosmeticSet", cosmeticSetId = "ridge-strider-gold" },
		},
	},
	subscriptions = {
		{
			key = "routeGuildMonthly",
			name = "Route Guild Monthly",
			price = 99,
			id = 0,
			grant = { kind = "subscriptionMonthly", cosmeticSetId = "route-guild-monthly", storageSlots = 5 },
		},
	},
}

return catalog
