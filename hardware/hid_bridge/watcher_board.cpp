#include "watcher_board.h"
#if WATCHER_BOARD
#include <Wire.h>
#include <WiFi.h>
#include <driver/rtc_io.h>
#include <driver/spi_master.h>
#include <esp_lcd_panel_ops.h>
#include <esp_lcd_io_spi.h>
#include <esp_sleep.h>
#include "src/spd2010/esp_lcd_spd2010.h"
#include "watcher_controls.h"
#include "watcher_screen.h"
#include "ble_link.h"
#include "ble_hid.h"
#include "netcfg.h"
#include "video_link.h"
#include "src/airplay/airplay.h"

// Seeed BSP: PCA9535 P10 system hold, P9 LCD, P15 battery ADC;
// P02 USB present (low), P03 wheel pressed (low), P13 battery present (low).
static uint16_t outputs = (1 << 10) | (1 << 15), inputs = 0xffff;
static bool inputOK, screenOn = true, displayOK;
static WatcherButton button;
static esp_lcd_panel_handle_t panel;
static esp_lcd_panel_io_handle_t io;
static SemaphoreHandle_t drawn;
static uint16_t *pixels, *stripe;
static uint32_t lastPoll, lastDraw;
static bool lastHold;
static RTC_DATA_ATTR bool standbyRequested;

static bool write16(uint8_t reg, uint16_t value) {
  Wire.beginTransmission(0x21); Wire.write(reg);
  Wire.write(uint8_t(value)); Wire.write(uint8_t(value >> 8));
  return Wire.endTransmission() == 0;
}
static bool readInputs() {
  Wire.beginTransmission(0x21); Wire.write(0);
  if (Wire.endTransmission(false) != 0 || Wire.requestFrom(uint8_t(0x21), uint8_t(2)) != 2) return false;
  inputs = Wire.read(); inputs |= uint16_t(Wire.read()) << 8;
  return true;
}
static bool usbPower() { return !inputOK || !(inputs & (1 << 2)); }

static bool IRAM_ATTR drawDone(esp_lcd_panel_io_handle_t, esp_lcd_panel_io_event_data_t *, void *) {
  BaseType_t woken = pdFALSE;
  xSemaphoreGiveFromISR(drawn, &woken);
  return woken == pdTRUE;
}

static bool displayBegin() {
  pixels = (uint16_t *)heap_caps_malloc(412 * 412 * 2, MALLOC_CAP_SPIRAM);
  stripe = (uint16_t *)heap_caps_malloc(412 * 8 * 2, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
  drawn = xSemaphoreCreateBinary();
  if (!pixels || !stripe || !drawn) return false;
  outputs |= 1 << 9;
  if (!write16(2, outputs)) return false;
  delay(100);
  spi_bus_config_t bus = {};
  bus.sclk_io_num = 7; bus.data0_io_num = 9; bus.data1_io_num = 1;
  bus.data2_io_num = 14; bus.data3_io_num = 13;
  bus.max_transfer_sz = 412 * 8 * 2;
  if (spi_bus_initialize(SPI3_HOST, &bus, SPI_DMA_CH_AUTO) != ESP_OK) return false;
  esp_lcd_panel_io_spi_config_t config = {};
  config.cs_gpio_num = 45; config.dc_gpio_num = -1; config.spi_mode = 3;
  config.pclk_hz = 40000000; config.trans_queue_depth = 1;
  config.lcd_cmd_bits = 32; config.lcd_param_bits = 8; config.flags.quad_mode = true;
  config.on_color_trans_done = drawDone;
  if (esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)SPI3_HOST, &config, &io) != ESP_OK) return false;
  spd2010_vendor_config_t vendor = {};
  vendor.flags.use_qspi_interface = true;
  esp_lcd_panel_dev_config_t device = {};
  device.reset_gpio_num = -1; device.rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB;
  device.bits_per_pixel = 16; device.vendor_config = &vendor;
  if (esp_lcd_new_panel_spd2010(io, &device, &panel) != ESP_OK ||
      esp_lcd_panel_reset(panel) != ESP_OK || esp_lcd_panel_init(panel) != ESP_OK ||
      esp_lcd_panel_mirror(panel, false, false) != ESP_OK ||
      esp_lcd_panel_disp_on_off(panel, true) != ESP_OK) return false;
  return true;
}

static bool flushScreen() {
  for (int y = 0; y < 412; y += 8) {
    int rows = min(8, 412 - y);
    memcpy(stripe, pixels + y * 412, 412 * rows * 2);
    if (esp_lcd_panel_draw_bitmap(panel, 0, y, 412, y + rows, stripe) != ESP_OK ||
        xSemaphoreTake(drawn, pdMS_TO_TICKS(500)) != pdTRUE) {
      Serial.println("watcher: LCD transfer failed; disabling display");
      digitalWrite(8, LOW);
      displayOK = false; // keep DMA memory alive; a late transfer may still own it
      return false;
    }
  }
  digitalWrite(8, screenOn ? HIGH : LOW);
  return true;
}

static void render(bool hold, const char *message = nullptr) {
  if (!displayOK) return;
  WatcherScreen canvas(pixels);
  canvas.clear();
  canvas.text("WATCHER", 55, 4, 0xFFFF);
  canvas.text("PHONE AGENT", 94, 2, 0x7BEF);
  if (message || hold) {
    canvas.text(message ? message : "RELEASE TO", 160, 3, 0xFD20);
    canvas.text(usbPower() ? "STANDBY" : "POWER OFF", 200, 3, 0xFFFF);
    canvas.text(usbPower() ? "PRESS WHEEL TO WAKE" : "HOLD WHEEL TO START", 270, 2, 0x7BEF);
  } else {
    bool hid = ble_hid_ready(), wifi = net_peers() > 0;
    VideoStats v = video_stats();
    bool video = airplay_state() == 2 && v.gop_bytes > 0;
    canvas.text(hid ? "BLUETOOTH READY" : "PAIR BLUETOOTH", 143, 2, hid ? 0x07E0 : 0xFD20);
    canvas.text(wifi ? "WI-FI CONNECTED" : "JOIN WI-FI", 178, 2, wifi ? 0x07E0 : 0xFD20);
    canvas.text(video ? "MIRROR RECEIVING" : "START MIRRORING", 213, 2, video ? 0x07E0 : 0xFD20);
    String network = "BOARD " + board_suffix(); network.toUpperCase();
    canvas.text(network.c_str(), 249, 2, 0x7BEF);
    char power[32];
    if (!inputOK) snprintf(power, sizeof power, "POWER UNKNOWN");
    else if (usbPower()) snprintf(power, sizeof power, "USB POWER");
    else if (inputs & (1 << 13)) snprintf(power, sizeof power, "NO BATTERY");
    else snprintf(power, sizeof power, "BAT %.2fV", analogReadMilliVolts(3) * 4.1 / 1000);
    canvas.text(power, 280, 2, 0xFFFF);
    canvas.text("PRESS: SCREEN", 317, 2, 0x7BEF);
    canvas.text("HOLD 3S: POWER", 340, 2, 0x7BEF);
  }
  flushScreen();
}

static void deepSleep() {
  readInputs(); // acknowledge PCA9535 interrupt before arming GPIO2 wake
  esp_sleep_enable_ext0_wakeup(GPIO_NUM_2, 0);
  rtc_gpio_pullup_en(GPIO_NUM_2);
  rtc_gpio_pulldown_dis(GPIO_NUM_2);
  Serial.flush();
  esp_deep_sleep_start();
}

static void sleepNow() {
  watcher_prepare_sleep();
  render(false, "GOING TO");
  delay(400);
  inputOK = readInputs();
  if (!inputOK) { button.lostInput(); Serial.println("watcher: power request cancelled; I2C error"); return; }
  bool usb = usbPower();
  Serial.printf("watcher: %s requested by wheel\n", usb ? "standby" : "battery power off");
  digitalWrite(8, LOW);
  rgbLedWrite(40, 0, 0, 0);
  if (!write16(2, usb ? (1 << 10) : 0)) { button.lostInput(); return; }
  standbyRequested = usb;
  // De-power the shared LCD/touch bus without feeding its rail through the pins.
  for (int pin : {39, 38, 7, 9, 1, 14, 13, 45, 8}) { pinMode(pin, OUTPUT); digitalWrite(pin, LOW); }
  deepSleep();
}

bool watcher_begin() {
  for (int pin : {39, 38, 7, 9, 1, 14, 13, 45, 8}) { pinMode(pin, OUTPUT); digitalWrite(pin, LOW); }
  if (!Wire.begin(47, 48, 400000)) return false;
  Wire.setTimeOut(20);
  // The expander also interrupts for charger changes. Stay asleep unless the
  // wheel was pressed; a charger transition must not undo deliberate standby.
  if (standbyRequested && esp_sleep_get_wakeup_cause() == ESP_SLEEP_WAKEUP_EXT0 &&
      readInputs() && (inputs & (1 << 3))) {
    if (inputs & (1 << 2)) write16(2, 0); // unplugged during standby: release battery latch
    deepSleep();
  }
  standbyRequested = false;
  if (!write16(2, outputs) || !write16(6, 0x20ff)) return false;
  inputOK = readInputs();
  analogSetPinAttenuation(3, ADC_2_5db);
  rgbLedWrite(40, 12, 5, 0);
  displayOK = displayBegin();
  if (!displayOK) { outputs &= ~(1 << 9); write16(2, outputs); }
  Serial.printf("watcher: status LCD %s; wheel controls ready\n", displayOK ? "ready" : "unavailable (LED fallback)");
  return true; // a display failure must not take the bridge offline
}

void watcher_poll() {
  uint32_t now = millis();
  if (now - lastPoll < 20) return;
  lastPoll = now;
  inputOK = readInputs();
  if (!inputOK) { button.lostInput(); return; }
  auto event = button.update(!(inputs & (1 << 3)), now);
  if (event == WatcherButton::Power) { sleepNow(); return; }
  if (event == WatcherButton::Click) {
    screenOn = !screenOn;
    digitalWrite(8, screenOn && displayOK ? HIGH : LOW);
    Serial.printf("watcher: screen %s\n", screenOn ? "on" : "off");
  }
  bool hold = button.holding(now);
  if (hold && !lastHold) { screenOn = true; Serial.println("watcher: release wheel to power down"); }
  if (now - lastDraw >= 1000 || hold != lastHold || event == WatcherButton::Click) {
    lastDraw = now;
    if (hold) rgbLedWrite(40, 18, 0, 0);
    else if (!ble_hid_ready()) rgbLedWrite(40, 12, 5, 0);
    else if (net_peers() > 0 && airplay_state() == 2 && video_stats().gop_bytes) rgbLedWrite(40, 0, 12, 0);
    else rgbLedWrite(40, 0, 3, 15);
    if (screenOn) render(hold);
  }
  lastHold = hold;
}

String watcher_status() {
  return String("ok lcd ") + (displayOK ? "ready" : "failed") + " screen " + (screenOn ? "on" : "off")
    + " power " + (inputOK ? (usbPower() ? "usb" : "battery") : "unknown")
    + " button " + (button.down ? "down" : "up");
}
#endif
