--!strict
export type Control = {
	id: string,
	action: string,
	args: { any },
	label: string,
	kind: "button" | "prompt" | "player-button",
}
local controls: { Control } = {
	[1] = {
		["action"] = "survival-coop:buy-defense",
		["args"] = {},
		["id"] = "survival-coop:buy-defense",
		["kind"] = "prompt",
		["label"] = "Buy defense",
	},
	[2] = {
		["action"] = "survival-coop:defend-active",
		["args"] = {},
		["id"] = "survival-coop:defend-active",
		["kind"] = "button",
		["label"] = "Defend",
	},
}
return controls
