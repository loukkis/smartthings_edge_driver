-- drivers/zigbee-tuya-button/src/tuya-EF00/init.lua
-- Tuya EF00 sub-driver for buttons + battery fallback + fingerprint-scoped battery fix (Option B)

local log          = require "log"
local capabilities = require "st.capabilities"
local clusters     = require "st.zigbee.zcl.clusters"
local zcl_clusters = require "st.zigbee.zcl.clusters"

local PowerConfig  = clusters.PowerConfiguration

-- ========================= Tuya EF00 helpers =========================
-- EF00 byte layout: [seq?][cmd?][DP][DTYPE][LEN_hi][LEN_lo][VALUE...]
local TUYA_DT = { RAW=0x00, BOOL=0x01, VALUE=0x02, STRING=0x03, ENUM=0x04, FAULT=0x05 }

-- Common Tuya battery DP ids found across TS004x/TS0601 variants
local TUYA_BATTERY_DPS = {
  [0x0F] = true,
  [0x15] = true,
}

local function get_ep_offset(device)
  return device.fingerprinted_endpoint_id and (device.fingerprinted_endpoint_id - 1) or 0
end

local function parse_tuya_ef00(body_bytes)
  local dp     = body_bytes:byte(3)
  local dtype  = body_bytes:byte(4)
  local len    = (body_bytes:byte(5) << 8) + body_bytes:byte(6)
  local vstart = 7
  local vend   = vstart + len - 1
  return dp, dtype, len, vstart, vend
end

-- Try to emit battery % from EF00 when device doesn't use 0x0001
local function try_emit_battery_from_ef00(device, body_bytes)
  local dp, dtype, len, vstart, vend = parse_tuya_ef00(body_bytes)
  if not TUYA_BATTERY_DPS[dp] then return false end

  local pct = nil

  if dtype == TUYA_DT.VALUE and len == 4 then
    -- 4-byte unsigned big-endian
    local b1, b2, b3, b4 = body_bytes:byte(vstart, vend)
    local raw = ((b1 << 24) | (b2 << 16) | (b3 << 8) | b4)
    if raw <= 100 then
      pct = raw
    elseif raw <= 200 then
      pct = math.floor(raw / 2 + 0.5)
    end
  elseif dtype == TUYA_DT.ENUM and len == 1 then
    -- Low-battery flag on some firmwares
    local flag = body_bytes:byte(vstart)
    pct = (flag == 1) and 5 or nil
  end

  if pct then
    pct = math.max(0, math.min(100, pct))
    device:emit_event(capabilities.battery.battery(pct))
    log.info(string.format("EF00 battery dp=0x%02X -> %d%%", dp, pct))
    return true
  end

  return false
end

-- ================== Option B: fingerprint-scoped battery handler ==================
-- Your logs show EP1 reports 0x0021=0xC8 (→100%), while EP2–EP4 respond 0x00 (→0%) shortly after.
-- This handler accepts EP1 values and drops spurious EP2–EP4 zeros for this fingerprint only.
-- Zigbee 0x0021 is in 0.5% units; convert -> 0..100%
local function battery_attr_handler(driver, device, value, zb_rx)
  if not (device:get_manufacturer() == "_TZ3000_zgyzgdua" and device:get_model() == "TS0044") then
    return
  end

  local ep  = zb_rx.address_header.src_endpoint.value
  local raw = tonumber(value.value) or 0  -- Uint8 0..200

  -- Drop the known-bad 0 from EP2..EP4
  if ep ~= 1 and raw == 0 then
    log.debug(string.format("battery_attr_handler: drop EP%d raw=0 (spurious)", ep))
    return
  end

  local pct = math.floor((raw / 2) + 0.5)
  pct = math.max(0, math.min(100, pct))

  -- Debounce duplicate emissions
  local last = device:get_field("last_batt")
  if last ~= pct then
    device:set_field("last_batt", pct, { persist = false })
    device:emit_event(capabilities.battery.battery(pct))
    log.info(string.format("battery_attr_handler: EP%d raw=%d -> %d%%", ep, raw, pct))
  else
    log.debug(string.format("battery_attr_handler: EP%d raw=%d -> %d%% (no change)", ep, raw, pct))
  end
end

-- ========================= EF00 button handler =========================
local function button_handler_EF00(driver, device, zb_rx)
  local bytes = zb_rx.body.zcl_body.body_bytes
  log.debug("tuya-ef00 rx: " .. tostring(bytes))

  -- If EF00 contains battery, emit and stop
  if try_emit_battery_from_ef00(device, bytes) then return end

  -- Button component: descMap.data[2] (0-based) -> byte(3)
  local component_id = string.format("button%d", bytes:byte(3))

  -- Click type at byte(7): 0=click, 1=double, 2=held
  local clickType = bytes:byte(7)
  local ev
  if     clickType == 0 then ev = capabilities.button.button.pushed()
  elseif clickType == 1 then ev = capabilities.button.button.double()
  elseif clickType == 2 then ev = capabilities.button.button.held()
  end

  if ev ~= nil then
    ev.state_change = true
    local comp = device.profile.components[component_id]
    if comp then comp:emit_event(ev) else device:emit_event(ev) end
  end
end

-- ========================= lifecycle =========================
local function device_added(driver, device)
  for id, _ in pairs(device.profile.components) do
    device.profile.components[id]:emit_event(capabilities.button.supportedButtonValues({"pushed","double","held"}))
    device.profile.components[id]:emit_event(capabilities.button.button.pushed())
  end

  -- Optional: request an initial battery read if PowerConfiguration exists
  if device:supports_server_cluster(zcl_clusters.PowerConfiguration.ID) then
    device:send(zcl_clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
  end
end

local function device_doconfigure(self, device)
  device:configure()
  -- Optional: configure reporting on EP1 (mirrors ST defaults)
  -- device:send(PowerConfig.attributes.BatteryPercentageRemaining:configure_reporting(device, 30, 21600, 1))
end

-- ========================= fingerprints & sub-driver table =========================
local ZIGBEE_TUYA_BUTTON_EF00_FINGERPRINTS = {
  { mfr = "_TZE200_zqtiam4u", model = "TS0601" },
  { mfr = "_TZE204_mpg22jc1", model = "TS0601" },
  { mfr = "_TZ3210_3ulg9kpo", model = "TS0021" },
  { mfr = "_TZ3000_zgyzgdua", model = "TS0044" }, -- MOES 4-gang scene switch
}

local function is_tuya_ef00(opts, driver, device)
  for _, fp in ipairs(ZIGBEE_TUYA_BUTTON_EF00_FINGERPRINTS) do
    if device:get_manufacturer() == fp.mfr and device:get_model() == fp.model then
      log.info("tuya-ef00: matched " .. fp.mfr .. " / " .. fp.model)
      return true
    end
  end
  return false
end

local tuya_ef00 = {
  NAME = "tuya ef00",
  zigbee_handlers = {
    -- Option B: scoped battery handler for this sub-driver
    attr = {
      [PowerConfig.ID] = {
        [PowerConfig.attributes.BatteryPercentageRemaining.ID] = battery_attr_handler
      },
    },
    cluster = {
      [0xEF00] = { [0x01] = button_handler_EF00 }, -- Tuya Data Report
    },
  },
  lifecycle_handlers = {
    added = device_added,
    doConfigure = device_doconfigure,
  },
  can_handle = is_tuya_ef00,
}

return tuya_ef00