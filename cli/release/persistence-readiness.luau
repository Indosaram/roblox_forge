--!strict
-- Bounded readiness runtime for the objects the owned server bootstrap publishes asynchronously.
--
-- The RuntimeBackend parents ServerStorage.ForgePersistence and its StartupLeaseReached marker from
-- its own startup path: the marker is parented with an empty Value at RuntimeBackend.luau:112 and
-- its Value is assigned later when the barrier is actually reached (:114), and ObservedLeaseExpiry is
-- set at :304, after the lease wait. The embedded ForgeBuildIdentity script assigns
-- ServerScriptService.ForgeBuildIdentity.Handshake before it parents that child
-- (cli/forge/lib/buildidentity.luau:146 then :149). The owned editor registers with the bridge as
-- soon as its datamodel is reachable, which can be before any of that has happened, so a read issued
-- at registration races the bootstrap (observed: COLLECTION_FAILED, 'ForgePersistence is not a valid
-- member of ServerStorage').
--
-- This runtime subscribes to the exact creation/child/attribute/value signals BEFORE its first
-- check, wakes on those signals rather than on a poll, and waits under one absolute deadline that a
-- bounded wait can never extend. Every connection is released on every path, the bounded wait's own
-- expiry is tolerated only when it coincides with that deadline, and any other error is re-raised
-- with its exact value. No Roblox global is read here: the container, the aggregate signal, the
-- maintained observe helper and the clock all arrive through the context, so the same code runs in
-- Studio and in the Lune fixture that drives it.
local M = {}

-- The only child condition. The marker's Value is assigned after the child is parented, so the
-- child's existence alone is not readiness and its Value change has to wake the wait. The
-- BindableFunction handshake states no condition: the producer assigns the callback before it
-- parents the child (cli/forge/lib/buildidentity.luau:146 then :149), so a parented child of that
-- class is already invokable, and the runtime never reads the callback property, which has no
-- property-changed signal.
local NON_EMPTY = "nonempty"

function M.await(
	ctx: any,
	spec: {
		object: string,
		child: string?,
		childClass: string?,
		childCondition: string?,
		attribute: string?,
		budgetMs: number,
	}
): any
	local valueRequired = spec.childCondition == NON_EMPTY
	local function ready(): any
		local target = ctx.service:FindFirstChild(spec.object)
		if not target then
			return nil
		end
		if spec.child then
			local child = target:FindFirstChild(spec.child)
			if not child or not child:IsA(spec.childClass) then
				return nil
			end
			if valueRequired and child.Value == "" then
				return nil
			end
		end
		if spec.attribute and type(target:GetAttribute(spec.attribute)) ~= "number" then
			return nil
		end
		return target
	end
	-- One absolute deadline for the whole wait. Each bounded wait is capped by what is left of it, so
	-- no wait can extend it.
	local deadline = ctx.now() + spec.budgetMs
	local aggregate = ctx.signal()
	local connections: { any } = {}
	local tracked: any = nil
	local childTracked: any = nil
	local childConnection: any = nil
	local function wake()
		aggregate.fire()
	end
	-- One connection per signal: the child's Value signal replaces any previous one, so a child that
	-- is removed and republished cannot accumulate connections.
	local function syncChild(target: any)
		local child = if spec.child then target:FindFirstChild(spec.child) else nil
		if child == childTracked then
			return
		end
		if childConnection then
			childConnection:Disconnect()
			childConnection = nil
		end
		childTracked = child
		if child and valueRequired then
			childConnection = child:GetPropertyChangedSignal("Value"):Connect(wake)
		end
	end
	local function track(instance: any)
		if tracked or not instance or instance.Name ~= spec.object or instance.Parent ~= ctx.service then
			return
		end
		tracked = instance
		if spec.attribute then
			table.insert(connections, instance:GetAttributeChangedSignal(spec.attribute):Connect(wake))
		end
		table.insert(
			connections,
			instance.ChildAdded:Connect(function()
				syncChild(instance)
				wake()
			end)
		)
		table.insert(
			connections,
			instance.ChildRemoved:Connect(function()
				syncChild(instance)
				wake()
			end)
		)
		syncChild(instance)
		wake()
	end
	table.insert(connections, ctx.service.ChildAdded:Connect(track))
	track(ctx.service:FindFirstChild(spec.object))
	local failure: any = nil
	while not ready() do
		local remaining = (deadline - ctx.now()) / 1000
		if remaining <= 0 then
			break
		end
		local ok, err = pcall(ctx.waitEvent, aggregate.event, function()
			return true
		end, function()
			return ready() == nil
		end, remaining)
		if not ok then
			-- The bounded wait's own expiry IS this deadline, so it is tolerated here and the asserts
			-- below decide. Any other error, including that same error raised before the deadline, is
			-- a real failure and keeps its exact value.
			if tostring(err) ~= "WORKLOAD_EVENT_TIMEOUT" or ctx.now() < deadline then
				failure = err
			end
			break
		end
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	if childConnection then
		childConnection:Disconnect()
	end
	aggregate.destroy()
	if failure ~= nil then
		error(failure, 0)
	end
	local target = ctx.service:FindFirstChild(spec.object)
	assert(target, "READINESS_OBJECT_TIMEOUT:" .. spec.object)
	if spec.child then
		local child = target:FindFirstChild(spec.child)
		assert(
			child and child:IsA(spec.childClass) and (not valueRequired or child.Value ~= ""),
			"READINESS_CHILD_TIMEOUT:" .. spec.object .. "." .. spec.child
		)
	end
	if spec.attribute then
		assert(
			type(target:GetAttribute(spec.attribute)) == "number",
			"READINESS_ATTRIBUTE_TIMEOUT:" .. spec.object .. "." .. spec.attribute
		)
	end
	return target
end

return M
