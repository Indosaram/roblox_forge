--!strict
-- Saltmeadow town plots (plan G17, C5a; the town-layout spec §2, §4).
-- Pure and engine-free: the 28 claimable 64x64 plots of the 1536x1536 town, claim rules, and
-- build/demolish on a plot through core Settlement. Each plot is one Settlement.State with
-- tribeId "town:<townId>:<plotId>", a 16x16 grid of 4-stud cells and up to 4 members.
-- Time is always a parameter; the only randomness (stake corner, flag hue) is a fork of the
-- recorded seed, so the same seed always yields the same town.
local Rng = require("../../../../core/domain/random/Rng")
local Settlement = require("../../../../core/domain/settlement/Settlement")
local M = {}

M.PLOT_STUDS = 64
M.CELL_STUDS = 4
M.GRID = 16
M.MAX_MEMBERS = 4
-- First-plot rule: development grade 1 (100 points). The first two guides, rw.g01 (gather fiber x3)
-- and rw.g02 (craft the first axe), give 50 points each and are both beats of the C1 opening, so a
-- new player meets it in the first session; the town is reachable from onboarding before that, so
-- the refusal is shown as a toast naming those two guides (trv.RANK_REQUIRED, see toastReason).
M.MIN_DEVELOPMENT_RANK = 1
M.FIRST_PLOT_GUIDES = table.freeze({ "rw.g01.first-gather", "rw.g02.first-axe" })
-- Claim outcomes the stake prompt publishes (RoleWorld, "<outcome>|<serial>") that the client toasts.
M.CLAIM_OUTCOMES = table.freeze({
	town_claimed = true,
	town_unavailable = true,
	RANK_REQUIRED = true,
	PLOT_OWNED = true,
	ALREADY_CLAIMED = true,
	UNKNOWN_PLOT = true,
	PLOT_UNREACHABLE = true,
})
-- Island ellipse radii and the inner fraction every plot footprint must stay within (§2 coast check).
M.ISLAND = table.freeze({ x = 760, z = 740, inner = 0.86 })
-- Town-hall-only and siege structures never go on a plot (§4 rule 7).
M.DISALLOWED = table.freeze({ ["clan-hall"] = true, ["volcanic-wall"] = true })
-- Station caps per plot, by station family (tiers share their family's cap).
M.STATION_CAPS = table.freeze({ workbench = 1, kiln = 1, campfire = 2 })
-- Flag hues for claimed stakes: rustic, readable on grass and sand.
M.FLAG_COLOURS = table.freeze({
	{ 196, 72, 58 },
	{ 58, 112, 176 },
	{ 214, 168, 48 },
	{ 84, 148, 72 },
	{ 140, 82, 160 },
	{ 222, 120, 52 },
	{ 52, 150, 150 },
	{ 170, 60, 110 },
})

export type Plot = {
	id: string,
	district: string,
	min: { x: number, z: number },
	max: { x: number, z: number },
	centre: { x: number, z: number },
	-- Corner (1..4: NW, NE, SE, SW) that carries the stake and flag.
	stake: number,
}
export type Layout = { seed: number, plots: { Plot }, byId: { [string]: Plot } }
export type Doc = {
	plotId: string,
	ownerId: string,
	claimedAt: number,
	settlement: Settlement.State,
}
export type Definition = {
	id: string,
	footprintX: number,
	footprintZ: number,
	cost: { Settlement.Cost },
	station: boolean?,
}
export type Request = { structure: string, x: number, z: number, rotation: number }

local function integer(value: any, minimum: number, maximum: number): boolean
	return type(value) == "number" and value == value and value >= minimum and value <= maximum and value % 1 == 0
end

-- District rows from the spec table: x starts per column, z starts per row (plots are 64 square).
local DISTRICTS = {
	{ prefix = "W", xs = { -608, -528, -448, -368 }, zs = { -224, -144, -64 } },
	{ prefix = "E", xs = { 304, 384, 464, 544 }, zs = { -224, -144, -64 } },
	{ prefix = "N", xs = { -224, -144, 96, 176 }, zs = { -416 } },
}

--- The 28 plots. Geometry is fixed by the town spec; the seed only picks each stake corner.
function M.layout(seed: number): Layout
	assert(integer(seed, 0, 2 ^ 53 - 1), "INVALID_SEED")
	local rng = Rng.new(seed):fork("town:plots")
	local plots: { Plot } = {}
	local byId: { [string]: Plot } = {}
	for _, district in DISTRICTS do
		local index = 0
		for _, z in district.zs do
			for _, x in district.xs do
				index += 1
				local plot: Plot = {
					id = string.format("%s%02d", district.prefix, index),
					district = district.prefix,
					min = { x = x, z = z },
					max = { x = x + M.PLOT_STUDS, z = z + M.PLOT_STUDS },
					centre = { x = x + M.PLOT_STUDS / 2, z = z + M.PLOT_STUDS / 2 },
					stake = rng:nextInteger(1, 4),
				}
				table.insert(plots, plot)
				byId[plot.id] = plot
			end
		end
	end
	return { seed = seed, plots = plots, byId = byId }
end

--- World position of a plot corner (1..4: NW, NE, SE, SW).
function M.corner(plot: Plot, index: number): { x: number, z: number }
	return if index == 1
		then { x = plot.min.x, z = plot.min.z }
		elseif index == 2 then { x = plot.max.x, z = plot.min.z }
		elseif index == 3 then { x = plot.max.x, z = plot.max.z }
		else { x = plot.min.x, z = plot.max.z }
end

--- Deterministic flag colour of an owner on a town: a fork of the recorded seed per owner.
function M.flagColour(seed: number, ownerId: string): { number }
	local rng = Rng.new(seed):fork("town:flag:" .. ownerId)
	return M.FLAG_COLOURS[rng:nextInteger(1, #M.FLAG_COLOURS)]
end

--- The claim outcome to toast for a published ForgeTravelResult value ("<outcome>|<serial>"), or nil
--- when the value is not a plot claim result (dock travel results keep the objective-card line).
function M.toastReason(published: any): string?
	if type(published) ~= "string" then
		return nil
	end
	local outcome = string.match(published, "^([^|]+)")
	return if outcome and M.CLAIM_OUTCOMES[outcome] then outcome else nil
end

function M.tribeId(townId: string, plotId: string): string
	return "town:" .. townId .. ":" .. plotId
end

function M.config(townId: string, plotId: string): Settlement.Config
	return {
		tribeId = M.tribeId(townId, plotId),
		width = M.GRID,
		depth = M.GRID,
		cellStuds = M.CELL_STUDS,
		maxMembers = M.MAX_MEMBERS,
	}
end

--- Durable key of one plot document (FencedStore keys are at most 50 characters).
function M.key(townId: string, plotId: string): string
	return "town:" .. townId .. ":plot:" .. plotId
end

--- Durable key of an account's single claim across every town.
function M.accountKey(actor: string): string
	return "townclaim:" .. actor
end

export type ClaimFacts = { developmentRank: number, claimed: string? }

--- Claims a free plot. `current` is the persisted plot document (nil when never claimed) and
--- `facts.claimed` the plot this account already holds anywhere ("<townId>:<plotId>"), if any.
function M.claim(
	layout: Layout,
	townId: string,
	current: Doc?,
	plotId: string,
	actor: string,
	facts: ClaimFacts,
	now: number
): (Doc?, string?)
	if not integer(now, 0, 2 ^ 53 - 1) then
		return nil, "INVALID_CLOCK"
	elseif type(actor) ~= "string" or actor == "" then
		return nil, "INVALID_ACTOR"
	elseif layout.byId[plotId] == nil then
		return nil, "UNKNOWN_PLOT"
	elseif current ~= nil then
		return nil, if current.ownerId == actor then "ALREADY_CLAIMED" else "PLOT_OWNED"
	elseif facts.claimed ~= nil then
		return nil, "ALREADY_CLAIMED"
	elseif type(facts.developmentRank) ~= "number" or facts.developmentRank < M.MIN_DEVELOPMENT_RANK then
		return nil, "RANK_REQUIRED"
	end
	return {
		plotId = plotId,
		ownerId = actor,
		claimedAt = now,
		settlement = Settlement.new(M.config(townId, plotId), actor, now),
	},
		nil
end

local function family(id: string): string
	return (string.gsub(id, "%-t%d+$", ""))
end

--- Reserves a structure at a world position on `doc`'s plot. Refuses a disallowed structure,
--- a station over its plot cap, a non-member, and any footprint or entry outside the plot.
--- Returns the next document, the reservation id and the cost the caller must pay before commit.
function M.reserve(
	layout: Layout,
	doc: Doc,
	actor: string,
	request: Request,
	definitions: { [string]: Definition }
): (Doc?, string?, string?, { Settlement.Cost }?)
	local plot = layout.byId[doc.plotId]
	local definition = definitions[request.structure]
	if plot == nil then
		return nil, "UNKNOWN_PLOT", nil, nil
	elseif doc.settlement.roles[actor] == nil then
		return nil, "NOT_PLOT_MEMBER", nil, nil
	elseif definition == nil then
		return nil, "UNKNOWN_STRUCTURE", nil, nil
	elseif M.DISALLOWED[definition.id] then
		return nil, "STRUCTURE_NOT_ALLOWED", nil, nil
	elseif type(request.x) ~= "number" or type(request.z) ~= "number" then
		return nil, "OUT_OF_PLOT", nil, nil
	elseif request.x < plot.min.x or request.x >= plot.max.x or request.z < plot.min.z or request.z >= plot.max.z then
		return nil, "OUT_OF_PLOT", nil, nil
	end
	local cap = M.STATION_CAPS[family(definition.id)]
	if cap and definition.station then
		local count = 0
		for _, group in { doc.settlement.reservations, doc.settlement.structures } do
			for _, placed in group do
				if family(placed.definition.id) == family(definition.id) then
					count += 1
				end
			end
		end
		if count >= cap then
			return nil, "STATION_CAP", nil, nil
		end
	end
	local state = doc.settlement
	local id = "b" .. tostring(state.version + 1)
	local reserved, err = Settlement.reserve(state, actor, state.version, state.membershipRevision, {
		id = id,
		definition = {
			id = definition.id,
			footprintX = definition.footprintX,
			footprintZ = definition.footprintZ,
			cost = definition.cost,
		},
		x = (request.x - plot.min.x) // M.CELL_STUDS,
		z = (request.z - plot.min.z) // M.CELL_STUDS,
		rotation = request.rotation,
	})
	if not reserved then
		return nil, err, nil, nil
	end
	local result = table.clone(doc)
	result.settlement = reserved
	return result, nil, id, table.clone(definition.cost)
end

function M.commit(doc: Doc, actor: string, reservationId: string): (Doc?, string?)
	local committed, err = Settlement.commit(doc.settlement, actor, doc.settlement.version, reservationId)
	if not committed then
		return nil, err
	end
	local result = table.clone(doc)
	result.settlement = committed
	return result, nil
end

function M.cancel(doc: Doc, actor: string, reservationId: string): (Doc?, string?)
	local cancelled, err = Settlement.cancel(doc.settlement, actor, doc.settlement.version, reservationId)
	if not cancelled then
		return nil, err
	end
	local result = table.clone(doc)
	result.settlement = cancelled
	return result, nil
end

--- Reserve and commit in one step (no payment between); specs and free placements use it.
function M.build(
	layout: Layout,
	doc: Doc,
	actor: string,
	request: Request,
	definitions: { [string]: Definition }
): (Doc?, string?)
	local reserved, err, id = M.reserve(layout, doc, actor, request, definitions)
	if not reserved then
		return nil, err
	end
	return M.commit(reserved, actor, id :: string)
end

--- Persisted form: the settlement uses its own versioned save.
function M.save(doc: Doc): any
	return {
		saveVersion = 1,
		plotId = doc.plotId,
		ownerId = doc.ownerId,
		claimedAt = doc.claimedAt,
		settlement = Settlement.save(doc.settlement),
	}
end

--- Restores a saved plot against trusted, version-pinned definitions (never the save's costs).
function M.fromSave(raw: any, layout: Layout, townId: string, definitions: { [string]: Definition }): Doc
	assert(type(raw) == "table" and raw.saveVersion == 1, "UNSUPPORTED_TOWN_PLOT_SAVE")
	assert(type(raw.plotId) == "string" and layout.byId[raw.plotId], "UNKNOWN_PLOT")
	assert(type(raw.ownerId) == "string" and raw.ownerId ~= "", "INVALID_OWNER")
	assert(integer(raw.claimedAt, 0, 2 ^ 53 - 1), "INVALID_CLAIM_TIME")
	local pinned: { [string]: Settlement.Definition } = {}
	for id, definition in definitions do
		pinned[id] = {
			id = definition.id,
			footprintX = definition.footprintX,
			footprintZ = definition.footprintZ,
			cost = definition.cost,
		}
	end
	return {
		plotId = raw.plotId,
		ownerId = raw.ownerId,
		claimedAt = raw.claimedAt,
		settlement = Settlement.fromSave(raw.settlement, M.config(townId, raw.plotId), pinned),
	}
end

return M
