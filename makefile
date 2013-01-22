LUAPATH = /usr/local/share/lua/5.1
LUACPATH = /usr/local/lib/lua/5.1
INCDIR = -I/usr/include/lua5.1
LIBDIR = -L/usr/lib
LUALIB = lua5.1

CMOD = mosquitto.so
OBJS = lua-mosquitto.o
LIBS = -l$(LUALIB) -lmosquitto
CSTD = -std=gnu99

WARN = -Wall -pedantic
CFLAGS = -fPIC $(CSTD) $(WARN) $(INCDIR)
LDFLAGS = -shared $(CSTD) $(LIBDIR)

$(CMOD): $(OBJS)
	$(CC) $(LDFLAGS) $(OBJS) $(LIBS) -o $@

.c.o:
	$(CC) -c $(CFLAGS) -o $@ $<

install:
	cp $(CMOD) $(LUACPATH)
clean:
	rm -f $(CMOD) $(OBJS)
