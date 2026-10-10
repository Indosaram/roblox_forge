#!/usr/bin/env bash
# Publish one Forge-generated game to the private staging experience.
#
#   cli/forge/publish-staging.sh <genre-slug> [<sweep-stamp>]
#
# <genre-slug>   genre id, e.g. grow-harvest, collect-raid, pvp-arena,
#                rpg-progression, social-rp-fashion, survival-coop,
#                survival-coop-crafting  (the sweep pack is "<slug>-sweep").
# <sweep-stamp>  build/sweep/<stamp> (default: newest stamp holding the pack).
#
# Publishes with `--env staging --development` (explicit staging-only status,
# never release approval) to the start place of universe 10768717424, owned by
# group 570462331 "Kaiju Egg Raiders Studio". The experience stays private:
# this script never touches production and never changes the public/private
# setting. The pack is read from build/sweep/<stamp>/packs/ and games/ is never
# edited. Each run records pack, sweep stamp, accepted version and artifact
# sha256 into build/publish/published.tsv.
set -euo pipefail

SLUG="${1:?usage: publish-staging.sh <genre-slug> [<sweep-stamp>]}"
STAMP="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PACK="${SLUG}-sweep"
if [ -z "$STAMP" ]; then
	# Only timestamp-stamped sweeps count as a "fresh" generation; legacy
	# scratch dirs (e.g. build/sweep/wave4) must never be picked by default.
	STAMP="$(ls -1d build/sweep/*/packs/"$PACK" 2>/dev/null \
		| sed -n 's#^build/sweep/\([0-9]\{8\}T[0-9]\{6\}Z\)/packs/.*#\1#p' \
		| sort | tail -1)"
fi
[ -n "$STAMP" ] || {
	echo "no sweep pack for $PACK under build/sweep/*/packs" >&2
	exit 1
}
DIR="build/sweep/$STAMP/packs/$PACK"
[ -f "$DIR/game.yml" ] || {
	echo "missing pack: $DIR" >&2
	exit 1
}

# Staging target = the private staging experience. Production stays unset (0/0)
# so the deploy refuses any production path and the overlap check stays clean.
cat >"$DIR/deploy.yml" <<'YAML'
environments:
  staging:
    universeId: 10768717424
    placeId: 83924867000873
  production:
    universeId: 0
    placeId: 0
    requiresHumanMerge: true
assets: {}
YAML

# Explicit owner provisioning. A survival-crafting pack is generated with
# policy = "developmental" and an empty owner, which a published server refuses
# to admit any real player under (the reviewed P1: settlement membership was
# never granted). Publishing it therefore requires an explicit real owner and
# consent record; the empty-owner path is never used.
OWNER_ID="${FORGE_OWNER_USER_ID:-11734795308}"
PROVISION="$DIR/src/server/SurvivalProvisionConfig.luau"
if [ -f "$PROVISION" ]; then
	case "$OWNER_ID" in
	'' | *[!0-9]*)
		echo "FORGE_OWNER_USER_ID must be a numeric Roblox user id" >&2
		exit 1
		;;
	esac
	cat >"$PROVISION" <<LUAU
--!strict
-- Explicit owner/consent provisioning written by cli/forge/publish-staging.sh.
-- policy = "staging": a published server admits exactly the owner and the
-- consented members below and refuses every other actor. The generated
-- "developmental" policy (empty owner, Studio-only allowlist) is never published.
return {
	provisionId = "staging",
	policy = "staging",
	ownerId = "$OWNER_ID",
	acceptedInvitations = { ["$OWNER_ID"] = true },
	actors = {},
}
LUAU
	echo "provisioned explicit owner $OWNER_ID for $PACK"
fi

: "${ROBLOX_API_KEY:?ROBLOX_API_KEY is not set}"
export ROBLOX_STAGING_API_KEY="$ROBLOX_API_KEY"
export ROBLOX_STAGING_UNIVERSE_ID=10768717424
export ROBLOX_STAGING_PLACE_ID=83924867000873

mkdir -p build/publish
LOG="build/publish/deploy-$PACK-$STAMP.log"
lune run cli/forge deploy --env staging --development --pack "$PACK" --pack-dir "$DIR" 2>&1 | tee "$LOG"

SHA="$(grep -oE 'artifactSha256=[0-9a-f]+' "$LOG" | tail -1 | cut -d= -f2)"
VER="$(grep -oE 'accepted version=[0-9]+' "$LOG" | tail -1 | cut -d= -f2)"
REC="build/publish/published.tsv"
[ -f "$REC" ] || printf 'utc\tpack\tsweep\tversion\tsha256\n' >"$REC"
printf '%s\t%s\t%s\t%s\t%s\n' \
	"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PACK" "$STAMP" "${VER:-?}" "${SHA:-?}" >>"$REC"
echo "recorded: $REC"
