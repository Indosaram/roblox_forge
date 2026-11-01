--!strict
-- OpeningScene: the pure step machine of the C1 opening ("Skylark down", opening-script.md).
-- The server owns it (OpeningDirector): every step completes from server facts only (tutorial
-- state, the bag, positions, scripted-boar windows, server prompts), never from a client claim.
-- The client reads `view` (published per player) to stage beats and the quest-card tracker.
-- Time is always a parameter (milliseconds); nothing here reads a clock or randomness.
local M = {}

-- `target`: the layout anchor or resource node the step sends the player to (Waypoint arrow, minimap
-- pin and beam; p134 c1 dead end 2). A craft step points at the next stop: crafting runs anywhere.
export type Step = { id: string, beat: number, line: string?, count: string?, of: number?, target: string? }
export type Facts = {
	tutorialIndex: number,
	tutorialComplete: boolean,
	items: { [string]: number },
	nearFord: boolean,
	nearMarit: boolean,
	windbreak: boolean,
	-- Start of the player's latest server-accepted dodge window (combat.defense.dodgeStart).
	dodgeAt: number?,
}

M.STEPS = table.freeze({
	{ id = "arrive", beat = 0 },
	{ id = "dodge", beat = 1, line = "opening.tumble.dodges", count = "dodges", of = 2 },
	{ id = "tumble", beat = 1, line = "opening.tumble.stakes", count = "stakes", of = 3 },
	{ id = "mirror", beat = 2, line = "opening.mirror.heap", target = "rw.onboarding.carcass" },
	{ id = "bone", beat = 3, line = "opening.knife.bone", target = "rw.onboarding.carcass" },
	{ id = "fiber", beat = 3, line = "opening.knife.fiber", target = "rw.onboarding.fiber" },
	{ id = "bone-knife", beat = 3, line = "opening.knife.craft", target = "rw.onboarding.extra-1" },
	{
		id = "flint",
		beat = 4,
		line = "opening.hatchet.flint",
		count = "flint",
		of = 2,
		target = "rw.onboarding.extra-1",
	},
	{ id = "hatchet", beat = 4, line = "opening.hatchet.craft", target = "opening.ford" },
	{ id = "stream", beat = 5, line = "opening.ridge.stream", target = "opening.ford" },
	{ id = "wood", beat = 5, line = "opening.ridge.wood", count = "wood", of = 7, target = "opening.windfall" },
	{ id = "camp", beat = 5, line = "opening.ridge.camp", target = "npc.marit" },
	{ id = "campfire", beat = 6, line = "opening.camp.place", target = "station.campfire.t1" },
	{ id = "accept", beat = 6, line = "opening.camp.accept", target = "npc.marit" },
	{ id = "deliver", beat = 6, line = "opening.camp.deliver", target = "opening.beacon" },
	{ id = "windbreak", beat = 7, line = "opening.beacon.windbreak", target = "npc.marit" },
	{ id = "beacon", beat = 7, line = "opening.beacon.light", target = "opening.beacon" },
	{ id = "board", beat = 7, line = "opening.beacon.board", target = "opening.jetty" },
} :: { Step })
M.TITLES = table.freeze({
	"opening.tumble.title",
	"opening.mirror.title",
	"opening.knife.title",
	"opening.hatchet.title",
	"opening.ridge.title",
	"opening.camp.title",
	"opening.beacon.title",
})

-- Beat timing (opening-script.md section 2).
M.COLD_OPEN_MILLIS = 30000 -- beat 0 budget: arrival counts without the client's cinematic end
M.FIRST_CHARGE_DELAY = 600 -- the boar bursts out this long after the 2nd stake pops
M.CHARGE_MILLIS = 1500 -- warning to strike
M.SLOW_FACTOR = 0.35 -- the first charge plays at 0.35 speed ...
M.SLOW_MILLIS = 1200 -- ... for 1.2 s of wall time
M.GRACE_MILLIS = 400 -- a dodge started up to this long after the strike still counts
M.NEXT_CHARGE_MILLIS = 4000
M.DODGES_NEEDED, M.MAX_TRIES = 2, 4
M.MIRROR_MILLIS = 6000 -- the signal card auto-advances
M.BOAT_MILLIS = 4000 -- the Gannet rounds the headland after the beacon is lit
M.STAKES = 3
-- The client starts each boar run at most this far (flat studs) from the player: at the closest
-- zoom (share 0.15) the 57-degree, 30-degree-FOV play camera still shows ~14 studs of ground
-- behind the character and ~20 ahead, so the whole run and its telegraph stay on screen at every
-- zoom. D2b (R04) never saw the boar in 8 dodge-beat frames: the run started at the lane anchor,
-- ~33 studs off, at the anchor's y=2 (under the relief terrain); the client now grounds it.
M.CHARGE_REACH = 14
-- C1 fix 1 (p134 C1 phone run: "no red telegraph was ever caught on screen"): a red ground ring
-- under the player shows this long before each charge starts and stays until the dodge grace ends.
M.TELEGRAPH_LEAD_MILLIS = 1500

--- Red ground-ring telegraph for `charge` at server time `now` (ms): shown, and its fill 0..1
--- (0 when it appears, 1 at the strike).
function M.telegraph(charge: any, now: number): (boolean, number)
	if type(charge) ~= "table" then
		return false, 0
	end
	local from = charge.startAt - M.TELEGRAPH_LEAD_MILLIS
	if now < from or now > charge.strikeAt + M.GRACE_MILLIS then
		return false, 0
	end
	return true, math.clamp((now - from) / math.max(1, charge.strikeAt - from), 0, 1)
end

--- Flat (x, z) start of a boar run from the lane anchor toward the player at (px, pz).
function M.chargeFrom(lx: number, lz: number, px: number, pz: number): (number, number)
	local dx, dz = lx - px, lz - pz
	local length = math.sqrt(dx * dx + dz * dz)
	if length <= M.CHARGE_REACH then
		return lx, lz
	end
	local k = M.CHARGE_REACH / length
	return px + dx * k, pz + dz * k
end

--- Flat (x, z) of the boar at run progress k (0 start, 1 at the player).
function M.chargeAt(sx: number, sz: number, px: number, pz: number, k: number): (number, number)
	local t = math.clamp(k, 0, 1)
	return sx + (px - sx) * t, sz + (pz - sz) * t
end

local INDEX: { [string]: number } = {}
for index, step in M.STEPS do
	INDEX[step.id] = index
end
M.INDEX = INDEX

export type Charge = { startAt: number, strikeAt: number, slow: boolean }
export type State = {
	index: number, -- current step (#STEPS + 1 = finished)
	bypass: boolean, -- returning player: the opening never stages
	startedAt: number,
	coldOpenDone: boolean,
	pulled: { boolean },
	dodges: number,
	tries: number,
	dodgePassed: boolean,
	charge: Charge?,
	lastHit: boolean,
	mirrorAt: number?,
	mirrorDismissed: boolean,
	beaconAt: number?,
	boarded: boolean,
}

local function count(pulled: { boolean }): number
	local n = 0
	for index = 1, M.STAKES do
		n += if pulled[index] then 1 else 0
	end
	return n
end
M.stakes = count

function M.new(now: number): State
	return {
		index = 1,
		bypass = false,
		startedAt = now,
		coldOpenDone = false,
		pulled = { false, false, false },
		dodges = 0,
		tries = 0,
		dodgePassed = false,
		charge = nil,
		lastHit = false,
		mirrorAt = nil,
		mirrorDismissed = false,
		beaconAt = nil,
		boarded = false,
	}
end

function M.current(state: State): Step?
	return if state.bypass then nil else M.STEPS[state.index]
end

function M.finished(state: State): boolean
	return state.bypass or state.index > #M.STEPS
end

--- Resumes a player. `saved` is the persisted record (nil when none). A player with no record
--- whose tutorial is already complete is a returning player: bypassed, never staged. A player
--- with no record who is past the arrival and first gather resumes after the scripted beats.
function M.resume(saved: any, tutorialIndex: number, tutorialComplete: boolean, now: number): State
	local state = M.new(now)
	if type(saved) == "table" and type(saved.index) == "number" then
		state.index = math.clamp(math.floor(saved.index), 1, #M.STEPS + 1)
		state.bypass = saved.bypass == true
		state.dodges = if type(saved.dodges) == "number" then saved.dodges else 0
		state.tries = if type(saved.tries) == "number" then saved.tries else 0
		state.beaconAt = if type(saved.beaconAt) == "number" then saved.beaconAt else nil
		state.coldOpenDone = state.index > INDEX.arrive
		state.dodgePassed = state.index > INDEX.dodge
		for index = 1, M.STAKES do
			state.pulled[index] = state.index > INDEX.tumble
				or (type(saved.pulled) == "table" and saved.pulled[index] == true)
		end
		-- A rejoin during the dodge beat restarts its charges from the pulled stakes.
		if state.index == INDEX.dodge and count(state.pulled) >= 2 then
			state.charge = M.charge(now + M.FIRST_CHARGE_DELAY, state.tries == 0)
		end
		return state
	end
	if tutorialComplete then
		state.bypass = true
	elseif tutorialIndex > 2 then
		state.index, state.coldOpenDone, state.dodgePassed = INDEX.bone, true, true
		state.pulled = { true, true, true }
	end
	return state
end

function M.save(state: State): any
	return {
		v = 1,
		index = state.index,
		bypass = state.bypass,
		pulled = table.clone(state.pulled),
		dodges = state.dodges,
		tries = state.tries,
		beaconAt = state.beaconAt,
	}
end

function M.charge(startAt: number, slow: boolean): Charge
	local strike = startAt + M.CHARGE_MILLIS
	if slow then
		-- 1.2 s of wall time covers only 0.35 x 1.2 s of the charge.
		strike += math.floor(M.SLOW_MILLIS * (1 - M.SLOW_FACTOR) + 0.5)
	end
	return { startAt = startAt, strikeAt = strike, slow = slow }
end

local function is(state: State, id: string): boolean
	return not state.bypass and state.index == INDEX[id]
end

--- Pulls one rope stake (server prompt). Stakes 1-2 are pulled before the charge; popping the
--- second sends the scripted boar. The last stake is pulled after the dodge beat.
function M.pull(state: State, stake: number, now: number): (boolean, string?)
	if stake % 1 ~= 0 or stake < 1 or stake > M.STAKES then
		return false, "INVALID_STAKE"
	elseif state.pulled[stake] then
		return false, "ALREADY_PULLED"
	end
	local pulled = count(state.pulled)
	if not ((is(state, "dodge") and pulled < 2) or is(state, "tumble")) then
		return false, "NOT_NOW"
	end
	state.pulled[stake] = true
	if pulled + 1 == 2 and is(state, "dodge") then
		state.charge = M.charge(now + M.FIRST_CHARGE_DELAY, true)
	end
	return true, nil
end

function M.coldOpenDone(state: State): boolean
	if not is(state, "arrive") then
		return false
	end
	state.coldOpenDone = true
	return true
end

function M.dismissMirror(state: State): boolean
	if not is(state, "mirror") then
		return false
	end
	state.mirrorDismissed = true
	return true
end

function M.lightBeacon(state: State, now: number): boolean
	if not is(state, "beacon") then
		return false
	end
	state.beaconAt = now
	return true
end

function M.boatArrived(state: State, now: number): boolean
	return state.beaconAt ~= nil and now >= state.beaconAt + M.BOAT_MILLIS
end

function M.board(state: State, now: number): (boolean, string?)
	if not is(state, "board") then
		return false, "NOT_NOW"
	elseif not M.boatArrived(state, now) then
		return false, "BOAT_NOT_IN"
	end
	state.boarded = true
	return true, nil
end

-- Resolves due boar charges. The boar is a scripted presentation, never a wildlife entity: a
-- charge has no damage path at all; a missed dodge only changes the card text.
local function resolve(state: State, facts: Facts, now: number)
	local charge = state.charge
	while charge and now >= charge.strikeAt + M.GRACE_MILLIS do
		local at = facts.dodgeAt
		local clean = at ~= nil and at >= charge.startAt and at <= charge.strikeAt + M.GRACE_MILLIS
		state.tries += 1
		state.dodges += if clean then 1 else 0
		state.lastHit = not clean
		if state.dodges >= M.DODGES_NEEDED or state.tries >= M.MAX_TRIES then
			state.dodgePassed, charge = true, nil
		else
			charge = M.charge(charge.strikeAt + M.GRACE_MILLIS + M.NEXT_CHARGE_MILLIS, false)
		end
	end
	state.charge = charge
end

local function satisfied(state: State, id: string, facts: Facts, now: number): boolean
	local items, t = facts.items, facts.tutorialIndex
	local knife = (items["bone-knife"] or 0) > 0
	local axe = (items["stone-axe"] or 0) > 0 or t > 3
	if id == "arrive" then
		return t > 1 and (state.coldOpenDone or now >= state.startedAt + M.COLD_OPEN_MILLIS)
	elseif id == "dodge" then
		return state.dodgePassed
	elseif id == "tumble" then
		return count(state.pulled) >= M.STAKES
	elseif id == "mirror" then
		return state.mirrorDismissed or (state.mirrorAt ~= nil and now >= state.mirrorAt + M.MIRROR_MILLIS)
	elseif id == "bone" then
		return (items.bone or 0) > 0 or knife or axe
	elseif id == "fiber" then
		return (items.fiber or 0) >= 3 or knife or axe
	elseif id == "bone-knife" then
		return knife or axe
	elseif id == "flint" then
		return (items.flint or 0) >= 2 or axe
	elseif id == "hatchet" then
		return axe
	elseif id == "stream" then
		return facts.nearFord or facts.nearMarit or t > 4
	elseif id == "wood" then
		return (items.wood or 0) >= 7 or t > 4
	elseif id == "camp" then
		return facts.nearMarit or t > 4
	elseif id == "campfire" then
		return t > 4
	elseif id == "accept" then
		return t > 5
	elseif id == "deliver" then
		return facts.tutorialComplete
	elseif id == "windbreak" then
		return facts.windbreak
	elseif id == "beacon" then
		return state.beaconAt ~= nil
	elseif id == "board" then
		return state.boarded
	end
	return false
end

--- Advances on server facts. Steps complete strictly in order; each completed step calls
--- `emit(stepId, index, beat)` exactly once (the `opening_step` analytics event). Returns
--- true when anything changed.
function M.advance(state: State, facts: Facts, now: number, emit: (string, number, number) -> ()): boolean
	if state.bypass then
		return false
	end
	local before = state.index
	local tries, charge = state.tries, state.charge
	resolve(state, facts, now)
	while state.index <= #M.STEPS do
		local step = M.STEPS[state.index]
		if step.id == "mirror" and state.mirrorAt == nil then
			state.mirrorAt = now
		end
		if not satisfied(state, step.id, facts, now) then
			break
		end
		emit(step.id, state.index, step.beat)
		state.index += 1
	end
	return state.index ~= before or state.tries ~= tries or state.charge ~= charge
end

--- Name-plate key over Tumble (client-only rig): tangled, then named once freed; nil after.
function M.tumbleLabel(view: any): string?
	if type(view) ~= "table" or view.active ~= true or (view.beat or 0) > 7 then
		return nil
	end
	return if view.freed then "opening.tumble.name" else "opening.tumble.label"
end

--- Per-stake staging for a view (C1 fix 1, dead end 1): the client applies it to its local copy of
--- the shared stake parts. A stake's prompt is on only while `pull` would accept it (the nearest
--- enabled prompt is never a stake that refuses), a pulled stake lies fallen with its rope cut, and
--- every stake that can be pulled now glows so it is not mistaken for a tent guy-line post.
function M.stakeMarks(view: any): { { prompt: boolean, fallen: boolean, glow: boolean } }
	local marks = {}
	if type(view) ~= "table" or view.active ~= true then
		return marks
	end
	local pulled = view.pulled or {}
	local pulling = view.step == "tumble" or (view.step == "dodge" and count(pulled) < 2)
	for index = 1, M.STAKES do
		local out = pulled[index] == true
		marks[index] = { prompt = not out and pulling, fallen = out, glow = not out and pulling }
	end
	return marks
end

-- Refusal reasons a stake or beacon prompt can surface as a toast (KO and EN: opening.refusal.*).
M.REFUSALS = table.freeze({ "ALREADY_PULLED", "NOT_NOW", "TOO_FAR" })

--- Pack string key of a prompt refusal toast.
function M.refusalKey(reason: string): string
	return "opening.refusal." .. string.lower(reason)
end

-- Gather node the tracker's current step points at (the client marks it with a glow).
M.BONE_NODE = "rw.onboarding.crash-bones"
local GUIDE_NODES: { [string]: string } = {
	mirror = M.BONE_NODE,
	bone = M.BONE_NODE,
	fiber = "rw.onboarding.fiber",
	flint = "rw.onboarding.extra-1",
}
function M.guideNode(view: any): string?
	if type(view) ~= "table" or view.active ~= true then
		return nil
	end
	return GUIDE_NODES[view.step]
end

--- The recipe the craft sheet preselects for a view: the one the opening tracker is asking for.
function M.craftPin(view: any): string?
	if type(view) ~= "table" or view.active ~= true then
		return nil
	end
	local step = view.step
	if step == "bone" or step == "fiber" or step == "bone-knife" then
		return "bone-knife"
	elseif step == "flint" or step == "hatchet" then
		return "stone-axe"
	end
	return nil
end

--- The per-player view the client stages (published as JSON on the Player).
function M.view(state: State, facts: Facts): any
	local step = M.current(state)
	local view = {
		v = 1,
		active = step ~= nil,
		step = if step then step.id else nil,
		beat = if step then step.beat else nil,
		coldOpen = step ~= nil and step.id == "arrive" and not state.coldOpenDone,
		pulled = table.clone(state.pulled),
		dodges = state.dodges,
		tries = state.tries,
		hit = state.lastHit,
		charge = if state.charge then table.clone(state.charge) else nil,
		freed = state.index > INDEX.tumble,
		mirrorAt = state.mirrorAt,
		beaconAt = state.beaconAt,
		boatAt = if state.beaconAt then state.beaconAt + M.BOAT_MILLIS else nil,
		flint = math.min(facts.items.flint or 0, 2),
		wood = math.min(facts.items.wood or 0, 7),
	}
	-- The craft sheet preselects the recipe the tracker asks for (SurvivalHUDModel.extensionPin).
	view.craftPin = M.craftPin(view)
	return view
end

--- Waypoint target (layout anchor or resource node id) of the view's current step, or nil.
function M.target(view: any): string?
	if type(view) ~= "table" or view.active ~= true or type(view.step) ~= "string" then
		return nil
	end
	local index = INDEX[view.step]
	return if index then M.STEPS[index].target else nil
end

--- Quest-card tracker for a view: the beat title and its lines (done lines checked). Beat 0 has
--- no tracker. `text(key)` returns the localized string; counted lines take one %d.
function M.tracker(view: any, text: (string) -> string): (string?, { string })
	if not view or not view.active or (view.beat or 0) < 1 then
		return nil, {}
	end
	local current = INDEX[view.step]
	local lines: { string } = {}
	for index, step in M.STEPS do
		if step.beat ~= view.beat or not step.line then
			continue
		end
		-- The dodge line only shows once the boar is out (two stakes pulled).
		if step.id == "dodge" and count(view.pulled or {}) < 2 then
			continue
		end
		local line = text(step.line)
		if step.count then
			local value = if step.count == "stakes" then count(view.pulled or {}) else view[step.count] or 0
			if index < current then
				value = step.of :: number
			end
			line = string.format(line, math.min(value, step.of :: number))
		end
		if index < current then
			line = (string.gsub(line, "^□", "■"))
		end
		table.insert(lines, line)
	end
	return text(M.TITLES[view.beat]), lines
end

return M
