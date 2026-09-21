describe("HardcoverSettings", function()
  local HardcoverSettings
  local SETTING = require("hardcover/lib/constants/settings")
  local current_version

  local FakeLuaSettings = {}
  FakeLuaSettings.__index = FakeLuaSettings

  function FakeLuaSettings:open(path)
    return setmetatable({ path = path, data = {}, flushed = 0 }, FakeLuaSettings)
  end

  function FakeLuaSettings:readSetting(key, default)
    if self.data[key] == nil and default ~= nil then
      self.data[key] = default
    end
    return self.data[key]
  end

  function FakeLuaSettings:saveSetting(key, value)
    self.data[key] = value
  end

  function FakeLuaSettings:flush()
    self.flushed = self.flushed + 1
  end

  before_each(function()
    current_version = 202501010000
    package.loaded["version"] = {
      getNormalizedCurrentVersion = function()
        return current_version
      end
    }
    package.loaded["luasettings"] = FakeLuaSettings
    package.loaded["hardcover/lib/hardcover_settings"] = nil
    HardcoverSettings = require("hardcover/lib/hardcover_settings")
  end)

  after_each(function()
    package.loaded["version"] = nil
    package.loaded["luasettings"] = nil
    package.loaded["hardcover/lib/hardcover_settings"] = nil
  end)

  local ui = function(file)
    return { document = { file = file } }
  end

  describe("new", function()
    it("keeps state per instance", function()
      local a = HardcoverSettings:new("a.lua", ui("a.epub"))
      local b = HardcoverSettings:new("b.lua", ui("b.epub"))

      assert.are_not.equal(a.settings, b.settings)
      assert.are_not.equal(a.subscribers, b.subscribers)
      assert.are.equal("a.lua", a.settings.path)
      assert.are.equal("a.epub", a:getFilePath())
      assert.are.equal("b.epub", b:getFilePath())
      assert.is_nil(rawget(HardcoverSettings, "settings"))
      assert.is_nil(rawget(HardcoverSettings, "subscribers"))
    end)

    it("shares stored settings between instances using the same file", function()
      local a = HardcoverSettings:new("a.lua", ui("a.epub"))
      local b = HardcoverSettings:new("a.lua", ui("b.epub"))

      assert.are.equal(a.settings, b.settings)
      assert.are_not.equal(a.subscribers, b.subscribers)

      a:updateSetting("always_sync", true)
      assert.is_true(b:readSetting("always_sync"))
    end)

    it("enables compatibility mode for old KOReader versions", function()
      current_version = 202301010000
      local settings = HardcoverSettings:new("a.lua", ui("a.epub"))

      assert.is_true(settings:compatibilityMode())
    end)

    it("does not enable compatibility mode for recent KOReader versions", function()
      local settings = HardcoverSettings:new("a.lua", ui("a.epub"))

      assert.is_false(settings:compatibilityMode())
    end)
  end)

  describe("updateBookSetting", function()
    it("applies deletions before new values", function()
      local settings = HardcoverSettings:new("a.lua", ui("a.epub"))
      settings:updateBookSetting("a.epub", { edition_format = "Paperback", pages = 100 })

      settings:updateBookSetting("a.epub", { edition_format = "E-Book", _delete = { "edition_format", "pages" } })

      assert.are.equal("E-Book", settings:readBookSetting("a.epub", "edition_format"))
      assert.is_nil(settings:readBookSetting("a.epub", "pages"))
    end)

    it("notifies subscribers with a copy of the original values", function()
      local settings = HardcoverSettings:new("a.lua", ui("a.epub"))
      settings:updateBookSetting("a.epub", { book_id = 1, title = "Old" })

      local received
      settings:subscribe(function(field, change, original_value)
        received = { field = field, change = change, original_value = original_value }
      end)

      settings:updateBookSetting("a.epub", { title = "New" })

      assert.are.equal(SETTING.BOOKS, received.field)
      assert.are.same({ filename = "a.epub", config = { title = "New" } }, received.change)
      assert.are.same({ book_id = 1, title = "Old" }, received.original_value)
    end)
  end)

  describe("clearLinkedBook", function()
    it("removes linked book values and keeps other book settings", function()
      local settings = HardcoverSettings:new("a.lua", ui("a.epub"))
      settings:updateBookSetting("a.epub", {
        book_id = 1,
        edition_id = 2,
        edition_format = "E-Book",
        pages = 100,
        title = "Title",
        sync = true
      })

      settings:clearLinkedBook("a.epub")

      assert.are.same({ sync = true }, settings:readBookSettings("a.epub"))
    end)
  end)
end)
