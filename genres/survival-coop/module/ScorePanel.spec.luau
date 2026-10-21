--!strict
local Panel = require("./ScorePanel")
local Rules = require("../../../core/domain/music/TestCatalog")
local serde = require("@lune/serde")
return {
	["editor preserves invalid draft and schedules immutable timestamps once"] = function()
		local rendered: any = nil
		local events: { any } = {}
		local panel = Panel.new({
			rules = Rules,
			decode = function(text)
				return serde.decode("json", text)
			end,
			encode = function(value)
				return serde.encode("json", value)
			end,
			render = function(value)
				rendered = value
			end,
			send = function()
				return { ok = true }
			end,
			confirmDiscard = function()
				return false
			end,
			serverNow = function()
				return 10
			end,
			playAt = function(event)
				table.insert(events, event)
			end,
			preview = function() end,
		})
		assert(
			panel.import('{"version":1,"tempo":120,"parts":[{"instrumentId":"piano","notes":[]}]}'),
			"ScorePanel.spec.luau: invariant failed"
		)
		assert(not panel.close(), "ScorePanel.spec.luau: invariant failed")
		assert(not panel.tempo(201), "ScorePanel.spec.luau: invariant failed")
		assert(rendered.tempo == 120, "ScorePanel.spec.luau: invariant failed")
		assert(
			panel.edit(1, 1, { startTick = 0, durationTicks = 480, pitch = 60, velocity = 100 }),
			"ScorePanel.spec.luau: invariant failed"
		)
		assert(not panel.edit(1, 1, { pitch = 999 }), "ScorePanel.spec.luau: invariant failed")
		assert(rendered.parts[1].notes[1].pitch == 60, "ScorePanel.spec.luau: invariant failed")
		assert(panel.save(nil).ok, "ScorePanel.spec.luau: invariant failed")
		assert(panel.close(), "ScorePanel.spec.luau: invariant failed")
		local snapshot =
			{ ensemble = { room = { startAt = 12, events = { { at = 12, untilAt = 13, instrumentId = "piano" } } } } }
		panel.snapshot(snapshot)
		panel.snapshot(snapshot)
		assert(#events == 1 and events[1].at == 12, "ScorePanel.spec.luau: invariant failed")
		assert(not panel.preview("unknown", 60, 100), "ScorePanel.spec.luau: invariant failed")
	end,
}
