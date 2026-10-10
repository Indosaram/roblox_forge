# social-rp-fashion design template

## Common loop (plan §11.4)

Dress up -> role-play/contest -> vote

## Systems

- **Outfit** (`module/Outfit.luau`): a `hat/top/bottom/shoes/accessory` slot map;
  `equip` validates the slot and ownership and replaces the slot's current item.
- **ThemeRound** (`module/ThemeRound.luau`): the round machine
  `lobby -> dressing -> voting -> results -> lobby`; picks a theme from a list
  through a seeded `pickIndex`.
- **Voting** (`module/Voting.luau`): 1-5 star votes, one per voter per target, no
  self-votes; results rank by average then vote count.

## Loop beats

1. The lobby fills; the round reveals a theme and opens the dressing window.
2. Players equip owned cosmetics to match the theme.
3. The voting window opens; each player rates the other contestants.
4. Results rank by average stars, with ties broken by vote count.

## Hooks

Game packs register `OnThemeStart` / `OnResults` to drive UI, camera, and rewards;
they own the avatar catalog and never edit this module.
