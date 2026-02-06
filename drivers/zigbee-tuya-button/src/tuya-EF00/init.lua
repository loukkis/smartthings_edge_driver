-- drivers/zigbee-tuya-button/src/tuya-EF00/init.lua
-- Tuya EF00 sub-driver for buttons + battery fallback

local log          = require "log"
local capabilities = require "st.capabilities"
local zcl_clusters = require "st.zigbee.zcl.clusters"

-- Tuya EF00 message structure (common across devices)
-- byte(1) seqno?, byte(2) cmd?, byte(3)=DP, byte(4)=datatype, byte(5..6)=len, byte(7..)=value
local TUYA_DT = { RAW=0x00, BOOL=0x01, VALUE=0x02, STRING=0x03, ENUM=0x04, FAULT=0x05 }

-- A couple of commonly seen battery DP ids for Tuya EF00 devices.
-- You can add more if logs show otherwise for a new fingerprint.
local TUYA_BATTERY_DPS = {
  [0x0F] = true,  -- often VALUE(4)
  [0x15] = true,  -- often VALUE(4)
}

local function parse_tuya_ef00(body_bytes)
  local dp     = body_bytes:byte(3)
  local dtype  = body_bytes:byte(4)
  local len    = (body_bytes:byte(5) << 8) + body_bytes:byte(6)
  local vstart = 7
  local vend   = vstart + len - 1
  return dp, dtype, len, vstart, vend
end

local function try_emit_battery_from_ef00(device, body_bytes)
  local dp, dtype, len, vstart, vend = parse_tuya_ef00(body_bytes)
  if not TUYA_BATTERY_DPS[dp] then return false end

  local pct = nil

  if dtype == TUYA_DT.VALUE and len == 4 then
    -- 4-byte unsigned big-endian
    local b1, b2, b3, b4 = body_bytes:byte(vstart, vend)
    local raw = ((b1 << 24) | (b2 << 16) | (b3 << 8) | b4)

    -- Normalize: some firmwares send 0..100 (percent), others 0..200 (half-percent)
    if     raw <= 100 then pct = raw
    elseif raw <= 200 then pct = math.floor(raw / 2 + 0.5)
    end

  elseif dtype == TUYA_DT.ENUM and len == 1 then
    -- Sometimes only a low-battery flag is exposed.
    local flag = body_bytes:byte(vstart)
    pct = (flag == 1) and 5 or nil  -- conservative mapping
  end

  if pct then
    pct = math.max(0, math.min(100, pct))
    device:emit_event(capabilities.battery.battery(pct))
    log.info(string.format("EF00 battery dp=0x%02X -> %d%%", dp, pct))
    return true
  end

  return false
end

local function button_handler_EF00(driver, device, zb_rx)
  local bytes = zb_rx.body.zcl_body.body_bytes
  log.info("<< tuya-ef00 >> rx bytes: " .. tostring(bytes))

  -- First: if this EF00 frame carries battery, emit and exit.
  if try_emit_battery_from_ef00(device, bytes) then
    return
  end

  -- DO NOT indiscriminately return for specific DPs (e.g., 0x0A).
  -- Some models reuse DPs across FW versions; early returns can drop telemetry.

  -- Button event mapping (original logic)
  -- DTH used descMap.data[2] for buttonNumber -> here it's byte(3)
  local component_id = string.format("button%d", bytes:byte(3))

  -- Click type at byte(7): 00 click / 01 double / 02 held
  local clickType = bytes:byte(7)
  local ev
  if     clickType == 0 then ev = capabilities.button.button.pushed()
  elseif clickType == 1 then ev = capabilities.button.button.double()
  elseif clickType == 2 then ev = capabilities.button.button.held()
  end

  if ev ~= nil then
    ev.state_change = true
    device.profile.components[component_id]:emit_event(ev)
  end
end

local function device_added(driver, device)
  for id, _ in pairs(device.profile.components) do
    device.profile.components[id]:emit_event(capabilities.button.supportedButtonValues({"pushed","double","held"}))
    device.profile.components[id]:emit_event(capabilities.button.button.pushed())
  end
  -- If device actually supports PowerConfiguration (0x0001), request a fresh read.
  if device:supports_server_cluster(zcl_clusters.PowerConfiguration.ID) then
    device:send(zcl_clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
  end
end

local function device_doconfigure(self, device)
  device:configure()
end

-- Add your known Tuya EF00 fingerprints here
local ZIGBEE_TUYA_BUTTON_EF00_FINGERPRINTS = {
  { mfr = "_TZE200_zqtiam4u", model = "TS0601" },
  { mfr = "_TZE204_mpg22jc1", model = "TS0601" },
  { mfr = "_TZ3210_3ulg9kpo", model = "TS0021" },
  -- Your device (MOES 4-gang scene switch)
  { mfr = "_TZ3000_zgyzgdua", model = "TS0044" }, -- verified as TS0044 4-gang in community/device interviews
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