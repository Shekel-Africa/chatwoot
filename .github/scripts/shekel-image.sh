#!/usr/bin/env bash
# Shekel fork image: build, assert community edition, push to ECR (ADR 0042 in Shekel-Africa/Ops, S20-4856).
# Run by .github/workflows/shekel-build-deploy.yml; offline cases in shekel-image.check.sh.
#
#   shekel-image.sh build  <sha>   docker build -f docker/Dockerfile, tagged <local repo>:<sha>, labelled with the sha
#   shekel-image.sh assert <sha>   the built image is the community edition of that commit:
#                                    DISABLE_ENTERPRISE=true and CW_EDITION=ce in its config AND inside a container,
#                                    no enterprise/ or spec/enterprise/, the public-host guard present,
#                                    /app/.git_sha and the revision label equal <sha>
#   shekel-image.sh push   <sha>   push to $ECR_REGISTRY/$ECR_REPOSITORY:<sha> (an existing tag is kept: tags are
#                                    immutable and name one commit), then print the registry digest
#
# Env: DRY_RUN ("false" pushes; anything else, unset included, never touches AWS), ECR_REGISTRY, ECR_REPOSITORY,
#      AWS_REGION (default us-east-1), LOCAL_IMAGE (default shekel-chatwoot), GITHUB_STEP_SUMMARY, GITHUB_OUTPUT,
#      DOCKER / AWS (binaries, overridable for the checks).
# SC2016: single quotes are deliberate: Markdown backticks in the summary, and the script run inside the container.
# shellcheck disable=SC2016
set -euo pipefail

DOCKER=${DOCKER:-docker}
AWS=${AWS:-aws}
LOCAL_IMAGE=${LOCAL_IMAGE:-shekel-chatwoot}
REGION=${AWS_REGION:-us-east-1}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}
OUTPUT=${GITHUB_OUTPUT:-/dev/null}
DRY_RUN=${DRY_RUN:-true}
[[ $DRY_RUN == false ]] || DRY_RUN=true

die() { echo "shekel-image: $*" >&2; printf '**Failed:** %s\n' "$*" >> "$SUMMARY"; exit 1; }
usage() { die "usage: shekel-image.sh build|assert|push <40-hex sha>"; }

[[ $# -eq 2 ]] || usage
cmd=$1 sha=$2
[[ $sha =~ ^[0-9a-f]{40}$ ]] || die "not a full git sha: '$sha'"
local_ref="$LOCAL_IMAGE:$sha"

build() {
  "$DOCKER" build -f docker/Dockerfile --build-arg "GIT_SHA=$sha" \
    --label "org.opencontainers.image.revision=$sha" \
    --label "org.opencontainers.image.source=https://github.com/Shekel-Africa/chatwoot" \
    -t "$local_ref" .
  printf '## Image\n\n- Commit: `%s`\n- Built: `%s` (docker/Dockerfile)\n' "$sha" "$local_ref" >> "$SUMMARY"
}

assert_ce() {
  local env label inside
  env=$("$DOCKER" image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$local_ref") \
    || die "image $local_ref not found (build first)"
  grep -qx 'DISABLE_ENTERPRISE=true' <<<"$env" || die "image config: DISABLE_ENTERPRISE is not true"
  grep -qx 'CW_EDITION=ce' <<<"$env" || die "image config: CW_EDITION is not ce"
  label=$("$DOCKER" image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$local_ref")
  [[ $label == "$sha" ]] || die "revision label is '$label', expected $sha"

  # Inside the container, with no network: what Rails will actually see.
  inside=$("$DOCKER" run --rm --network none --entrypoint /bin/sh "$local_ref" -c '
    cd /app || exit 3
    echo "DISABLE_ENTERPRISE=${DISABLE_ENTERPRISE:-}"
    echo "CW_EDITION=${CW_EDITION:-}"
    if [ -e enterprise ]; then echo "enterprise=present"; else echo "enterprise=absent"; fi
    if [ -e spec/enterprise ]; then echo "spec_enterprise=present"; else echo "spec_enterprise=absent"; fi
    if [ -f app/middleware/shekel/public_host_guard.rb ]; then echo "guard=present"; else echo "guard=absent"; fi
    echo "git_sha=$(cat .git_sha 2>/dev/null)"
  ') || die "could not run $local_ref"
  local want
  for want in DISABLE_ENTERPRISE=true CW_EDITION=ce enterprise=absent spec_enterprise=absent guard=present "git_sha=$sha"; do
    grep -qx -- "$want" <<<"$inside" || die "inside the image: expected '$want', got: $(tr '\n' ' ' <<<"$inside")"
  done
  printf -- '- Community edition: `DISABLE_ENTERPRISE=true`, `CW_EDITION=ce`, no `enterprise/`, public-host guard present, `.git_sha` = commit\n' >> "$SUMMARY"
}

push() {
  [[ -n ${ECR_REGISTRY:-} && -n ${ECR_REPOSITORY:-} ]] || die "ECR_REGISTRY and ECR_REPOSITORY are required"
  local remote="$ECR_REGISTRY/$ECR_REPOSITORY:$sha" digest
  if [[ $DRY_RUN == true ]]; then
    printf -- '- Push: skipped (dry run); would push `%s`\n' "$remote" >> "$SUMMARY"
    echo "digest=" >> "$OUTPUT"
    return 0
  fi
  "$AWS" ecr get-login-password --region "$REGION" | "$DOCKER" login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null
  trap '"$DOCKER" logout "$ECR_REGISTRY" >/dev/null 2>&1 || true' EXIT
  if digest=$(ecr_digest) ; then
    # Immutable tags: this commit is already in ECR (a re-run, or a dispatch of an already-built commit). Keep it.
    printf -- '- Push: `%s` already in ECR (immutable tag kept)\n' "$remote" >> "$SUMMARY"
  else
    "$DOCKER" tag "$local_ref" "$remote"
    "$DOCKER" push "$remote"
    digest=$(ecr_digest) || die "pushed $remote but ECR does not list it"
    printf -- '- Push: `%s`\n' "$remote" >> "$SUMMARY"
  fi
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "unexpected digest for $remote: '$digest'"
  printf -- '- Digest: `%s`\n' "$digest" >> "$SUMMARY"
  echo "digest=$digest" >> "$OUTPUT"
}

ecr_digest() {
  "$AWS" ecr describe-images --region "$REGION" --repository-name "$ECR_REPOSITORY" --image-ids "imageTag=$sha" \
    --query 'imageDetails[0].imageDigest' --output text 2>/dev/null
}

case $cmd in
  build) build ;;
  assert) assert_ce ;;
  push) push ;;
  *) usage ;;
esac
