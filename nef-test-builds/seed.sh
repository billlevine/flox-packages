#!/usr/bin/env bash
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

help() {
    cat <<'EOF'
Usage: seed.sh [--catalog NAME] [--run-dir DIR] [--dry-run] [--no-install] [PACKAGE ...]
Build and publish packages in dependency order; optionally select packages and
their dependencies. Stop on the first failure and restore the project lock.
  --catalog NAME   CATALOG environment variable, default billlevine
  --run-dir DIR    RUN_DIR environment variable, default seed-runs/<UTC timestamp>-seed-<pid>
  --dry-run        Print order and commands without executing any Flox command or writing files
  --no-install     Skip installing and running top packages
  -h, --help       Show this help
Run captures are private local artifacts; review before sharing.
EOF
}

install=true
packages=()
while (($#)); do
    case $1 in
        --catalog|--run-dir)
            (($# >= 2)) || die "Missing value for $1"
            [[ -n $2 ]] || die "Empty value for $1"
            if [[ $1 == --catalog ]]; then CATALOG=$2; else RUN_DIR=$2; fi
            shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --no-install) install=false; shift ;;
        -h|--help) help; exit 0 ;;
        --) shift; packages+=("$@"); break ;;
        -*) die "Unknown option: $1" ;;
        *) packages+=("$1"); shift ;;
    esac
done
scan_packages
select_order "${packages[@]}"
printf 'Order:'; printf ' %s' "${ORDER[@]}"; printf '\n'
if [[ $DRY_RUN == true ]]; then
    RUN_DIR=${RUN_DIR:-$ROOT/seed-runs/<UTC-timestamp>-seed-<pid>}
    printf 'Run directory: %s\n' "$RUN_DIR"
    printf 'Back up any catalog.lock, start without it, then restore it on exit.\n'
    command_line flox --version
else
    start_run seed
    fresh_lock
fi
cd -- "$ROOT"
i=0
for pkg in "${ORDER[@]}"; do
    i=$((i+1)); printf -v prefix '%02d-%s' "$i" "$pkg"
    publish_package "$pkg" "$prefix"
done
# With everything published, one project-wide capture of the resolved lock.
capture_catalog_lock _project final
if [[ $install == true ]]; then
    for pkg in "${TOPS[@]}"; do try_package "$pkg"; done
fi
[[ $DRY_RUN == true ]] || printf 'Complete: %s\n' "$RUN_DIR"
