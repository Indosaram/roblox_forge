---
name: audio
description: Load when creating, licensing, or uploading SFX and BGM audio for a game pack.
---

# audio

## When to use

- A game pack needs a new sound effect (`sfx`) or background music (`bgm`).
- You must choose an audio source, track the upload quota yourself, or register a
  generated asset.

## Preferred: keyless procedural audio

Add the cue to `games/<pack>/assets/audio.yml` (`kind` music/sfx/ambience with a
stable `seed`) and run `lune run cli/forge gen audio --pack <slug> [--install]`.
It synthesises the WAVs offline with `core/domain/procgen/Synth` + `Music`
(deterministic, no API keys, no `math.random`), refreshes `Assets.luau`, and with
`--install` copies them into the newest Studio `content/forge/<pack>/` so
`rbxasset://forge/<pack>/<cue>.wav` resolves. The steps below cover the
library/provider fallback for cues that cannot be synthesised.

## Steps

1. Reuse the Roblox audio library / Creator Store first: check the game pack's
   existing manifest (`games/<slug>/assets/manifest.yml`) for an asset with a
   matching purpose before generating anything new.
2. Only if nothing fits, generate the SFX through the routed provider
   (`sfx` -> ElevenLabs, commercial API plan):
   `ELEVENLABS_API_KEY=<key> lune run cli/forge gen sfx --pack <slug> --key <key> --prompt "<text>"`
   The CLI POSTs `{"text":...}` to `https://api.elevenlabs.io/v1/sound-generation` and
   expects MP3 bytes, writes `games/<slug>/assets/sfx/<key>.mp3`, then upserts the
   manifest entry as `tool: elevenlabs`, `moderation: NotUploaded`.
   Use `--dry-run` to print the exact request (api key masked) and target path without
   generating; an unset `ELEVENLABS_API_KEY` prints the request and exits 1 with
   `missing env ELEVENLABS_API_KEY`.
3. Generate through the agent lane, normalize volume, and upload only the final
   confirmed file — drafts are never uploaded.
4. Track the upload quota yourself before uploading: Roblox limits audio uploads to
   100/month on ID-verified accounts (unverified accounts: 10 total, no updates). The
   CLI does not track or enforce this; count your own uploads for the month and stop
   requesting new ones once you are at the limit.
5. Run `lune run cli/forge check`.

## Rules

- API 1 generators supply assets/<genre>/audio.yml with stable seeds and
  <genre>-... keys. Assembly merges cues and runs only declared capabilities.
  A short starter cue is not a production soundscape or proof a control plays it.
  Common new/plan does not call providers, upload or pass --install; runtime asset
  IDs/installation and audio QA remain separate explicit work.

- Record provider/tool/version, recipe/input version, commercial rights source,
  ownership and artifact digest for generated or imported audio. Provenance and
  moderation are separate from experience quality; an allowed provider cannot
  approve a soundscape. Local-not-applicable does not mean Roblox-approved.
- Capture actual first-play audio and action logs for the configured evaluator.
  Judge timing, coherence and feedback against the reference, including visible
  warnings when muted. `forge quality check --pack <slug>` requires a current
  authorized receipt for higher tiers; regenerated clips invalidate its digests.
  Starter generation and explicit staging development never imply release approval.
- **AudioCraft is forbidden**: weights are CC-BY-NC 4.0 (non-commercial).
- Upload quota is hard: 100 uploads/month on verified accounts. The CLI does not
  track or enforce this — count your own uploads for the month and stop before you
  exceed it.
- Upload only the final approved clip.
- No network calls inside specs; never read or print secrets (e.g. `ROBLOX_API_KEY`).
- Do not modify `core/` or genre modules for a game-pack asset.

## Verification

- `forge gen sfx --dry-run` exits 0 and prints the provider, the ElevenLabs URL, and the
  `games/<slug>/assets/sfx/<key>.mp3` target path (never the api key).
- A real run writes the `.mp3` under the game pack and upserts the manifest entry as
  `tool: elevenlabs`, `moderation: NotUploaded`.
- `lune run cli/forge check` exits 0.
