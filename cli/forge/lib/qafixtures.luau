--!strict
-- Native fixture contract: fixtures: [cli/forge/fixtures/example] loads
-- example/scenario.luau. Module loading declares metadata only; new(ctx) owns
-- per-run state and is called again on reload. Operations return nil on success
-- or a failure string. ctx contains backend, clock, now (integer seconds),
-- session (installed after construction), results, playerOf, packPath, scenario,
-- and fixture (the operation's own new(ctx) result).
-- Minimal scenario.luau:
-- return {
--   operations = { check = function(ctx, step)
--     return if ctx.session.snapshot(ctx.playerOf(step)) then nil else "not joined"
--   end },
--   new = function(_ctx) return {} end,
-- }
-- services, bind(session), and close() -> {ok, reason?} on the instance are
-- optional. Core operation names cannot be overridden; duplicate declarations
-- are rejected. Older fixture directories without operations remain legacy
-- data/service fixtures until migrated; they cannot declare custom operations.

local fs = require("@lune/fs")
local M = {}

function M.load(paths: { string }?, coreOperations: { string }): (any, { string })
	local registry: any = { modules = {}, operations = {} }
	local errors = {}
	local declared: { string } = paths or {}
	for _, path in declared do
		if type(path) ~= "string" or not string.match(path, "^cli/forge/fixtures/[a-z][a-z0-9%-]*$") then
			table.insert(errors, "fixtures: unsafe fixture path " .. tostring(path))
			continue
		end
		if not fs.isFile(path .. "/scenario.luau") then
			continue
		end
		local slug = assert(string.match(path, "([^/]+)$"))
		local ok, module = pcall(require, "../fixtures/" .. slug .. "/scenario")
		if not ok then
			table.insert(errors, "fixtures: cannot load " .. path .. ": " .. tostring(module))
			continue
		end
		if type(module) ~= "table" or module.operations == nil then
			continue
		end
		if type(module.operations) ~= "table" or type(module.new) ~= "function" then
			table.insert(errors, "fixtures: expected operations and new(ctx) in " .. path)
			continue
		end
		table.insert(registry.modules, module)
		for op, handler in module.operations do
			if type(op) ~= "string" or not string.match(op, "^[a-z][a-z0-9_]*$") or type(handler) ~= "function" then
				table.insert(errors, "fixtures: invalid operation in " .. path)
			elseif table.find(coreOperations, op) or registry.operations[op] then
				table.insert(errors, "fixtures: duplicate operation " .. op)
			else
				registry.operations[op] = module
			end
		end
	end
	return registry, errors
end

return M
