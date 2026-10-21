--!strict
-- Registry of durable command extensions for the survival-coop bootstrap.
-- A lane plugs a system in by appending ONE factory to `factories` below and
-- declaring its action ids in module/Contract.luau (`actions` + `extensionActions`).
-- Each factory receives the bootstrap context and returns an Extension (or nil to
-- stay disabled) plus an optional `close` that releases its owned resources.
local Shared = require("../../../core/domain/genre/Contract")
local Content = require("../../../core/domain/survival/Content")
local Fenced = require("../../../core/infra/data/FencedStore")
local ProfileStore = require("../../../core/infra/data/ProfileStore")
local Session = require("../../../core/infra/genre/Session")
local Events = require("../../../core/infra/analytics/Events")

export type Context = {
	content: Content.Document,
	-- Fenced store over the bootstrap's backend and options (same budget/lease).
	store: () -> Fenced.Store,
	backend: ProfileStore.Backend,
	options: Fenced.Options,
	now: () -> number,
	nowMillis: () -> number,
	world: any,
	journal: any?,
	members: () -> { string },
	-- Trusted settlement port (membership-gated snapshot); nil only before bind in tests.
	settlement: { snapshot: (string) -> (Shared.StateData?, string?) }?,
	personalTransfer: (string) -> Session.PersonalTransfer?,
	-- Optional core analytics emitter shared with the bootstrap (nil when none).
	analytics: Events.Emitter?,
	-- Live wildlife state by id (nil when absent or the pack has no wildlife source).
	wildlife: ((string) -> { catalogId: string, healthMilli: number }?)?,
	-- Durably takes a wild animal out of the world until untilMillis (tame capture), idempotent by
	-- captureId; returns a transient reason to retry. nil when the pack has no wildlife owner.
	captureWild: ((wildId: string, captureId: string, untilMillis: number) -> string?)?,
}
export type Built = Shared.Extension & { close: (() -> Shared.Result)? }
export type Factory = (Context) -> Built?

local factories: { Factory } = {
	-- Append extension factories here (one require of ./<Name>Extension per line, then .factory).
	require("./ContractsExtension").factory,
	require("./TamingExtension").factory,
	require("./CampExtension").factory,
	require("./MonetizationExtension").factory,
	require("./MarketExtension").factory,
	require("./DeathZoneExtension").factory,
	require("./LateEquipmentExtension").factory,
	require("./BrawlExtension").factory,
	require("./ClanExtension").factory,
	require("./OutpostExtension").factory,
	require("./EnsembleExtension").factory,
	require("./ScoreTransport").factory,
	require("./JournalExtension").factory,
}

return { factories = factories }
