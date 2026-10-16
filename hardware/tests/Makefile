# Host unit tests for the firmware's pure-C parts. Usage: make -C hardware/tests
SRC = ../hid_bridge/src
CFLAGS = -std=c11 -Wall -Wextra -g -fsanitize=address,undefined

all: test hid-descriptor watcher-controls

watcher-controls: test_watcher.cpp ../hid_bridge/watcher_controls.h ../hid_bridge/watcher_screen.h
	$(CXX) -std=c++17 -Wall -Wextra -g -fsanitize=address,undefined -o watcher_test test_watcher.cpp
	./watcher_test

hid-descriptor: test_hid_descriptor.cpp ../hid_bridge/hid_report_map.h
	$(CXX) -std=c++17 -Wall -Wextra -g -fsanitize=address,undefined -o hid_descriptor_test test_hid_descriptor.cpp
	./hid_descriptor_test

test: test_main.c $(SRC)/bplist/bplist.c $(SRC)/video/gop.c
	$(CC) $(CFLAGS) -o $@ $^
	./test

clean:
	rm -f test hid_descriptor_test watcher_test

.PHONY: all clean hid-descriptor watcher-controls
