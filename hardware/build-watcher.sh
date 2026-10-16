#!/usr/bin/env bash
# Compile only. The Watcher's UART bridge is NOT its native USB port.
# Usage: hardware/build-watcher.sh [--hid-test]
# Optional NIMBLE_LIBRARIES points to a folder containing NimBLE-Arduino 2.5.x.
set -euo pipefail
cd "$(dirname "$0")"
DEFS="-DHID_OVER_BLE=1 -DWATCHER_BOARD=1 -DDEBUG_SERIAL=1"
OUTPUT=build-watcher
for arg in "$@"; do
  case "$arg" in
    --hid-test) DEFS+=" -DHID_TEST_ONLY=1"; OUTPUT=build-watcher-hid-test ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done
[[ $PWD != *" "* ]] || { echo "Build path must not contain spaces" >&2; exit 1; }
DEFS+=" -include $PWD/hid_bridge/nimble_cfg.h"
ARGS=(compile -b 'esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=default,FlashSize=32M,PSRAM=opi,PartitionScheme=default_8MB')
[[ -z ${NIMBLE_LIBRARIES:-} ]] || ARGS+=(--libraries "$NIMBLE_LIBRARIES")
ARGS+=(--build-property "compiler.cpp.extra_flags=$DEFS" --build-property "compiler.c.extra_flags=$DEFS")
arduino-cli "${ARGS[@]}" --output-dir "$OUTPUT" hid_bridge
