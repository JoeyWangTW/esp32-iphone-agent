# SenseCAP Watcher bring-up findings

## USB check (2026-10-16)

The connected device enumerated on macOS as **USB Dual_Serial**, vendor `0x1a86`, product `0x55d2`, with two `cu.usbmodem` interfaces. This establishes a dual serial bridge, not native ESP32 USB HID. No reset, erase, or firmware upload was performed.

Seeed's v1.0 schematic confirms the distinction:

- Sheet 4, **Power IN & Charger**: the programming USB connector routes `USB_UD+/-` into a USB-to-TTL bridge, which exposes separate ESP32 and Himax UARTs. The other USB connector is power only.
- Sheet 10, **Port & IO Exp & RTC**: connector **J2** exposes `ESP_GPIO19/USB_DM` at pin **4**, and `ESP_GPIO20/USB_DP` at pin **5**. Ground is at pins **1** and **8**. Pin **7** is the fused 5 V rail; pin **2** is 3.3 V. These are schematic pin numbers, not a verified physical orientation on the user's unit.

Source: [Seeed SenseCAP Watcher v1.0 schematic](https://github.com/Seeed-Studio/OSHW-SenseCAP-Watcher/blob/main/Hardware/SenseCAP_Watcher_v1.0_SCH.pdf), [hardware overview](https://wiki.seeedstudio.com/watcher_hardware_overview/).

## Next hardware step

Use a suitable USB breakout/adapter to reach native USB D-/D+ and ground at J2, after physically verifying pin 1/orientation and the unit's board revision. USB-C device attachment needs the appropriate connector/CC configuration. Verify the power arrangement before connecting the iPhone; do not directly connect 5 V to the 3.3 V pin or tie two power sources together. The schematic proves a possible signal path, not a tested cable or confirmed iPhone enumeration.

Alternatively, validate the iPhone application first with the upstream-supported XIAO ESP32-S3 (native USB and PSRAM), while retaining the Watcher for the later custom port.

## Before firmware upload

1. Identify which UART is the ESP32; do not assume the first macOS port is correct or flash the Himax port.
2. Read chip/flash information and back up the complete factory flash, including device provisioning data. Keep backups out of Git.
3. Test a minimal HID enumeration firmware through the native USB connection before bringing up AirPlay/BLE.
4. Port the Watcher power-latch/expander initialization and correct flash/PSRAM settings. Upstream defaults to an 8 MB board; Seeed specifies 32 MB flash and 8 MB PSRAM for Watcher.
5. Verify board power, USB identity, recovery path, then AirPlay/BLE throughput. Only then add display, wheel, microphone, and the result protocol.

Do **not** run upstream `hardware/flash.sh` against an automatically selected Watcher port. Its automatic port selection and XIAO-oriented configuration are not a Watcher port. No Watcher-specific flash command is provided until the UART, native-USB wiring, power initialization, and backup are verified.
