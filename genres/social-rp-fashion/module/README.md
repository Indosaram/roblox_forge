# social-rp-fashion module

Reusable social-rp-fashion pieces: avatar slot outfits, the themed round state
machine, and star voting. Engine-free pure Luau; game packs own the catalog and
register hooks instead of editing this module.

## Outfit

`Outfit.new(catalog, ownedIds?)` takes `{ id, slot }` definitions for the
`hat`/`top`/`bottom`/`shoes`/`accessory` slots plus the owned item ids.
`Outfit.equip(state, id)` fills that item's slot (replacing what was there) and
returns `(true, nil)`, or `(false, reason)` for `"unknown item"` / `"not owned"`.
`Outfit.unequip(state, slot)` clears a slot and returns the removed id;
`Outfit.get(state, slot)` and `Outfit.equipped(state)` read the current look.

## ThemeRound

`ThemeRound.new(config, themes, pickIndex, hooks)` builds the round machine
`lobby -> dressing -> voting -> results -> lobby`. `round:tick(now, playerCount)`
advances at most one transition per call and returns the phase. Entering dressing
calls `pickIndex(#themes)` (a seeded index in `1..#themes`), stores the theme, and
fires `OnThemeStart`; entering results fires `OnResults`.
`round:state()` and `round:currentTheme()` read the machine.

### ThemeRound config

| key              | type   | meaning                                            |
| ---------------- | ------ | -------------------------------------------------- |
| `minPlayers`     | number | players required to leave the lobby for dressing   |
| `dressingSeconds`| number | seconds the dressing window is open                |
| `votingSeconds`  | number | seconds the voting window is open                  |
| `resultsSeconds` | number | seconds results stay up before the next lobby      |

### Hooks

| hook           | called when                          | argument          |
| -------------- | ------------------------------------ | ----------------- |
| `OnThemeStart` | `lobby -> dressing` transition       | theme `string`    |
| `OnResults`    | `voting -> results` transition       | theme `string`    |

## Voting

`Voting.new()` creates vote state. `Voting.cast(state, voter, target, stars)`
records a 1-5 star vote and returns `(true, nil)`, or `(false, reason)` for
`"self vote"`, `"invalid stars"`, or `"already voted"` (one vote per voter per
target). `Voting.score(state, target)` returns `(totalStars, voteCount)`;
`Voting.average(state, target)` returns the mean. `Voting.results(state)` returns
`{ target, average, votes }` ranked by average (descending), then vote count
(descending), then target name (ascending).

## Example

```lua
local Outfit = require("genres/social-rp-fashion/module/Outfit")
local ThemeRound = require("genres/social-rp-fashion/module/ThemeRound")
local Voting = require("genres/social-rp-fashion/module/Voting")

local outfit = Outfit.new({
	{ id = "crown", slot = "hat" },
	{ id = "tee", slot = "top" },
}, { "crown", "tee" })
Outfit.equip(outfit, "crown")

local round = ThemeRound.new(
	{ minPlayers = 2, dressingSeconds = 45, votingSeconds = 20, resultsSeconds = 10 },
	{ "beach", "royal", "cyber" },
	function(count)
		return math.random(count)
	end,
	{
		OnThemeStart = function(theme)
			print("theme: " .. theme)
		end,
		OnResults = function(theme)
			print("results for " .. theme)
		end,
	}
)
round:tick(0, 2) -- dressing; OnThemeStart fires
```
