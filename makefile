PKGC ?= pkg-config

LUAPKG ?= lua lua5.1 lua5.2 lua5.3
# lua's package config can be under various names
LUAPKGC := $(shell for pc in $(LUAPKG); do \
		$(PKGC) --exists $$pc && echo $$pc && break; \
	done)

LUA_VERSION := $(shell $(PKGC) --variable=V $(LUAPKGC))
LUA_LIBDIR := $(shell $(PKGC) --variable=libdir $(LUAPKGC))
LUA_CFLAGS := $(shell $(PKGC) --cflags $(LUAPKGC))
LUA_LDFLAGS := $(shell $(PKGC) --libs-only-L $(LUAPKGC))

CMOD = mosquitto.so
OBJS = lua-mosquitto.o
LIBS = -lmosquitto
CSTD = -std=gnu99

OPT ?= -Os
WARN = -Wall -pedantic
CFLAGS += -fPIC $(CSTD) $(WARN) $(OPT) $(LUA_CFLAGS)
LDFLAGS += -shared $(CSTD) $(LIBS) $(LUA_LDFLAGS)

ifeq ($(OPENWRT_BUILD),1)
LUA_VERSION=
endif

ifeq ($(LUA_MOSQUITTO_COMPAT),yes)
CFLAGS += -DLUA_MOSQUITTO_COMPAT
endif

$(CMOD): $(OBJS)
	$(CC) $(LDFLAGS) $(OBJS) $(LIBS) -o $@

.c.o:
	$(CC) -c $(CFLAGS) -o $@ $<

install:
	mkdir -p $(DESTDIR)$(LUA_LIBDIR)/lua/$(LUA_VERSION)
	cp $(CMOD) $(DESTDIR)$(LUA_LIBDIR)/lua/$(LUA_VERSION)

docs: $(CMOD) config.ld
	ldoc .

clean:
	$(RM) -r $(CMOD) $(OBJS) docs .build

# Tests. The module is built separately for each Lua version under
# .build/ so it does not clash with the regular build.
LUA ?= lua5.5
LUA_VERSIONS ?= lua5.1 lua5.2 lua5.3 lua5.4 lua5.5 luajit
BUSTED ?= busted
# kill the run if something hangs instead of blocking forever
TEST_TIMEOUT ?= 120
TEST_BUILDDIR = .build/$(LUA)
# pkg-config name of the Lua used for the tests
TEST_LUAPKG ?= $(LUA)

$(TEST_BUILDDIR)/$(CMOD): lua-mosquitto.c compat.h
	mkdir -p $(TEST_BUILDDIR)
	$(CC) -fPIC $(CSTD) $(WARN) $(OPT) $(shell $(PKGC) --cflags $(TEST_LUAPKG)) \
		-shared lua-mosquitto.c $(LIBS) -o $@

check: $(TEST_BUILDDIR)/$(CMOD)
	timeout $(TEST_TIMEOUT) $(BUSTED) --lua=$(LUA) --cpath='./$(TEST_BUILDDIR)/?.so' $(BUSTED_ARGS)

check-all:
	set -e; for lua in $(LUA_VERSIONS); do \
		echo "=== $$lua"; \
		$(MAKE) --no-print-directory check LUA=$$lua; \
	done

.PHONY: install docs clean check check-all
