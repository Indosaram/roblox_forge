# core/

Layer 1 of the three-layer split (plan §11.1): everything common to all games —
data storage, economy engine, monetization, analytics, localization, liveops,
asset/deploy pipeline, and agent skills.

- `domain/` — engine-free pure Luau, runnable by Lune.
- `infra/` — engine adapters (DataStore, networking, Instances).
- `anticheat/`, `ui-kit/` — shared anti-exploit checks and shared UI components.

Core is a semver package; game packs pin its version and never modify it.
