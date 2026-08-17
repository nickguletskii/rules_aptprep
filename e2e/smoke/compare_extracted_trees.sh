#!/usr/bin/env bash
set -euo pipefail

tar_root=$1
bazel_root=$2
tar_manifest=$3
bazel_manifest=$4

tree_manifest() {
    local root=$1
    local output=$2
    local relative full mode target digest inode hardlink_root kind
    declare -A hardlink_roots=()

    : >"$output"
    while IFS= read -r -d '' relative; do
        case "$relative" in
            BUILD.bazel|REPO.bazel|install_manifest.json)
                continue
                ;;
        esac

        full="$root/$relative"
        mode=$(stat -c '%a' -- "$full")
        if [[ -L "$full" ]]; then
            target=$(readlink -- "$full")
            printf 'symlink\t%q\t%s\t%q\n' "$relative" "$mode" "$target" >>"$output"
        elif [[ -d "$full" ]]; then
            printf 'directory\t%q\t%s\n' "$relative" "$mode" >>"$output"
        elif [[ -f "$full" ]]; then
            digest=$(sha256sum -- "$full")
            digest=${digest%% *}
            inode=$(stat -c '%d:%i' -- "$full")
            if [[ -n "${hardlink_roots[$inode]+present}" ]]; then
                hardlink_root=${hardlink_roots[$inode]}
            else
                hardlink_root=$relative
                hardlink_roots[$inode]=$relative
            fi
            printf 'file\t%q\t%s\t%s\t%q\n' "$relative" "$mode" "$digest" "$hardlink_root" >>"$output"
        else
            kind=$(stat -c '%F' -- "$full")
            printf 'other:%s\t%q\t%s\n' "$kind" "$relative" "$mode" >>"$output"
        fi
    done < <(find -P "$root" -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z)
}

tree_manifest "$tar_root" "$tar_manifest"
tree_manifest "$bazel_root" "$bazel_manifest"

if ! cmp -s "$tar_manifest" "$bazel_manifest"; then
    diff -u "$tar_manifest" "$bazel_manifest"
    exit 1
fi
