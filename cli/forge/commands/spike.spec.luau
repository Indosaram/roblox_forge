--!strict
-- `forge spike` as a real process: writes the JSON report and maps the gate
-- verdict and usage errors onto exit codes.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local OUT = "build/spec-tmp/spike-spec.json"

local function forge(args: { string }): { code: number, stdout: string, stderr: string }
	local argv = { "run", "cli/forge", "spike" }
	for _, arg in args do
		table.insert(argv, arg)
	end
	local res = process.exec("lune", argv)
	return { code = res.code, stdout = res.stdout, stderr = res.stderr }
end

return {
	["spike writes a passing schemaVersion 1 report and exits 0"] = function()
		if fs.isFile(OUT) then
			fs.removeFile(OUT)
		end
		local res = forge({ "--players", "64", "--seed", "1", "--out", OUT })
		assert(res.code == 0, "exit " .. res.code .. "\n" .. res.stdout .. res.stderr)
		assert(string.find(res.stdout, "spike: PASS players=64", 1, true), res.stdout)
		local report = serde.decode("json", fs.readFile(OUT))
		assert(report.schemaVersion == 1 and report.ok == true, "report not ok")
		assert(report.lost == 0 and report.overfull == 0 and report.leaks == 0, "gate counters not zero")
		assert(report.wait.p95 <= report.targetP95, "p95 over target")
		fs.removeFile(OUT)
	end,

	["spike rejects bad arguments with exit 1"] = function()
		for _, args in { { "--players", "0" }, { "--seed", "x" }, { "--bogus" }, { "--seed", "1", "--seed", "2" } } do
			local res = forge(args)
			assert(res.code == 1, table.concat(args, " ") .. " exited " .. res.code)
		end
	end,
}
