--!strict
-- Compatibility entrypoint for the collect-raid package-owned planner.
local Planner = require("../../../genres/collect-raid/generation/planner")
export type CreatureDef = Planner.CreatureDef
export type EggDef = Planner.EggDef
export type Roster = Planner.Roster
export type PoolEntry = Planner.PoolEntry
export type EconomyEgg = Planner.EconomyEgg
export type EconomyCreature = Planner.EconomyCreature
export type MonetizationItem = Planner.MonetizationItem
export type Monetization = Planner.Monetization
export type Economy = Planner.Economy
export type TargetReport = Planner.TargetReport
export type TuneResult = Planner.TuneResult
return Planner
