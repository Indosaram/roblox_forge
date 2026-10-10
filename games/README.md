# games/

Layer 3 of the three-layer split (plan §11.1): Game Packs — per-game
`game.yml`, design docs, `econ.yml`, assets, product lists, and game-specific
Luau hook extensions in `src/`.

A pack never copies or modifies core or genre code; it only registers hooks
exposed by Genre Modules. A new game means a new pack directory only.

Packs:
- `kaiju-egg-raiders/` — first pack, `collect-raid` genre.
- `grow-and-defend-garden/` — second pack, `grow-harvest` + `survival-coop` (pivot candidate).
