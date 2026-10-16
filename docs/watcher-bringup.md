# SenseCAP Watcher Bluetooth HID bring-up

The Watcher can use **Bluetooth mouse and keyboard reports**, alongside the app's existing BLE command/video service. It does not need a native-USB cable to the iPhone. The iOS companion still does screen decoding, OCR, model requests and ride comparison; HID alone cannot read another app's screen or recognize microphone audio.

## Connected hardware (2026-10-16)

- ESP32-S3 revision 0.2, 32 MiB flash, 8 MiB octal PSRAM.
- USB Dual_Serial bridge: VID `0x1a86`, PID `0x55d2`.
- The tested ESP32 UART was `/dev/cu.usbmodem5B142658573`; the other UART is for the Himax chip. Port names may change. Identify the ESP32 using `esptool flash-id` before an upload.
- Secure boot and flash encryption were read as **disabled**. No eFuses were changed.
- The user explicitly chose to skip the factory backup. Interrupted partial files are not recovery images.

Seeed's [v1.0 schematic](https://github.com/Seeed-Studio/OSHW-SenseCAP-Watcher/blob/main/Hardware/SenseCAP_Watcher_v1.0_SCH.pdf) routes the programming connector through a dual UART bridge. Native ESP32 USB is on expansion pins, but that wiring is unnecessary for this Bluetooth build.

## Firmware profiles

Requires Arduino ESP32 core 3.3.x and NimBLE-Arduino **2.5.1**. Both scripts force-include the required NimBLE buffer configuration.

```sh
arduino-cli lib install 'NimBLE-Arduino@2.5.1'
hardware/build-watcher.sh --hid-test  # output: hardware/build-watcher-hid-test
hardware/build-watcher.sh             # output: hardware/build-watcher
```

Set `NIMBLE_LIBRARIES=/path/to/library-parent` to use an isolated NimBLE installation. These commands compile only; they do not choose a serial port or flash a device.

Both profiles use UART serial, 32 MiB flash, octal PSRAM and an 8 MiB application partition layout. The remaining flash is not used. They initialize the Watcher's PCA9535 at address `0x21` (SDA 47, SCL 48) and hold system power on P10. Display, touch, audio amplifier, Himax and expansion power remain off. The power wiring follows Seeed's [board support package](https://github.com/Seeed-Studio/SenseCAP-Watcher-Firmware/tree/main/components/sensecap-watcher).

The pairing-test profile disables Wi-Fi and AirPlay at startup. The full profile starts the local Wi-Fi AP and AirPlay receiver. Neither profile implements Watcher microphone capture or display UI yet.

Do **not** run the upstream auto-selecting `hardware/flash.sh` on Watcher. Use an explicitly verified ESP32 UART. With `ESPTOOL` set to an esptool 5.1 executable and `ESP32_CORE` to the installed Arduino core directory, the pairing-test upload is:

```sh
"$ESPTOOL" --chip esp32s3 --port "$WATCHER_PORT" --baud 115200 \
  --before default-reset --after hard-reset write-flash -z \
  --flash-mode keep --flash-freq keep --flash-size keep \
  0x0 hardware/build-watcher-hid-test/hid_bridge.ino.bootloader.bin \
  0x8000 hardware/build-watcher-hid-test/hid_bridge.ino.partitions.bin \
  0xe000 "$ESP32_CORE/tools/partitions/boot_app0.bin" \
  0x10000 hardware/build-watcher-hid-test/hid_bridge.ino.bin
```

This replaces the factory bootloader, partition table and ESP32 application. It does not flash the separate Himax chip. Restoring the factory setup without a verified device backup requires the appropriate Seeed firmware and provisioning process; partial backup files are insufficient.

## Pairing and manual input checks

1. Power Watcher over USB. Its screen stays dark in this prototype.
2. On iPhone, enable **Settings → Accessibility → Touch → AssistiveTouch**. Under **Devices → Bluetooth Devices**, pair **Watcher Agent** followed by its four-character suffix.
3. Open **ESP32 Agent**, allow Bluetooth and connect to the same Watcher. The app's Mouse indicator becomes ready only when the encrypted keyboard and mouse report subscriptions are active.
4. For the initial test, use UART at 115200 baud to send `1 ping`. No mouse movements or typing happen automatically at boot or pairing.
5. With a harmless text field such as a new Notes note focused, send `2 type Watcher test`. With the pointer visible, send `3 move 20 0`, then `4 move -20 0`. Send `5 homescreen` only when intentionally testing Home navigation.
6. Check disconnect/reconnect and released keys/buttons before enabling screen mirroring or an agent run.

[Apple's AssistiveTouch pointer instructions](https://support.apple.com/en-us/111775) describe Bluetooth pointer pairing.

## Transport behavior

The Watcher advertises standard HID service `0x1812` and the existing app service. One central is allowed: iOS is expected to share its system HID and CoreBluetooth connection. Reports are encrypted and sent only to that central. Commands require an encrypted connection. USB builds keep their existing two-peer debug behavior.

Keyboard, mouse and consumer reports have independent report IDs. Reconnecting sends neutral reports before allowing commands. A failed queued HID notification disconnects the central to avoid leaving a held key/button. Video yields to HID while reports are sent. Notification success means accepted by the BLE host; physical execution still needs visual confirmation.

Status includes `hid` and `transport`; the app falls back to `usb` only for older firmware. The full screen-mirroring/video/HID concurrency path and live fare comparison require supervised device validation.

## Validation recorded on 2026-10-16

The pairing-test firmware was flashed to the connected Watcher; esptool verified the
written hashes. UART logs confirm the power latch, NimBLE-Arduino 2.5.1 startup and
an `ok` response to `ping`. The iOS companion was signed with the user's existing
Apple development team and installed/launched on the connected iPhone.

The full Watcher build and the original USB build compile locally with Arduino
ESP32 3.3.7 and NimBLE 2.5.1. Host tests validate keyboard/mouse/consumer report sizes,
signed relative axes, and the original bplist/video code. The user confirmed iPhone pairing and that `Watcher test` appeared in Notes. UART
confirmed an encrypted/bonded reconnect, all three HID subscriptions, and the iOS
app's command/status/video subscriptions on the same connection. The test exposed
and fixed a connection-handle lookup bug (NimBLE peer indices are not handles).
The user observed the small pointer after toggling AssistiveTouch's **Perform Touch
Gestures**, then confirmed leftward movement to the top-left edge and movement
back into view using three `move 100 100` commands. Keyboard typing and relative
pointer movement are visually confirmed. This observation does not establish that
the gesture toggle is required on every iPhone. Clicks and coordinate calibration
remain unverified.

After input verification, the full profile was rebuilt and installed by writing
only the application at `0x10000`; esptool verified its hash. Startup logs show
successful `_airplay` and `_raop` registration for **Watcher Agent**, about 105 KB
free internal heap, and about 3.37 MB free PSRAM. The firmware preserves NVS and
Bluetooth bonds. The companion's local signing profile lacks the hotspot
entitlement, so use its displayed network name/password to join manually if the
automatic Wi-Fi join fails.

Video streaming concurrency and live ride comparison remain unverified.
