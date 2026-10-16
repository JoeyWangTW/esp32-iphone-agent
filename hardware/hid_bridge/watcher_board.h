#pragma once
#include <Arduino.h>
#if WATCHER_BOARD
bool watcher_begin();
void watcher_poll();
void watcher_prepare_sleep(); // bridge releases HID and stops the app
String watcher_status();
#endif
