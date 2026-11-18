#!/usr/bin/env bash
# Offline cases for shekel-ops-bump.sh. `gh` is a stub prepended to PATH: it logs every call to $CALLS, serves the
# Ops host_vars file and the open-PR list from STUB_* files, and records what would be written. No network.
#
# Usage: bash .github/scripts/shekel-ops-bump.check.sh      (exit 0 = every case passed)
# SC2015: `ok` only echoes and always returns 0, so `cond && ok … || bad …` is a true if/else here.
# shellcheck disable=SC2015
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=${SCRIPT:-$HERE/shekel-ops-bump.sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0 passes=0
OLD=7c6831836d1f3858e32525f1a388553ecf787c4a
SHA=0123456789abcdef0123456789abcdef01234567
DIGEST=sha256:8db7a1fd6b6ce26b0841ff83c5c407372950a533c8ca40230cb911e5ded45f83

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh api: logs "METHOD path" (+ -f fields to $WRITES), serves fixtures, fails on demand (STUB_FAIL=<word>).
shift # "api"
method=GET path= jqexpr=
fields=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -f) fields+=("$2"); shift 2 ;;
    --jq) jqexpr=$2; shift 2 ;;
    *) path=$1; shift ;;
  esac
done
printf '%s %s\n' "$method" "$path" >> "$CALLS"
for f in "${fields[@]}"; do printf '  %s\n' "$f" >> "$WRITES"; done
fail() { [[ ",${STUB_FAIL:-}," == *",$1,"* ]] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }; return 0; }
emit() { if [[ -n $jqexpr ]]; then jq -r "$jqexpr"; else cat; fi; }
case "$method $path" in
  "GET repos/Shekel-Africa/Ops/contents/"*) fail read
    jq -n --arg c "$(base64 -w60 < "$STUB_FILE")" '{sha: "blob123", content: $c}' | emit ;;
  "GET repos/Shekel-Africa/Ops/pulls?"*) fail list; cat "$STUB_PRS" | emit ;;
  "GET repos/Shekel-Africa/Ops/git/ref/heads/main") echo '{"object":{"sha":"mainsha"}}' | emit ;;
  "POST repos/Shekel-Africa/Ops/git/refs") fail branch; echo '{}' ;;
  "PUT repos/Shekel-Africa/Ops/contents/"*) fail commit
    for f in "${fields[@]}"; do [[ $f == content=* ]] && base64 -d <<<"${f#content=}" > "$COMMITTED"; done; echo '{}' ;;
  "POST repos/Shekel-Africa/Ops/pulls") fail pr; echo '{"html_url":"https://github.com/Shekel-Africa/Ops/pull/300"}' | emit ;;
  "POST repos/Shekel-Africa/Ops/issues/"*"/comments") echo '{}' ;;
  "PATCH repos/Shekel-Africa/Ops/pulls/"*) fail close; echo '{}' ;;
  "DELETE repos/Shekel-Africa/Ops/git/refs/heads/"*) : ;;
  *) echo "stub gh: unexpected $method $path" >&2; exit 99 ;;
esac
STUB
chmod +x "$T/bin/gh"

hostvars() { # <tag line(s)>
  printf '%s\n' "---" "chatwoot_env: staging" "chatwoot_registry: 213080125158.dkr.ecr.us-east-1.amazonaws.com" "$1" \
    "# Third-party images" "chatwoot_redis_image: redis:7.4-alpine"
}
NOPRS='[]'
OLDPRS='[{"number":290,"head":{"ref":"chatwoot-staging/image-aaaaaaaaaaaa"},"html_url":"u290"},
 {"number":291,"head":{"ref":"S20-9999-other"},"html_url":"u291"}]'
SAMEPR='[{"number":295,"head":{"ref":"chatwoot-staging/image-0123456789ab"},"html_url":"https://github.com/Shekel-Africa/Ops/pull/295"}]'

# run <name> <rc> <tagline> <prs json> [args...] -- [VAR=value ...]
run() {
  local name=$1 want=$2 tl=$3 prs=$4; shift 4
  local args=() d="$T/$name"
  while [[ $# -gt 0 && $1 != -- ]]; do args+=("$1"); shift; done; [[ ${1:-} == -- ]] && shift
  mkdir -p "$d"; hostvars "$tl" > "$d/file"; printf '%s' "$prs" > "$d/prs"
  : > "$d/calls"; : > "$d/writes"; : > "$d/summary"; rm -f "$d/committed"
  out=$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" CALLS="$d/calls" WRITES="$d/writes" COMMITTED="$d/committed" \
    STUB_FILE="$d/file" STUB_PRS="$d/prs" GITHUB_STEP_SUMMARY="$d/summary" GH_TOKEN=x RUN_URL=https://run/1 \
    "$@" bash "$SCRIPT" "${args[@]}" 2>&1); rc=$?
  calls=$(cat "$d/calls"); writes=$(cat "$d/writes"); summary=$(cat "$d/summary")
  committed=$(cat "$d/committed" 2>/dev/null); orig=$(cat "$d/file")
  if [[ $rc -ne $want ]]; then bad "$name: rc=$rc, want $want"$'\n'"$out"; return 1; fi
}
ok() { passes=$((passes + 1)); echo "ok   $1"; }
bad() { fails=$((fails + 1)); echo "FAIL $1"; }
has() { grep -qF -- "$2" <<<"$1"; }
writes_any() { grep -qE '^(POST|PUT|PATCH|DELETE) ' <<<"$1"; }
TL="chatwoot_image_tag: $OLD   # shekel/main @ #2; was 49237666 (#1)"

# 1. Unset DRY_RUN: reads Ops, shows the diff, writes nothing.
if run dry 0 "$TL" "$NOPRS" "$SHA" "$DIGEST"; then
  ! writes_any "$calls" && has "$summary" "- chatwoot_image_tag: $OLD" && has "$summary" "+ chatwoot_image_tag: $SHA" \
    && has "$summary" "Dry run: would open" && ok "dry run (unset): diff in the summary, no write" || bad "dry: $calls"
fi
# 2. Dry run without a digest (nothing was pushed) is fine.
run dry-nodigest 0 "$TL" "$NOPRS" "$SHA" "" -- DRY_RUN=true && { ! writes_any "$calls" && ok "dry run without a digest" || bad "dry-nodigest"; }
# 3. Real run without a digest: refused before any call.
run live-nodigest 1 "$TL" "$NOPRS" "$SHA" "" -- DRY_RUN=false && { [[ -z $calls ]] && ok "live run needs a digest" || bad "live-nodigest: $calls"; }

# 4. Live: branch from main, one commit changing only the tag line, PR into main.
if run live 0 "$TL" "$NOPRS" "$SHA" "$DIGEST" -- DRY_RUN=false; then
  d=$(diff <(printf '%s\n' "$orig") <(printf '%s\n' "$committed"))
  if has "$writes" "ref=refs/heads/chatwoot-staging/image-0123456789ab" && has "$writes" "sha=mainsha" \
    && has "$writes" "sha=blob123" && has "$writes" "branch=chatwoot-staging/image-0123456789ab" \
    && has "$writes" "base=main" && has "$writes" "title=chatwoot staging: deploy shekel/main @ 0123456789ab" \
    && [[ $(grep -c '^[<>]' <<<"$d") -eq 2 ]] && has "$committed" "chatwoot_image_tag: $SHA   # shekel/main @ 0123456789ab; ECR digest $DIGEST" \
    && has "$writes" "compare/$OLD...$SHA" && has "$summary" "pull/300"
  then ok "live: branch, a one-line commit, PR into main (no ticket key in the title)"; else bad "live: $writes"$'\n'"$d"; fi
fi
# 5. Live with an older bump PR open: it is closed as superseded and its branch deleted; other PRs untouched.
if run supersede 0 "$TL" "$OLDPRS" "$SHA" "$DIGEST" -- DRY_RUN=false; then
  has "$calls" "PATCH repos/Shekel-Africa/Ops/pulls/290" && has "$calls" "DELETE repos/Shekel-Africa/Ops/git/refs/heads/chatwoot-staging/image-aaaaaaaaaaaa" \
    && has "$writes" "body=Superseded by #300." && ! has "$calls" "pulls/291" \
    && ok "older bump PR superseded; unrelated PR untouched" || bad "supersede: $calls"
fi
# 6. The PR for this sha is already open: nothing written (re-runs are idempotent).
if run same 0 "$TL" "$SAMEPR" "$SHA" "$DIGEST" -- DRY_RUN=false; then
  ! writes_any "$calls" && has "$summary" "Already proposed" && ok "already proposed: no write" || bad "same: $calls"
fi
# 7. Ops main already names the sha: nothing to do, no PR listing even.
if run current 0 "chatwoot_image_tag: $SHA" "$NOPRS" "$SHA" "$DIGEST" -- DRY_RUN=false; then
  ! writes_any "$calls" && has "$summary" "already deploys" && ok "Ops main already on the sha: no PR" || bad "current: $calls"
fi
# 8-9. The Ops file is not what we expect: refuse.
run two-lines 1 "$TL"$'\n'"chatwoot_image_tag: $OLD" "$NOPRS" "$SHA" "$DIGEST" -- DRY_RUN=false \
  && { ! writes_any "$calls" && has "$summary" "found 2" && ok "two tag lines in Ops: refused" || bad "two-lines"; }
run no-line 1 "# none" "$NOPRS" "$SHA" "$DIGEST" -- DRY_RUN=false \
  && { ! writes_any "$calls" && has "$summary" "found 0" && ok "no tag line in Ops: refused" || bad "no-line"; }
# 10-11. Bad inputs.
run bad-sha 1 "$TL" "$NOPRS" "abc" "$DIGEST" -- DRY_RUN=false && { [[ -z $calls ]] && ok "a short sha is refused" || bad "bad-sha"; }
run bad-digest 1 "$TL" "$NOPRS" "$SHA" "latest" -- DRY_RUN=false && { [[ -z $calls ]] && ok "a non-digest is refused" || bad "bad-digest"; }
# 12-14. API failures stop the run at the right place.
run read-fails 1 "$TL" "$NOPRS" "$SHA" "$DIGEST" -- DRY_RUN=false STUB_FAIL=read && { ! writes_any "$calls" && ok "cannot read Ops: fails, no write" || bad "read-fails"; }
run branch-fails 1 "$TL" "$NOPRS" "$SHA" "$DIGEST" -- DRY_RUN=false STUB_FAIL=branch \
  && { ! has "$calls" "PUT " && has "$summary" "cannot create branch" && ok "branch exists/fails: no commit" || bad "branch-fails: $calls"; }
run pr-fails 1 "$TL" "$OLDPRS" "$SHA" "$DIGEST" -- DRY_RUN=false STUB_FAIL=pr \
  && { ! has "$calls" "PATCH" && ok "PR creation fails: nothing superseded" || bad "pr-fails: $calls"; }

echo "$passes passed, $fails failed"
[[ $fails -eq 0 ]]
