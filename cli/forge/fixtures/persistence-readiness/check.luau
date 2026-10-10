--!strict
-- Behavioral fixture for the readiness runtime the Studio driver embeds
-- (cli/release/persistence-readiness.luau, wrapped by cli/release/persistence-readiness.mjs). It
-- requires that exact module and drives it with staged publication -- the container, then the
-- child, then the child's Value or the attribute -- under a deterministic clock, so the wake path,
-- the single absolute deadline and the cleanup on every path are executed rather than matched.
local runtime = require("../../../release/persistence-readiness")

local function signal(): any
	local listeners: { { connected: boolean, fn: (...any) -> () } } = {}
	local s: any = {}
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
	function s:count(): number
		local total = 0
		for _, entry in listeners do
			if entry.connected then
				total += 1
			end
		end
		return total
	end
	return s
end

local function instance(className: string, name: string): any
	local object: any = {
		ClassName = className,
		Name = name,
		Parent = nil,
		Value = "",
		attrs = {},
		children = {},
		ChildAdded = signal(),
		ChildRemoved = signal(),
		attributeSignals = {},
		propertySignals = {},
	}
	function object:IsA(class)
		return self.ClassName == class
	end
	function object:FindFirstChild(childName)
		for _, child in ipairs(self.children) do
			if child.Name == childName then
				return child
			end
		end
		return nil
	end
	function object:GetAttribute(key)
		return self.attrs[key]
	end
	function object:GetAttributeChangedSignal(key)
		if not self.attributeSignals[key] then
			self.attributeSignals[key] = signal()
		end
		return self.attributeSignals[key]
	end
	function object:GetPropertyChangedSignal(key)
		if not self.propertySignals[key] then
			self.propertySignals[key] = signal()
		end
		return self.propertySignals[key]
	end
	return object
end

local function adopt(parent: any, child: any)
	child.Parent = parent
	table.insert(parent.children, child)
	parent.ChildAdded:Fire(child)
end

local function disown(parent: any, child: any)
	child.Parent = nil
	for index, entry in ipairs(parent.children) do
		if entry == child then
			table.remove(parent.children, index)
			break
		end
	end
	parent.ChildRemoved:Fire(child)
end

local function setValue(object: any, value: string)
	object.Value = value
	object:GetPropertyChangedSignal("Value"):Fire()
end

local function setAttribute(object: any, key: string, value: any)
	object.attrs[key] = value
	object:GetAttributeChangedSignal(key):Fire()
end

-- Lune prefixes an assert message with the position that raised it, so a refusal's code is the
-- message's tail rather than its whole text; the repository's own specs match assert messages the
-- same way (core/domain/genre/Executor.spec.luau:332, core/ui-kit/InventoryGrid.spec.luau:137). The
-- errors raised with error(..., 0) are compared exactly below, because nothing prefixes those.
local function refusal(err: any, code: string): boolean
	return string.sub(tostring(err), -#code) == code
end

-- Deterministic stand-in for the maintained observe helper. It runs the caller's action once and,
-- while the predicate still means STILL WAITING, publishes the next staged event and reports whether
-- that publication woke the caller's own aggregate signal. Nothing woke it, or nothing is left to
-- publish, is the bounded wait expiring: the clock then advances to the deadline and the helper
-- raises exactly the error the real observe raises. ctx.failWith injects a raised error instead, and
-- ctx.advanceOnFail chooses whether it arrives before or at the deadline.
local function harness(container: any, stages: { () -> () }): (any, () -> any)
	local clock = 0
	local expiries = 0
	local publishes = 0
	local destroyed = 0
	local aggregates = 0
	local waits = 0
	local maxSeconds = 0
	local ctx: any = {
		service = container,
		signal = function()
			aggregates += 1
			local s = signal()
			return {
				event = s,
				fire = function()
					s:Fire()
				end,
				destroy = function()
					destroyed += 1
				end,
			}
		end,
		now = function()
			return clock
		end,
	}
	ctx.waitEvent = function(aggregateEvent, action, required, seconds)
		waits += 1
		if seconds > maxSeconds then
			maxSeconds = seconds
		end
		local result = action()
		if not required(result) then
			return result, true
		end
		if ctx.failWith then
			if ctx.advanceOnFail then
				clock += math.ceil(seconds * 1000)
			end
			error(ctx.failWith, 0)
		end
		local observed = nil
		local connection = aggregateEvent:Connect(function()
			observed = true
		end)
		local published = false
		local stage = stages[publishes + 1]
		if stage then
			publishes += 1
			published = true
			stage()
		end
		connection:Disconnect()
		if published and observed then
			return result, observed
		end
		expiries += 1
		clock += math.ceil(seconds * 1000)
		error("WORKLOAD_EVENT_TIMEOUT", 0)
	end
	return ctx,
		function()
			return {
				clock = clock,
				expiries = expiries,
				publishes = publishes,
				destroyed = destroyed,
				aggregates = aggregates,
				waits = waits,
				maxSeconds = maxSeconds,
			}
		end
end

local markerSpec = {
	object = "ForgePersistence",
	child = "StartupLeaseReached",
	childClass = "StringValue",
	childCondition = "nonempty",
	budgetMs = 25000,
}

-- The defect this fixture exists for: the marker is parented with an empty Value and its Value is
-- assigned later (RuntimeBackend.luau:112 then :114), so readiness must wake on the child's Value
-- change. Without that signal the wait burns its whole budget and only then finds the value, which
-- the expiry count below refuses.
do
	local container = instance("ServerStorage", "ServerStorage")
	local target = instance("Folder", "ForgePersistence")
	local marker = instance("StringValue", "StartupLeaseReached")
	local ctx, state = harness(container, {
		function()
			adopt(container, target)
		end,
		function()
			adopt(target, marker)
		end,
		function()
			setValue(marker, '{"ticket":"t"}')
		end,
	})
	local result = runtime.await(ctx, markerSpec)
	local observed = state()
	assert(result == target, "the awaited object is returned")
	assert(observed.publishes == 3, "every staged publication was consumed")
	assert(
		observed.expiries == 0 and observed.clock == 0,
		"each publication woke the wait and the deadline was never consumed"
	)
	assert(
		observed.aggregates == 1 and observed.destroyed == 1 and observed.waits == 3,
		"one aggregate signal, one bounded wait per publication, destroyed on the success path"
	)
	assert(
		container.ChildAdded:count() == 0
			and target.ChildAdded:count() == 0
			and target.ChildRemoved:count() == 0
			and marker:GetPropertyChangedSignal("Value"):count() == 0,
		"every connection is released on the success path"
	)
end

-- A child that is removed and republished must not accumulate Value connections.
do
	local container = instance("ServerStorage", "ServerStorage")
	local target = instance("Folder", "ForgePersistence")
	local marker = instance("StringValue", "StartupLeaseReached")
	local ctx, state = harness(container, {
		function()
			adopt(container, target)
		end,
		function()
			adopt(target, marker)
		end,
		function()
			disown(target, marker)
		end,
		function()
			adopt(target, marker)
		end,
		function()
			setValue(marker, '{"ticket":"t"}')
		end,
	})
	local result = runtime.await(ctx, markerSpec)
	local observed = state()
	assert(result == target and observed.expiries == 0, "a republished child still wakes the wait")
	assert(
		observed.publishes == 5 and marker:GetPropertyChangedSignal("Value"):count() == 0,
		"one Value connection at a time, none surviving the success path"
	)
end

-- The handshake needs no callback property read: OnInvoke is assigned before the child is parented
-- (cli/forge/lib/buildidentity.luau:146 then :149), so the parented child is the readiness contract.
-- The fake child has no OnInvoke field at all, so any read of it would never become ready.
do
	local container = instance("ServerScriptService", "ServerScriptService")
	local identity = instance("Script", "ForgeBuildIdentity")
	local handshake = instance("BindableFunction", "Handshake")
	local ctx, state = harness(container, {
		function()
			adopt(container, identity)
		end,
		function()
			adopt(identity, handshake)
		end,
	})
	local result = runtime.await(
		ctx,
		{ object = "ForgeBuildIdentity", child = "Handshake", childClass = "BindableFunction", budgetMs = 25000 }
	)
	local observed = state()
	assert(
		result == identity and observed.expiries == 0,
		"a parented handshake child is ready without reading its callback"
	)
	assert(
		observed.publishes == 2 and identity.ChildAdded:count() == 0,
		"the wait ended on the publication, and released"
	)
end

-- An attribute that is set after the object exists must wake the wait through its own signal.
do
	local container = instance("ServerStorage", "ServerStorage")
	local target = instance("Folder", "ForgePersistence")
	local ctx, state = harness(container, {
		function()
			adopt(container, target)
		end,
		function()
			setAttribute(target, "ObservedLeaseExpiry", 1791373040)
		end,
	})
	local result =
		runtime.await(ctx, { object = "ForgePersistence", attribute = "ObservedLeaseExpiry", budgetMs = 25000 })
	local observed = state()
	assert(
		result == target and observed.expiries == 0 and observed.publishes == 2,
		"the attribute publication wakes the wait"
	)
	assert(target:GetAttributeChangedSignal("ObservedLeaseExpiry"):count() == 0, "the attribute connection is released")
	assert(
		target.ChildAdded:count() == 0 and target.ChildRemoved:count() == 0,
		"no child signal is connected when no child is required"
	)
end

-- The child exists but its Value never arrives: one bounded wait, then the child readiness failure,
-- with the connections and the aggregate signal released before the error.
do
	local container = instance("ServerStorage", "ServerStorage")
	local target = instance("Folder", "ForgePersistence")
	local marker = instance("StringValue", "StartupLeaseReached")
	local ctx, state = harness(container, {
		function()
			adopt(container, target)
		end,
		function()
			adopt(target, marker)
		end,
	})
	local ok, err = pcall(runtime.await, ctx, markerSpec)
	local observed = state()
	assert(
		not ok and refusal(err, "READINESS_CHILD_TIMEOUT:ForgePersistence.StartupLeaseReached"),
		"an unset marker Value is a child readiness failure: ok=" .. tostring(ok) .. " err=" .. tostring(err)
	)
	assert(
		observed.expiries == 1
			and observed.waits == observed.publishes + 1
			and observed.maxSeconds <= 25
			and observed.clock == 25000,
		"one expiry at the deadline, and no wait after it"
	)
	assert(
		observed.destroyed == 1
			and marker:GetPropertyChangedSignal("Value"):count() == 0
			and container.ChildAdded:count() == 0
			and target.ChildAdded:count() == 0,
		"cleanup ran on the readiness failure path"
	)
end

-- Nothing published: the deadline expires, is tolerated as the wait's own expiry, and the object
-- assert decides with its own code.
do
	local container = instance("ServerStorage", "ServerStorage")
	local ctx, state = harness(container, {})
	local ok, err =
		pcall(runtime.await, ctx, { object = "ForgePersistence", attribute = "ObservedLeaseExpiry", budgetMs = 25000 })
	local observed = state()
	assert(
		not ok and refusal(err, "READINESS_OBJECT_TIMEOUT:ForgePersistence"),
		"a missing object fails with its own code: ok=" .. tostring(ok) .. " err=" .. tostring(err)
	)
	assert(
		observed.expiries == 1 and observed.destroyed == 1 and container.ChildAdded:count() == 0,
		"cleanup ran before the object assert"
	)
end

-- The object exists but the attribute never arrives.
do
	local container = instance("ServerStorage", "ServerStorage")
	local target = instance("Folder", "ForgePersistence")
	local ctx, state = harness(container, {
		function()
			adopt(container, target)
		end,
	})
	local ok, err =
		pcall(runtime.await, ctx, { object = "ForgePersistence", attribute = "ObservedLeaseExpiry", budgetMs = 25000 })
	assert(
		not ok and refusal(err, "READINESS_ATTRIBUTE_TIMEOUT:ForgePersistence.ObservedLeaseExpiry"),
		"a missing attribute fails with its own code: ok=" .. tostring(ok) .. " err=" .. tostring(err)
	)
	assert(state().destroyed == 1 and container.ChildAdded:count() == 0, "cleanup ran before the attribute assert")
end

-- An unexpected error is re-raised with its exact value even when it arrives at the deadline: the
-- tolerance is only ever the bounded wait's own expiry, never any error.
do
	local container = instance("ServerStorage", "ServerStorage")
	local ctx, state = harness(container, {})
	ctx.failWith = "UNEXPECTED_ENGINE_FAILURE"
	ctx.advanceOnFail = true
	local ok, err = pcall(runtime.await, ctx, { object = "ForgePersistence", budgetMs = 25000 })
	assert(
		not ok and tostring(err) == "UNEXPECTED_ENGINE_FAILURE",
		"an unexpected error keeps its exact value at the deadline"
	)
	assert(state().destroyed == 1 and container.ChildAdded:count() == 0, "cleanup ran before the rethrow")
end

-- The same error before the deadline is re-raised too: the tolerance is the deadline, not the text.
do
	local container = instance("ServerStorage", "ServerStorage")
	local ctx, state = harness(container, {})
	ctx.failWith = "WORKLOAD_EVENT_TIMEOUT"
	ctx.advanceOnFail = false
	local ok, err = pcall(runtime.await, ctx, { object = "ForgePersistence", budgetMs = 25000 })
	assert(
		not ok and tostring(err) == "WORKLOAD_EVENT_TIMEOUT",
		"the wait's own expiry before the deadline is a real failure"
	)
	assert(state().destroyed == 1, "cleanup ran before the rethrow")
end

-- The wait's own expiry exactly at the deadline is tolerated, and the readiness assert then decides.
do
	local container = instance("ServerStorage", "ServerStorage")
	local ctx, state = harness(container, {})
	ctx.failWith = "WORKLOAD_EVENT_TIMEOUT"
	ctx.advanceOnFail = true
	local ok, err = pcall(runtime.await, ctx, { object = "ForgePersistence", budgetMs = 25000 })
	assert(
		not ok and refusal(err, "READINESS_OBJECT_TIMEOUT:ForgePersistence"),
		"a tolerated expiry still refuses through the readiness assert: ok=" .. tostring(ok) .. " err=" .. tostring(err)
	)
	assert(state().destroyed == 1, "cleanup ran before the readiness assert")
end

print("PASS readiness runtime: staged publication wake, single bounded wait, cleanup and exact errors")
