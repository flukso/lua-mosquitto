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

clean:
	$(RM) $(CMOD) $(OBJS)
