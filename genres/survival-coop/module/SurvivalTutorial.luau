--!strict
-- SurvivalTutorial: the survival-coop first five minutes (plan §9.4, QA-CORE-01)
-- on top of core/domain/progression/Tutorial.
--
-- One step teaches one thing: arrive (skippable) -> gather -> craft stone axe
-- -> declare settlement -> accept first contract -> deliver first contract.
-- Every advance emits `tutorial_step {step = n}` exactly once and the last one
-- emits `tutorial_complete` exactly once. Progress is the saved step index, so
-- a rejoin resumes at the same step and never re-emits finished steps.

local Tutorial = require("../../../core/domain/progression/Tutorial")

local M = {}

export type Emit = (name: string, fields: { [string]: any }) -> ()
export type Session = { state: Tutorial.State, emit: Emit }

local STEPS: { Tutorial.Step } = {
	{ id = "arrive", hint = "tutorial.arrive", event = "ArrivalDone" },
	{ id = "gather", hint = "tutorial.gather", event = "Gathered" },
	{ id = "craft-stone-axe", hint = "tutorial.craft-stone-axe", event = "CraftedStoneAxe" },
	{ id = "declare-settlement", hint = "tutorial.declare-settlement", event = "SettlementDeclared" },
	{ id = "accept-contract", hint = "tutorial.accept-contract", event = "ContractAccepted" },
	{ id = "deliver-contract", hint = "tutorial.deliver-contract", event = "ContractDelivered" },
}
M.STEPS = STEPS

--- Starts or resumes a session from a saved `Tutorial.Save` (nil = new player).
function M.resume(saved: Tutorial.Save?, emit: Emit): Session
	return { state = Tutorial.fromSave(STEPS, saved), emit = emit }
end

function M.current(session: Session): string?
	local step = Tutorial.current(session.state)
	return if step then step.id else nil
end

--- Feeds one observed gameplay event. Out-of-order and repeated events are
--- ignored and emit nothing.
function M.observe(session: Session, eventName: string): boolean
	local index = session.state.index
	if not Tutorial.observe(session.state, eventName) then
		return false
	end
	session.emit("tutorial_step", { step = index, id = STEPS[index].id })
	if Tutorial.isComplete(session.state) then
		session.emit("tutorial_complete", {})
	end
	return true
end

--- The arrival scene can be skipped immediately; skipping only finishes step 1.
function M.skipArrival(session: Session): boolean
	return M.observe(session, "ArrivalDone")
end

-- The world owner supplies the landing observation; joining or being airborne is
-- not proof of arrival. Repeated landing callbacks never advance the gather step.
function M.landed(session: Session, grounded: boolean): boolean
	return grounded and M.observe(session, "ArrivalDone")
end

function M.save(session: Session): Tutorial.Save
	return Tutorial.toSave(session.state)
end

return M
