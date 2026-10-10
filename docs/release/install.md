# Source archive installation and packaging

The release is a coherent source tree, not a bundle of installed executables or
independently resolved per-pack dependencies. `core/forge-package.yml`, every
`genres/*/forge-package.yml`, and every shipped pack's `forge-lock.yml` must agree.
Keep CLI, core, genres and packs from the same archive together. Windows x64 is
the first supported target; fresh consumer verification remains deferred to the
consolidated release verification task.

## Consumer setup

Extract the archive into a new, empty directory that you own. Do not merge it
over an existing game checkout. Keep `LICENSE.md`, `RUNTIME-LICENSE.md`,
`THIRD_PARTY_NOTICES.md`, `docs/release/shipped-licenses.json` and
`forge-release-manifest.json` with the source. The manifest records the Git
revision, exact SHA-256 and length of every source file, whole-source package
versions, tool pins and inventory digest. It is a local integrity record, not a
signature or production approval. Check the archive SHA-256 against the separate
release receipt before extracting; compare extracted files with the manifest
before running code.

Install Rokit separately, then run these commands from the extracted root:

```powershell
rokit install
lune run cli/forge new consumer-island --genre collect-raid
lune run cli/forge plan --concept "Defend ancient groves" --genre survival-coop --pack consumer-grove --seed 42
lune run cli/forge build --pack consumer-island
lune run cli/forge check --all
```

Rokit downloads the pinned external tools unless its compatible cache is already
provisioned. A fresh machine needs network access for that installation. No
developer's tool cache, binaries or credentials are inside this archive. The
first `check` also downloads the pinned, digest-checked Roblox definitions into
`build/cache/globalTypes.d.luau`; a valid existing cache avoids that download.
Keyless therefore does not mean a fresh installation is network-free. Offline
use requires separately provisioned tools and the valid definitions cache.
Scaffold, deterministic planning and building need no Roblox API key. Studio,
its MCP bridge, external evaluators and authenticated services are separate
requirements for their respective operations, not part of source installation.

No-argument CLI usage and `--help` are not documented as successful commands:
the existing entrypoint reports usage with a nonzero exit. Starter generation,
build success and headless checks do not approve a production game.

## Maintainer packaging

From a source checkout with Git and the pinned Lune installed:

```powershell
lune run cli/release/package --out build/forge-release.zip
```

The command emits structured JSON with `ok`, `output`, `manifest` and `sha256`
on success; failure emits `ok: false` and `error` and exits nonzero. It also writes
`build/forge-release-manifest.json`, identical to the manifest inside the ZIP.
Use fresh output names: existing outputs are refused, not overwritten. A second
reproducibility run can use `build/forge-repeat.zip`; output names never enter the
archive. Failed writes remove only the fresh outputs owned by that invocation.

Packaging accepts only a clean, recorded shipped source tree. Staged changes,
untracked or ignored new files within included source trees, deleted shipped
files and bytes differing from HEAD are rejected. This intentionally requires
the approved release changes and the rights inventory to be committed before
the real archive run. Packaging itself never commits. Non-shipped developer
files may remain dirty. Archive contents are read from immutable Git blobs,
compared with the working tree, and checked again before writing.

The explicit source selection is root `README.md`, `CHANGELOG.md`, license documents,
`THIRD_PARTY_NOTICES.md`, `AGENTS.md`, `rokit.toml`, `selene.toml`, `stylua.toml`,
`.luaurc`, `.styluaignore`, `.gitattributes`, `.gitignore`, and the `cli/`, `core/`,
`genres/`, `games/`, `skills/`, `docs/release/` trees. Other root files and archival
research documents are not shipped. Exclusions within those trees include hidden
files, build/reports/scratch/secrets/vendor/packages/node_modules directories,
credential or secret named files, `.tmp` files, `.forge-*` state, logs, backups,
private key files, ZIPs and built places. Exclusions are filename rules, not a
claim that arbitrary source code cannot contain a secret: review shipped content
before approving a release. Symlinks, submodules, unsafe Windows filenames and
case-colliding paths cannot become archive entries.

Any sibling `games/<pack>.forge-stage` or `games/<pack>.forge-backup` file or
directory rejects packaging, including an orphan, malformed journal or completed
but not cleaned transaction. Packaging uses the read-only publication guard;
it never interprets a completion marker as permission, recovers generation,
deletes another writer's state or includes backup/stage bytes. Finish the
generator's explicit recovery and cleanup before retrying.

ZIP entries are sorted by path, use uncompressed STORE data, fixed 1980-01-01
timestamps, and no comments, extra fields or host attributes. This avoids
compressor and filesystem timestamp variation. ZIP32 size/count limits fail
instead of truncating. The source manifest uses sorted JSON keys and contains no
wall clock, user directory, output path or host identifier.

## Rights inventory gate

`docs/release/shipped-licenses.json` records the owner-selected first-party
license scopes and explicitly inventoried source paths, plus separate asset
records. New source paths need a coverage decision rather than silently
inheriting permission. `freezeInventory(entries, policy)` expands those reviewed
scopes into exact current file hashes. Every selected file except the inventory
itself gets a record keyed by its relative path with these machine fields:

```json
{
  "sha256": "<exact SHA-256 of the shipped file>",
  "status": "verified",
  "verifiedBy": "<reviewer identity>",
  "evidence": "<versioned authorship or upstream rights evidence>",
  "kind": "first-party-tooling",
  "license": "LicenseRef-Forge-SUL-1.0"
}
```

First-party embedded runtime and first-party generated assets use
`kind: first-party-runtime` and
`license: LicenseRef-Forge-SUL-1.0-Runtime-Exception`. Tooling remains under SUL;
the Roblox commercial game exception does not authorize paid tooling resale or
hosting. Third-party files use `kind: third-party`, their own license identifier,
`redistribution: true`, and `notice` naming an included notice file. A Forge
license identifier is rejected for third-party records. Missing, stale,
unknown-status, digest-mismatched or incomplete entries reject packaging. Extra
inventory file entries also reject, preventing stale coverage claims.

This inventory describes bundled bytes only. Rokit-installed executable licenses
and Roblox platform permissions are separate; an upstream default-branch license
does not prove the license of a pinned binary release. Tool registration and
asset moderation do not establish individual redistribution rights.

### Freeze after repairs, before verification and commits

The Task16 harness loads `package.luau` with `luau.load` and the explicit
`"module"` argument, as the adjacent spec does. It captures all selected files
into `{path, bytes}` entries in an owned fixture and checks publication markers
before and after capture. It then calls `freezeInventory(entries, policy)`.
The returned unknown list must be empty before packaging can succeed. Write the
returned inventory with `canonical(frozen) .. "\n"`, replace only that entry in
the captured map, then call `captureCandidate(entries, baselineRevision)` and
`assembleCandidate(candidate)`. Capture returns frozen entry tables with immutable
byte strings and a full content digest. No source execution, Git history creation
or commit is needed to freeze the records. The library itself performs no writes.

The inventory never includes its own hash in `files`; the outer release manifest
hashes the complete inventory. There is no recursive digest cycle. Frozen source
hashes are computed only after implementation/format repairs settle. Any later
source change requires a new freeze and justified affected verification. Media
overrides keep their separately reviewed hash, so freezing cannot approve changed
asset bytes merely by recomputing a hash.

Before Task16, collect every active worker's final added-path list and origin
statement. Enumerate the complete selected tree and reconcile it against
`coveredSourcePaths` and `assetRecords`; explicitly add newly authored first-party
modules, fixtures, scenarios and release docs with their task ownership basis.
`releaseAuthorshipIntake` records the latest additions and expected pending task
outputs, but expected names are not automatic rights grants. Run the library
freeze on the captured map and persist its sorted unknown-path return plus each
`frozen.files[path].reason`. Resolve this intake report before candidate consumer
verification. Do not postpone missing-path discovery to the final production ZIP.
The inventory is the only self-hash exception; package module/spec/install remain
ordinary covered first-party tooling. Existing asset approval hashes are never
changed by source-path intake.

Provisional intake is not the final freeze. The inventory's `provisionalIntake`
lists settled additions separately from sorted blocked paths awaiting worker
origin/configuration handoff. While any worker is authoring, retain empty/unfrozen
`files` hashes and repeat filename reconciliation only when a handoff adds paths.
After every worker has stopped, take one complete selected snapshot, reconcile
all outstanding paths and dependencies, then freeze the immutable candidate map.

Executable helpers belong in the source archive when authored in selected trees:
JavaScript/Luau/PowerShell/C# source is not equivalent to bundling its runtime or
compiled executable. The shipped first-party audiovisual helper
`cli/forge/native/qualityav-capture/` is C++20 source plus a `CMakeLists.txt`
(CMake 3.21 or newer) with no vendored source and no prebuilt binary. Building it
is optional and consumer-supplied: it needs a local Windows SDK providing C++/WinRT,
Windows.Graphics.Capture and WASAPI process-loopback declarations, and it links only
system import libraries (`ole32`, `mmdevapi`, `mfplat`, `mfreadwrite`, `mfuuid`,
`d3d11`, `dxgi`, `windowsapp`, `user32`). Neither Rokit nor `rokit install`
provides a compiler, CMake or that SDK, and no build output ships in the archive;
successful Forge commands never imply the helper was built or runs. New native
project/build files still require explicit intake, and unsupported extensions
remain unknown rather than being silently approved. Capture compiler/SDK and
runtime requirements, exact dependency pins, source-license notices and whether
any third-party bytes ship.
Do not import local FFmpeg binaries, SDK caches, credentials or worker receipts
containing workstation installation paths into consumer configuration. Decoder
paths/hashes and Studio transport settings must be supplied by each consumer;
maintained helpers must resolve shipped source relative to the extracted root.
The observed local FFmpeg 9.0.1 installation is not a bundled tool, automatic
installation promise or proven consumer support floor. No pinned external binary
license attestation gates first-party source permission when its bytes do not ship.

The maintained Open Cloud subprocess transport additionally needs an installed
`bun` on PATH; Rokit does not install it. Bun 1.4 on Windows is the intended
consolidated verification target, not a verified minimum-version promise.
Run Forge from the extracted root: the parent resolves
`cli/forge/lib/opencloud-transport.mjs` relative to that directory. The helper,
parent lifecycle module and local fixtures are first-party source with only
built-in runtime APIs; no npm dependencies or Bun executable are bundled.
Credentials enter the helper via stdin, not its argument list. Missing Bun fails
closed. Parent exit/pipe cleanup and consumer discovery remain unverified.

The optional first-party `cli/release/local-persistence-host.mjs` uses Bun's
built-in SQLite and HTTP server, with no npm package or SQLite binary bundled.
Its controller supplies `FORGE_LOCAL_DB`, `FORGE_LOCAL_TOKEN`,
`FORGE_LOCAL_NAMESPACE` and `FORGE_LOCAL_PORT`; no workstation DB path or live
token is shipped. Keep its runtime token out of source and evidence. The host
binds `127.0.0.1`; the Roblox adapter requires explicit Studio loopback/HTTP
permission, which remains unverified. Default `PersistenceConfig.luau` stays in
memory mode. Local-host persistence is distinct from Roblox DataStore service
durability. This source inventory does not prove either one works.

Task16 can exercise reproducibility and the fresh consumer using this exact
archive mechanism before commits. Candidate manifests explicitly say
`immutable-candidate-not-committed`; `sourceRevision` is the baseline, not a claim
that the candidate bytes belong to that revision. `candidateDigest` binds the
captured map. After successful consolidated checks, record the verified source
and frozen inventory in authorized commits. Run the production CLI once afterward
to bind the final HEAD revision and check the final artifact. Production CLI still
rejects dirty shipped source; it has no candidate or dirty override flag. Final
and candidate ZIP hashes differ because their revision/state manifests differ;
compare the shipped file content maps to prove the source bytes did not change.

### Historical media origins and deferred byte comparison

The following 36 existing files now have grounded historical origin records and
independently stored expected SHA-256 values in `assetRecords`. Current byte
comparison remains deferred for every file. Read-only Git history in the historical provenance checkout
identifies the owner-authored generation commit for each output; its historical
`final-scoped-source-sha256.txt` records the expected bytes. That fingerprint is a
post-run source inventory, not a generation receipt or proof of current bytes.
Packaging must reject any mismatch. Do not approve a changed asset merely by
recomputing its inventory hash.

The eight PPMs originate in `76126039d3ae8180a66f2ec0526328f0bd95f6c1`, which adds
the icon renderer and outputs together. The procgen document at that commit
contains the retired creature names, colors, scales and seeds. Their absence from
the current roster is therefore not missing historical provenance. Reproduction
must use the historical recipe and implementation, not the current roster.
Each audio and launch-art record likewise names its own origin commit and input
path, plus the maintained renderer/encoder contract. Any later reproduction runs
only in an owned fixture and must not rewrite these existing media files.

Under **each** of `games/kaiju-egg-raiders/assets/` and
`games/plan-demo/assets/`, these 14 relative files are unresolved:

```text
audio/ambienceBirds.wav
audio/ambienceWind.wav
audio/musicExplore.wav
audio/musicSiege.wav
audio/sfxClick.wav
audio/sfxCoin.wav
audio/sfxError.wav
audio/sfxHatch.wav
audio/sfxRaid.wav
audio/sfxRare.wav
icon/icon-a.png
icon/icon-b.png
thumbnails/thumb-a.png
thumbnails/thumb-b.png
```

The remaining eight are under `games/kaiju-egg-raiders/assets/icons/`:

```text
abyss-leviathan.ppm
ember.ppm
magma-mauler.ppm
pyro-pup.ppm
reef-runner.ppm
solar-titan.ppm
storm-serpent.ppm
tidal.ppm
```

`games/primal-isles/assets/audio/survival-coop-action.wav` instead has an explicit
first-party rights/provider/recipe record and SHA-256 in its asset manifest;
the inventory carries that approved digest and packaging compares actual bytes.
Roblox built-in sounds remain URI references, not bundled recordings. No tool
binary or model weight is included, so external executable license verification
is not misrepresented as bundled-source clearance. Upstream SUL attribution is
retained in `THIRD_PARTY_NOTICES.md`, separate from Forge copyright and exception.

## Deferred fresh consumer proof and cleanup

### Rokit storage isolation is not Windows profile isolation

Forge pins the six managed tools in `rokit.toml`, **not Rokit itself**. The
read-only source investigation used Rokit source commit
`c8f279983046739d3a80a2d5fe976da08d26add7` (Cargo version 1.2.0); it does not
establish the version or behavior of an installed executable. Before later
execution, record the actual Rokit bootstrap version/digest and match its source
contract. Do not assume `ROKIT_HOME` exists.

That source supports `ROKIT_ROOT`: `Home::load_from_env` puts configuration,
`auth.toml`, `tool-storage/cache.json`, downloaded tools and `bin` aliases under
the specified root. A fresh empty owned root can therefore isolate Rokit storage
and authentication. `install --no-trust-check` is an actual supported flag for
noninteractive installation after reviewing the exact pins; it bypasses trust
prompts, not network or installation work. `--force` is not cache isolation.

However, `install` calls `discover_all_manifests(false, false)`, which scans the
extracted working directory **and every ancestor**, plus the real Windows home
`.rokit`, `.aftman` and `.foreman` manifests. That discovery does not use
`ROKIT_ROOT`. The inspected `dirs` 6.0 Windows implementation uses
`SHGetKnownFolderPath(FOLDERID_Profile)`, not a child-process `USERPROFILE` or
`HOME` override. Thus changing those variables does not establish isolated Rokit
manifest discovery. No supported install flag to skip that home search was found
in this source. Do not rename, edit or temporarily hide user manifests.

For a later owned-root dependency-install trial, use a child-only environment,
an empty owned absolute `ROKIT_ROOT`, owned temp directories, and the recorded
Rokit executable explicitly. Avoid `self-install`/`self-update` and registry/PATH
mutations. Extract outside the developer checkout and inspect every ancestor and
the actual Windows home manifest locations before invoking install. If any
additional tool declaration would be discovered, mark strict isolated install
proof blocked; do not silently include it. Clear inherited credentials/provider
variables and use an allowlisted PATH containing only the owned tool aliases,
declared separate runtime prerequisites and required Windows system directories.
Keep the same `ROKIT_ROOT` in every tool child. Record resolved executable paths
and reject developer-cache fallback. Forge's current `run.luau` also probes
`USERPROFILE/.rokit/bin` directly: set child `USERPROFILE` to an empty owned
profile for that probe only, while explicitly acknowledging that this does not
change Rokit's Windows known-folder discovery. Exclude Git from consumer PATH
and Git configuration/environment; no `.git` belongs in extraction.

If clean manifest discovery cannot be established without changing the account,
split the evidence: (1) extracted-source consumer behavior using an explicitly
declared preinstalled toolchain, and (2) fresh dependency installation **blocked**.
A shared toolchain run is not fresh-install proof. Do not create an account or
claim a sandbox exists. Network restrictions or unauthenticated GitHub rate limits
remain recorded blockers rather than reasons to borrow developer tokens/cache.
This procedure is authored only; no Rokit invocation or environment change ran.

Source references:
- [Rokit home override](https://github.com/rojo-rbx/rokit/blob/c8f279983046739d3a80a2d5fe976da08d26add7/lib/storage/home.rs)
- [Install flags and discovery call](https://github.com/rojo-rbx/rokit/blob/c8f279983046739d3a80a2d5fe976da08d26add7/src/cli/install.rs)
- [Manifest search paths](https://github.com/rojo-rbx/rokit/blob/c8f279983046739d3a80a2d5fe976da08d26add7/lib/discovery/mod.rs)
- [Windows home lookup](https://docs.rs/crate/dirs/6.0.0/source/src/win.rs)
- [Known-folder implementation](https://docs.rs/crate/dirs-sys/0.5.0/source/src/lib.rs)

Consolidated verification must create a new owned temporary extraction directory,
without copying a developer cache, and use a separately owned Rokit profile/cache.
Record actual downloads, tool versions, commands, exit codes and original archive
and extracted-file hashes. Run the workflow above and compare two independently
produced archive hashes. No such execution has been performed by this authoring
task. Record unavailable network or installation capabilities as blocked.

The verification driver must register its owned directory before extraction,
reject traversal and collisions, retain the original failure receipt, and remove
only its owned extraction/cache directories in `finally`, including after failed
extraction. It must not delete user projects or inherited caches. Archive consumers
do not need Git for normal Forge workflows; rebuilding the release archive itself
requires the committed source checkout and its Git object database.
