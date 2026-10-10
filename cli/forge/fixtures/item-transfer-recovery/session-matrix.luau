--!strict
local run = require("../../lib/run")
local count = 0
for _, direction in { "deposit", "withdraw" } do
	for _, boundary in
		{
			"GRANT_ACCEPTED",
			"SOURCE_PREPARED",
			"SOURCE_ESCROWED",
			"DESTINATION_CREDITED",
			"SOURCE_FINALIZED",
			"CURSOR_SELECTED",
			"SOURCE_FENCED",
			"DESTINATION_SOURCE_FINALIZED",
			"SOURCE_REMOVED",
			"DESTINATION_REMOVED",
			"GRANT_REMOVED",
			"CURSOR_CLEARED",
		}
	do
		for _, mode in { "failure", "lost", "crash" } do
			local result = run.exec(
				"lune",
				{ "run", "cli/forge/fixtures/item-transfer-recovery/session", direction, boundary, mode }
			)
			assert(result.ok, direction .. " " .. boundary .. " " .. mode .. "\n" .. result.stderr .. result.stdout)
			print(result.stdout)
			count += 1
		end
	end
end
print("session-transfer-crash-matrix: " .. count .. " passed, 0 failed")
