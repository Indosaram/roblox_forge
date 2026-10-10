--!strict
-- Behavioral fixture for the real gather correlation and per-attempt reset modules the Studio
-- gameplay driver embeds (cli/forge/qa/gathering-correlation.luau, gathering-reset.luau). It
-- requires those modules and drives the real event ordering, so what the marker accepts, refuses
-- and keeps is executed here, not matched as text and not returned by a mock.
local serde = require("@lune/serde")
local correlation = require("../../qa/gathering-correlation")
local resetModule = require("../../qa/gathering-reset")

local function signal()
	local listeners: { { connected: boolean, fn: (...any) -> () } } = {}
	local s = {}
	function s:Connect(fn)
		local entry = { connected = true, fn = fn }
		table.insert(listeners, entry)
		return {
			Disconnect = function()
				entry.connected = false
			end,
		}
	end
	function s:Fire(...)
		for _, entry in listeners do
			if entry.connected then
				entry.fn(...)
			end
		end
	end
	return s
end

local input = signal()
local triggered = signal()
local function marker()
	local value: any = { Name = "ForgeQAGameplayProof", Value = "", attrs = {} }
	function value:GetAttribute(key)
		return self.attrs[key]
	end
	function value:SetAttribute(key, v)
		self.attrs[key] = v
	end
	return value
end
local function bindable()
	local e: any = { Event = signal() }
	function e:Fire(...)
		self.Event:Fire(...)
	end
	return e
end

local nodeId = "tree-1"
local target = { Name = "ForgeGather" }
local relay, requested = bindable(), bindable()
local connections: { any } = {}
local m = marker()
local ctx = {
	input = { InputBegan = input },
	prompt = { PromptTriggered = triggered },
	keyE = "E",
	now = function(): number
		return 0
	end,
	encode = function(value: any): string
		return serde.encode("json", value)
	end,
}
correlation.install(ctx, m, target, nodeId, relay, requested, connections)
assert(#connections == 4, "every correlation subscription is installed once")
assert(m:GetAttribute("RequestId") == false and m:GetAttribute("Captured") == false, "no identity before any dispatch")
assert(m:GetAttribute("Input") == false and m:GetAttribute("Relevant") == 0, "no input and no correlation yet")

local function dispatch(requestId: string)
	requested:Fire({ nodeId = nodeId, requestId = requestId, serverTime = 1 })
end
local function deliver(requestId: string, result: any)
	relay:Fire({ nodeId = nodeId, requestId = requestId, result = result })
end
local function delivered(): any
	if m.Value == "" or m.Value == "INVALID" then
		return nil
	end
	return serde.decode("json", m.Value)
end

-- No result may be accepted before this step's own injected input, even when the client has
-- published a dispatch identity for it.
dispatch("r-1")
deliver("r-1", { ok = true, data = { status = "confirmed" } })
assert(delivered() == nil and m:GetAttribute("Relevant") == 0, "a result before any input is refused")
triggered:Fire(target)
assert(m:GetAttribute("Triggered") == true, "the service trigger is recorded as evidence")
triggered:Fire({ Name = "ForgeGather" })
assert(m:GetAttribute("Triggered") == true, "a foreign prompt never marks the target")

input:Fire({ KeyCode = "E" })
assert(m:GetAttribute("Input") == true, "the injected key arms the input gate")

-- The defect this fixture exists for: the attempt that dispatched r-1 times out, the driver
-- prepares the next attempt without a settled result, and the client's late result for the
-- request it still holds arrives while that next attempt is preparing. The reset must keep the
-- identity and the value, so the late result is correlated with the input that caused it.
resetModule.reset(m, false, false)
assert(m:GetAttribute("RequestId") == "r-1", "an unresolved request keeps its identity across attempts")
assert(m:GetAttribute("Input") == true, "the step's input gate survives an attempt reset")
deliver("r-1", { ok = true, data = { status = "confirmed" } })
local late = delivered()
assert(late ~= nil and late.requestId == "r-1" and late.result.data.status == "confirmed", "late result accepted")
assert(m:GetAttribute("Relevant") == 1 and m:GetAttribute("Packets") == 2, "only the correlated result is relevant")

-- An unrelated dispatch identity is never accepted while the client holds the correlated request.
deliver("r-other", { ok = true, data = { status = "confirmed" } })
assert(delivered().requestId == "r-1" and m:GetAttribute("Relevant") == 1, "a different dispatch identity is refused")

-- An intermediate result for the same identity reaches the marker, and the terminal result for
-- that identity replaces it once the consumed value is cleared for the next attempt.
resetModule.reset(m, true, false)
deliver("r-1", { ok = false, data = { status = "pending" } })
assert(delivered().result.data.status == "pending", "an intermediate result for the same identity is delivered")
assert(m:GetAttribute("Captured") == "r-1", "the same identity stays captured")
resetModule.reset(m, true, false)
deliver("r-1", { ok = true, data = { status = "confirmed" } })
assert(delivered().result.data.status == "confirmed", "the terminal result for the same identity is delivered")
assert(m:GetAttribute("Relevant") == 3, "every correlated result is counted")

-- A refusal that decided against the frozen payload ends the client's request, so the driver
-- clears the captured identity and the fresh identity the next activation allocates is accepted.
resetModule.reset(m, true, false)
deliver("r-1", { ok = false, reason = "STALE_VERSION", data = { status = "rejected" } })
assert(delivered().result.reason == "STALE_VERSION", "the settled refusal is delivered")
resetModule.reset(m, true, true)
assert(m:GetAttribute("RequestId") == false and m:GetAttribute("Captured") == false, "a settled rejection clears")
dispatch("r-2")
deliver("r-2", { ok = true, data = { status = "confirmed" } })
assert(delivered().requestId == "r-2", "the fresh identity after a settled rejection is accepted")
assert(m:GetAttribute("Relevant") == 5, "the fresh identity is counted once")

-- Without that clear the client's next identity is refused rather than mistaken for the request
-- the marker still holds, which is why the reset is driven by the settled result, not by the
-- attempt count.
dispatch("r-3")
deliver("r-3", { ok = true, data = { status = "confirmed" } })
assert(m.Value == "INVALID", "an identity change without a settled rejection is refused")
assert(m:GetAttribute("Relevant") == 6, "the refused identity is not delivered as this request's result")

print("PASS real gather correlation: input gate, per-dispatch identity, late result, settled rejection")
