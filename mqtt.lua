-- control4-lua-mqtt: MQTT 3.1.1, QoS 0, by hand for Control4 DriverWorks (Lua 5.1,
-- no bit operators). Transport-agnostic byte framing - the driver owns the socket
-- (a network-connection binding, or C4:CreateTCPClient) and just moves bytes.
--
-- There is no `require` inside a .c4z, so drivers CONCATENATE this file ahead of their
-- own body at package time (`cat mqtt.lua driver-body.lua > driver.lua`). It defines
-- one global table, C4MQTT, which the body then uses.
--
-- Encoders return a byte string to write to the socket; C4MQTT.parse consumes the
-- bytes read from it and dispatches whole packets to a handler table. Self-check:
-- `lua5.1 test.lua`.

C4MQTT = {}

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function mstr(s) return u16(#s) .. s end       -- length-prefixed MQTT string

-- Remaining Length: 1-4 bytes, 7 bits each, high bit = "more".
local function encodeLen(n)
  local s = ""
  repeat
    local b = n % 128
    n = math.floor(n / 128)
    if n > 0 then b = b + 128 end
    s = s .. string.char(b)
  until n == 0
  return s
end

local function packet(hdr, body) return string.char(hdr) .. encodeLen(#body) .. body end

C4MQTT.u16 = u16
C4MQTT.mstr = mstr

-- CONNECT. opts = { keepalive = 60, user = nil, pass = nil }. Clean session always.
-- A password without a username is not valid MQTT, so pass is sent only with user.
function C4MQTT.connect(clientId, opts)
  opts = opts or {}
  local flags = 0x02                                 -- clean session
  local payload = mstr(clientId)
  if opts.user and opts.user ~= "" then
    flags = flags + 0x80
    payload = payload .. mstr(opts.user)
    if opts.pass and opts.pass ~= "" then
      flags = flags + 0x40
      payload = payload .. mstr(opts.pass)
    end
  end
  local vh = mstr("MQTT") .. string.char(4) .. string.char(flags) .. u16(opts.keepalive or 60)
  return packet(0x10, vh .. payload)
end

-- SUBSCRIBE at QoS 0 to one topic (string) or several (array). pid: 1..65535.
function C4MQTT.subscribe(pid, topics)
  if type(topics) == "string" then topics = { topics } end
  local body = u16(pid)
  for _, t in ipairs(topics) do body = body .. mstr(t) .. string.char(0) end
  return packet(0x82, body)
end

-- PUBLISH, QoS 0 (no packet id, not retained).
function C4MQTT.publish(topic, payload)
  return packet(0x30, mstr(topic) .. (payload or ""))
end

function C4MQTT.pingreq()    return string.char(0xC0, 0x00) end
function C4MQTT.disconnect() return string.char(0xE0, 0x00) end

-- Pull whole packets out of `buf`, calling the handlers you provide, and return the
-- unconsumed tail (keep it and prepend the next read; MQTT packets split across reads).
--   handlers = {
--     connack  = function(returnCode)        -- 0 = accepted
--     publish  = function(topic, payload)
--     suback   = function(packetId)
--     pingresp = function()
--   }
-- Unhandled packet types are skipped. A malformed Remaining Length drops the buffer
-- (resync) rather than looping.
function C4MQTT.parse(buf, handlers)
  handlers = handlers or {}
  while #buf >= 2 do
    local first = buf:byte(1)
    local mult, len, pos, b = 1, 0, 2, 0
    repeat
      if pos > #buf then return buf end              -- length not fully arrived yet
      b = buf:byte(pos)
      len = len + (b % 128) * mult
      mult = mult * 128
      pos = pos + 1
      if mult > 128 * 128 * 128 * 128 then return "" end  -- malformed: resync
    until b < 128
    if #buf < (pos - 1) + len then return buf end    -- body not fully arrived yet
    local typ = math.floor(first / 16)
    local qos = math.floor(first / 2) % 4
    local body = buf:sub(pos, pos + len - 1)
    buf = buf:sub(pos + len)
    if typ == 2 then                                 -- CONNACK
      if handlers.connack then handlers.connack(body:byte(2) or 1) end
    elseif typ == 3 then                             -- PUBLISH
      local tl = body:byte(1) * 256 + body:byte(2)
      local topic = body:sub(3, 2 + tl)
      local payload = body:sub(3 + tl + (qos > 0 and 2 or 0))
      if handlers.publish then handlers.publish(topic, payload) end
    elseif typ == 9 then                             -- SUBACK
      if handlers.suback then handlers.suback(body:byte(1) * 256 + body:byte(2)) end
    elseif typ == 13 then                            -- PINGRESP
      if handlers.pingresp then handlers.pingresp() end
    end
  end
  return buf
end
