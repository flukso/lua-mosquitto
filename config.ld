-- Config file for ldoc
project = "lua-mosquitto"
description = "Lua bindings to libmosquitto"
dir = "docs" -- for compatibility with github pages

-- allow links to upstream documentation
local upat = "http://mosquitto.org/api/files/mosquitto-h.html#%s"
custom_see_handler('^(mosquitto_[%w_]+)$',function(name)
    local url = upat:format(name)
    return name, url
end)
