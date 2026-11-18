#!/usr/bin/env bash
# Propose the new image to Ops (ADR 0042 in Shekel-Africa/Ops, S20-4856): open a PR on Shekel-Africa/Ops that sets
# chatwoot_image_tag in ansible/services/host_vars/crm-staging.yml to <sha>. Merging it deploys staging (Ops
# chatwoot-staging-deploy workflow); this script never deploys. Run by .github/workflows/shekel-build-deploy.yml;
# offline cases in shekel-ops-bump.check.sh.
#
#   shekel-ops-bump.sh <sha> <digest>
#
# - Ops main already names <sha>: nothing to do.
# - An open PR from branch chatwoot-staging/image-<sha12> exists: nothing to do (re-runs are idempotent).
# - Otherwise: branch from Ops main, one commit changing only the tag line, PR into main; then every other open
#   chatwoot-staging/image-* PR is closed as superseded and its branch deleted.
# DRY_RUN ("false" writes; anything else, unset included, only reads Ops and prints the planned change).
# Env: GH_TOKEN (GitHub App installation token for Ops), OPS_REPO (default Shekel-Africa/Ops), RUN_URL,
#      GITHUB_STEP_SUMMARY, GH (binary, overridable for the checks).
set -euo pipefail

GH=${GH:-gh}
OPS_REPO=${OPS_REPO:-Shekel-Africa/Ops}
FILE=ansible/services/host_vars/crm-staging.yml
PREFIX=chatwoot-staging/image-
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}
RUN_URL=${RUN_URL:-}
DRY_RUN=${DRY_RUN:-true}
[[ $DRY_RUN == false ]] || DRY_RUN=true

say() { printf '%s\n' "$@" >> "$SUMMARY"; }
die() { echo "shekel-ops-bump: $*" >&2; say "**Failed:** $*"; exit 1; }

[[ $# -eq 2 ]] || die "usage: shekel-ops-bump.sh <40-hex sha> <sha256 digest>"
sha=$1 digest=$2
[[ $sha =~ ^[0-9a-f]{40}$ ]] || die "not a full git sha: '$sha'"
if [[ $DRY_RUN == true && -z $digest ]]; then digest="(not pushed: dry run)"
else [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "not an image digest: '$digest'"; fi
short=${sha:0:12}
branch=$PREFIX$short

say "## Ops change" ""

# The file at Ops main, and its blob sha (needed to update it).
meta=$("$GH" api "repos/$OPS_REPO/contents/$FILE?ref=main") || die "cannot read $OPS_REPO:$FILE at main"
blob=$(jq -r .sha <<<"$meta")
current=$(jq -r .content <<<"$meta" | base64 -d) || die "cannot decode $FILE"

# Exactly one tag line, replaced by a new one; nothing else in the file changes.
n=$(grep -cE '^chatwoot_image_tag:' <<<"$current" || true)
[[ $n -eq 1 ]] || die "expected exactly one chatwoot_image_tag line in $FILE at Ops main, found $n"
old=$(grep -E '^chatwoot_image_tag:' <<<"$current" | sed -E 's/^chatwoot_image_tag:[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//')
if [[ $old == "$sha" ]]; then
  say "- Ops main already deploys \`$sha\`: no PR."
  exit 0
fi
newline="chatwoot_image_tag: $sha   # shekel/main @ $short; ECR digest $digest"
updated=$(awk -v nl="$newline" '/^chatwoot_image_tag:/ { print nl; next } { print }' <<<"$current")
changed=$(diff <(printf '%s\n' "$current") <(printf '%s\n' "$updated") | grep -c '^[<>]' || true)
[[ $changed -eq 2 ]] || die "internal: the edit changed $changed lines, expected 2"

say "- \`$OPS_REPO\` \`$FILE\`:" '```diff' "- chatwoot_image_tag: $old" "+ chatwoot_image_tag: $sha" '```'

if [[ $DRY_RUN == true ]]; then
  say "- Dry run: would open a PR from \`$branch\` into \`main\`, and close older \`$PREFIX*\` PRs as superseded."
  exit 0
fi

open_prs=$("$GH" api "repos/$OPS_REPO/pulls?state=open&base=main&per_page=100") || die "cannot list Ops PRs"
existing=$(jq -r --arg b "$branch" '.[] | select(.head.ref == $b) | .html_url' <<<"$open_prs")
if [[ -n $existing ]]; then
  say "- Already proposed: $existing"
  exit 0
fi

main_sha=$("$GH" api "repos/$OPS_REPO/git/ref/heads/main" --jq .object.sha) || die "cannot read Ops main"
"$GH" api -X POST "repos/$OPS_REPO/git/refs" -f "ref=refs/heads/$branch" -f "sha=$main_sha" >/dev/null \
  || die "cannot create branch $branch (left over from an earlier run? delete it and re-run)"

msg="chatwoot staging: deploy shekel/main @ $short"
"$GH" api -X PUT "repos/$OPS_REPO/contents/$FILE" -f "message=$msg" -f "branch=$branch" -f "sha=$blob" \
  -f "content=$(printf '%s\n' "$updated" | base64 -w0)" >/dev/null || die "cannot commit to $branch"

body=$(cat <<BODY
Automated by Shekel-Africa/chatwoot \`shekel-build-deploy\`${RUN_URL:+ ([run]($RUN_URL))}. ADR 0042.

## What changed

\`$FILE\`: \`chatwoot_image_tag\` \`$old\` → \`$sha\`
([commit](https://github.com/Shekel-Africa/chatwoot/commit/$sha),
[changes since the running image](https://github.com/Shekel-Africa/chatwoot/compare/$old...$sha)).

## How it was verified

- Image \`chatwoot:$sha\`, digest \`$digest\`, built from that commit with \`docker/Dockerfile\`.
- Community edition asserted on the image: \`DISABLE_ENTERPRISE=true\`, \`CW_EDITION=ce\`, no \`enterprise/\`, public-host guard present.
- Shekel specs passed on that commit.

**Merging deploys Chatwoot staging** (\`chatwoot-staging-deploy\`: \`TAGS=app CHECK=1\`, the real run, then verify).
Rollback: revert this PR.
BODY
)
pr=$("$GH" api -X POST "repos/$OPS_REPO/pulls" -f "title=$msg" -f "head=$branch" -f base=main -f "body=$body" --jq .html_url) \
  || die "cannot open the PR (branch $branch is pushed)"
number=${pr##*/}
say "- Opened: $pr"

# Supersede: one candidate open at a time.
while IFS=$'\t' read -r num ref; do
  [[ -n $num && $ref != "$branch" ]] || continue
  "$GH" api -X POST "repos/$OPS_REPO/issues/$num/comments" -f "body=Superseded by #$number." >/dev/null || true
  "$GH" api -X PATCH "repos/$OPS_REPO/pulls/$num" -f state=closed >/dev/null || { say "- Could not close #$num"; continue; }
  "$GH" api -X DELETE "repos/$OPS_REPO/git/refs/heads/$ref" >/dev/null || true
  say "- Closed #$num as superseded"
done < <(jq -r --arg p "$PREFIX" '.[] | select(.head.ref | startswith($p)) | [.number, .head.ref] | @tsv' <<<"$open_prs")
