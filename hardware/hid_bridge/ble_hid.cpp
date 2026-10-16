#include "ble_hid.h"
#if HID_OVER_BLE
#include <NimBLEHIDDevice.h>
#include <atomic>
#include <esp_task_wdt.h>
#include <keyboardLayout/KeyboardLayout.h>

// Report IDs: 1 keyboard (8 bytes), 2 relative mouse (5 bytes), 3 consumer (2 bytes).
#include "hid_report_map.h"
static NimBLEServer *hidServer;
static NimBLECharacteristic *reports[3];
static std::atomic<int> host{-1};
static std::atomic<uint8_t> subscriptions{0};
static std::atomic<bool> resetNeeded{true};
// Report state belongs only to Arduino's loop task; callbacks only mark a reset.
static uint8_t keys[8], buttons;
static bool commandOK = true;

class ReportCallbacks : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic *c, NimBLEConnInfo &ci, uint16_t sub) override {
    int h = ci.getConnHandle(), expected = -1;
    if ((sub & 1) && !host.compare_exchange_strong(expected, h) && expected != h) return;
    if (host != h) return;
    for (int i = 0; i < 3; i++) if (reports[i] == c) {
      if (sub & 1) subscriptions.fetch_or(1 << i);
      else subscriptions.fetch_and(~(1 << i));
    }
    resetNeeded = true;
    Serial.printf("hid: subscriptions %u\n", subscriptions.load());
  }
};
static ReportCallbacks reportCallbacks;

void ble_hid_begin(NimBLEServer *server) {
  hidServer = server;
  auto *hid = new NimBLEHIDDevice(server);
  hid->setManufacturer("Watcher Agent prototype");
  // Prototype has no allocated product/vendor ID; do not impersonate another product.
  hid->setPnp(0x02, 0, 0, 0x0100);
  hid->setHidInfo(0, 0x02);
  hid->setReportMap(reportMap, sizeof(reportMap));
  for (int i = 0; i < 3; i++) {
    reports[i] = hid->getInputReport(i + 1);
    reports[i]->setCallbacks(&reportCallbacks);
  }
  hid->getOutputReport(1)->setValue(uint8_t(0));
}
void ble_hid_disconnected(uint16_t handle) {
  if (host != handle) return;
  host = -1;
  subscriptions = 0;
  resetNeeded = true;
}
static bool connected() {
  int h = host;
  // Connection handles are not zero-based peer-list indices (the iPhone used handle 1).
  return h >= 0 && hidServer && hidServer->getPeerInfoByHandle(h).isEncrypted();
}
static bool send(int index, const uint8_t *data, size_t size) {
  int h = host;
  bool ok = connected() && (subscriptions & (1 << index)) &&
            ble_hid_send(reports[index], h, data, size);
  if (!ok) commandOK = false;
  return ok;
}
void ble_hid_poll() {
  if (!resetNeeded || !connected() || (subscriptions & 3) != 3) return;
  // Clear held keys/buttons before accepting a command on a new/restored connection.
  resetNeeded = false;
  memset(keys, 0, sizeof(keys)); buttons = 0;
  uint8_t mouse[5] = {}, consumer[2] = {};
  bool ok = send(0, keys, sizeof(keys));
  ok = send(1, mouse, sizeof(mouse)) && ok;
  if (subscriptions & 4) ok = send(2, consumer, sizeof(consumer)) && ok;
  if (!ok) resetNeeded = true;
}
bool ble_hid_ready() { return connected() && (subscriptions & 3) == 3 && !resetNeeded; }
void ble_hid_command_begin() { commandOK = true; }
bool ble_hid_command_ok() { return commandOK; }
void BleMouse::move(int8_t x, int8_t y, int8_t wheel, int8_t pan) {
  uint8_t data[] = {buttons, uint8_t(x), uint8_t(y), uint8_t(wheel), uint8_t(pan)};
  send(1, data, sizeof(data));
}
void BleMouse::press(uint8_t button) { buttons |= button; move(0, 0); }
void BleMouse::release(uint8_t button) { buttons &= ~button; move(0, 0); }
size_t BleKeyboard::press(uint8_t key) {
  uint8_t usage = 0;
  if (key >= 0x88) usage = key - 0x88;
  else if (key >= 0x80) keys[0] |= 1 << (key - 0x80);
  else {
    uint8_t mapped = KeyboardLayout_en_US[key];
    if (!mapped) { commandOK = false; return 0; }
    if (mapped & 0x80) keys[0] |= 0x02;
    usage = mapped & 0x7f;
  }
  if (usage) {
    int i = 2;
    while (i < 8 && keys[i] && keys[i] != usage) i++;
    if (i == 8) { commandOK = false; return 0; }
    keys[i] = usage;
  }
  return send(0, keys, sizeof(keys)) ? 1 : 0;
}
void BleKeyboard::releaseAll() { memset(keys, 0, sizeof(keys)); send(0, keys, sizeof(keys)); }
void BleKeyboard::print(const String &text) {
  // Validate the whole string before emitting anything. This protocol supports US ASCII only.
  for (unsigned i = 0; i < text.length(); i++)
    if (uint8_t(text[i]) >= 128 || !KeyboardLayout_en_US[uint8_t(text[i])]) { commandOK = false; return; }
  for (unsigned i = 0; i < text.length() && commandOK; i++) {
    esp_task_wdt_reset();
    press(text[i]); delay(12); releaseAll(); delay(12);
  }
}
void BleConsumer::press(uint16_t usage) {
  uint8_t data[] = {uint8_t(usage), uint8_t(usage >> 8)};
  send(2, data, sizeof(data));
}
void BleConsumer::release() { press(0); }
#endif
