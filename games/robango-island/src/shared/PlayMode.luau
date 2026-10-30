--!strict
-- Single-player mode switches. Source of truth: game.yml `play_mode` (play-mode.spec.luau asserts
-- equality). Multiplayer is on hold (owner): with solo = true the screens that only act on other
-- players are held off the menu and navigator, the camp sheet puts materials in from your own bag
-- and one player may finish a camp project. solo = false restores every multiplayer surface.
export type PlayMode = {
	solo: boolean,
	campMinContributors: number,
	flares: boolean,
	population: boolean,
	chat: boolean,
	clanTag: boolean,
	held: { [string]: string },
	navHidden: { [string]: string },
}

local mode: PlayMode = {
	solo = true,
	campMinContributors = 1,
	flares = false,
	population = false,
	chat = false,
	clanTag = false,
	held = {
		brawl = "brawl needs minimumPlayers 2",
		["direct-trade"] = "trades with another player on this server",
		outpost = "team siege: one clan against another",
		party = "invites other players to an expedition party",
		clan = "a clan is a group of players",
		["clan-membership"] = "create or join a clan of players",
		["home-permissions"] = "grants visit/use/build to friends and clan members",
		["death-zone"] = "opt-in PvP zone, only used by brawl and team siege",
		players = "lists the other players on this server",
		["clan-treasury"] = "a clan treasury is shared by clan members",
		["clan-research"] = "clan research is funded by clan members",
		["clan-roles"] = "roles inside a clan of players",
		territory = "clan territory claims against other clans",
		["ensemble-lobby"] = "plays a score together with other players",
		["score-share"] = "shares a score with another player",
	},
	navHidden = {
		nav_social = "the Together row opens the camp as a group space; Survival opens it solo",
	},
}

return table.freeze(mode)
