--!strict
local Shared = require("../../../core/domain/genre/Contract")
local Content = require("../../../core/domain/survival/Content")
local Fenced = require("../../../core/infra/data/FencedStore")
local ProfileStore = require("../../../core/infra/data/ProfileStore")
local Session = require("../../../core/infra/genre/Session")
local Events = require("../../../core/infra/analytics/Events")

export type Context = {
	content: Content.Document,
	store: () -> Fenced.Store,
	backend: ProfileStore.Backend,
	options: Fenced.Options,
	now: () -> number,
	nowMillis: () -> number,
	world: any,
	journal: any?,
	members: () -> { string },
	settlement: { snapshot: (string) -> (Shared.StateData?, string?) }?,
	personalTransfer: (string) -> Session.PersonalTransfer?,
	personalTransaction: ((string, (any) -> any) -> (boolean, any))?,
	analytics: Events.Emitter?,
	wildlife: ((string) -> { catalogId: string, healthMilli: number }?)?,
	captureWild: ((wildId: string, captureId: string, untilMillis: number) -> string?)?,
	-- Paid cosmetics the actor currently wears (MonetizationExtension.appearance), as a set of ids.
	appearance: ((actor: string) -> { [string]: boolean }?)?,
}
export type Built = Shared.Extension & { close: (() -> Shared.Result)? }
export type Factory = (Context) -> Built?

local factories: { Factory } = {
	require("./ContractsExtension").factory,
	require("./TamingExtension").factory,
	require("./CampExtension").factory,
	require("./MonetizationExtension").factory,
	require("./MarketExtension").factory,
	require("./HarborBuybackExtension").factory,
	require("./DeathZoneExtension").factory,
	require("./LateEquipmentExtension").factory,
	require("./BrawlExtension").factory,
	require("./ClanExtension").factory,
	require("./OutpostExtension").factory,
	require("./EnsembleExtension").factory,
	require("./ScoreTransport").factory,
	require("./JournalExtension").factory,
	require("./CharacterExtension").factory,
	require("./DirectTradeExtension").factory,
	require("./OperationExtension").factory,
	require("./StanceExtension").factory,
}

return { factories = factories }
