--!strict
-- ui.dialogue: one pane of original NPC/station text. Opened from a harbor NPC prompt or a
-- station prompt (workbench, communication station, market board): the prompt talks first
-- and its service panel becomes a choice. When the active journal chapter's current
-- objective belongs here (speak with <npc>, assemble at the workbench, activate the relay),
-- Continue shows the chapter's authored offer line and Complete sends
-- survival-coop:journal-interact for that objective; finishing the chapter's last objective
-- shows the authored complete line. Goodbye closes.
local Sheet = require("./SocialSheet")
local L = require("./SocialLocale")
local M = {}
M.DISPLAY_ORDER = 50

-- Objectives a station owns; NPCs own "speak" objectives that name them.
local STATIONS: { [string]: (any) -> boolean } = {
	["station.workbench"] = function(objective: any): boolean
		return objective.action == "assemble"
	end,
	["station.relay"] = function(objective: any): boolean
		return objective.action == "activate" and objective.target == "rw.harbor.relay"
	end,
}
-- Authored guide line a station shows when no chapter objective is due there.
local GUIDES: { [string]: string } = { ["station.market"] = "rw.g08.market.offer" }
-- Mission NPC per objective type (quests spec dialogue table): Marit gathers, Bram crafts and
-- surveys, Ines rescues and hunts, Pip transports.
M.MISSION_NPC = table.freeze({
	gather = "marit",
	craft = "bram",
	survey = "bram",
	rescue = "ines",
	hunt = "ines",
	transport = "pip",
})
-- Extra service choices an NPC offers besides its own panel.
M.EXTRA_SERVICES = table.freeze({ marit = { "organizations" } })

--- The authored mission line this NPC speaks for the actor's active archipelago stage:
--- the offer while its objective is open (hunt picks the stage-specific .sN variant) and the
--- complete line once the objective is recorded. nil when no current objective belongs to it.
function M.missionLine(content: any, archipelago: any, npc: string): string?
	if type(archipelago) ~= "table" or archipelago.status ~= "active" then
		return nil
	end
	local layout = tostring(archipelago.templateId) .. ".s" .. tostring(archipelago.stage)
	for _, stage in content.stages or {} do
		if stage.layout == layout then
			for _, objective in stage.objectives do
				for _, mission in content.missions or {} do
					local kind = string.match(mission.id, "^rw%.m%d+%.(%a+)$")
					local owns = kind ~= nil and M.MISSION_NPC[kind] == npc
					for _, row in if owns then mission.objectives else {} do
						if row.id == objective.id then
							local done = archipelago.completed and archipelago.completed[objective.id]
							if done then
								return mission.id .. ".complete"
							end
							local variant = mission.id .. ".offer.s" .. tostring(archipelago.stage)
							return if table.find(mission.dialogueKeys, variant) then variant else mission.id .. ".offer"
						end
					end
				end
			end
		end
	end
	return nil
end

-- The active chapter's first unfinished objective, if it belongs to this npc/station.
function M.speakObjective(content: any, journal: any, npc: string): (any?, any?)
	if not journal or not journal.active then
		return nil, nil
	end
	local owns = STATIONS[npc]
		or function(objective: any): boolean
			return objective.action == "speak" and objective.target == npc
		end
	for _, chapter in content.chapters or {} do
		if chapter.id == journal.active then
			for _, objective in chapter.objectives do
				if (journal.counts[objective.id] or 0) < objective.quantity then
					return if owns(objective) then objective else nil, if owns(objective) then chapter else nil
				end
			end
		end
	end
	return nil, nil
end

-- state = { npc, service, objective, page, status }
function M.rows(locale: string, state: any, act: any, text: (string) -> string?): { any }
	if not state.npc then
		return { { text = L.text(locale, "npc.default") } }
	end
	local rows: { any } = {}
	local line = if L.has("npc." .. state.npc)
		then L.text(locale, "npc." .. state.npc)
		else L.text(locale, "npc.default")
	local chapter = state.chapter
	if state.objective and state.page >= 2 then
		-- The chapter's authored offer line; objective text only when it is missing.
		line = (chapter and chapter.dialogueKeys and text(chapter.dialogueKeys[1]))
			or text(state.objective.id .. ".text")
			or line
	elseif not state.objective and GUIDES[state.npc] then
		line ..= "\n" .. (text(GUIDES[state.npc]) or "")
	elseif not state.objective and state.mission then
		line ..= "\n" .. (text(state.mission) or "")
	end
	table.insert(rows, { text = line })
	if state.status then
		table.insert(rows, { text = state.status })
	end
	if state.objective and state.page < 2 then
		table.insert(rows, { text = L.text(locale, "dialogue.continue"), onClick = act.continue })
	elseif state.objective then
		table.insert(rows, {
			text = L.text(locale, "dialogue.complete", text(state.objective.id .. ".text") or state.objective.id),
			onClick = act.complete,
		})
	end
	if state.service then
		table.insert(rows, {
			text = L.text(
				locale,
				"dialogue.service",
				L.text(
					locale,
					if L.has("service." .. state.service) then "service." .. state.service else "service.journal"
				)
			),
			onClick = act.service,
		})
	end
	for _, extra in M.EXTRA_SERVICES[state.npc] or {} do
		table.insert(rows, {
			text = L.text(locale, "dialogue.service", L.text(locale, "service." .. extra)),
			onClick = function()
				act.extra(extra)
			end,
		})
	end
	table.insert(rows, { text = L.text(locale, "dialogue.bye"), onClick = act.bye })
	return rows
end

function M.factory(ctx: any): any
	local npc: string?, service: string? = nil, nil
	local page, status = 1, nil :: string?
	local panel: any
	panel = Sheet.mount(ctx, {
		id = "dialogue",
		name = "Dialogue",
		title = L.text(ctx.locale, "dialogue.title"),
		order = 15,
		-- Dialogue takes priority over docked sheets, the menu (30), and placement (40).
		displayOrder = M.DISPLAY_ORDER,
		select = function(extensions: any): any
			return { journal = extensions.journal, archipelago = extensions.archipelago }
		end,
		rows = function(view: any): { any }
			local journal = view and view.journal
			local objective, chapter = nil, nil
			local mission: string? = nil
			if npc then
				objective, chapter = M.speakObjective(ctx.content, journal, npc)
				mission = M.missionLine(ctx.content, view and view.archipelago, npc)
			end
			local function authored(key: string?): string?
				return if key and ctx.journalText then ctx.journalText(key) else nil
			end
			return M.rows(ctx.locale, {
				npc = npc,
				service = service,
				objective = objective,
				chapter = chapter,
				mission = mission,
				page = page,
				status = status,
			}, {
				continue = function()
					page += 1
					panel.render()
				end,
				complete = function()
					-- Objective IDs map to world checkpoints "<objective>:1".
					local result = ctx.send("survival-coop:journal-interact", { objective.id .. ":1" })
					local last = chapter and chapter.objectives[#chapter.objectives].id == objective.id
					status = if not result.ok
						then L.refusal(ctx.locale, result.reason)
						elseif last and chapter.dialogueKeys then authored(chapter.dialogueKeys[2]) or L.text(
							ctx.locale,
							"dialogue.done"
						)
						else L.text(ctx.locale, "dialogue.done")
					page = 1
					panel.render()
				end,
				service = function()
					panel.close()
					if ctx.openPanel and service then
						ctx.openPanel(service)
					end
				end,
				bye = function()
					panel.close()
				end,
				extra = function(id: string)
					panel.close()
					if ctx.openPanel then
						ctx.openPanel(id)
					end
				end,
			}, authored)
		end,
	})
	panel.talk = function(id: string, panelId: string?)
		npc, service, page, status = id, panelId, 1, nil
		panel.show()
	end
	return panel
end

return M
