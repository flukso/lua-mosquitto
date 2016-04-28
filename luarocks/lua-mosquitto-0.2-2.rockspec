package = "lua-mosquitto"
version = "0.2-2"
source = {
	url = "git://github.com/flukso/lua-mosquitto",
	tag = "v0.2"
}
description = {
	summary = "Lua bindings to libmosquitto",
	detailed = [[
		Lua bindings to the libmosquitto client library.
		The parameters to all functions are as per libmosquitto's api
		only with sensible defaults for optional values, and return
		values directly rather than via pointers.
	]],
	homepage = "https://github.com/flukso/lua-mosquitto",
	license = "MIT"
}
dependencies = {
	"lua >= 5.1"
}
external_dependencies = {
	LIBMOSQUITTO = {
		header = "mosquitto.h"
	}
}
build = {
	type = "builtin",
	modules = {

		mosquitto = {
			sources = { "lua-mosquitto.c" },
			defines = {},
			libraries = { "mosquitto" },
			incdirs = { "$LIBMOSQUITTO_INCDIR" },
			libdirs = { "$LIBMOSQUITTO_LIBDIR" },
		}
	}
}

