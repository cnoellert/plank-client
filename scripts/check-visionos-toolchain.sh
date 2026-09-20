#!/usr/bin/env bash
set -u

failures=0

pass() {
    printf 'PASS  %s\n' "$1"
}

fail() {
    printf 'FAIL  %s\n' "$1"
    failures=$((failures + 1))
}

check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        pass "$1: $(command -v "$1")"
    else
        fail "$1 is not installed"
    fi
}

printf 'PLANK visionOS toolchain preflight\n\n'

developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ "$developer_dir" == */Contents/Developer ]]; then
    pass "full Xcode selected: $developer_dir"
else
    fail "full Xcode is not selected (current path: ${developer_dir:-none})"
fi

check_command xcodebuild
check_command xcrun
check_command cmake
check_command ninja
check_command cargo
check_command rustup

for sdk in xros xrsimulator; do
    if sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null)"; then
        pass "$sdk SDK: $sdk_path"
    else
        fail "$sdk SDK is unavailable"
    fi
done

qt_host="${PLANK_QT_HOST_PATH:-}"
if [[ -n "$qt_host" && -x "$qt_host/bin/qmake" ]]; then
    pass "host Qt: $qt_host"
else
    fail "PLANK_QT_HOST_PATH must contain a host Qt build with bin/qmake"
fi

qt_visionos="${PLANK_QT_VISIONOS_PATH:-}"
if [[ -n "$qt_visionos" && -x "$qt_visionos/bin/qmake" ]]; then
    pass "visionOS Qt: $qt_visionos"
else
    fail "PLANK_QT_VISIONOS_PATH must contain a visionOS Qt build with bin/qmake"
fi

deps="${PLANK_VISIONOS_DEPS:-}"
if [[ -n "$deps" && -f "$deps/include/SDL3/SDL.h" ]]; then
    pass "visionOS dependencies: $deps"
else
    fail "PLANK_VISIONOS_DEPS must contain target-built SDL3 and codec dependencies"
fi

rust_target="${PLANK_RUST_TARGET:-}"
case "$rust_target" in
    aarch64-apple-visionos|aarch64-apple-visionos-sim)
        if rustup target list --installed 2>/dev/null | grep -Fxq "$rust_target"; then
            pass "Rust target installed: $rust_target"
        else
            fail "Rust target is selected but not installed: $rust_target"
        fi
        ;;
    *)
        fail "PLANK_RUST_TARGET must be aarch64-apple-visionos or aarch64-apple-visionos-sim"
        ;;
esac

printf '\n'
if (( failures > 0 )); then
    printf '%d requirement(s) missing.\n' "$failures"
    exit 1
fi

printf 'Toolchain is ready for a visionOS configure attempt.\n'
