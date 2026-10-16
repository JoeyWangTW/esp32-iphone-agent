#pragma once
#include <Arduino.h>
#if WATCHER_BOARD
#include <Wire.h>
// Seeed SenseCAP Watcher v1.0: PCA9535 at 0x21, system power hold on P10.
// Source: Seeed-Studio/SenseCAP-Watcher-Firmware, components/sensecap-watcher.
inline bool watcher_begin() {
  // Keep the unpowered LCD/touch bus low, matching Seeed's BSP.
  for (int pin : {39, 38, 7, 9, 1, 14, 13, 45, 8}) { pinMode(pin, OUTPUT); digitalWrite(pin, LOW); }
  if (!Wire.begin(47, 48, 400000)) return false;
  auto write16 = [](uint8_t reg, uint16_t value) {
    Wire.beginTransmission(0x21); Wire.write(reg);
    Wire.write(uint8_t(value)); Wire.write(uint8_t(value >> 8));
    return Wire.endTransmission() == 0;
  };
  // Set the latch before enabling outputs. Leave LCD, PA, AI and expansion power off.
  if (!write16(0x02, 1 << 10) || !write16(0x06, 0x20ff)) return false;
  delay(100);
  Serial.println("watcher: system power held; display/audio disabled for bring-up");
  return true;
}
#endif
