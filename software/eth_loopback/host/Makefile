# Host-side Ethernet loopback test
#   macOS / Linux: needs libpcap; run with sudo
#   Windows: needs Npcap + the Npcap SDK; build in an MSYS2 MINGW64 shell with
#            make NPCAP_SDK=C:/path/to/npcap-sdk, run as Administrator
ifeq ($(OS),Windows_NT)
NPCAP_SDK ?= C:/npcap-sdk
TARGET = eth_loopback_test.exe
CFLAGS = -O2 -Wall -I$(NPCAP_SDK)/Include
LIBS   = -L$(NPCAP_SDK)/Lib/x64 -lwpcap -liphlpapi -lws2_32 -lpthread
else
TARGET = eth_loopback_test
CFLAGS = -O2 -Wall
LIBS   = -lpcap -lpthread
endif

$(TARGET): eth_loopback_test.c
	cc $(CFLAGS) -o $@ $< $(LIBS)

clean:
	rm -f eth_loopback_test eth_loopback_test.exe

.PHONY: clean
