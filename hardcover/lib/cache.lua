local Api = require("hardcover/lib/hardcover_api")
local User = require("hardcover/lib/user")

local Cache = {}
Cache.__index = Cache

function Cache:new(o)
  return setmetatable(o, self)
end

-- Keep the existing privacy setting of a user book, so that changing its status does not reset it
function Cache:_privacySettingId(book_id)
  local book_status = self.state.book_status
  if book_status.id and book_status.book_id == book_id then
    return book_status.privacy_setting_id
  end

  local user_book = Api:findUserBook(book_id, User:getId())
  if user_book then
    return user_book.privacy_setting_id
  end

  -- new user book: use the account default
  return User:getAccountPrivacySettingId()
end

function Cache:updateBookStatus(filename, status, privacy_setting_id)
  local settings = self.settings:readBookSettings(filename)
  local book_id = settings.book_id
  if not book_id then
    self.state.book_status = {}
    return
  end

  privacy_setting_id = privacy_setting_id or self:_privacySettingId(book_id)

  self.state.book_status = Api:updateUserBook(book_id, status, privacy_setting_id, settings.edition_id) or {}
end

function Cache:cacheUserBook()
  local status, errors = Api:findUserBook(self.settings:getLinkedBookId(), User:getId())
  self.state.book_status = status or {}

  return errors
end

return Cache
