# Agente rpimon para Raspberry Pi
#
#   make                      compila nativo (en la propia RPi o con un toolchain cruzado en CXX)
#   make STATIC=1             binario estático (recomendado para un SO custom sin libstdc++)
#   make CXX=aarch64-linux-gnu-g++ STATIC=1     cross-compile 64 bits
#   make CXX=arm-linux-gnueabihf-g++ STATIC=1   cross-compile 32 bits (armv7)
#   make docker-arm64 | make docker-armv7       cross-compile usando Docker (qemu/binfmt)

CXX      ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall -Wextra
LDFLAGS  ?=
ifeq ($(STATIC),1)
  LDFLAGS += -static
endif
TARGET   = rpimon
SRC      = src/rpimon.cpp
PREFIX  ?= /usr/local

all: $(TARGET)

$(TARGET): $(SRC)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS)
	@echo "binario: $@ ($$(stat -c %s $@ 2>/dev/null || stat -f %z $@) bytes)"

strip: $(TARGET)
	$(STRIP) $(TARGET) 2>/dev/null || strip $(TARGET)

# Compilación en Docker con Alpine (musl): binario 100% estático, sin dependencia de glibc/NSS.
DOCKER_BUILD = apk add --no-cache -q build-base >/dev/null && make STATIC=1 && strip rpimon
docker-arm64:
	docker run --rm --platform linux/arm64 -v "$(CURDIR)":/src -w /src alpine:3.20 \
	  sh -c '$(DOCKER_BUILD) && mv rpimon rpimon-arm64'
	@echo "listo: rpimon-arm64"

docker-armv7:
	docker run --rm --platform linux/arm/v7 -v "$(CURDIR)":/src -w /src alpine:3.20 \
	  sh -c '$(DOCKER_BUILD) && mv rpimon rpimon-armv7'
	@echo "listo: rpimon-armv7"

# Alternativa con glibc (gcc:13). Con -static, getaddrinfo necesita las libs NSS de glibc en
# la RPi para resolver nombres; con IPs funciona igual.
docker-arm64-glibc:
	docker run --rm --platform linux/arm64 -v "$(CURDIR)":/src -w /src gcc:13 \
	  sh -c 'make STATIC=1 && strip rpimon && mv rpimon rpimon-arm64'

install: $(TARGET)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/$(TARGET)
	@test -f $(DESTDIR)/etc/rpimon.conf || install -m 600 rpimon.conf.example $(DESTDIR)/etc/rpimon.conf

clean:
	rm -f $(TARGET) rpimon-arm64 rpimon-armv7

.PHONY: all strip docker-arm64 docker-armv7 docker-arm64-glibc install clean
