#!/usr/bin/env bash
# Shared package scan and run capture for seed.sh and nef (Bash 4+).
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CATALOG=${CATALOG:-billlevine}
DRY_RUN=${DRY_RUN:-false}
declare -A DEPS VERSIONS SELECTED
PACKAGES=() ORDER=() TOPS=()

die() { printf '%s\n' "$*" >&2; exit 1; }
command_line() { printf '+ '; printf '%q ' "$@"; printf '\n'; }
flox_command() { command_line flox "$@"; flox "$@"; }

scan_packages() {
    local file pkg ref catalog dep sorted
    [[ $CATALOG =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid catalog: $CATALOG"
    for file in "$ROOT"/.flox/pkgs/*/default.nix; do
        pkg=${file%/default.nix}; pkg=${pkg##*/}
        PACKAGES+=("$pkg")
        DEPS[$pkg]=''
        VERSIONS[$pkg]=$(sed -nE 's/^[[:space:]]*version = "([^"]+)";.*/\1/p' "$file")
        [[ -n ${VERSIONS[$pkg]} && ${VERSIONS[$pkg]} != *$'\n'* ]] || die "Expected one version assignment: $file"
        while read -r ref; do
            ref=${ref#catalogs.}; catalog=${ref%%.*}; dep=${ref#*.}
            [[ $catalog == "$CATALOG" ]] || die "$pkg references catalog $catalog; retarget expressions before using CATALOG=$CATALOG"
            DEPS[$pkg]+="$dep "
        done < <(grep -oE 'catalogs\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+' "$file" | sort -u)
    done
    for pkg in "${PACKAGES[@]}"; do
        for dep in ${DEPS[$pkg]}; do
            [[ -v VERSIONS[$dep] ]] || die "$pkg references unknown package: $dep"
        done
    done
    sorted=$(for pkg in "${PACKAGES[@]}"; do
        printf '%s %s\n' "$pkg" "$pkg"
        for dep in ${DEPS[$pkg]}; do printf '%s %s\n' "$dep" "$pkg"; done
    done | tsort) || die 'Dependency cycle: cannot order packages'
    mapfile -t ORDER <<< "$sorted"
}

require_package() { [[ -v VERSIONS[$1] ]] || die "Unknown package: $1"; }
select_package() {
    local dep
    require_package "$1"
    [[ -v SELECTED[$1] ]] && return 0
    SELECTED[$1]=1
    for dep in ${DEPS[$1]}; do select_package "$dep"; done
}
select_order() {
    local pkg dep
    local -a chosen=()
    local -A consumed=()
    if (($#)); then
        for pkg in "$@"; do select_package "$pkg"; done
        for pkg in "${ORDER[@]}"; do [[ -v SELECTED[$pkg] ]] && chosen+=("$pkg"); done
        ORDER=("${chosen[@]}")
    fi
    for pkg in "${ORDER[@]}"; do
        for dep in ${DEPS[$pkg]}; do consumed[$dep]=1; done
    done
    for pkg in "${ORDER[@]}"; do [[ -v consumed[$pkg] ]] || TOPS+=("$pkg"); done
}

capture_project() {
    local prefix=$1 file
    for file in manifest.toml manifest.lock; do
        [[ ! -f $ROOT/.flox/env/$file ]] || cp -p "$ROOT/.flox/env/$file" "$RUN_DIR/$prefix.$file"
    done
    [[ ! -f $ROOT/.flox/env.json ]] || cp -p "$ROOT/.flox/env.json" "$RUN_DIR/$prefix.env.json"
}

start_run() {
    local kind=$1 parent version dirty
    RUN_DIR=${RUN_DIR:-$ROOT/seed-runs/$(date -u +%Y%m%dT%H%M%S)-$kind-$$}
    mkdir -p -- "$(dirname -- "$RUN_DIR")"
    parent=$(cd -- "$(dirname -- "$RUN_DIR")" && pwd)
    RUN_DIR=$parent/$(basename -- "$RUN_DIR")
    mkdir -- "$RUN_DIR" || die "Use a new run directory: $RUN_DIR"
    printf 'Run directory: %s\n' "$RUN_DIR"
    command_line flox --version
    version=$(flox --version)
    dirty=$(git -C "$ROOT" status --porcelain)
    if [[ -n $dirty ]]; then dirty=yes; else dirty=no; fi
    {
        printf 'start_utc\t%s\nflox_version\t%s\nhead\t%s\ndirty\t%s\ncatalog\t%s\n' \
            "$(date -u +%FT%TZ)" "$version" "$(git -C "$ROOT" rev-parse HEAD)" "$dirty" "$CATALOG"
        printf 'order'; printf '\t%s' "${ORDER[@]}"; printf '\n'
    } > "$RUN_DIR/run.tsv"
    printf 'package\tstep\texit_code\tseconds\tlog_file\n' > "$RUN_DIR/summary.tsv"
    capture_project initial
}

restore_lock() {
    rm -f -- "$ROOT/.flox/catalog.lock"
    [[ ! -e $RUN_DIR/original.catalog.lock && ! -L $RUN_DIR/original.catalog.lock ]] ||
        cp -a "$RUN_DIR/original.catalog.lock" "$ROOT/.flox/catalog.lock"
}
fresh_lock() {
    if [[ -e $ROOT/.flox/catalog.lock || -L $ROOT/.flox/catalog.lock ]]; then
        cp -a "$ROOT/.flox/catalog.lock" "$RUN_DIR/original.catalog.lock"
    fi
    trap restore_lock EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    rm -f -- "$ROOT/.flox/catalog.lock"
}

step() {
    local pkg=$1 name=$2 log=$3 started=$SECONDS code=0
    shift 3
    command_line flox "$@"
    if [[ $DRY_RUN == true ]]; then return; fi
    flox "$@" > "$log" 2>&1 || code=$?
    printf '%s\t%s\t%d\t%d\t%s\n' "$pkg" "$name" "$code" "$((SECONDS-started))" "$log" >> "$RUN_DIR/summary.tsv"
    capture_project "$pkg.$name"
    if ((code)); then
        printf 'FAILED: %s at %s (see %s)\n' "$pkg" "$name" "$log" >&2
        exit "$code"
    fi
}

publish_package() {
    local pkg=$1 prefix=$2
    if [[ -n ${DEPS[$pkg]} ]]; then
        step "$pkg" update-catalogs "$RUN_DIR/$prefix.update-catalogs.log" build update-catalogs
        if [[ $DRY_RUN == true ]]; then
            command_line cp .flox/catalog.lock "$RUN_DIR/$prefix.catalog.lock"
        elif ! cp .flox/catalog.lock "$RUN_DIR/$prefix.catalog.lock"; then
            die "FAILED: $pkg at capture-catalog-lock (see $RUN_DIR/$prefix.update-catalogs.log)"
        fi
    fi
    step "$pkg" build "$RUN_DIR/$prefix.build.log" build "$pkg"
    step "$pkg" publish "$RUN_DIR/$prefix.publish.log" publish -o "$CATALOG" "$pkg"
}

try_package() {
    local pkg=$1 version=${2:-} env_dir spec=$CATALOG/$1
    [[ -z $version ]] || spec+=@$version
    if [[ $DRY_RUN == true ]]; then
        env_dir=$RUN_DIR/install-$pkg.XXXXXX
        command_line mktemp -d "$env_dir"
        printf '(in %s)\n' "$env_dir"
        command_line flox init
        command_line flox install "$spec"
        command_line flox activate -- "$pkg"
        return
    fi
    env_dir=$(mktemp -d "$RUN_DIR/install-$pkg.XXXXXX")
    printf 'Environment: %s\n' "$env_dir"
    (
        cd -- "$env_dir" || exit
        step "$pkg" init "$RUN_DIR/install-$pkg.init.log" init
        step "$pkg" install "$RUN_DIR/install-$pkg.install.log" install "$spec"
        cp .flox/env/manifest.lock "$RUN_DIR/install-$pkg.manifest.lock"
        step "$pkg" activate "$RUN_DIR/install-$pkg.out" activate -- "$pkg"
        cat "$RUN_DIR/install-$pkg.out"
    )
}
