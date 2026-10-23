--!strict
-- pool: run independent child-process jobs with bounded concurrency.
-- Each job is a list of steps (argv for `lune run cli/forge ...`); a job stops
-- at its first failing step. Results keep job order.

local process = require("@lune/process")
local task = require("@lune/task")
local specs = require("./specs")

local M = {}

export type Job = { name: string, steps: { { string } } }
export type StepResult = { args: { string }, code: number, stdout: string, stderr: string }
export type JobResult = { name: string, ok: boolean, ms: number, steps: { StepResult } }

local function drain(reader: any, sink: { string })
	while true do
		local chunk = reader:read()
		if chunk == nil or chunk == "" then
			return
		end
		table.insert(sink, chunk)
	end
end

-- Runs one forge invocation without blocking sibling coroutines.
function M.forge(args: { string }): StepResult
	local argv = { "run", "cli/forge" }
	for _, arg in args do
		table.insert(argv, arg)
	end
	local okCreate, child = pcall(process.create, specs.luneExecutable(), argv)
	if not okCreate then
		return { args = args, code = 127, stdout = "", stderr = tostring(child) }
	end
	local out: { string } = {}
	local err: { string } = {}
	local readers = 2
	task.spawn(function()
		drain(child.stdout, out)
		readers -= 1
	end)
	task.spawn(function()
		drain(child.stderr, err)
		readers -= 1
	end)
	while readers > 0 do
		task.wait(0.05)
	end
	local status = child:status()
	return { args = args, code = status.code, stdout = table.concat(out), stderr = table.concat(err) }
end

function M.run(jobs: { Job }, concurrency: number, onDone: ((JobResult) -> ())?): { JobResult }
	local results: { JobResult } = {}
	local nextIndex = 1
	local active = 0
	local finished = 0
	local function worker()
		while nextIndex <= #jobs do
			local index = nextIndex
			nextIndex += 1
			local job = jobs[index]
			local started = os.clock()
			local steps: { StepResult } = {}
			local ok = true
			for _, args in job.steps do
				local step = M.forge(args)
				table.insert(steps, step)
				if step.code ~= 0 then
					ok = false
					break
				end
			end
			local result = { name = job.name, ok = ok, ms = (os.clock() - started) * 1000, steps = steps }
			results[index] = result
			finished += 1
			if onDone then
				onDone(result)
			end
		end
		active -= 1
	end
	for _ = 1, math.max(1, math.min(concurrency, #jobs)) do
		active += 1
		task.spawn(worker)
	end
	while active > 0 do
		task.wait(0.05)
	end
	return results
end

return M
