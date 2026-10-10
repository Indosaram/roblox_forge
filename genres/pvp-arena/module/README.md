# pvp-arena module

Reusable pvp-arena loop pieces: matchmaking, the round state machine, and Elo
ranking. Engine-free pure Luau; game packs call these and register hooks.

## Round

`Round.new(config, hooks)` builds a round state machine that cycles
`lobby -> countdown -> active -> ended -> lobby`. `Round.tick(r, now, playerCount)`
advances one transition per call and returns the phase; `Round.state(r)` reads it.

### Config

| key            | type   | meaning                                              |
| -------------- | ------ | ---------------------------------------------------- |
| `minPlayers`   | number | players required to leave the lobby and start a round |
| `countdown`    | number | seconds in countdown before the round goes active     |
| `duration`     | number | seconds a round stays active                          |
| `intermission` | number | seconds between the round ending and the next lobby   |

### Hooks

| hook           | called when                          |
| -------------- | ------------------------------------ |
| `OnRoundStart` | `countdown -> active` transition     |
| `OnRoundEnd`   | `active -> ended` transition         |

Transitions: `lobby -> countdown` once `playerCount >= minPlayers`;
`countdown -> lobby` if players drop below `minPlayers`; `countdown -> active`
after `countdown` seconds; `active -> ended` after `duration` seconds;
`ended -> lobby` after `intermission` seconds.

## Matchmaking

`Matchmaking.new()` creates a queue. `Matchmaking.enqueue(q, id, rating, now)`
appends a waiting player (insertion order is the queue order).
`Matchmaking.pair(q, maxDelta)` greedily pairs the oldest waiting entry with the
oldest still-waiting entry whose rating is within `maxDelta`, removes both, and
returns the pairs as `{{idA, idB}, ...}`. Entries with no compatible partner stay
queued.

## Rank

`Rank.update(ratingA, ratingB, scoreA, k)` applies one standard Elo update and
returns `(newA, newB)`. `scoreA` is `1` for an A win, `0.5` for a draw, `0` for a
loss; `k` is the rating step. Both ratings are floored at `0`.
