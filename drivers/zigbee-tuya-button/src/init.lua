-- drivers/zigbee-tuya-button/src/init.lua
-- Zigbee Tuya Button (main driver)

local log           = require "log"
local capabilities  = require "st.capabilities"
local ZigbeeDriver  = require "st.zigbee"
local defaults      = require "st.zigbee.defaults"
local zcl_clusters  = require "st.zigbee.zcl.clusters"

local function get_ep_offset(device)
  return device.fingerprinted_endpoint_id - 1
end

local function refresh_handler(driver, device, command)
  -- Let the defaults do their thing (including battery).
  -- If the device has 0x0001, this will trigger reads/bindings.
  device:refresh()
  -- Optionally, force a BatteryPercentageRemaining read once
  if device:supports_server_cluster(zcl_clusters.PowerConfiguration.ID) then
    device:send(zcl_clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
  end
end

local function button_handler_onoff_cluster(driver, device, zb_rx)
  -- Some TS004x variants send button presses on OnOff cluster with command 0xFD.
  local ep = zb_rx.address_header.src_endpoint.value
  local number = ep - get_ep_offset(device)
  local component_id = string.format("button%d", number)

  local ev = capabilities.button.button.pushed()
  ev.state_change = true
  device.profile.components[component_id]:emit_event(ev)
end

local function device_added(driver, device)
  for key, _ in pairs(device.profile.components) do
    device.profile.components[key]:emit_event(capabilities.button.supportedButtonValues({"pushed","double","held"}))
    device.profile.components[key]:emit_event(capabilities.button.button.pushed())
  end
end

local function configure_device(self, device)
  device:configure()
  -- Ask for battery once if the device supports 0x0001
  if device:supports_server_cluster(zcl_clusters.PowerConfiguration.ID) then
    device:send(zcl_clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
  end
end

local driver_template = {
  supported_capabilities = {
    capabilities.button,
    capabilities.battery,   -- << critical for Samsung default battery handling
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
        [0xFD] = button_handler_onoff_cluster, -- vendor specific 'scene' command some TS004x use
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

-- Register Samsung's Zigbee defaults (including the Battery default)
defaults.register_for_default_handlers(driver_template, driver_template.supported_capabilities) -- [3](https://developer.smartthings.com/docs/edge-device-drivers/zigbee/defaults.html)

local driver = ZigbeeDriver("zigbee-tuya-button", driver_template)
driver:run()
