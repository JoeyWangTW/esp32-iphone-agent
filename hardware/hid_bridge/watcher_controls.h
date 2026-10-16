#pragma once
#include <stdint.h>

// Commit on release. Ignore a power-on press held across boot, and never infer
// a release after an I2C failure. Unsigned elapsed times handle millis() wrap.
struct WatcherButton {
  enum Event { None, Click, Power };
  bool raw = true, down = true, armed = false;
  uint32_t changed = 0, pressed = 0;
  Event update(bool value, uint32_t now) {
    if (value != raw) { raw = value; changed = now; }
    if (now - changed < 40) return None;
    if (!armed) { if (!value) { armed = true; down = false; } return None; }
    if (value == down) return None;
    down = value;
    if (down) { pressed = now; return None; }
    return now - pressed >= 3000 ? Power : Click;
  }
  bool holding(uint32_t now) const { return armed && down && now - pressed >= 3000; }
  void lostInput() { *this = WatcherButton(); }
};
