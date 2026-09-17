#!/bin/bash

# Precompile MTTransitions Metal shaders for Swift Package Manager.
#
# The generated default.metallib is copied into the SwiftPM resource bundle by
# Package.swift, which preserves the enclosing Shaders directory. MTTransition
# looks it up as Shaders/default.metallib in Bundle.module, so the output
# directory and file name below are a contract with Source/MTTransition.swift.
#
# Re-run this script whenever a .metal file under Source/Transitions changes;
# the resulting library is checked into the repository.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METAL_SOURCE_DIR="$SCRIPT_DIR/Source/Transitions"
OUTPUT_DIR="$SCRIPT_DIR/Source/Resources/Shaders"
IOS_MIN_VERSION="${IOS_MIN_VERSION:-16.0}"
METAL_STANDARD="${METAL_STANDARD:-ios-metal2.4}"

METAL_TOOLCHAIN_IDENTIFIER="${METAL_TOOLCHAIN_IDENTIFIER:-$(
    xcodebuild -showComponent MetalToolchain 2>/dev/null \
        | sed -n 's/^Toolchain Identifier: //p' \
        | head -1 \
        || true
)}"

run_xcrun() {
    local sdk="$1"
    shift
    TOOLCHAINS="$METAL_TOOLCHAIN_IDENTIFIER" xcrun -sdk "$sdk" "$@"
}

find_metalpetal_shader_dir() {
    local candidate

    for candidate in \
        "$SCRIPT_DIR/Pods/MetalPetal/Frameworks/MetalPetal/Shaders" \
        "$SCRIPT_DIR/.build/checkouts/MetalPetal/Frameworks/MetalPetal/Shaders"; do
        if [[ -f "$candidate/MTIShaderLib.h" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

if ! METALPETAL_SHADER_DIR="$(find_metalpetal_shader_dir)"; then
    echo "error: MTIShaderLib.h was not found." >&2
    echo "Run 'pod install' or 'swift package resolve', then try again." >&2
    exit 1
fi

if [[ -z "$METAL_TOOLCHAIN_IDENTIFIER" ]] || ! run_xcrun iphonesimulator metal --version >/dev/null 2>&1; then
    echo "error: The Metal toolchain is not installed." >&2
    echo "Install it with: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/default.metallib"

metal_files=()
while IFS= read -r metal_file; do
    metal_files+=("$metal_file")
done < <(find "$METAL_SOURCE_DIR" -type f -name '*.metal' -print | LC_ALL=C sort)

if [[ ${#metal_files[@]} -eq 0 ]]; then
    echo "error: No Metal sources found in $METAL_SOURCE_DIR" >&2
    exit 1
fi

compile_library() (
    local sdk="$1"
    local target="$2"
    local output_file="$3"
    local temp_dir
    local metal_file
    local base_name
    local air_file
    local air_files=()

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mttransitions-metal.XXXXXX")"
    trap 'rm -rf "$temp_dir"' EXIT

    for metal_file in "${metal_files[@]}"; do
        base_name="$(basename "$metal_file" .metal)"
        air_file="$temp_dir/$base_name.air"

        echo "Compiling $base_name.metal for $sdk"
        run_xcrun "$sdk" metal \
            -c \
            -target "$target" \
            -std="$METAL_STANDARD" \
            -I "$METAL_SOURCE_DIR" \
            -I "$METALPETAL_SHADER_DIR" \
            "$metal_file" \
            -o "$air_file"

        air_files+=("$air_file")
    done

    echo "Linking ${#air_files[@]} shaders into $(basename "$output_file")"
    run_xcrun "$sdk" metallib -o "$output_file" "${air_files[@]}"
)

compile_library \
    iphonesimulator \
    "air64-apple-ios${IOS_MIN_VERSION}-simulator" \
    "$OUTPUT_DIR/default.metallib"

echo "Generated Metal libraries in $OUTPUT_DIR"
