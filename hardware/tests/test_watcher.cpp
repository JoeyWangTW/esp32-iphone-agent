#include <assert.h>
#include <stdio.h>
#include <vector>
#include "../hid_bridge/watcher_controls.h"
#include "../hid_bridge/watcher_screen.h"

int main(int argc, char **argv) {
  WatcherButton b;
  assert(b.update(true, 5000) == WatcherButton::None); // held during boot
  b.update(false, 5010);
  assert(b.update(false, 5050) == WatcherButton::None);
  assert(b.armed);
  b.update(true, 5100); b.update(false, 5110); // contact bounce
  assert(b.update(false, 5160) == WatcherButton::None);
  b.update(true, 5200); b.update(true, 5240);
  b.update(false, 5340);
  assert(b.update(false, 5380) == WatcherButton::Click);
  b.update(true, 6000); b.update(true, 6040);
  assert(b.update(true, 10000) == WatcherButton::None); // held, not committed
  assert(b.holding(10000));
  b.update(false, 10010);
  assert(b.update(false, 10050) == WatcherButton::Power);
  assert(b.update(false, 10100) == WatcherButton::None); // once only
  b.update(true, 11000); b.update(true, 11040); b.lostInput();
  assert(b.update(true, 15000) == WatcherButton::None);
  b.update(false, 15010);
  assert(b.update(false, 15050) == WatcherButton::None); // input failure cannot power off
  b.update(true, UINT32_MAX - 1000); b.update(true, UINT32_MAX - 950);
  assert(b.holding(3000));
  b.update(false, 3010);
  assert(b.update(false, 3060) == WatcherButton::Power);

  for (char c : "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-:.")
    assert(strlen(WatcherScreen::glyph(c)) == 35);
  std::vector<uint16_t> image(412 * 412);
  WatcherScreen s(image.data());
  s.clear();
  s.text("WATCHER", 55, 4, 0xffff); s.text("PHONE AGENT", 94, 2, 0x7bef);
  s.text("BLUETOOTH READY", 143, 2, 0x07e0); s.text("WI-FI CONNECTED", 178, 2, 0x07e0);
  s.text("MIRROR RECEIVING", 213, 2, 0x07e0); s.text("BOARD CA05", 249, 2, 0x7bef);
  s.text("USB POWER", 280, 2, 0xffff); s.text("PRESS: SCREEN", 317, 2, 0x7bef);
  s.text("HOLD 3S: POWER", 340, 2, 0x7bef);
  if (argc > 1) {
    FILE *f = fopen(argv[1], "wb"); assert(f);
    fprintf(f, "P6\n412 412\n255\n");
    for (auto p : image) {
      p = uint16_t((p << 8) | (p >> 8));
      unsigned char rgb[] = {static_cast<unsigned char>((p >> 11) * 255 / 31),
        static_cast<unsigned char>(((p >> 5) & 63) * 255 / 63), static_cast<unsigned char>((p & 31) * 255 / 31)};
      fwrite(rgb, 1, 3, f);
    }
    fclose(f);
  }
  s.text("A VERY LONG LINE THAT MUST BE CLIPPED SAFELY", -10, 8, 0xffff);
  puts("Watcher button and framebuffer tests passed");
}
