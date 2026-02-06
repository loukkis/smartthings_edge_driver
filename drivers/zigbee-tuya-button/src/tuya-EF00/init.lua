-- Zigbee Tuya Button
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local log = require "log"
local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local zcl_clusters = require "st.zigbee.zcl.clusters"

local function get_ep_offset(device)
  return device.fingerprinted_endpoint_id - 1
end

-- **UPDATED: Full battery + payload logging handler**
local button_handler_EF00 = function(driver, device, zb_rx)
  local body_bytes = zb_rx.body.zcl_body.body_bytes
  
  -- **NEW: Log FULL raw payload**
  local hex_dump = ""
  for i = 1, #body_bytes do
    hex_dump = hex_dump .. string.format("%02X ", body_bytes:byte(i))
  end
  log.info("<<---- Moon ---->> FULL PAYLOAD hex: " .. hex_dump)
  log.info("<<---- Moon ---->> FULL PAYLOAD length: " .. #body_bytes)
  
  -- **NEW: Battery handling (your noted byte 3 == 10)**
  local msg_type = body_bytes:byte(3)
  if msg_type == 10 then
    log.info("<<---- Moon ---->> BATTERY MESSAGE detected!")
    -- Common battery positions for Tuya - we'll confirm with logs
    local battery = body_bytes:byte(5) or body_bytes:byte(7)
    if battery and battery >= 0 and battery <= 100 then
      device:emit_event(capabilities.battery.battery(battery))
      log.info("<<---- Moon ---->> Battery emitted: " .. battery .. "%")
    else
      log.warn("<<---- Moon ---->> Battery byte invalid: " .. (battery or "nil"))
    end
    return
  end
  
  -- **EXISTING: Button handling**
  local component_id = string.format("button%d", msg_type)
  log.info("<<---- Moon ---->> button_handler component_id", component_id)

  local clickType = body_bytes:byte(7)
  log.info("<<---- Moon ---->> button_handler clickType", clickType)
  local ev
  if clickType == 0 then
    ev = capabilities.button.button.pushed()
  elseif clickType == 1 then
    ev = capabilities.button.button.double()
  elseif clickType == 2 then
    ev = capabilities.button.button.held()
  end

  if ev ~= nil then
    ev.state_change = true
    device.profile.components[component_id]:emit_event(ev)
  end
end

local device_added = function(driver, device)
  log.info("<<---- Moon ---->> multi / device_added")

  for key, value in pairs(device.profile.components) do
    log.info("<<---- Moon ---->> device_added - component : ", key)
    device.profile.components[key]:emit_event(capabilities.button.supportedButtonValues({ "pushed", "double", "held" }))
    device.profile.components[key]:emit_event(capabilities.button.button.pushed())
  end
end

local device_doconfigure = function(self, device)
  log.info("<<---- Moon ---->> configure_device")
  device:configure()
end

local ZIGBEE_TUYA_BUTTON_EF00_FINGERPRINTS = {
  { mfr = "_TZE200_zqtiam4u", model = "TS0601" },
  { mfr = "_TZE204_mpg22jc1", model = "TS0601" },
  { mfr = "_TZ3210_3ulg9kpo", model = "TS0021" },
}

local is_tuya_ef00 = function(opts, driver, device)
  for _, fingerprint in ipairs(ZIGBEE_TUYA_BUTTON_EF00_FINGERPRINTS) do
    log.info("<<---- Moon ---->> is_tuya_ef00 :", device:pretty_print())

    if device:get_manufacturer() == fingerprint.mfr and device:get_model() == fingerprint.model then
      log.info("<<---- Moon ---->> is_tuya_ef00 : true / device.fingerprinted_endpoint_id :", device.fingerprinted_endpoint_id)
      return true
    end
  end

  log.info("<<---- Moon ---->> is_tuya_ef00 : false")
  return false
end

local tuya_ef00 = {
  NAME = "tuya ef00",
  lifecycle_handlers = {
    added = device_added,
    doConfigure = device_doconfigure,
  },
  zigbee_handlers = {
    cluster = {
      -- **NEW: Standard Zigbee battery (PowerConfig cluster)**
      [0x0001] = {
        [0x0021] = {  -- BatteryPercentageRemaining
          on_receive = function(driver, device, zb_rx)
            local battery = zb_rx.body.zcl_body.data.value.value
            log.info("<<---- Moon ---->> STANDARD Battery report: " .. battery .. "%")
            device:emit_event(capabilities.battery.battery(battery))
          end,
        },
      },
      -- **EXISTING EF00 handler (now with battery + logging)**
      [0xEF00] = {
        [0x01] = button_handler_EF00
      },
    },
  },
  can_handle = is_tuya_ef00,
}

return tuya_ef00
