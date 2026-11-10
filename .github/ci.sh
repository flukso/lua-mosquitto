#!/bin/sh
# Install dependencies, build and run the test suite in an Alpine container.
# Usage: .github/ci.sh <lua5.1|lua5.2|lua5.3|lua5.4|lua5.5|luajit>
set -eu

lua=${1:-lua5.5}
case "$lua" in
luajit) modver=5.1 ;;  # luajit uses the Lua 5.1 modules
*) modver=${lua#lua} ;;
esac

apk add --no-cache build-base pkgconf make mosquitto mosquitto-clients mosquitto-dev openssl \
	lua-busted "$lua" "$lua-dev" "lua$modver-busted" "lua$modver-posix"

# /usr/bin/busted runs "lua", which may not be installed. Use the
# versioned runner, which re-executes itself with $lua.
make="make check LUA=$lua BUSTED=busted-$modver"

# mosquitto drops privileges when started as root and could then not
# read the generated certificates and password file
if [ "$(id -u)" = 0 ]; then
	adduser -D tester
	chown -R tester .
	exec su tester -c "$make"
fi
exec $make
