--!strict
local M = {}
local current: any = nil
local listeners: { (any) -> () } = {}

function M.get(): any
	return current
end

function M.set(value: { scoreId: string, revision: number, parts: number?, owned: boolean? }?)
	current = if value then table.clone(value) else nil
	for _, listener in listeners do
		listener(current)
	end
end

function M.subscribe(callback: (any) -> ()): () -> ()
	table.insert(listeners, callback)
	return function()
		local index = table.find(listeners, callback)
		if index then
			table.remove(listeners, index)
		end
	end
end

return M
