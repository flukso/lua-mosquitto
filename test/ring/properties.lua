local mosq  = require("mosquitto")

local MOSQ_ID            = "flukso_"
local MOSQ_CLEAN_SESSION = true
local MOSQ_HOST          = arg[1]
local MOSQ_PORT          = 1883
local MOSQ_KEEPALIVE     = 300
local MOSQ_MAX_READ      = 10 -- packets
local MOSQ_MAX_WRITE     = 10 -- packets

function dump(o)
	if type(o) == 'table' then
	   local s = '{ '
	   for k,v in pairs(o) do
		  if type(k) ~= 'number' then k = '"'..k..'"' end
		  s = s .. '['..k..'] = ' .. dump(v) .. ','
	   end
	   return s .. '} '
	else
	   return tostring(o)
	end
end

mosq.init()
local mqtt = mosq.new(MOSQ_ID, MOSQ_CLEAN_SESSION)

mqtt:option(mosq.OPT_PROTOCOL_VERSION, mosq.MQTT_PROTOCOL_V5);

while not mqtt:connect_bind_v5(MOSQ_HOST, MOSQ_PORT, MOSQ_KEEPALIVE, nil, conncect_props) do
	print("trying to connect to broker ...")
end

mqtt.ON_CONNECT_V5 = function(success, rc, rc_string, flags, properties)
	print("ON_CONNECT_V5", success, rc_string, flags, dump(properties)) 
	mqtt:subscribe_v5("v5")
end

mqtt.ON_CONNECT = function(success, rc, rc_string)
	print("ON_CONNECT", success, rc_string, flags) 
end

mqtt.ON_SUBSCRIBE_V5 = function(mid, properties, ...)
	print("ON_SUBSCRIBE_V5", mid, dump(properties)) 

	-- for reference
	os.execute([[mosquitto_pub \
			 -V 5 \
			 -t 'v5' \
			 -m 'message' \
			 -D publish user-property a testA \
			 -D publish payload-format-indicator 0 \
			 -D publish content-type text/json \
			 -D publish user-property b testB \
			 -D publish response-topic this/is/my/response/topic \
			 -D publish message-expiry-interval 255 \
			 ]])

	-- send own
	properties = {}
	properties["content-type"] = "text/json"
	properties["response-topic"] = "this/is/my/response/topic"
	properties["payload-format-indicator"] = 0
	properties["user-property"] = {a = "testA", b = "testB"}
	properties["message-expiry-interval"] = 255
	assert(mqtt:publish_v5("v5", "message", 0, false, properties))

	-- send without properties
	assert(mqtt:publish_v5("v5", "message", 0, false, nil))

	-- unsubscribe
	assert(mqtt:unsubscribe_v5("not-subscribed"))
	
	properties = {}
	properties["user-property"] = {a = "testA", b = "testB"}
	--assert(mqtt:disconnect_v5(140, properties))
end

mqtt.ON_UNSUBSCRIBE_V5 = function(mid, properties)
	print("ON_UNSUBSCRIBE_V5", mid, dump(properties)) 
end

mqtt.ON_DISCONNECT_V5 = function(succes, rc, rc_string, properties)
	print("ON_DISCONNECT_V5", succes, rc, rc_string, dump(properties)) 
end

mqtt.ON_MESSAGE_V5 = function(mid, topic, payload, qos, retain, properties)
	print("ON_MESSAGE_V5", topic, payload, dump(properties)) 
end

mqtt:loop_forever()

