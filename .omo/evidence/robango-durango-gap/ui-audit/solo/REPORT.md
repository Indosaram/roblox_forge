# Robango Island - single-player (solo) UI audit

Worktree `rgf-camp1p`, base 9874fc7 + cherry-pick 0252927 (robango text lane, 1219d53). Changes are staged
(`git add`), not committed.

## The switch

`games/robango-island/game.yml` `play_mode` is the source of truth; `src/shared/PlayMode.luau` mirrors it
and `play-mode.spec.luau` asserts they are equal. Values today: `solo: true`, `campMinContributors: 1`,
`flares/population/chat/clanTag: false`, a `held` map (15 screen ids, each with its reason) and
`navHidden` (`nav_social`). Setting `solo: false` brings every multiplayer surface back: the client and
server still read the same PlayMode keys, and ExtensionPanels applies `held`/`navHidden` only while `solo`
is true. No multiplayer code was deleted.

## Multiplayer affordances found and what was done

| Affordance | Where | Action |
|---|---|---|
| brawl, direct-trade, outpost, party, clan, clan-membership, home-permissions, death-zone, players, clan-treasury, clan-research, clan-roles, territory, ensemble-lobby, score-share | menu tiles, navigator rows | **Held** (PlayMode.held): no tile, no navigator row |
| The same 15 screens, through other entry points | `ctx.open` / `openPanel` (in-panel buttons like ClanPanel "browse", RecoveredScreens shortcuts, Siege "outpost"), the Studio `ForgeQAOpen`, `availability()` | **Blocked in solo** (ExtensionPanels `blocked()`): open returns false, the dock `setOpen(true)` is ignored and availability reports unknown. Follow-up to the party capture that still opened |
| Direct-trade auto-open on an incoming invite | DirectTradePanel `autoOpen` | Covered by the same block (setOpen(true) is ignored) |
| Expedition party-invite popup ("파티 초대") | ExpeditionPanels popup | **Hidden in solo** |
| "파티 준비: 예" on the route depart card | ExpeditionModels.confirm | **Reworded in solo** to `exp_depart_body_solo` ("4단계 중 1단계. %s 후 마감. ...") |
| "함께" (nav_social) row | navigator | **Hidden** (navHidden); 생존 opens the same camp sheet |
| Trading post: 사기 / 내 물건 / 수령함 tabs, list price, fee, "등록" | CrossServerMarketPanel (shell) | **Solo keeps only the harbor (NPC) buyback**: one tab, "항구에 팔기"; the bag shows only items the harbor buys; quantity + "X 팔기 (개당 N)"; no price stepper, fee or listing. The cross-server player market code is unchanged with solo off |
| Score import: score-id lookup ("이 악보 ID 사용") | MusicScreens score-import | **Hidden in solo** (only reachable with an id someone shared); JSON import stays |
| Inbox (보관함) | InboxPanel | **Kept**: craft jobs, expedition results and market claims are all your own |
| Old CampPanel (프로젝트 button): 방문자 N / 재가입 대기 N chips, visit, help, item picker, loans | CampPanel | **Hidden in solo**; one "재료 넣기" button fills the project from your bag (or `CampBagEmpty`) |
| SurvivalCampPanel "기부", "공용 창고" | SurvivalCampPanel | **Reworded**: 재료 넣기, 캠프 창고 (camp_storage_*_solo) |
| Camp completion NOT_JOINT (needs 2 contributors) | Camp.complete / CampExtension | **Config floor**: `campMinContributors` 1 in solo; the default stays 2 |
| Rescue flare card | RescueExtension | **Off** (`flares: false`); "rescue" is dropped from the options and refused (INVALID_OPTION) |
| "N명" population on docks and route cards | server visitWorld.population / client populationCounts | **Off** (`population: false`) |
| HUD chat token and Roblox chat window | SurvivalHUD / client | **Off** (`chat: false`) |
| "부족 없음" clan tag line | SurvivalHUD | **Off** (`clanTag: false`) |
| Guide g04 "캠프 기부" wording + camp refusal rows | strings.csv | **Reworded** to neutral "넣기" (p53-ux assertion updated: "Camp project") |
| Guides g06 visit (rw.home-demo works solo), g12 route-share, g15 clan, g18 | content.yml | **Noted, not changed**: rank-gated (developmentRank 5-10), the generated SurvivalContent was not hand-edited |
| Organizations (NPC factions) | OrganizationsPanel | **Kept**: NPC reputation, works alone |

### Solo navigator, verified in Studio (both presets)
`survival, craft, build, skills, journal, explore, market, music, score-import, inbox, recipe-tracker,
score-library, build-manage, arrival, jobs, audio`. All 16 rows work alone (reasons listed in the spec).
`ForgeQAOpen` = party / players / clan / direct-trade returned **false and opened no sheet** at
800x360 and 1280x720 (`cap-after.log`).

## Solo camp projects are completable
A spec on the real command path (`camp-admission.spec`): one player gathers branch x10 and fiber x14 on
rw.onboarding, then the panel's "재료 넣기" (`CampPanelModel.putIn`) sends contribute per stack and then
complete; the windbreak finishes. On the old code this fails with NOT_JOINT.

## Camp sheet scroll reset (all FarmCraft hub sheets)
`FarmCraftSheet.clear()` saves CanvasPosition, `footer()` restores it, and the restore is applied again
when AbsoluteCanvasSize changes (disconnected in destroy). One fix covers all 8 hub sheets (CraftPreview,
CropBook, CropSpecialize, FarmArea, FarmPlot, Inbox, Processing, SurvivalCamp); all of them end render
with footer(). Studio: scroll set to the bottom, then 6 s of state pushes: **499 -> 499 (phone), 238 -> 238 (PC)**.
Spec: SurvivalCampPanel "a state push keeps the camp sheet's scroll position".

## v61 text leftovers
- Craft time "3s" -> "3초" (`hud.seconds`).
- Key hints "(I)" (hunger) and "Y로 회전" (build): wrapped in `{{...}}` in strings.csv; `SurvivalHUDLocale.keyHints`
  drops them on a touch-only device and shows them with a keyboard.
- "* 꼰 끈": the favorite asterisk prefix is removed.
- "내구도 0" on materials: `SurvivalHUDModel.wears` shows durability only for items that wear.

## Skills pill and scroll bar
The "아래에 더 있어요" pill sits in its own 28 px strip below the grid (the list shrinks while it overflows)
and the fade moved up 28 px, so it no longer overlaps a row. The bar uses dark ink (74,52,34) on a visible
`SkillScrollTrack`; `HudShell` no longer recolours ScrollingFrames that carry `ForgeShellKeep`. Verified in the
first after-run phone capture (pill under the grid, dark bar visible). That file was overwritten; see "Not verified".

## Specs (each one fails on the old code, checked by reverting the source)
- dock-close: "solo: menu, navigator, HUD row and camp panel ...", "solo: no route into a multiplayer-only sheet;
  navigator rows all work alone" (old: `players opened by id in solo`; old market: no "항구에 팔기";
  old score-import: `shared score-id lookup in solo`), "v61 text ...", "v61 skills ...".
  Two existing multiplayer tests (every-dock-entry cycle, trading post four tabs) now run with
  `multiplayer = true` (PlayMode with solo off), so the multiplayer path stays covered.
- ExpeditionPanels: "solo: depart confirm names no party and a party invite does not pop up" (old: party line;
  with only the invite gate reverted: the popup appears).
- camp-admission (solo windbreak), Camp.spec (solo floor), SurvivalCampPanel (solo put-in, scroll keep),
  RescueExtension (flares off), CampPanelModel (put-in fill), play-mode (yml = Luau mirror, client/server read PlayMode).

## Results
- Full suite: **`specs: 3318 passed, 0 failed, 485 files`** (`specs-all.txt`). The run before the fixes had 3 failures
  caused by this work, all fixed:
  - p102 Hangul: a Korean example sat in a SurvivalHUDLocale comment; it is now English.
  - play-mode: the client again passes `held = require(Shared.PlayMode).held`; the solo-only rule moved into ExtensionPanels.
  - server-services boot: that harness's shared table lacked PlayMode; it was added.
- Fast lint: `forge check --only selene,stylua,luau-lsp,locale,provenance,game` -> **check: PASS (6 stages)** (`fast-lint.txt`).
- Build: `forge build --pack robango-island` build + inspect PASS (`build-after.txt`). That build predates the last
  fix, which only changes the solo-off path and the PlayMode wiring; the specs cover it.

## Captures
Studio via studio_mcp, presets D2_Phone_800 (799x339) and D2_PC_1280 (1279x720), sheets opened by `ForgeQAOpen`.
`before/` (solo-before.rbxl): hud, camp, survival, navigator, party, players. `after/` (solo-after.rbxl): the
same set plus survival-bottom, clan, direct-trade, market, inbox, score-import, explore, skills, craft, build, bag.
Side-by-side images are in `sbs/` (`<device>-<screen>.jpg`, plus `<device>-after-only.jpg`). The before/after Studios (pids 26788, 17624, 19280)
are closed.

## Not verified
- **after/explore, skills, craft, build, bag are unusable**: opening `explore` moved the Studio camera into the island
  preview ("돌아가기 / UI 숨기기"), and the later captures show that preview. The skills pill/bar was seen in an
  earlier after-run capture that this run overwrote. The v61 text and skills fixes rest on the dock-close specs.
- No before captures exist for market, inbox, score-import, skills, craft, build or bag.
- The solo market sell path, the depart card and the hidden invite popup are proven by specs and the market capture; a real
  harbor sale and a real party invite were not exercised in Studio.
- Guides g06/g12/g15/g18 still mention visiting or other players (rank-gated, unchanged).
- `solo: false` is only covered by the specs (multiplayer harness); it was not run in Studio.
