--!strict
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
return {
	require(Forge.genres["survival-coop"].module.Contract),
}
