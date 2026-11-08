--!strict
-- Local/Studio runs use the in-memory backend: RuntimeBackend never persists
-- outside a published place, so a local session cannot pollute real saves.
return { mode = "memory", namespace = "grow-and-defend-garden" }
