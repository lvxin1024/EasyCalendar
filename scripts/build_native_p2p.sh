#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${ROOT_DIR}/native/easycalendar_p2p"
OUTPUT_DIR_INPUT="${2:?output directory is required}"
case "${OUTPUT_DIR_INPUT}" in
  /*) OUTPUT_DIR="${OUTPUT_DIR_INPUT}" ;;
  *) OUTPUT_DIR="${ROOT_DIR}/${OUTPUT_DIR_INPUT}" ;;
esac

case "${1:?target is required}" in
  android)
    command -v cargo-ndk >/dev/null 2>&1 || {
      echo "cargo-ndk is required for Android native builds" >&2
      exit 1
    }
    rm -rf "${OUTPUT_DIR}"
    mkdir -p "${OUTPUT_DIR}"
    (
      cd "${CRATE_DIR}"
      cargo ndk \
        -t arm64-v8a \
        -t armeabi-v7a \
        -t x86_64 \
        -t x86 \
        -o "${OUTPUT_DIR}" \
        build --release \
        --target-dir "${ROOT_DIR}/target"
    )
    for abi in arm64-v8a armeabi-v7a x86_64 x86; do
      test -f "${OUTPUT_DIR}/${abi}/libeasycalendar_p2p.so"
    done
    ;;
  macos)
    command -v cargo >/dev/null 2>&1 || {
      echo "cargo is required for macOS native builds" >&2
      exit 1
    }
    command -v lipo >/dev/null 2>&1 || {
      echo "lipo is required for universal macOS native builds" >&2
      exit 1
    }
    rm -rf "${OUTPUT_DIR}"
    mkdir -p "${OUTPUT_DIR}"
    cargo build --release --manifest-path "${CRATE_DIR}/Cargo.toml" \
      --target-dir "${ROOT_DIR}/target" --target aarch64-apple-darwin
    cargo build --release --manifest-path "${CRATE_DIR}/Cargo.toml" \
      --target-dir "${ROOT_DIR}/target" --target x86_64-apple-darwin
    lipo -create \
      "${ROOT_DIR}/target/aarch64-apple-darwin/release/libeasycalendar_p2p.dylib" \
      "${ROOT_DIR}/target/x86_64-apple-darwin/release/libeasycalendar_p2p.dylib" \
      -output "${OUTPUT_DIR}/libeasycalendar_p2p.dylib"
    install_name_tool -id "@rpath/libeasycalendar_p2p.dylib" \
      "${OUTPUT_DIR}/libeasycalendar_p2p.dylib"
    ;;
  *)
    echo "usage: $0 <android|macos> <output-directory>" >&2
    exit 2
    ;;
esac
