#pragma once
#include <Arduino.h>
#if HID_OVER_BLE
#include <NimBLEDevice.h>
// Arduino key constants and the same US layout used by the USB build.
#include <USBHIDKeyboard.h>
#include <USBHIDMouse.h>
void ble_hid_begin(NimBLEServer *server);
void ble_hid_disconnected(uint16_t handle);
void ble_hid_poll();
bool ble_hid_ready();
void ble_hid_command_begin();
bool ble_hid_command_ok();
bool ble_hid_send(NimBLECharacteristic *report, uint16_t handle, const uint8_t *data, size_t size);

class BleMouse {
public:
  void begin() {}
  void move(int8_t x, int8_t y, int8_t wheel = 0, int8_t pan = 0);
  void press(uint8_t button);
  void release(uint8_t button);
};
class BleKeyboard {
public:
  void begin() {}
  size_t press(uint8_t key);
  void releaseAll();
  void print(const String &text);
};
class BleConsumer {
public:
  void begin() {}
  void press(uint16_t usage);
  void release();
};
#endif
