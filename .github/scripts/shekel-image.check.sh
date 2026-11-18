#!/usr/bin/env bash
# Offline cases for shekel-image.sh. `docker` and `aws` are stub scripts prepended to PATH: they log every argv to
# $CALLS and answer from STUB_* variables. No Docker daemon, no network.
#
# Usage: bash .github/scripts/shekel-image.check.sh      (exit 0 = every case passed)
# SC2015: `ok` only echoes and always returns 0, so `cond && ok … || bad …` is a true if/else here.
# shellcheck disable=SC2015
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=${SCRIPT:-$HERE/shekel-image.sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0 passes=0
SHA=7c6831836d1f3858e32525f1a388553ecf787c4a
DIGEST=sha256:8db7a1fd6b6ce26b0841ff83c5c407372950a533c8ca40230cb911e5ded45f83

mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$CALLS"
case "$1 $2" in
  "image inspect")
    [[ -z ${STUB_NO_IMAGE:-} ]] || { echo "Error: No such image" >&2; exit 1; }
    if [[ $* == *Labels* ]]; then printf '%s\n' "${STUB_LABEL}"; else printf '%b' "${STUB_ENV}"; fi ;;
  "run --rm") printf '%b' "${STUB_INSIDE}" ;;
  "push "*) [[ -z ${STUB_PUSH_FAIL:-} ]] || exit 1; echo pushed > "$STATE" ;;
  "login --username") cat >/dev/null ;;
esac
exit 0
STUB
cat > "$T/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf 'aws %s\n' "$*" >> "$CALLS"
case "$2" in
  get-login-password) echo not-a-real-token ;;
  describe-images)
    if [[ -n ${STUB_EXISTS:-} || -s $STATE ]]; then printf '%s\n' "${STUB_DIGEST}"; exit 0; fi
    echo "An error occurred (ImageNotFoundException)" >&2; exit 254 ;;
esac
STUB
chmod +x "$T/bin/"*

GOOD_ENV='PATH=/usr/bin\nDISABLE_ENTERPRISE=true\nCW_EDITION=ce\nRAILS_ENV=production\n'
GOOD_INSIDE="DISABLE_ENTERPRISE=true\nCW_EDITION=ce\nenterprise=absent\nspec_enterprise=absent\nguard=present\ngit_sha=$SHA\n"

# run <name> <expected rc> <args...> -- [VAR=value ...]
run() {
  local name=$1 want=$2; shift 2
  local args=() d="$T/$name"
  while [[ $# -gt 0 && $1 != -- ]]; do args+=("$1"); shift; done; [[ ${1:-} == -- ]] && shift
  mkdir -p "$d"; : > "$d/calls"; : > "$d/summary"; : > "$d/output"; : > "$d/state"
  out=$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" CALLS="$d/calls" STATE="$d/state" \
    STUB_ENV="$GOOD_ENV" STUB_LABEL="$SHA" STUB_INSIDE="$GOOD_INSIDE" STUB_DIGEST="$DIGEST" \
    ECR_REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com ECR_REPOSITORY=chatwoot \
    GITHUB_STEP_SUMMARY="$d/summary" GITHUB_OUTPUT="$d/output" "$@" bash "$SCRIPT" "${args[@]}" 2>&1); rc=$?
  calls=$(cat "$d/calls"); summary=$(cat "$d/summary"); output=$(cat "$d/output")
  if [[ $rc -ne $want ]]; then bad "$name: rc=$rc, want $want"$'\n'"$out"; return 1; fi
}
ok() { passes=$((passes + 1)); echo "ok   $1"; }
bad() { fails=$((fails + 1)); echo "FAIL $1"; }
has() { grep -qF -- "$2" <<<"$1"; }

# --- arguments
run bad-sha 1 build 7c6831836d && { [[ -z $calls ]] && ok "a short sha is refused before docker" || bad "bad-sha: $calls"; }
run no-args 1 && ok "no arguments: usage error"
run bad-cmd 1 deploy "$SHA" && ok "an unknown subcommand is refused"

# --- build
if run build 0 build "$SHA"; then
  has "$calls" "docker build -f docker/Dockerfile --build-arg GIT_SHA=$SHA --label org.opencontainers.image.revision=$SHA" \
    && has "$calls" "-t shekel-chatwoot:$SHA ." && ok "build: docker/Dockerfile, GIT_SHA arg, revision label, local tag" || bad "build: $calls"
fi

# --- assert: the good image passes; each single defect fails
if run assert-good 0 assert "$SHA"; then
  has "$calls" "docker run --rm --network none --entrypoint /bin/sh shekel-chatwoot:$SHA" && has "$summary" "Community edition" \
    && ok "assert: a community image passes (checked inside a network-less container)" || bad "assert-good: $calls"
fi
for c in \
  "env-no-disable|STUB_ENV=PATH=/usr/bin\nCW_EDITION=ce\n|DISABLE_ENTERPRISE is not true" \
  "env-disable-false|STUB_ENV=DISABLE_ENTERPRISE=false\nCW_EDITION=ce\n|DISABLE_ENTERPRISE is not true" \
  "env-ee|STUB_ENV=DISABLE_ENTERPRISE=true\nCW_EDITION=ee\n|CW_EDITION is not ce" \
  "label|STUB_LABEL=0000000000000000000000000000000000000000|revision label" \
  "inside-enterprise|STUB_INSIDE=DISABLE_ENTERPRISE=true\nCW_EDITION=ce\nenterprise=present\nspec_enterprise=absent\nguard=present\ngit_sha=$SHA\n|enterprise=absent" \
  "inside-spec-enterprise|STUB_INSIDE=DISABLE_ENTERPRISE=true\nCW_EDITION=ce\nenterprise=absent\nspec_enterprise=present\nguard=present\ngit_sha=$SHA\n|spec_enterprise=absent" \
  "inside-no-guard|STUB_INSIDE=DISABLE_ENTERPRISE=true\nCW_EDITION=ce\nenterprise=absent\nspec_enterprise=absent\nguard=absent\ngit_sha=$SHA\n|guard=present" \
  "inside-env-overridden|STUB_INSIDE=DISABLE_ENTERPRISE=\nCW_EDITION=ce\nenterprise=absent\nspec_enterprise=absent\nguard=present\ngit_sha=$SHA\n|DISABLE_ENTERPRISE=true" \
  "inside-wrong-sha|STUB_INSIDE=DISABLE_ENTERPRISE=true\nCW_EDITION=ce\nenterprise=absent\nspec_enterprise=absent\nguard=present\ngit_sha=unknown\n|git_sha=$SHA" \
  "no-image|STUB_NO_IMAGE=1|not found"; do
  IFS='|' read -r n v msg <<<"$c"
  run "assert-$n" 1 assert "$SHA" -- "$v" && { has "$summary" "$msg" && ok "assert refuses: $n" || bad "assert-$n: $summary"; }
done

# --- push
if run push-dry 0 push "$SHA"; then
  ! has "$calls" "aws" && ! has "$calls" "docker push" && has "$summary" "skipped (dry run)" \
    && ok "push: unset DRY_RUN touches neither AWS nor the registry" || bad "push-dry: $calls"
fi
if run push-dry-true 0 push "$SHA" -- DRY_RUN=true; then
  [[ -z $calls ]] && ok "push: DRY_RUN=true makes no call" || bad "push-dry-true: $calls"
fi
if run push-new 0 push "$SHA" -- DRY_RUN=false; then
  r=123456789012.dkr.ecr.us-east-1.amazonaws.com/chatwoot:$SHA
  # The two ends of `get-login-password | docker login` start together: their log order is not fixed, so sort them.
  order=$(grep -oE '^(aws ecr [a-z-]+|docker (login|tag|push|logout))' <<<"$calls" \
    | awk 'NR <= 2 { head[NR] = $0; next } NR == 3 { if (head[1] > head[2]) { t = head[1]; head[1] = head[2]; head[2] = t }
                     print head[1]; print head[2] } { print }' | tr '\n' ',')
  [[ $order == "aws ecr get-login-password,docker login,aws ecr describe-images,docker tag,docker push,aws ecr describe-images,docker logout," ]] \
    && has "$calls" "docker push $r" && has "$output" "digest=$DIGEST" && has "$summary" "$DIGEST" \
    && ok "push: login, not there, tag, push, digest to output and summary, logout" || bad "push-new: $order"
fi
if run push-exists 0 push "$SHA" -- DRY_RUN=false STUB_EXISTS=1; then
  ! has "$calls" "docker push" && has "$summary" "already in ECR" && has "$output" "digest=$DIGEST" \
    && ok "push: an existing immutable tag is kept, its digest reported" || bad "push-exists: $calls"
fi
run push-fails 1 push "$SHA" -- DRY_RUN=false STUB_PUSH_FAIL=1 && ok "push: a failed docker push fails"
run push-bad-digest 1 push "$SHA" -- DRY_RUN=false STUB_EXISTS=1 STUB_DIGEST=None && ok "push: a non-digest answer is refused"
run push-no-registry 1 push "$SHA" -- DRY_RUN=false ECR_REGISTRY= && { [[ -z $calls ]] && ok "push: no registry configured, no call" || bad "push-no-registry: $calls"; }

echo "$passes passed, $fails failed"
[[ $fails -eq 0 ]]
