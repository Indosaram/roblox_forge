--!strict
-- Engine-free presentation policy. Slots, gains and event mappings come from the pack.
local M = {}
export type Slot = { asset: string, group: string, looped: boolean }
export type Config = {
	slots: { [string]: Slot },
	events: { [string]: string },
	regions: { [string]: string },
	groups: { [string]: number },
	receiptLimit: number,
}
export type Ports = {
	play: (string, Slot) -> (),
	stop: (string) -> (),
	volume: (string, number) -> (),
}
function M.new(config: Config, ports: Ports)
	local disposed, muted = false, false
	local current: string? = nil
	local gains = table.clone(config.groups)
	local seen: { [string]: boolean } = {}
	local order: { string } = {}
	local loops: { [string]: boolean } = {}
	local director = {}
	function director.setMuted(value: boolean)
		if disposed then
			return
		end
		muted = value
		for group, gain in gains do
			ports.volume(group, if muted then 0 else gain)
		end
	end
	function director.setVolume(group: string, gain: number): boolean
		if disposed or gains[group] == nil or gain ~= gain or gain < 0 or gain > 1 then
			return false
		end
		gains[group] = gain
		ports.volume(group, if muted then 0 else gain)
		return true
	end
	function director.event(event: string, active: boolean?): boolean
		if disposed then
			return false
		end
		local name = config.events[event]
		local slot = if name then config.slots[name] else nil
		if not name or not slot then
			return false
		end
		if active == false then
			if loops[name] then
				loops[name] = nil
				ports.stop(name)
			end
			return true
		end
		if slot.looped then
			if loops[name] then
				return true
			end
			loops[name] = true
		elseif muted then
			return true
		end
		ports.play(name, slot)
		return true
	end
	function director.region(region: string): boolean
		if disposed then
			return false
		end
		local name = config.regions[region]
		local slot = if name then config.slots[name] else nil
		if not name or not slot then
			return false
		end
		if current == name then
			return true
		end
		if current then
			ports.stop(current)
		end
		current = name
		ports.play(name, slot)
		return true
	end
	-- The caller supplies the committed domain event, not a button/request prediction.
	function director.result(request: any, result: any, event: string): boolean
		if
			disposed
			or type(request) ~= "table"
			or type(result) ~= "table"
			or result.ok ~= true
			or type(result.stateVersion) ~= "number"
			or type(request.requestId) ~= "string"
			or type(request.action) ~= "string"
			or not config.events[event]
		then
			return false
		end
		local data = result.data
		if type(data) == "table" and data.status ~= nil and data.status ~= "confirmed" then
			return false
		end
		local identity = tostring(request.sessionEpoch) .. ":" .. request.action .. ":" .. request.requestId
		if seen[identity] then
			return false
		end
		seen[identity] = true
		table.insert(order, identity)
		if #order > config.receiptLimit then
			local oldest = assert(table.remove(order, 1), "receipt order nonempty")
			seen[oldest] = nil
		end
		return director.event(event)
	end
	function director.destroy()
		if disposed then
			return
		end
		disposed = true
		if current then
			ports.stop(current)
		end
		for name in loops do
			ports.stop(name)
		end
		table.clear(loops)
		table.clear(seen)
		table.clear(order)
	end
	director.setMuted(false)
	return director
end
return M
