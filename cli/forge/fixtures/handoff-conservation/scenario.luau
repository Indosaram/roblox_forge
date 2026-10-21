--!strict
-- Production camp ownership and transactions; all injected failures and
-- observations are declared by the native scenario, not reimplemented here.
local Camp = require("../camp-ladder/scenario")
local M = {}
function M.new(packPath, backend, now)
	return Camp.new(packPath, backend, now)
end
return M
