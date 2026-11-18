#!/usr/bin/env bash
# Offline cases for shekel-specs.sh: a stub `bundle` records its argv; each case runs in a throwaway spec/ tree.
# Usage: bash .github/scripts/shekel-specs.check.sh      (exit 0 = every case passed)
# SC2016: the stub body is written verbatim; its variables expand when the stub runs.
# shellcheck disable=SC2016
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=${SCRIPT:-$HERE/shekel-specs.sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0 passes=0
ok() { passes=$((passes + 1)); echo "ok   $1"; }
bad() { fails=$((fails + 1)); echo "FAIL $1"; }
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$CALLS"\nexit "${STUB_RC:-0}"\n' > "$T/bin/bundle"; chmod +x "$T/bin/bundle"

tree() { # <dir> <files...>
  local d=$1; shift; mkdir -p "$d"; for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; : > "$d/$f"; done
}
run() { # <dir> -> rc, calls
  (cd "$1" && env -i PATH="$T/bin:/usr/bin:/bin" CALLS="$1/calls" STUB_RC="${STUB_RC:-0}" bash "$SCRIPT" >/dev/null 2>&1); rc=$?
  calls=$(cat "$1/calls" 2>/dev/null || true)
}

tree "$T/a" spec/middleware/shekel/public_host_guard_spec.rb spec/jobs/shekel/retention_job_spec.rb \
  spec/controllers/shekel_api_tokens_spec.rb spec/models/user_spec.rb spec/shekel_helper.rb spec/enterprise/x_spec.rb
run "$T/a"
if [[ $rc -eq 0 && $calls == "exec rspec --format progress spec/controllers/shekel_api_tokens_spec.rb spec/jobs/shekel/retention_job_spec.rb spec/middleware/shekel/public_host_guard_spec.rb" ]]
then ok "runs exactly the Shekel *_spec.rb files, sorted"; else bad "selection: rc=$rc calls=$calls"; fi

tree "$T/b" spec/models/user_spec.rb
run "$T/b"
if [[ $rc -ne 0 && -z $calls ]]; then ok "no Shekel spec: fails without running rspec"; else bad "empty: rc=$rc calls=$calls"; fi

STUB_RC=1 run "$T/a"
if [[ $rc -eq 1 ]]; then ok "a failing rspec fails the step"; else bad "rspec failure: rc=$rc"; fi

echo "$passes passed, $fails failed"
[[ $fails -eq 0 ]]
