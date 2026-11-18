-- Self-check for mqtt.lua: `lua5.1 test.lua`. Pure byte-level, no Control4 stubs.
dofile("mqtt.lua")

local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

-- ---- encoders ---------------------------------------------------------------
-- CONNECT, no auth: 10 <len> 0004 "MQTT" 04 02 <ka16> <idlen> <id>
local c = C4MQTT.connect("cid", { keepalive = 30 })
assert(c:byte(1) == 0x10, "CONNECT type")
assert(c:sub(3) == "\0\4MQTT" .. string.char(4, 0x02, 0, 30) .. "\0\3cid", "CONNECT body: " .. hex(c))

-- CONNECT with auth sets flags 0xC2 and appends user then pass.
local ca = C4MQTT.connect("x", { user = "control4", pass = "tok" })
assert(ca:find("\194", 1, true), "auth flag 0xC2 present")           -- 0xC2 == 194
assert(ca:sub(-#("\0\8control4\0\3tok")) == "\0\8control4\0\3tok", "user+pass appended: " .. hex(ca))

-- PUBLISH QoS 0: 30 <len> <tlen16> topic payload
local p = C4MQTT.publish("a/b", "hi")
assert(p == string.char(0x30, 7) .. "\0\3a/bhi", "PUBLISH: " .. hex(p))

-- SUBSCRIBE two topics in one packet, each with its QoS byte 0x00.
local s = C4MQTT.subscribe(1, { "x/status", "x/state/#" })
assert(s:byte(1) == 0x82, "SUBSCRIBE type")
assert(s:sub(3) == "\0\1" .. "\0\8x/status\0" .. "\0\9x/state/#\0", "SUBSCRIBE body: " .. hex(s))

assert(C4MQTT.pingreq() == string.char(0xC0, 0x00))
assert(C4MQTT.disconnect() == string.char(0xE0, 0x00))

-- ---- parse ------------------------------------------------------------------
local got = {}
local H = {
  connack  = function(rc) got.connack = rc end,
  publish  = function(t, pl) got.pub = { t, pl } end,
  pingresp = function() got.ping = true end,
}

-- CONNACK accepted.
local tail = C4MQTT.parse(string.char(0x20, 0x02, 0x00, 0x00), H)
assert(got.connack == 0 and tail == "", "CONNACK parsed")

-- A PUBLISH delivered in two reads (split mid-packet) is held then dispatched once whole.
local pub = C4MQTT.publish("openspeakerpoint/spk/state/audio/volume", "55")
tail = C4MQTT.parse(pub:sub(1, 5), H)
assert(not got.pub and tail == pub:sub(1, 5), "incomplete packet buffered, not dispatched")
tail = C4MQTT.parse(tail .. pub:sub(6), H)
assert(got.pub and got.pub[1] == "openspeakerpoint/spk/state/audio/volume" and got.pub[2] == "55", "split PUBLISH reassembled")
assert(tail == "", "buffer fully consumed")

-- Two packets in one read both fire; PINGRESP handled.
got = {}
C4MQTT.parse(C4MQTT.publish("t", "x") .. string.char(0xD0, 0x00), H)
assert(got.pub[1] == "t" and got.ping, "back-to-back packets")

-- A long topic (>127B remaining length, 2-byte varint) round-trips.
got = {}
local longTopic = string.rep("z", 300)
C4MQTT.parse(C4MQTT.publish(longTopic, "p"), H)
assert(got.pub[1] == longTopic and got.pub[2] == "p", "multi-byte remaining length")

print("control4-lua-mqtt selfcheck OK")
