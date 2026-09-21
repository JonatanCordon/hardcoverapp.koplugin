local SETTING = require("hardcover/lib/constants/settings")

local Device = require("device")

local NetworkMgr = require("ui/network/manager")

local AutoWifi = {}
AutoWifi.__index = AutoWifi

function AutoWifi:new(o)
  return setmetatable(o, self)
end

function AutoWifi:canEnableWifi()
  return self.settings:readSetting(SETTING.ENABLE_WIFI)
      and not NetworkMgr.pending_connection
      and Device:hasWifiRestore()
      and G_reader_settings:nilOrFalse("airplanemode")
end

-- Whether withWifi will run its callback (wifi is already on, or can be enabled automatically)
function AutoWifi:canRunWithWifi()
  if NetworkMgr:isWifiOn() then
    return true
  end

  return self:canEnableWifi() and true or false
end

-- Run callback with wifi enabled. If wifi is off and cannot be enabled automatically,
-- callback is not called. Use canRunWithWifi() to check this beforehand.
function AutoWifi:withWifi(callback)
  if NetworkMgr:isWifiOn() then
    callback(false)
    return
  end

  if self:canEnableWifi() then
    local original_on = NetworkMgr.wifi_was_on

    NetworkMgr:restoreWifiAsync()
    NetworkMgr:scheduleConnectivityCheck(function()
      -- restore original "was on" state to prevent wifi being restored automatically after suspend
      NetworkMgr.wifi_was_on = original_on
      G_reader_settings:saveSetting("wifi_was_on", original_on)

      callback(true)

      -- TODO: schedule turn off wifi, debounce
      self:wifiDisableSilent()
    end)
  end
end

function AutoWifi:wifiDisableSilent()
  NetworkMgr:turnOffWifi(function()
    -- explicitly disable wifi was on
    NetworkMgr.wifi_was_on = false
    G_reader_settings:saveSetting("wifi_was_on", false)
  end)
end

function AutoWifi:wifiPrompt(callback)
  if NetworkMgr:isWifiOn() then
    if callback then
      callback(false)
    end

    return
  end

  if G_reader_settings:isTrue("airplanemode") then
    return
  end

  local network_callback = callback and function() callback(true) end or nil

  if self.settings:readSetting(SETTING.ENABLE_WIFI) then
    NetworkMgr:turnOnWifiAndWaitForConnection(network_callback)
  else
    NetworkMgr:promptWifiOn(network_callback)
  end
end

function AutoWifi:wifiDisablePrompt()
  if self.settings:readSetting(SETTING.ENABLE_WIFI) and Device:hasWifiRestore() then
    self:wifiDisableSilent()
  else
    NetworkMgr:toggleWifiOff()
  end
end

return AutoWifi
