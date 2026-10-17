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

export type Context = {
	content: Content.Document,
	-- Fenced store over the bootstrap's backend and options (same budget/lease).
	store: () -> Fenced.Store,
	backend: ProfileStore.Backend,
	options: Fenced.Options,
	now: () -> number,
	nowMillis: () -> number,
	world: any,
	members: () -> { string },
	personalTransfer: (string) -> Session.PersonalTransfer?,
	-- Live wildlife state by id (nil when absent or the pack has no wildlife source).
	wildlife: ((string) -> { catalogId: string, healthMilli: number }?)?,
}
export type Built = Shared.Extension & { close: (() -> Shared.Result)? }
export type Factory = (Context) -> Built?

local factories: { Factory } = {
	-- Append extension factories here, e.g. require("./TamingExtension").factory,
	require("./TamingExtension").factory,
	require("./MonetizationExtension").factory,
}

return { factories = factories }
