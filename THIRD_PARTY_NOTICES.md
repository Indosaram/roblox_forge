# Third-Party Software Notices and Asset Obligations

Roblox Game Forge references and interacts with third-party tools, libraries, and runtime environments. This document inventories these components, cites their upstream licenses from repository inspections, and identifies known and unknown obligations.

## 1. External Developer Toolchain (Rokit Managed)

The repository's `rokit.toml` pins external tools used during local development. These binaries are not vendored into the repository tree. They are downloaded by Rokit into user tool storage.

Upstream licenses cited below were verified directly against their official repositories:

| Tool | Version | Upstream Project / Repository | Verified Upstream License | Usage in Forge |
| --- | --- | --- | --- | --- |
| rojo | 7.7.0 | rojo-rbx/rojo | MPL-2.0 (Mozilla Public License 2.0) | Place and model building, sourcemap generation |
| wally | 0.3.2 | UpliftGames/wally | MPL-2.0 (Mozilla Public License 2.0) | Package manifest management tool |
| lune | 0.10.5 | lune-org/lune | MPL-2.0 (Mozilla Public License 2.0) | Standalone Luau CLI runtime for `cli/forge` scripts |
| selene | 0.31.0 | Kampfkarren/selene | MPL-2.0 (Mozilla Public License 2.0) | Static analysis linter for Luau code |
| stylua | 2.5.2 | JohnnyMorganz/StyLua | MPL-2.0 (Mozilla Public License 2.0) | Code formatter for Luau |
| luau-lsp | 1.70.1 | JohnnyMorganz/luau-lsp | MIT License | Language server protocol and type analysis CLI |

Obligations:
- When distributing pre-built binary packages of MPL-2.0 tools, their respective license notices and source distribution offers must accompany the distributions.
- Source checkouts and source archives of Roblox Game Forge contain only source files and configuration (`rokit.toml`). No compiled third-party binaries are included.

## 2. External Definition Files and Schemas

| Asset / File | Source / Reference | Inspected License | Obligations / Notes |
| --- | --- | --- | --- |
| Roblox LSP Type Definitions | `JohnnyMorganz/luau-lsp@1.70.1/scripts/globalTypes.d.luau` | MIT License (luau-lsp) / Roblox Terms | Downloaded dynamically during `check` if not cached in `build/cache/`. |
| Asphalt Schema Reference | `jackTabsCode/asphalt` schema URI in `cli/forge/lib/assets.luau` | MIT License (Asphalt) | Referenced as URI metadata schema string only; no file vendored. |

## 3. Asset Generation Providers and External Model Weights

The asset verification registry (`cli/forge/lib/licenses.luau`) tracks tool usability for asset generation. Tool registration answers whether a tool may run under internal framework policy. It does not grant blanket commercial rights or create first-party ownership over third-party outputs.

### Allowed Providers (Commercial Use Evaluation Required)

| Tool / Provider Key | Stated License / Basis | Declared Ownership Class | Upstream Rights Basis and Scope |
| --- | --- | --- | --- |
| `forge-procgen` | First-party Luau procedural algorithms | first-party | First-party generator in this repository (`core/domain/procgen/`). Commercial use permitted under project terms. |
| `trellis` | MIT License | first-party | Microsoft TRELLIS model weights and code. Output rights require checking upstream model terms. |
| `elevenlabs` | ElevenLabs Commercial API Plan | licensed | Generated sound rights depend on active commercial subscription plan terms. |
| `creator-store` | Roblox Creator Store Terms | licensed | Purchased or acquired assets governed by individual creator terms and platform rules. |
| `roblox-audio-library` | Roblox Audio Library Terms | platform | In-experience platform license per Roblox Terms of Use. No standalone extraction permitted. |
| `studio-mcp` | Roblox Creator Terms of Use | platform | Studio generation API under platform creator terms. |

### Denied Tools (Strictly Banned)

The following generative models are denied in `cli/forge/lib/licenses.luau` and AGENTS.md. They must never be used to produce assets for Roblox Game Forge:

| Tool Key | Reason for Denial | Upstream License / Constraint |
| --- | --- | --- |
| `audiocraft` | Non-commercial weights | AudioCraft model weights are licensed under CC-BY-NC 4.0, which prohibits commercial exploitation. |
| `roblox-cube` | Research-only restriction | Roblox Cube model weights are restricted to research use only. |
| `hunyuan3d-2` | Geographic exclusion | Hunyuan3D-2 license terms explicitly exclude Korea, the EU, and the UK. |

### In-Platform Runtime Sounds (Primal Isles Sample)

| Component | Path / Location | Source | Rights Status and Limitations |
| --- | --- | --- | --- |
| Character Sounds | `games/primal-isles/assets/audio-provenance.yml` | Roblox client built-in sound content (`rbxasset://sounds/...`) | References built-in content inside Roblox only. No binary files copied or uploaded. No redistribution or sublicensing rights asserted outside Roblox. |

## 4. Unknown Obligations and Packaging Blocks

To maintain strict compliance and prevent unlicensed distribution:

1. Unregistered Tools: Any asset tool not registered in `cli/forge/lib/licenses.luau` is classified as unregistered. Assets from unregistered tools require explicit, versioned rights evidence (`document`, `version`, `verifiedBy`) in the asset manifest.
2. Tool Usability Is Not Asset Approval: Registering a tool as allowed permits the generation tool to run. It does not certify that any individual asset produced by that tool possesses commercial clearance.
3. Packaging Block on Unknowns: Release packaging pipelines must refuse any asset or code module whose provenance or license status is unknown, unverified, or incomplete.
4. Unknown Upstream Rights Remain Unknown: When full upstream terms for third-party recordings or external models cannot be independently verified from repository records, they are recorded as unknown obligations and restricted from unqualified commercial claims.

## 5. Upstream Sustainable Use License Notice

Roblox Game Forge incorporates and adapts the text of the Sustainable Use License v1.0. Upstream SUL was authored by n8n (https://github.com/n8n-io/n8n/blob/master/LICENSE.md). The base SUL terms are preserved byte-for-byte in LICENSE.md, accompanied by the separately stated Commercial Game Runtime Exception and repository copyright attribution.
