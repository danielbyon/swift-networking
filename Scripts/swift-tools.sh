#!/usr/bin/env bash
set -euo pipefail

readonly script_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
readonly repository_root=$(cd -- "$script_directory/.." && pwd -P)
readonly lock_file="$script_directory/swift-tools.lock"
readonly default_repository_url="https://github.com/danielbyon/swift-tooling"
cleanup_root=''

die() {
    printf 'swift-tools: %s\n' "$1" >&2
    exit 1
}

cleanup_exit() {
    if [[ -n "$cleanup_root" ]]; then
        rm -rf "$cleanup_root"
        cleanup_root=''
    fi
}

trap cleanup_exit EXIT

# Keep this validator aligned with the standalone setup asset before extraction.
validate_release_archive() {
    local archive=$1
    local member listing entry_type
    local member_list detail_list

    member_list=$(mktemp "${TMPDIR:-/tmp}/swift-tooling-tar-members.XXXXXX")
    detail_list=$(mktemp "${TMPDIR:-/tmp}/swift-tooling-tar-details.XXXXXX")
    if ! tar -tzf "$archive" > "$member_list" || ! tar -tvzf "$archive" > "$detail_list"; then
        rm -f "$member_list" "$detail_list"
        die "could not inspect release archive: $archive"
    fi

    while IFS= read -r member; do
        case "$member" in
            ''|./) continue ;;
            /*|../*|*/../*|*/..|..)
                rm -f "$member_list" "$detail_list"
                die "release archive contains an unsafe path: $member"
                ;;
        esac
    done < "$member_list"

    while IFS= read -r listing; do
        entry_type=${listing:0:1}
        case "$entry_type" in
            -|d) ;;
            *)
                rm -f "$member_list" "$detail_list"
                die 'release archive contains a symlink, hard link, or special file'
                ;;
        esac
    done < "$detail_list"

    rm -f "$member_list" "$detail_list"
}

lock_value() {
    local key=$1
    awk -F= -v expected_key="$key" '$1 == expected_key { print substr($0, index($0, "=") + 1); exit }' "$lock_file"
}

manifest_value() {
    local key=$1
    local file=$2
    awk -F= -v expected_key="$key" '$1 == expected_key { print substr($0, index($0, "=") + 1); exit }' "$file"
}

[[ -f "$lock_file" ]] || die "lock file is missing: $lock_file"

release_version=$(lock_value SWIFT_TOOLING_RELEASE_VERSION)
release_sha256=$(lock_value SWIFT_TOOLING_RELEASE_SHA256)
release_asset=$(lock_value SWIFT_TOOLING_RELEASE_ASSET)
release_repository_url=$(lock_value SWIFT_TOOLING_REPOSITORY_URL)
release_repository_url=${release_repository_url:-$default_repository_url}
release_asset=${release_asset:-swift-tooling.tar.gz}

[[ -n "$release_version" ]] || die 'lock file must define SWIFT_TOOLING_RELEASE_VERSION'
[[ -n "$release_sha256" ]] || die 'lock file must define SWIFT_TOOLING_RELEASE_SHA256'
[[ "$release_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "release version must look like vMAJOR.MINOR.PATCH: $release_version"

release_root="${SWIFT_TOOLING_RELEASE_ROOT:-$repository_root/.tools/swift-tooling/$release_version}"

release_contents_match() {
    local archive=$1
    local root=$2
    local manifest_file
    local member relative current_sha archive_sha actual_file

    manifest_file=$(mktemp "${TMPDIR:-/tmp}/swift-tooling-manifest.XXXXXX")
    if ! tar -tzf "$archive" > "$manifest_file"; then
        rm -f "$manifest_file"
        return 1
    fi

    while IFS= read -r member; do
        case "$member" in
            ''|*/|./) continue ;;
        esac
        relative=${member#./}
        actual_file="$root/$relative"
        [[ -f "$actual_file" && ! -L "$actual_file" ]] || {
            rm -f "$manifest_file"
            return 1
        }
        if ! archive_sha=$(tar -xOf "$archive" "$member" | shasum -a 256 | awk '{print $1}'); then
            rm -f "$manifest_file"
            return 1
        fi
        current_sha=$(shasum -a 256 "$actual_file" | awk '{print $1}')
        if [[ "$archive_sha" != "$current_sha" ]]; then
            rm -f "$manifest_file"
            return 1
        fi
    done < "$manifest_file"

    while IFS= read -r -d '' actual_file; do
        relative=${actual_file#"$root"/}
        [[ "$relative" = .swift-tooling-release.tar.gz ]] && continue
        if ! grep -Fqx -- "./$relative" "$manifest_file" && ! grep -Fqx -- "$relative" "$manifest_file"; then
            rm -f "$manifest_file"
            return 1
        fi
    done < <(find "$root" -type f -print0)

    while IFS= read -r -d '' actual_file; do
        relative=${actual_file#"$root"/}
        [[ "$relative" = .swift-tooling-release.tar.gz ]] && continue
        rm -f "$manifest_file"
        return 1
    done < <(find "$root" ! -type f ! -type d -print0)

    rm -f "$manifest_file"
}

ensure_release() {
    local archive=${SWIFT_TOOLING_RELEASE_ARCHIVE:-}
    local cached_archive="$release_root/.swift-tooling-release.tar.gz"
    local archive_is_cached=0
    local archive_sha256
    local temporary_root
    local temporary_archive
    local archive_url

    if [[ -z "${SWIFT_TOOLING_RELEASE_ARCHIVE:-}" && -f "$cached_archive" ]]; then
        archive="$cached_archive"
        archive_is_cached=1
    fi

    if [[ -n "$archive" ]]; then
        [[ -f "$archive" ]] || die "release archive does not exist: $archive"
        archive_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
        if [[ "$archive_sha256" != "$release_sha256" ]]; then
            if [[ "$archive_is_cached" -eq 1 ]]; then
                archive=''
            else
                die 'shared release checksum mismatch'
            fi
        else
            validate_release_archive "$archive"
            if [[ -x "$release_root/bin/swift-tooling" ]] \
                && release_contents_match "$archive" "$release_root"; then
                return
            fi
        fi
    fi

    temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-tooling-consumer.XXXXXX")
    temporary_archive="$temporary_root/release.tar.gz"
    cleanup_root="$temporary_root"

    if [[ -n "$archive" ]]; then
        cp "$archive" "$temporary_archive"
    else
        archive_url="$release_repository_url/releases/download/$release_version/$release_asset"
        curl --fail --location --silent --show-error "$archive_url" --output "$temporary_archive"
    fi

    [[ -f "$temporary_archive" ]] || die 'shared release archive does not exist'
    [[ "$(shasum -a 256 "$temporary_archive" | awk '{print $1}')" = "$release_sha256" ]] \
        || die 'shared release checksum mismatch'

    local extracted_root="$temporary_root/release"
    mkdir -p "$extracted_root"
    validate_release_archive "$temporary_archive"
    tar -xzf "$temporary_archive" -C "$extracted_root"
    [[ -x "$extracted_root/bin/swift-tooling" ]] || die 'shared release is missing bin/swift-tooling'
    [[ -f "$extracted_root/Scripts/setup-swift-tools.sh" ]] \
        || die 'shared release is missing Scripts/setup-swift-tools.sh'

    mkdir -p "$(dirname "$release_root")"
    if [[ -e "$release_root" ]]; then
        rm -rf "$release_root"
    fi
    mv "$extracted_root" "$release_root"
    cp "$temporary_archive" "$release_root/.swift-tooling-release.tar.gz"
    cleanup_exit
}

update_release() {
    local temporary_root
    local manifest_file
    local archive_file
    local latest_version
    local latest_sha256
    local latest_asset

    temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-tooling-update.XXXXXX")
    manifest_file="$temporary_root/release-manifest.env"
    archive_file="$temporary_root/release.tar.gz"
    cleanup_root="$temporary_root"

    curl --fail --location --silent --show-error \
        "$release_repository_url/releases/latest/download/release-manifest.env" \
        --output "$manifest_file"
    latest_version=$(manifest_value RELEASE_VERSION "$manifest_file")
    latest_sha256=$(manifest_value RELEASE_SHA256 "$manifest_file")
    latest_asset=$(manifest_value RELEASE_ASSET "$manifest_file")
    latest_asset=${latest_asset:-swift-tooling.tar.gz}
    [[ -n "$latest_version" ]] || die 'release manifest did not provide RELEASE_VERSION'
    [[ -n "$latest_sha256" ]] || die 'release manifest did not provide RELEASE_SHA256'
    [[ "$latest_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "release version must look like vMAJOR.MINOR.PATCH: $latest_version"

    curl --fail --location --silent --show-error \
        "$release_repository_url/releases/download/$latest_version/$latest_asset" \
        --output "$archive_file"
    bash "$release_root/Scripts/setup-swift-tools.sh" \
        --repository-root "$repository_root" \
        --repository-url "$release_repository_url" \
        --release-archive "$archive_file" \
        --release-version "$latest_version" \
        --release-sha256 "$latest_sha256" \
        --release-asset "$latest_asset"
    cleanup_exit
}

release_supports_configured() {
    "$release_root/bin/swift-tooling" --capabilities 2>/dev/null \
        | grep -Fxq 'configured-exec=1'
}

write_legacy_local_config() {
    local target=$1
    {
        printf 'SWIFT_TOOLS_ROOT=%q\n' "$SWIFT_TOOLS_ROOT"
        printf 'SWIFT_TOOLS_SOURCE_PATHS=('
        if [[ "${#SWIFT_TOOLS_SOURCE_PATHS[@]}" -gt 0 ]]; then
            printf '%q ' "${SWIFT_TOOLS_SOURCE_PATHS[@]}"
        fi
        printf ')\n'
        printf 'SWIFT_TOOLS_SWIFTFORMAT_CONFIG=%q\n' "$SWIFT_TOOLS_SWIFTFORMAT_CONFIG"
        printf 'SWIFT_TOOLS_SWIFTLINT_CONFIG=%q\n' "$SWIFT_TOOLS_SWIFTLINT_CONFIG"
        printf 'SWIFT_TOOLS_COMMAND_PREFIX=('
        if [[ "${#SWIFT_TOOLS_COMMAND_PREFIX[@]}" -gt 0 ]]; then
            printf '%q ' "${SWIFT_TOOLS_COMMAND_PREFIX[@]}"
        fi
        printf ')\n'
    } > "$target"
}

run_legacy_configured() {
    [[ "$#" -ge 1 ]] || die 'configured requires swiftformat or swiftlint'
    local tool=$1
    shift
    local temporary_root
    local generated_local_config
    local status=0
    temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-tooling-config.XXXXXX")
    cleanup_root="$temporary_root"
    generated_local_config="$temporary_root/swift-tools-local.sh"

    # Resolve the consumer configuration once. Legacy releases source the
    # generated declarative snapshot, so they retain source paths, overlays,
    # and command prefixes without evaluating consumer code a second time.
    SWIFT_TOOLS_ROOT="$repository_root"
    SWIFT_TOOLS_SOURCE_PATHS=()
    SWIFT_TOOLS_SWIFTFORMAT_CONFIG=''
    SWIFT_TOOLS_SWIFTLINT_CONFIG=''
    SWIFT_TOOLS_COMMAND_PREFIX=()
    if [[ -f "$repository_root/Scripts/swift-tools-local.sh" ]]; then
        # shellcheck source=/dev/null
        source "$repository_root/Scripts/swift-tools-local.sh"
    fi
    if [[ -n "$SWIFT_TOOLS_SWIFTFORMAT_CONFIG" \
        && "$SWIFT_TOOLS_SWIFTFORMAT_CONFIG" != /* ]]; then
        SWIFT_TOOLS_SWIFTFORMAT_CONFIG="$repository_root/$SWIFT_TOOLS_SWIFTFORMAT_CONFIG"
    fi
    if [[ -n "$SWIFT_TOOLS_SWIFTLINT_CONFIG" \
        && "$SWIFT_TOOLS_SWIFTLINT_CONFIG" != /* ]]; then
        SWIFT_TOOLS_SWIFTLINT_CONFIG="$repository_root/$SWIFT_TOOLS_SWIFTLINT_CONFIG"
    fi
    if [[ -n "$SWIFT_TOOLS_SWIFTFORMAT_CONFIG" ]]; then
        [[ -f "$SWIFT_TOOLS_SWIFTFORMAT_CONFIG" ]] \
            || die "SwiftFormat config is missing: $SWIFT_TOOLS_SWIFTFORMAT_CONFIG"
    fi
    if [[ -n "$SWIFT_TOOLS_SWIFTLINT_CONFIG" ]]; then
        [[ -f "$SWIFT_TOOLS_SWIFTLINT_CONFIG" ]] \
            || die "SwiftLint config is missing: $SWIFT_TOOLS_SWIFTLINT_CONFIG"
    fi
    write_legacy_local_config "$generated_local_config"

    case "$tool" in
        swiftlint)
            [[ "$#" -ge 1 ]] || die 'configured SwiftLint execution requires a subcommand'
            local subcommand=$1
            shift
            local args=(
                --root "$repository_root"
                --release-root "$release_root"
                --local-config "$generated_local_config"
                exec swiftlint "$subcommand"
                --config "$release_root/config/swiftlint.base.yml"
            )
            if [[ -n "$SWIFT_TOOLS_SWIFTLINT_CONFIG" ]]; then
                args+=(--config "$SWIFT_TOOLS_SWIFTLINT_CONFIG")
            fi
            args+=("$@")
            "$release_root/bin/swift-tooling" "${args[@]}" || status=$?
            cleanup_exit
            return "$status"
            ;;
        swiftformat)
            local effective_config
            effective_config="$temporary_root/swiftformat.effective"
            {
                cat "$release_root/config/swiftformat.base"
                if [[ -n "$SWIFT_TOOLS_SWIFTFORMAT_CONFIG" ]]; then
                    cat "$SWIFT_TOOLS_SWIFTFORMAT_CONFIG"
                fi
            } > "$effective_config"
            "$release_root/bin/swift-tooling" \
                --root "$repository_root" \
                --release-root "$release_root" \
                --local-config "$generated_local_config" \
                exec swiftformat --config "$effective_config" "$@" || status=$?
            cleanup_exit
            return "$status"
            ;;
        *)
            die "unsupported configured tool: $tool"
            ;;
    esac
}

case "${1:-}" in
    update)
        shift
        [[ "$#" -eq 0 ]] || die 'update does not accept positional arguments'
        ensure_release
        update_release
        ;;
    bootstrap|format|lint|exec)
        command=$1
        shift
        ensure_release
        exec "$release_root/bin/swift-tooling" \
            --root "$repository_root" \
            --release-root "$release_root" \
            --local-config "$repository_root/Scripts/swift-tools-local.sh" \
            "$command" "$@"
        ;;
    configured)
        shift
        ensure_release
        if release_supports_configured; then
            exec "$release_root/bin/swift-tooling" \
                --root "$repository_root" \
                --release-root "$release_root" \
                --local-config "$repository_root/Scripts/swift-tools-local.sh" \
                configured "$@"
        fi
        run_legacy_configured "$@"
        ;;
    help|--help|-h|'')
        cat <<'USAGE'
Usage: Scripts/swift-tools.sh <bootstrap|format|lint|configured|exec|update>

The release version and checksum are recorded in Scripts/swift-tools.lock.
Project-specific paths and wrapper settings live in Scripts/swift-tools-local.sh.
SwiftLint and SwiftFormat config paths are optional overlays; the shared release
baseline is used when a repository does not define one.
USAGE
        ;;
    *)
        die "unknown command: $1"
        ;;
esac
