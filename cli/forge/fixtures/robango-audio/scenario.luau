--!strict
local Director = require("../../../../genres/survival-coop/module/AudioDirector")
local Catalog = require("../../../../games/robango-island/src/shared/RobangoAudioCatalog")
local M = {}
M.operations = {
	audio_refused_command = function(ctx, step): string?
		local actor = ctx.playerOf(step)
		local action = "survival-coop:craft-complete"
		local request = {
			action = action,
			requestId = "audio-missing-job",
			args = { "missing-job" },
			sessionEpoch = ctx.session.commandEpoch(actor, action),
		}
		local result = ctx.session.command(actor, request)
		ctx.results[actor] = result
		if result.ok then
			return "missing craft job unexpectedly succeeded"
		end
		local count = #ctx.fixture.plays
		ctx.fixture.director.result(request, result, "craft-complete")
		return if #ctx.fixture.plays == count then nil else "refused production command sounded complete"
	end,
	audio_presentation = function(ctx, _step): string?
		local d, plays = ctx.fixture.director, ctx.fixture.plays
		for region in Catalog.regions do
			assert(d.region(region), "configured region")
		end
		for event in Catalog.events do
			assert(d.event(event), "configured event")
		end
		local count = #plays
		d.setMuted(true)
		d.event("reward")
		if #plays ~= count then
			return "muted reward played"
		end
		d.setMuted(false)
		d.event("ui-confirm")
		return if #plays == count + 1 then nil else "unmute failed"
	end,
}
function M.new(_ctx): any
	local plays, stops, gains = {}, {}, {}
	local director = Director.new(Catalog, {
		play = function(name, slot)
			table.insert(plays, { slot = name, group = slot.group })
		end,
		stop = function(name)
			table.insert(stops, name)
		end,
		volume = function(group, gain)
			gains[group] = gain
		end,
	})
	return {
		plays = plays,
		director = director,
		snapshot = function()
			return { plays = plays, stops = stops, gains = gains }
		end,
		close = function()
			director.destroy()
			return { ok = true }
		end,
	}
end
return M
