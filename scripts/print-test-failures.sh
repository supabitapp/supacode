#!/usr/bin/env bash
# Print the assertion text behind each failed test. xcodebuild's streamed log reports parallel-bundle
# failures as a bare "Test case ... failed", so the message only survives in the result bundle.
set -uo pipefail

bundle="${1:-}"
if [ -z "$bundle" ]; then
  echo "usage: print-test-failures.sh <path.xcresult>" >&2
  exit 2
fi
if [ ! -d "$bundle" ]; then
  # No bundle means xcodebuild died before writing it (compile/scheme/launch failure); the build log above is
  # the whole story. Say so instead of exiting silently, since this script exists precisely to add detail.
  echo "print-test-failures: no result bundle at '$bundle'; xcodebuild likely failed before writing it (see the log above)." >&2
  exit 0
fi

# Keep xcresulttool's own stderr: if the subcommand ever churns across an Xcode bump, that error is the only
# signal this extractor went stale, so surface it rather than blackholing it behind a silent exit.
if ! summary="$(xcrun xcresulttool get test-results summary --path "$bundle" 2>&1)"; then
  echo "print-test-failures: could not read '$bundle':" >&2
  echo "$summary" >&2
  exit 0
fi

echo ""
echo "===== test failures ====="
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$summary" | jq -r '
    (.testFailures // [])
    | if length == 0 then
        "No failure recorded in the result bundle: the failure is outside the test report (build, launch, or crash)."
      else
        .[] | "✘ \(.targetName // "?") / \(.testName // "?")\n\(.failureText // "(no failure text)")\n"
      end
  '
else
  printf '%s\n' "$summary"
fi
echo "========================="
