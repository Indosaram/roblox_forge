--!strict
-- ui.dialogue: one pane of original NPC/station text. Opened from a harbor NPC prompt (the
-- prompt talks first; its service panel becomes a choice). Choices depend on the active
-- journal chapter: when the current objective is "speak with <npc>", a Complete choice sends
-- survival-coop:journal-interact for that objective (the individual checkpoint is saved
-- server-side). Continue advances the text; Goodbye closes.
local Sheet = require("./SocialSheet")
local L = require("./SocialLocale")
local M = {}

-- The active chapter's first unfinished objective, if it is "speak" with this npc.
function M.speakObjective(content: any, journal: any, npc: string): any?
	if not journal or not journal.active then
		return nil
	end
	for _, chapter in content.chapters or {} do
		if chapter.id == journal.active then
			for _, objective in chapter.objectives do
				if (journal.counts[objective.id] or 0) < objective.quantity then
					return if objective.action == "speak" and objective.target == npc then objective else nil
				end
			end
		end
	end
	return nil
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
	if state.objective and state.page >= 2 then
		line = text(state.objective.id .. ".text") or line
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
		select = function(extensions: any): any
			return extensions.journal
		end,
		rows = function(journal: any): { any }
			local objective = if npc then M.speakObjective(ctx.content, journal, npc) else nil
			return M.rows(
				ctx.locale,
				{ npc = npc, service = service, objective = objective, page = page, status = status },
				{
					continue = function()
						page += 1
						panel.render()
					end,
					complete = function()
						-- Objective IDs map to world checkpoints "<objective>:1".
						local result = ctx.send("survival-coop:journal-interact", { objective.id .. ":1" })
						status = if result.ok
							then L.text(ctx.locale, "dialogue.done")
							else L.refusal(ctx.locale, result.reason)
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
				},
				function(key: string): string?
					return if ctx.journalText then ctx.journalText(key) else nil
				end
			)
		end,
	})
	panel.talk = function(id: string, panelId: string?)
		npc, service, page, status = id, panelId, 1, nil
		panel.show()
	end
	return panel
end

return M
