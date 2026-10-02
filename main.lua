local _ = require("gettext")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local logger = require("logger")
local math = require("math")
local T = require("ffi/util").template

local NetworkManager = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")

local WidgetContainer = require("ui/widget/container/widgetcontainer")

local _t = require("hardcover/lib/table_util")
local Api = require("hardcover/lib/hardcover_api")
local AutoWifi = require("hardcover/lib/auto_wifi")
local Cache = require("hardcover/lib/cache")
local debounce = require("hardcover/lib/debounce")
local Hardcover = require("hardcover/lib/hardcover")
local HardcoverSettings = require("hardcover/lib/hardcover_settings")
local PageMapper = require("hardcover/lib/page_mapper")
local Scheduler = require("hardcover/lib/scheduler")
local throttle = require("hardcover/lib/throttle")
local User = require("hardcover/lib/user")

local DialogManager = require("hardcover/lib/ui/dialog_manager")
local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SETTING = require("hardcover/lib/constants/settings")

local HardcoverApp = WidgetContainer:extend {
  name = "hardcoverappsync",
  is_doc_only = false,
  state = nil,
  settings = nil,
  width = nil,
  enabled = true
}

local HIGHLIGHT_MENU_NAME = "13_0_make_hardcover_highlight_item"

-- only warn about a missing API key once per session
local missing_token_shown = false

function HardcoverApp:onDispatcherRegisterActions()
  Dispatcher:registerAction("hardcover_link", {
    category = "none",
    event = "HardcoverLink",
    title = _("Hardcover: Link book"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_track", {
    category = "none",
    event = "HardcoverTrack",
    title = _("Hardcover: Track progress"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_stop_track", {
    category = "none",
    event = "HardcoverStopTrack",
    title = _("Hardcover: Stop tracking progress"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_update_progress", {
    category = "none",
    event = "HardcoverUpdateProgress",
    title = _("Hardcover: Update progress"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_random_books", {
    category = "none",
    event = "HardcoverSuggestBook",
    title = _("Hardcover: Suggest a book"),
    general = true,
  })
end

function HardcoverApp:init()
  self.state = {
    page = nil,
    pos = nil,
    search_results = {},
    book_status = {},
    -- latest mapped page which has not been sent to Hardcover yet
    unsent_page = nil,
    page_sending = false
  }
  self.settings = HardcoverSettings:new(
    ("%s/%s"):format(DataStorage:getSettingsDir(), "hardcoversync_settings.lua"),
    self.ui
  )
  self.settings:subscribe(function(field, change, original_value) self:onSettingsChanged(field, change, original_value) end)

  User.settings = self.settings
  Api.on_error = function(err)
    if not err or not self.enabled then
      return
    end

    if err == HARDCOVER.ERROR.TOKEN or _t.dig(err, "extensions", "code") == HARDCOVER.ERROR.JWT or (err.message and string.find(err.message, "JWT")) then
      self:disable()
      UIManager:show(InfoMessage:new {
        text = _("Your Hardcover API key is not valid or has expired. Please update it and restart"),
        icon = "notice-warning",
      })
    end
  end

  self.cache = Cache:new {
    settings = self.settings,
    state = self.state
  }
  self.page_mapper = PageMapper:new {
    state = self.state,
    ui = self.ui,
  }
  self.wifi = AutoWifi:new {
    settings = self.settings
  }
  self.dialog_manager = DialogManager:new {
    page_mapper = self.page_mapper,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
    wifi = self.wifi
  }
  self.hardcover = Hardcover:new {
    cache = self.cache,
    dialog_manager = self.dialog_manager,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
    wifi = self.wifi
  }

  self.menu = HardcoverMenu:new {
    enabled = true,

    cache = self.cache,
    dialog_manager = self.dialog_manager,
    hardcover = self.hardcover,
    page_mapper = self.page_mapper,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
  }

  if not Api:hasToken() then
    self.enabled = false
    self.menu.enabled = false

    if not missing_token_shown then
      missing_token_shown = true
      UIManager:nextTick(function()
        UIManager:show(InfoMessage:new {
          text = _("Hardcover API key is missing. Add it to hardcover_config.lua and restart"),
          icon = "notice-warning",
        })
      end)
    end
  end

  self:onDispatcherRegisterActions()
  self:initializePageUpdate()
  self.ui.menu:registerToMainMenu(self)
end

function HardcoverApp:_bookSettingChanged(setting, key)
  return setting[key] ~= nil or _t.contains(_t.dig(setting, "_delete"), key)
end

-- Open note dialog
--
-- UIManager:broadcastEvent(Event:new("HardcoverNote", note_params))
--
-- note_params can contain:
--   text: Value will prepopulate the note section
--   page_number: The local page number
--   remote_page (optional): The mapped page in the linked book edition
--   note_type: one of "quote" or "note"
function HardcoverApp:onHardcoverNote(note_params)
  -- open journal dialog
  self.dialog_manager:journalEntryForm(
    note_params.text,
    self.ui.document,
    note_params.page_number,
    self.settings:pages(),
    note_params.remote_page,
    note_params.note_type or "quote"
  )
end

function HardcoverApp:disable()
  self.enabled = false
  if self.menu then
    self.menu.enabled = false
  end
  self:registerHighlight()
end

function HardcoverApp:onHardcoverLink()
  self.hardcover:showLinkBookDialog(false, function(book)
    UIManager:show(Notification:new {
      text = T(_("Linked to: %1"), book.title),
    })
  end)
end

function HardcoverApp:onHardcoverTrack()
  self.settings:setSync(true)
  UIManager:nextTick(function()
    UIManager:show(Notification:new {
      text = _("Progress tracking enabled")
    })
  end)
end

function HardcoverApp:onHardcoverStopTrack()
  self.settings:setSync(false)
  UIManager:show(Notification:new {
    text = _("Progress tracking disabled")
  })
end

function HardcoverApp:onHardcoverUpdateProgress()
  if self.ui.document and self.settings:bookLinked() then
    self:updatePageNow(function(result)
      if result then
        UIManager:show(Notification:new {
          text = _("Progress updated")
        })
      else
        logger.warn("Unsuccessful updating page progress", self.ui.document.file)
      end
    end)
  else
    local error_message
    if not self.ui.document then
      error_message = _("Unable to update reading progress: No book active")
    else
      error_message = _("Unable to update reading progress: Book has not been linked")
    end

    UIManager:show(InfoMessage:new {
      text = error_message,
      icon = "notice-warning",
    })
  end
end

function HardcoverApp:onHardcoverSuggestBook()
  self.hardcover:showRandomBookDialog()
end

function HardcoverApp:onSettingsChanged(field, change, original_value)
  if field == SETTING.BOOKS then
    local book_settings = change.config
    if self:_bookSettingChanged(book_settings, "sync") then
      if book_settings.sync then
        if not self.state.book_status.id then
          self:startReadCache()
        end
      else
        self:cancelPendingUpdates()
        self.state.unsent_page = nil
      end
    end

    if self:_bookSettingChanged(book_settings, "book_id") then
      self:registerHighlight()
    end
  elseif field == SETTING.TRACK_METHOD then
    self:cancelPendingUpdates()
    self:initializePageUpdate()
  elseif field == SETTING.LINK_BY_HARDCOVER or field == SETTING.LINK_BY_ISBN or field == SETTING.LINK_BY_TITLE then
    if change then
      self.hardcover:tryAutolink()
    end
  end
end

function HardcoverApp:_currentRead()
  if self.state.book_status.status_id ~= HARDCOVER.STATUS.READING then
    return
  end

  local reads = self.state.book_status.user_book_reads
  return reads and reads[#reads]
end

-- Record a page to send to Hardcover. It is kept until a request succeeds, so that
-- updates are not lost when offline, suspended or when a request fails
function HardcoverApp:queuePage(filename, mapped_page)
  if not mapped_page or not self:syncFileUpdates(filename) or not self:_currentRead() then
    return false
  end

  self.state.unsent_page = mapped_page
  return true
end

-- Send the unsent page, if any
--
-- wake_wifi: allow wifi to be enabled automatically for this update
-- immediate: send now (blocking) instead of in the background
function HardcoverApp:sendUnsentPage(wake_wifi, immediate, callback)
  local page = self.state.unsent_page
  local current_read = self:_currentRead()

  if not current_read then
    self.state.unsent_page = nil
  end

  if not page or not current_read or self.state.page_sending then
    if callback then
      callback()
    end
    return
  end

  if page == current_read.progress_pages then
    self.state.unsent_page = nil
    if callback then
      callback(self.state.book_status)
    end
    return
  end

  if not NetworkManager:isConnected() and not (wake_wifi and self.wifi:canRunWithWifi()) then
    -- keep the page until a connection is available
    if callback then
      callback()
    end
    return
  end

  local send = function()
    self.wifi:withWifi(function()
      if self.state.page_sending then
        return
      end

      self.state.page_sending = true
      local result = Api:updatePage(current_read.id, current_read.edition_id, page, current_read.started_at)
      self.state.page_sending = false

      if result then
        if self.state.unsent_page == page then
          self.state.unsent_page = nil
        end
        -- the book may have been closed while waiting for wifi
        if self.state.book_status.id == result.id then
          self.state.book_status = result
        end
      end

      if callback then
        callback(result)
      end
    end)
  end

  if immediate then
    send()
  else
    UIManager:scheduleIn(1, function()
      Trapper:wrap(send)
    end)
  end
end

-- Periodic updates do not enable wifi: waking the radio every few minutes is
-- expensive on e-readers. Pages are sent when a connection becomes available,
-- on resume, and when the document is closed
function HardcoverApp:_sendThrottledPage()
  self:sendUnsentPage(false)
end

function HardcoverApp:initializePageUpdate()
  local track_frequency = math.max(math.min(self.settings:trackFrequency(), 120), 1) * 60

  self._throttledSendPage, self._cancelPageSend = throttle(
    track_frequency,
    HardcoverApp._sendThrottledPage
  )

  self.onPageUpdate, self._cancelPageUpdateEvent = debounce(2, HardcoverApp.pageUpdateEvent)
end

function HardcoverApp:pageUpdateEvent(page)
  self.state.last_page = self.state.page
  self.state.page = page

  if not (self.state.book_status.id and self.settings:syncEnabled()) then
    return
  end
  local filename = self.ui.document.file
  local document_pages = self.ui.document:getPageCount()
  local remote_pages = self.settings:pages()

  if self.settings:trackByTime() then
    local mapped_page = self.page_mapper:getMappedPage(page, document_pages, remote_pages)

    if self:queuePage(filename, mapped_page) then
      self:_throttledSendPage()
    end
  elseif self.settings:trackByProgress() and self.state.last_page then
    local percent_interval = self.settings:trackPercentageInterval()

    local previous_percent = self.page_mapper:getRemotePagePercent(
      self.state.last_page,
      document_pages,
      remote_pages
    )

    local current_percent, mapped_page = self.page_mapper:getRemotePagePercent(
      self.state.page,
      document_pages,
      remote_pages
    )

    local last_compare = math.floor(previous_percent * 100 / percent_interval)
    local current_compare = math.floor(current_percent * 100 / percent_interval)

    -- progress milestones are infrequent, so these may enable wifi
    if last_compare ~= current_compare and self:queuePage(filename, mapped_page) then
      self:sendUnsentPage(true)
    end
  end
end

function HardcoverApp:onPosUpdate(_, page)
  -- scroll mode: share the page update debounce
  self:onPageUpdate(page)
end

function HardcoverApp:onUpdatePos()
  self.page_mapper:cachePageMap()
end

function HardcoverApp:onReaderReady()
  self.page_mapper:cachePageMap()
  self:registerHighlight()
  self.state.page = self.ui:getCurrentPage()

  if self.ui.document and (self.settings:syncEnabled() or (not self.settings:bookLinked() and self.settings:autolinkEnabled())) then
    UIManager:scheduleIn(2, self.startReadCache, self)
  end
end

-- Cancel scheduled work. Unsent pages are kept so they can be sent later
function HardcoverApp:cancelPendingUpdates()
  if self._cancelPageSend then
    self:_cancelPageSend()
  end

  if self._cancelPageUpdateEvent then
    self:_cancelPageUpdateEvent()
  end
end

function HardcoverApp:onDocumentClose()
  UIManager:unschedule(self.startReadCache)

  self:cancelPendingUpdates()
  self.state.read_cache_started = false

  if self.state.unsent_page and self.ui.document then
    self:sendUnsentPage(true, true)
  end

  self.state.unsent_page = nil
  self.state.book_status = {}
  self.state.page_map = nil
end

function HardcoverApp:onSuspend()
  self:cancelPendingUpdates()

  Scheduler:clear()
  self.state.read_cache_started = false
end

function HardcoverApp:onResume()
  if not (self.ui.document and self.settings:syncEnabled()) then
    return
  end

  if self.settings:readSetting(SETTING.ENABLE_WIFI) then
    UIManager:scheduleIn(2, self.startReadCache, self)
  end

  if self.state.unsent_page then
    -- send progress from before the device was suspended
    self:sendUnsentPage(true)
  end
end

function HardcoverApp:updatePageNow(callback)
  local mapped_page = self.page_mapper:getMappedPage(
    self.state.page,
    self.ui.document:getPageCount(),
    self.settings:pages()
  )

  if self:queuePage(self.ui.document.file, mapped_page) then
    self:sendUnsentPage(true, true, callback)
  elseif callback then
    callback()
  end
end

function HardcoverApp:onNetworkDisconnecting()
  if self.settings:readSetting(SETTING.ENABLE_WIFI) then
    return
  end

  self:cancelPendingUpdates()

  Scheduler:clear()
  self.state.read_cache_started = false

  if self.state.unsent_page and self.ui.document and self.settings:syncEnabled() then
    self:sendUnsentPage(false, true)
  end
end

function HardcoverApp:onNetworkConnected()
  if not (self.ui.document and self.settings:syncEnabled()) then
    return
  end

  if not self.state.read_cache_started then
    self:startReadCache()
  end

  if self.state.unsent_page then
    self:sendUnsentPage(false)
  end
end

function HardcoverApp:onEndOfBook()
  local file_path = self.ui.document.file

  if not self:syncFileUpdates(file_path) then
    return
  end

  local mark_read = false
  if G_reader_settings:isTrue("end_document_auto_mark") then
    mark_read = true
  end

  if not mark_read then
    local action = G_reader_settings:readSetting("end_document_action") or "pop-up"
    mark_read = action == "mark_read"

    if action == "pop-up" then
      mark_read = 'later'
    end
  end

  if not mark_read then
    return
  end

  local marker = function()
    self.cache:updateBookStatus(file_path, HARDCOVER.STATUS.FINISHED)
  end

  if mark_read == 'later' then
    UIManager:scheduleIn(30, function()
      local status = "reading"
      if DocSettings:hasSidecarFile(file_path) then
        local summary = DocSettings:open(file_path):readSetting("summary")
        if summary and summary.status and summary.status ~= "" then
          status = summary.status
        end
      end
      if status == "complete" then
        self.wifi:withWifi(function()
          marker()
        end)
      end
    end)
  else
    self.wifi:withWifi(function()
      marker()
      self:showStatusSaveResult()
    end)
  end
end

function HardcoverApp:syncFileUpdates(filename)
  return self.settings:readBookSetting(filename, "book_id") and self.settings:fileSyncEnabled(filename)
end

function HardcoverApp:onDocSettingsItemsChanged(file, doc_settings)
  if not self:syncFileUpdates(file) or not doc_settings then
    return
  end

  local summary_status = _t.dig(doc_settings, "summary", "status")
  local status
  if summary_status == "complete" then
    status = HARDCOVER.STATUS.FINISHED
  elseif summary_status == "reading" then
    status = HARDCOVER.STATUS.READING
  end

  if status then
    self.wifi:withWifi(function()
      self.cache:updateBookStatus(file, status)

      self:showStatusSaveResult()
    end)
  end
end

function HardcoverApp:showStatusSaveResult()
  if self.state.book_status.id then
    UIManager:show(InfoMessage:new {
      text = _("Hardcover status saved"),
      timeout = 2
    })
  else
    UIManager:show(InfoMessage:new {
      text = _("Hardcover status could not be saved"),
      icon = "notice-warning",
      timeout = 2
    })
  end
end

function HardcoverApp:startReadCache()
  if self.state.read_cache_started then
    return
  end

  if not self.ui.document then
    return
  end

  self.state.read_cache_started = true

  local cancel

  local restart = function(delay)
    delay = delay or 60
    cancel()
    self.state.read_cache_started = false
    UIManager:scheduleIn(delay, self.startReadCache, self)
  end

  cancel = Scheduler:withRetries(6, 3, function(success, fail)
      Trapper:wrap(function()
        if not self.ui.document then
          -- fail, but cancel retries
          return success()
        end
        local book_settings = self.settings:readBookSettings(self.ui.document.file) or {}
        if book_settings.book_id then
          if self.state.book_status.id then
            return success()
          elseif not self.wifi:canRunWithWifi() then
            -- wifi is off and cannot be enabled automatically. Stop here, and allow
            -- onNetworkConnected to start again once a connection is available
            cancel()
            self.state.read_cache_started = false
          else
            self.wifi:withWifi(function()
              if not NetworkManager:isConnected() then
                return restart()
              end

              local err = self.cache:cacheUserBook()
              if err and err.completed == false then
                return fail(err)
              end

              success()
            end)
          end
        else
          self.hardcover:tryAutolink()
          if self.settings:bookLinked() and self.settings:syncEnabled() then
            return restart(2)
          end

          -- Not linked (yet): finish this job instead of leaving it pending.
          -- If autolinking completes later, linking the book fetches its status
          success()
        end
      end)
    end,

    nil,

    function()
      if NetworkManager:isConnected() then
        UIManager:show(Notification:new {
          text = _("Failed to fetch book information from Hardcover"),
        })
      end
    end)
end

function HardcoverApp:registerHighlight()
  -- highlights are only available in the reader, not the file manager
  if not self.ui.highlight then
    return
  end

  self.ui.highlight:removeFromHighlightDialog(HIGHLIGHT_MENU_NAME)

  if self.enabled and self.settings:bookLinked() then
    self.ui.highlight:addToHighlightDialog(HIGHLIGHT_MENU_NAME, function(this)
      return {
        text_func = function()
          return _("Hardcover quote")
        end,
        callback = function()
          local selected_text = this.selected_text
          local raw_page = selected_text.pos0.page
          if not raw_page then
            raw_page = self.view.document:getPageFromXPointer(selected_text.pos0)
          end
          -- open journal dialog
          self:onHardcoverNote({
            text = selected_text.text,
            page_number = raw_page,
            note_type = "quote"
          })

          this:onClose()
        end,
      }
    end)
  end
end

function HardcoverApp:addToMainMenu(menu_items)
  menu_items.hardcover = self.menu:mainMenu()
end

return HardcoverApp
