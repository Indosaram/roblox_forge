--!strict
local Schema = require("../../infra/net/Schema")
export type ConfigData = { [string]: any }
export type StateData = { [string]: any }
export type PlayerId = string
export type SurvivalPosition = { x: number, y: number, z: number }
export type Event = { genre: string, name: string, playerId: PlayerId?, data: StateData }
export type Services = {
	survivalWildlife: {
		handles: (string) -> boolean,
		command: (string, { any }, CommandContext, number, () -> Result) -> Result,
		recover: (string, number) -> any,
		snapshot: (string) -> (StateData?, string?),
	}?,
	survivalGathering: {
		handles: (string) -> boolean,
		command: (string, { any }, CommandContext, number, () -> Result) -> Result,
		recover: (string, number) -> any,
		snapshot: (string) -> (StateData?, string?),
	}?,
	survivalTransfer: {
		handles: (string) -> boolean,
		epoch: (string, string) -> (number?, string?),
		command: (string, string, { any }, CommandContext, "client" | "server", (() -> Result)?) -> Result,
		recover: (string, number) -> any,
	}?,
	survivalSettlement: {
		handles: (string) -> boolean,
		epoch: (string, string) -> (number?, string?),
		command: (string, string, { any }, CommandContext, "client" | "server", (() -> Result)?) -> Result,
		snapshot: (string) -> (StateData?, string?),
		link: (string) -> { tribeId: string }?,
	}?,
	encode: ((any) -> string)?,
	now: () -> number,
	roll: () -> number,
	emit: (Event) -> (),
	survivalDeath: {
		worldRevision: string,
		equipment: (PlayerId) -> { [string]: boolean }?,
		position: (PlayerId) -> SurvivalPosition?,
		reachable: (PlayerId, SurvivalPosition) -> boolean,
	}?,
	survivalSpatial: {
		campfire: (PlayerId, string) -> { reachable: boolean }?,
		station: ((PlayerId, string) -> { kind: string, reachable: boolean }?)?,
	}?,
}
export type Action = {
	id: string,
	args: { Schema.Validator },
	origin: "client" | "server",
	rate: { capacity: number, refillPerSecond: number },
}
export type Result = { ok: boolean, reason: string?, stateVersion: number?, data: StateData? }
export type CommandStage = { result: Result, data: StateData, apply: () -> (), notify: (() -> ())? }
export type CommandContext = {
	actorId: string,
	requestId: string,
	sessionEpoch: number,
	nowMillis: number?,
	expiredBeforeEpoch: number?,
	serverId: string?,
}
export type Instance = {
	join: (PlayerId, StateData?) -> Result,
	hydrate: ((PlayerId, StateData) -> Result)?,
	prepareLeave: ((PlayerId) -> ())?,
	leave: (PlayerId) -> (),
	dispatch: (PlayerId, string, { any }) -> Result,
	stageCommand: ((PlayerId, string, { any }, CommandContext?) -> CommandStage?)?,
	pendingServerEvent: ((PlayerId, number) -> string?)?,
	advance: (number) -> (),
	snapshot: (PlayerId) -> StateData,
	save: (PlayerId) -> StateData,
}
export type RuntimeContract = {
	api: number,
	id: string,
	configVersion: number,
	saveVersion: number,
	actions: { Action },
	events: { string },
	hooks: { string },
	validateConfig: (ConfigData) -> { string },
	validateSave: (StateData) -> { string },
	create: (ConfigData, Services) -> Instance,
	recipe: {
		id: string,
		partners: { string },
		validateConfig: (({ [string]: ConfigData }) -> { string })?,
		create: ({ [string]: ConfigData }, Services) -> { [string]: Instance },
	}?,
}
export type PackConfig = { api: number, order: { string }, configs: { [string]: ConfigData }, recipe: string? }
export type SaveEnvelope =
	{ version: number, genres: { [string]: { version: number, data: StateData } }, commands: any? }
export type HookMap = { [string]: (Event) -> () }
return {}
