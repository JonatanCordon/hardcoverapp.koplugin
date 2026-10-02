local SETTING = require("hardcover/lib/constants/settings")
local Api = require("hardcover/lib/hardcover_api")

local User = {}

-- current user, fetched at most once per session
local me

function User:me()
  if not me then
    local result = Api:me()
    -- only keep a successful lookup (the request fails when offline)
    if result.id then
      me = result
    end
  end

  return me or {}
end

function User:getId()
  local user_id = self.settings:readSetting(SETTING.USER_ID)
  if not user_id then
    user_id = self:me().id
    if user_id then
      self.settings:updateSetting(SETTING.USER_ID, user_id)
    end
  end

  return user_id
end

function User:getAccountPrivacySettingId()
  return self:me().account_privacy_setting_id
end

return User
