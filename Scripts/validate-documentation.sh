#!/usr/bin/env bash

# Validates the DocC documentation catalogs that ship with the package.
#
# The check emits public symbol graphs for the package targets, converts each documentation
# catalog with DocC while treating warnings as errors, and verifies that every guide topic and
# catalog landing page required by the 1.0 specification is present in the shipped catalogs.
#
# Usage: Scripts/validate-documentation.sh
set -euo pipefail

readonly script_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
readonly repository_root=$(cd -- "$script_directory/.." && pwd -P)

temporary_root=""
symbol_graph_directory=""
cleanup() {
    if [[ -n "$temporary_root" && -d "$temporary_root" ]]; then
        rm -rf "$temporary_root"
    fi
}
trap cleanup EXIT

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-networking-documentation.XXXXXX")

# Guide topics required by the 1.0 specification, quoted as repository-relative paths.
readonly required_topics=(
    "Sources/Networking/Networking.docc/GettingStarted.md"
    "Sources/Networking/Networking.docc/EndpointAndRequest.md"
    "Sources/Networking/Networking.docc/BodyAndQueryEncoding.md"
    "Sources/Networking/Networking.docc/Authentication.md"
    "Sources/Networking/Networking.docc/Retries.md"
    "Sources/Networking/Networking.docc/Validation.md"
    "Sources/Networking/Networking.docc/Redirects.md"
    "Sources/Networking/Networking.docc/Uploads.md"
    "Sources/Networking/Networking.docc/Downloads.md"
    "Sources/Networking/Networking.docc/ProgressAndCancellation.md"
    "Sources/Networking/Networking.docc/ObservabilityAndLogging.md"
    "Sources/Networking/Networking.docc/CombineBridges.md"
    "Sources/NetworkingTestSupport/NetworkingTestSupport.docc/TestSupport.md"
)

# Catalog landing pages for each product documentation catalog.
readonly required_landing_pages=(
    "Sources/Networking/Networking.docc/Networking.md"
    "Sources/NetworkingTestSupport/NetworkingTestSupport.docc/NetworkingTestSupport.md"
)

fail() {
    printf 'validate-documentation: %s\n' "$1" >&2
    exit 1
}

cd "$repository_root"

for topic in "${required_topics[@]}"; do
    [[ -f "$topic" ]] || fail "required guide topic is missing: $topic"
done

for page in "${required_landing_pages[@]}"; do
    [[ -f "$page" ]] || fail "required landing page is missing: $page"
done

printf '%s\n' "Building public symbol graphs."
# The scratch path keeps build intermediates and emitted symbol graphs inside the
# temporary directory, so the checkout is never an output location for this script.
symbol_graph_output=$(swift package --scratch-path "$temporary_root/.scratch" \
    dump-symbol-graph --minimum-access-level public 2>&1)
symbol_graph_directory=$(printf '%s\n' "$symbol_graph_output" | sed -n 's/^Files written to //p' | tail -n 1)
if [[ -z "$symbol_graph_directory" || ! -d "$symbol_graph_directory" ]]; then
    fail "could not locate the symbol graph output directory"
fi

# Each DocC conversion covers exactly one module, so a catalog receives only the symbol graphs that
# belong to its own module. Extension-block graphs for the module share the module name prefix.
validate_catalog() {
    local module=$1
    local catalog=$2
    local isolated_directory="$temporary_root/$module-symbols"
    local output_directory="$temporary_root/$module-documentation"
    local graph

    mkdir -p "$isolated_directory"
    shopt -s nullglob
    for graph in "$symbol_graph_directory/$module.symbols.json" "$symbol_graph_directory/$module"@*.symbols.json; do
        cp "$graph" "$isolated_directory/"
    done
    shopt -u nullglob

    [[ -f "$isolated_directory/$module.symbols.json" ]] || fail "symbol graph for $module is missing"

    printf '%s\n' "Converting $module documentation."
    xcrun docc convert "$catalog" \
        --additional-symbol-graph-dir "$isolated_directory" \
        --output-dir "$output_directory" \
        --fallback-display-name "$module" \
        --warnings-as-errors
}

validate_catalog Networking Sources/Networking/Networking.docc
validate_catalog NetworkingTestSupport Sources/NetworkingTestSupport/NetworkingTestSupport.docc

printf '%s\n' "Documentation validation passed for both catalogs."
