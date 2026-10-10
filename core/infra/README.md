# core/infra/

Engine adapters for `core/domain` (plan §11.1): the layer that may touch Roblox
engine APIs.

- `data/` — DataStore persistence and session locking
- `net/` — RemoteEvent/RemoteFunction transport and rate limiting
- `monetization/` — game passes, developer products, subscriptions
- `analytics/` — Economy Events and telemetry
- `localization/` — string extraction and Localization API sync
- `liveops/` — events, messaging, weekly update plumbing

Adapters translate engine calls into domain inputs; domain logic stays pure.
