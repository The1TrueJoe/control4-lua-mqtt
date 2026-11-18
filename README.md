# control4-lua-mqtt

MQTT 3.1.1 (QoS 0) framing in pure Lua 5.1 for Control4 **DriverWorks** drivers.

Control4 drivers run Lua 5.1 with no bit operators, no `require` of external modules,
and no MQTT client. This is the missing piece: a single file, `mqtt.lua`, that encodes
and decodes the MQTT packets a driver needs to talk to a broker (CONNECT, SUBSCRIBE,
PUBLISH, PINGREQ, DISCONNECT in; CONNACK, PUBLISH, SUBACK, PINGRESP out).

It is **transport-agnostic** on purpose: it only turns bytes into packets and back. Your
driver owns the socket — whether that's a `<connection>` network binding
(`C4:SendToNetwork` / `ReceivedFromNetwork`) or `C4:CreateTCPClient()`. That's the part
that legitimately differs between drivers, so it's not baked in here.

## Use it

There is no `require` inside a `.c4z`, so **concatenate** this file ahead of your driver
body at package time:

```sh
cat control4-lua-mqtt/mqtt.lua driver-body.lua > build/driver.lua
```

It defines one global table, `C4MQTT`, that your body then uses.

```lua
-- connect (clean session; optional user/pass)
sock:write(C4MQTT.connect("c4-" .. C4:GetDeviceID(), { keepalive = 60 }))

-- subscribe (one topic or several in one packet)
sock:write(C4MQTT.subscribe(1, { "myapp/+/status", "myapp/+/state/#" }))

-- publish (QoS 0)
sock:write(C4MQTT.publish("myapp/box/cmd/volume", "42"))

-- on bytes read from the socket: dispatch whole packets, keep the tail
buf = C4MQTT.parse(buf .. data, {
  connack = function(rc) if rc == 0 then --[[ subscribe ]] end end,
  publish = function(topic, payload) --[[ update state ]] end,
})

-- keepalive
sock:write(C4MQTT.pingreq())
```

### API

| Function | Returns / does |
|---|---|
| `C4MQTT.connect(clientId, {keepalive, user, pass})` | CONNECT bytes (clean session; `user`/`pass` optional) |
| `C4MQTT.subscribe(packetId, topic\|{topics})` | SUBSCRIBE bytes, QoS 0, one or many topics |
| `C4MQTT.publish(topic, payload)` | PUBLISH bytes, QoS 0 |
| `C4MQTT.pingreq()` / `C4MQTT.disconnect()` | PINGREQ / DISCONNECT bytes |
| `C4MQTT.parse(buf, handlers)` | consumes whole packets, calls `handlers.{connack,publish,suback,pingresp}`, returns the unconsumed tail |

`parse` handles packets split across reads (return value is the leftover bytes) and
multi-byte Remaining Length. QoS 0 only — that's all a controller-side driver needs.

## Test

```sh
lua5.1 test.lua
```

Byte-level checks of every encoder and of `parse` (split packets, back-to-back packets,
multi-byte length, auth flags). CI runs it on `lua5.1`, the same interpreter the
controller uses.

## Used by

- [openSpeakerPoint](https://github.com/The1TrueJoe/openSpeakerPoint) — Control4 driver
- [openhc-control4](https://github.com/The1TrueJoe/openhc-control4) — Control4 driver

## License

MIT
