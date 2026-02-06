-- drivers/zigbee-tuya-button/src/init.lua
-- Zigbee Tuya Button (main driver)

local log           = require "log"
local capabilities  = require "st.capabilities"
local ZigbeeDriver  = require "st.zigbee"
local defaults      = require "st.zigbee.defaults"
local zcl_clusters  = require "st.zigbee.zcl.clusters"

local function get_ep_offset (device)
  return device.fingerprinted_endpoint_id and (device.fingerprinted_endpoint_id - 1) or 0
end

-- Expose a simple Refresh that asks devices to send current attributes.
-- (The default battery handler will still handle PowerConfiguration 0x0021)
local function refresh_handler(driver, device, command)
  device:refresh()
  -- If you want to force a read explicitly, uncomment:
  -- device:send(zcl_clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
end

-- Some Tuya buttons send scene presses on On/Off cluster with cmd 0xFD
local function button_handler_onoff_cluster(driver, device, zb_rx)
  local ep = zb_rx.address_header.src_endpoint.value
  local number = ep - get_ep_offset(device)
  if number < 1 then number = 1 end
  local component_id = string.format("button%d", number)
  local ev = capabilities.button.button.pushed()
  ev.state_change = true
  local comp = device.profile.components[component_id]
  if comp then comp:emit_event(ev) else device:emit_event(ev) end
end

local function device_added (driver, device)
  for key, _ in pairs(device.profile.components) do
    device.profile.components[key]:emit_event(capabilities.button.supportedButtonValues({"pushed","double","held"}))
    device.profile.components[key]:emit_event(capabilities.button.button.pushed())
  end
end

local function configure_device(self, device)
  device:configure()
  -- Optional: trigger one battery read; the custom handler in the sub-driver will filter EPs for your MOES TS0044
  -- device:send(zcl_clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
end

local driver_template = {
  -- You can set health_check=false to silence the “Monitored Attributes” deprecation warning
  -- health_check = false,

  supported_capabilities = {
    capabilities.button,
    capabilities.battery,   -- keep default battery handler registered
    capabilities.refresh
  },

  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler,
    }
  },

  zigbee_handlers = {
    cluster = {
      [zcl_clusters.OnOff.ID] = {
        [0xFD] = button_handler_onoff_cluster, -- vendor-specific 'scene' command some TS004x use
      }
    }
  },

  lifecycle_handlers = {
    added = device_added,
    doConfigure = configure_device,
  },

  sub_drivers = {
    require("tuya-EF00"),
  }
}

-- Register Samsung defaults (includes default Battery handler for PowerConfiguration 0x0021)
defaults.register_for_default_handlers(driver_template, driver_template.supported_capabilities)

local driver = ZigbeeDriver("zigbee-tuya-button", driver_template)
driver:run()