#!/usr/bin/env bash
# The fork's own checks before an image is built (S20-4856): every spec whose path names Shekel (spec/**/*shekel*,
# spec/**/shekel/**). Upstream's full suite runs on pull requests (run_foss_spec.yml); this is the gate on the
# commit that is about to be built. Offline cases in shekel-specs.check.sh.
# Env: BUNDLE (binary, overridable for the checks). Run from the repository root.
set -euo pipefail
BUNDLE=${BUNDLE:-bundle}

mapfile -t specs < <(find spec -type f -name '*_spec.rb' -path '*shekel*' | LC_ALL=C sort)
[[ ${#specs[@]} -gt 0 ]] || { echo "shekel-specs: no Shekel spec found under spec/ (were they renamed?)" >&2; exit 1; }
echo "shekel-specs: ${#specs[@]} files"
exec "$BUNDLE" exec rspec --format progress "${specs[@]}"
