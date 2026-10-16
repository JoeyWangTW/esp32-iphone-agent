// Decode the actual report map: catches host/report length mismatches and missing relative axes.
#include <cassert>
#include <cstdio>
#include <map>
#include <vector>
#include "../hid_bridge/hid_report_map.h"
int main() {
  struct Field { unsigned page, usage, size, count, flags, offset; int minimum, maximum; };
  std::map<unsigned, unsigned> inputBits, outputBits;
  std::map<unsigned, std::vector<Field>> fields;
  unsigned report = 0, page = 0, size = 0, count = 0;
  int minimum = 0, maximum = 0;
  std::vector<unsigned> usages;
  unsigned collections = 0;
  for (size_t i = 0; i < sizeof(reportMap);) {
    unsigned prefix = reportMap[i++], length = prefix & 3;
    assert(prefix != 0xfe);
    if (length == 3) length = 4;
    assert(i + length <= sizeof(reportMap));
    unsigned value = 0;
    for (unsigned b = 0; b < length; b++) value |= unsigned(reportMap[i++]) << (8 * b);
    unsigned tag = prefix & 0xfc;
    switch (tag) {
      case 0x04: page = value; break;
      case 0x08: usages.push_back(value); break;
      case 0x14: minimum = length == 1 ? int(int8_t(value)) : int(int16_t(value)); break;
      case 0x24: maximum = minimum < 0 && length == 1 ? int(int8_t(value)) : int(value); break;
      case 0x74: size = value; break;
      case 0x84: report = value; assert(report >= 1 && report <= 3); break;
      case 0x94: count = value; break;
      case 0xa0: collections++; break;
      case 0xc0: assert(collections); collections--; break;
      case 0x80:
        for (unsigned n = 0; n < usages.size(); n++)
          fields[report].push_back({page, usages[n], size, count, value, inputBits[report] + n * size, minimum, maximum});
        inputBits[report] += size * count; break;
      case 0x90: outputBits[report] += size * count; break;
    }
    if ((prefix & 0x0c) == 0) usages.clear();
  }
  assert(collections == 0);
  assert(inputBits.size() == 3 && inputBits[1] == 64 && inputBits[2] == 40 && inputBits[3] == 16);
  assert(outputBits.size() == 1 && outputBits[1] == 8);
  bool x = false, y = false, wheel = false, pan = false;
  for (auto field : fields[2]) {
    if (field.page == 1 && field.usage >= 0x30) {
      assert(field.size == 8 && field.minimum == -127 && field.maximum == 127 && field.flags == 6);
      if (field.usage == 0x30) { assert(field.offset == 8); x = true; }
      if (field.usage == 0x31) { assert(field.offset == 16); y = true; }
      if (field.usage == 0x38) { assert(field.offset == 24); wheel = true; }
    }
    if (field.page == 0x0c && field.usage == 0x238) {
      assert(field.offset == 32 && field.size == 8 && field.flags == 6); pan = true;
    }
  }
  assert(x && y && wheel && pan);
  std::puts("HID keyboard, mouse and consumer descriptors passed");
}
