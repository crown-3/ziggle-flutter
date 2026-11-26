#!/usr/bin/env bash
# Runs the Maestro E2E flows against the staging API, locally and in CI.
#
#   scripts/e2e/run.sh [--device <id>] [--include-tags <tags>] [flow ...]
#
# Without flows it runs the .maestro workspace, which config.yaml limits to
# .maestro/flows. Examples:
#
#   scripts/e2e/run.sh --include-tags core
#   scripts/e2e/run.sh .maestro/flows/05_reaction.yaml
#
# Needs: the E2E app installed on one booted device (see .maestro/README.md),
# .env in the project root, and E2E_IDP_EMAIL / E2E_IDP_PASSWORD.
#
# Results go to $E2E_OUTPUT_DIR (default build/e2e/<run id>): junit.xml, and
# per flow the screenshots, view hierarchy and Maestro and device logs.
set -euo pipefail

cd "$(dirname "$0")/../.."

maestro_args=()
flows=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device | --include-tags | --exclude-tags)
      maestro_args+=("$1" "$2")
      shift 2
      ;;
    -*)
      echo "unknown option: $1" >&2
      exit 64
      ;;
    *)
      flows+=("$1")
      shift
      ;;
  esac
done
[[ ${#flows[@]} -eq 0 ]] && flows=(.maestro)

if [[ -z "${E2E_IDP_EMAIL:-}" || -z "${E2E_IDP_PASSWORD:-}" ]]; then
  echo "set E2E_IDP_EMAIL and E2E_IDP_PASSWORD to the IdP test account" >&2
  exit 64
fi

# One ID per run keeps runs on different devices or CI jobs apart.
run_id="${E2E_RUN_ID:-local-$(date +%Y%m%d%H%M%S)-$RANDOM}"
# A directory per run, so runs on two devices from one checkout keep their
# results apart.
output_dir="${E2E_OUTPUT_DIR:-build/e2e/$run_id}"
rm -rf "$output_dir"
mkdir -p "$output_dir"
fixtures_env="$output_dir/fixtures.env"

finish() {
  local status=$?
  # Delete the notices of this run even when a flow failed, so their delayed
  # pushes are cancelled and the next run starts clean.
  dart run scripts/e2e/fixtures.dart cleanup --run-id "$run_id" || status=1
  # Maestro logs the typed text, as is and JSON-escaped in commands.json.
  # Keep every form of the password out of saved results.
  if [[ -d "$output_dir" ]]; then
    PASSWORD="$E2E_IDP_PASSWORD" find "$output_dir" -type f \
      \( -name '*.json' -o -name '*.log' -o -name '*.txt' -o -name '*.xml' -o -name '*.html' \) \
      -exec perl -MJSON::PP -pi -e '
        BEGIN {
          my $p = $ENV{PASSWORD};
          my %forms = ($p => 1);
          my $chars = $p;
          utf8::decode($chars);
          for my $json (JSON::PP->new->allow_nonref, JSON::PP->new->allow_nonref->ascii) {
            (my $escaped = $json->encode($chars)) =~ s/^"|"$//g;
            utf8::encode($escaped);
            $forms{$escaped} = 1;
            (my $slashes = $escaped) =~ s{/}{\\/}g;
            $forms{$slashes} = 1;
          }
          our $re = join "|", map { quotemeta } sort { length $b <=> length $a } keys %forms;
        }
        our $re;
        s/$re/***/g;
      ' {} +
  fi
  exit "$status"
}
trap finish EXIT

echo "E2E run $run_id"
# EXPERIMENT (#734): sample host CPU while the flows run.
(
  set +e +o pipefail
  sysctl -n hw.ncpu hw.memsize vm.swapusage
  memory_pressure | tail -3
  echo "== resident before flows (RSS KB)"
  ps -axo rss=,comm= | sort -rn | head -40
  # One process that loops in place, so a slow exec does not stall sampling.
  # vm_stat 10 prints one line per 10 s (pageins, pageouts, swapins, swapouts).
  vm_stat 10 | while read -r line; do
    echo "$(date -u +%H:%M:%S) $line"
  done &
  while true; do
    echo "== $(date -u +%H:%M:%S)"
    sysctl vm.swapusage
    top -l 1 -o mem -n 15 -stats pid,command,mem,cpu | awk '/^PID/{p=1} p'
    sleep 20
  done
) > "$output_dir/host-cpu.txt" 2>&1 &
sampler=$!
trap 'st=$?; kill $sampler 2>/dev/null; pkill -f "vm_stat 10"; (exit $st); finish' EXIT
dart run scripts/e2e/fixtures.dart setup --run-id "$run_id" --out "$fixtures_env"
set -a
# shellcheck disable=SC1090
source "$fixtures_env"
set +a
export MAESTRO_IDP_EMAIL="$E2E_IDP_EMAIL"
export MAESTRO_IDP_PASSWORD="$E2E_IDP_PASSWORD"
export MAESTRO_CLI_NO_ANALYTICS=1
export MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true

maestro test \
  ${maestro_args[@]+"${maestro_args[@]}"} \
  --format junit \
  --output "$output_dir/junit.xml" \
  --test-output-dir "$output_dir/flows" \
  --debug-output "$output_dir/debug" \
  --flatten-debug-output \
  "${flows[@]}"
