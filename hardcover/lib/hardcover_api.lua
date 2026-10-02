local _ = require("gettext")
local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local _t = require("hardcover/lib/table_util")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local socketutil = require("socketutil")

local Book = require("hardcover/lib/book")
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local VERSION = require("hardcover_version")

local api_url = "https://api.hardcover.app/v1/graphql"

local PLACEHOLDER_TOKEN = "your token here"

local config_loaded, config = pcall(require, "hardcover_config")
local token = config_loaded and type(config) == "table" and config.token
local has_token = type(token) == "string" and token ~= "" and token ~= PLACEHOLDER_TOKEN

if not has_token then
  logger.warn("Hardcover: API token missing. Add it to hardcover_config.lua")
end

local headers = {
  ["Content-Type"] = "application/json",
  ["User-Agent"] = T("hardcoverapp.koplugin/%1 (https://github.com/billiam/hardcoverapp.koplugin)",
    table.concat(VERSION, ".")),
  Authorization = has_token and ("Bearer " .. token) or nil
}

local HardcoverApi = {
  enabled = has_token
}

function HardcoverApi:hasToken()
  return has_token
end

local book_fragment = [[
fragment BookParts on books {
  book_id: id
  title
  release_year
  users_read_count
  pages
  book_series {
    position
    series {
      name
    }
  }
  contributions: cached_contributors
  cached_image
  user_books(where: { user_id: { _eq: $userId }}) {
    id
  }
}]]

local edition_fragment = book_fragment .. [[
fragment EditionParts on editions {
  id
  book {
    ...BookParts
  }
  cached_image
  edition_format
  language {
    code2
    language
  }
  pages
  publisher {
    name
  }
  release_date
  reading_format_id
  title
  users_count
}]]

local user_book_fragment = [[
fragment UserBookParts on user_books {
  id
  book_id
  status_id
  edition_id
  privacy_setting_id
  rating
  user_book_reads(order_by: {id: asc}) {
    id
    started_at
    finished_at
    progress_pages
    edition_id
  }
}]]

function HardcoverApi:me()
  local result = self:query([[{
    me {
      id
      account_privacy_setting_id
    }
  }]])

  if result and result.me then
    return result.me[1]
  end
  return {}
end

local loading_message

-- Requests made outside of Trapper:wrap block the UI until they complete, so display a
-- message meanwhile. It is closed after the current UI action, so that consecutive
-- requests share a single message (and e-ink refresh)
local function showLoadingMessage()
  if loading_message or coroutine.running() then
    return
  end

  loading_message = InfoMessage:new {
    text = _("Contacting Hardcover…"),
  }
  UIManager:show(loading_message)
  UIManager:forceRePaint()

  UIManager:nextTick(function()
    UIManager:close(loading_message)
    loading_message = nil
  end)
end

function HardcoverApi:query(query, parameters)
  if not NetworkManager:isConnected() or not self.enabled then
    return
  end

  showLoadingMessage()

  local completed, content

  completed, content = Trapper:dismissableRunInSubprocess(function()
    return self:_query(query, parameters)
  end, true, true)

  if completed and content then
    local code, response = string.match(content, "^([^:]*):(.*)")
    if code and string.find(code, "^%d%d%d") then
      local decoded, data = pcall(json.decode, response, json.decode.simple)
      if not decoded or type(data) ~= "table" then
        logger.warn("Hardcover: unable to parse response", code)
        return nil, { completed = false }
      end

      if data.data then
        return data.data
      elseif data.errors or data.error then
        local err = data.errors or { data.error }
        if self.on_error then
          for _, e in ipairs(err) do
            self.on_error(e)
          end
        end

        return nil, { errors = err }
      end

      return nil, { completed = false }
    else
      return nil, { completed = false }
    end
  else
    return nil, { completed = completed }
  end
end

function HardcoverApi:_query(query, parameters)
  local requestBody = {
    query = query,
    variables = parameters
  }

  local maxtime = 12
  local timeout = 6

  local sink = {}
  socketutil:set_timeout(timeout, maxtime or 30)
  local request = {
    url = api_url,
    method = "POST",
    headers = headers,
    source = ltn12.source.string(json.encode(requestBody)),
    sink = socketutil.table_sink(sink),
  }

  local _, code, _headers, _status = http.request(request)
  socketutil:reset_timeout()

  local content = table.concat(sink) -- empty or content accumulated till now
  if code == socketutil.TIMEOUT_CODE or
    code == socketutil.SSL_HANDSHAKE_CODE or
    code == socketutil.SINK_TIMEOUT_CODE
  then
    logger.warn("request interrupted:", code)
    return code .. ':'
  end

  if type(code) == "string" then
    logger.dbg("Request error", code)
  end

  if type(code) == "number" and (code < 200 or code > 299) then
    logger.dbg("Request error", code, content)
  end

  return code .. ':' .. content
end

function HardcoverApi:hydrateBooks(ids, user_id)
  if #ids == 0 then
    return {}
  end

  -- hydrate ids
  local bookQuery = [[
    query ($ids: [Int!], $userId: Int!) {
      books(where: { id: { _in: $ids }}) {
        ...BookParts
      }
    }
  ]] .. book_fragment

  local books, err = self:query(bookQuery, { ids = ids, userId = user_id })
  if not books then
    return {}, err
  end

  local list = books.books or {}

  if #list > 1 then
    local id_order = {}

    for i, v in ipairs(ids) do
      id_order[v] = i
    end

    -- sort books by original ID order
    table.sort(list, function(a, b)
      return id_order[a.book_id] < id_order[b.book_id]
    end)
  end

  return list
end

function HardcoverApi:hydrateBookFromEdition(edition_id, user_id)
  local editionSearch = [[
    query ($id: Int!, $userId: Int!) {
      editions(where: { id: { _eq: $id }}) {
        ...EditionParts
      }
    }]] .. edition_fragment

  local editions = self:query(editionSearch, { id = edition_id, userId = user_id })
  if editions and editions.editions and #editions.editions > 0 then
    return self:normalizedEdition(editions.editions[1])
  end
end

function HardcoverApi:findBookBySlug(slug, user_id)
  local slugSearch = [[
    query ($slug: String!, $userId: Int!) {
      books(where: { slug: { _eq: $slug }}) {
        ...BookParts
      }
    }]] .. book_fragment

  local books = self:query(slugSearch, { slug = slug, userId = user_id })
  if books and books.books and #books.books > 0 then
    return books.books[1]
  end
end

function HardcoverApi:findEditions(book_id, user_id)
  -- user books are fetched in the same request, to prefer editions the user has read
  local edition_search = [[
    query ($id: Int!, $userId: Int!, $audiobookFormat: Int!) {
      editions(where: { book_id: { _eq: $id }, _or: [{reading_format_id: { _is_null: true }}, {reading_format_id: { _neq: $audiobookFormat }} ]},
      order_by: { users_count: desc_nulls_last }) {
        ...EditionParts
      }
      user_books(where: { book_id: { _eq: $id }, user_id: { _eq: $userId }}) {
        edition_id
      }
    }]] .. edition_fragment

  local editions = self:query(edition_search, {
    id = book_id,
    userId = user_id,
    audiobookFormat = HARDCOVER.READING_FORMAT.AUDIOBOOK
  })
  if not editions or not editions.editions then
    return {}
  end
  local edition_list = editions.editions

  if #edition_list > 1 then
    -- prefer editions with user reads
    local read_index = {}
    for _, read in ipairs(editions.user_books or {}) do
      if read.edition_id then
        read_index[read.edition_id] = true
      end
    end

    table.sort(edition_list, function(a, b)
      -- sort by user reads
      local read_a = read_index[a.id] == true
      local read_b = read_index[b.id] == true

      if read_a ~= read_b then
        return read_a
      end

      -- then prefer ebooks
      local ebook_a = a.reading_format_id == HARDCOVER.READING_FORMAT.EBOOK
      local ebook_b = b.reading_format_id == HARDCOVER.READING_FORMAT.EBOOK

      if ebook_a ~= ebook_b then
        return ebook_a
      end

      -- then by popularity
      local users_a = tonumber(a.users_count) or 0
      local users_b = tonumber(b.users_count) or 0

      if users_a ~= users_b then
        return users_a > users_b
      end

      return a.id < b.id
    end)
  end

  return _t.map(edition_list, function(edition)
    return self:normalizedEdition(edition)
  end)
end

function HardcoverApi:search(title, author, userId, page)
  page = page or 1
  local query = [[
    query ($query: String!, $page: Int!) {
      search(query: $query, per_page: 25, page: $page, query_type: "Book") {
        ids
      }
    }]]
  local search = title .. " " .. (author or "")
  local results, err = self:query(query, { query = search, page = page })
  if err then
    return nil, err
  end

  if not results or not _t.dig(results, "search", "ids") then
    return {}
  end

  local ids = _t.map(results.search.ids, function(id) return tonumber(id) end)
  return self:hydrateBooks(ids, userId)
end

function HardcoverApi:findBookByIdentifiers(identifiers, user_id)
  local isbnKey

  if identifiers.edition_id then
    local book = self:hydrateBookFromEdition(identifiers.edition_id, user_id)
    if book then
      return book
    end
  end

  if identifiers.book_slug then
    local book = self:findBookBySlug(identifiers.book_slug, user_id)
    if book then
      return book
    end
  end

  if identifiers.isbn_13 then
    isbnKey = 'isbn_13'
  elseif identifiers.isbn_10 then
    isbnKey = 'isbn_10'
  end

  if isbnKey then
    local editionSearch = [[
      query ($isbn: String!, $userId: Int!) {
        editions(where: { ]] .. isbnKey .. [[: { _eq: $isbn }}) {
          ...EditionParts
        }
      }]] .. edition_fragment

    local editions = self:query(editionSearch, { isbn = tostring(identifiers[isbnKey]), userId = user_id })
    if editions and editions.editions and #editions.editions > 0 then
      return self:normalizedEdition(editions.editions[1])
    end
  end
end

function HardcoverApi:normalizedEdition(edition)
  local result = edition.book

  result.edition_id = edition.id
  result.edition_format = Book:editionFormatName(edition.edition_format, edition.reading_format_id)

  result.cached_image = edition.cached_image
  result.publisher = edition.publisher
  if edition.release_date then
    local year = edition.release_date:match("^(%d%d%d%d)-")
    result.release_year = year
  else
    result.release_year = nil
  end
  result.language = edition.language
  result.title = edition.title
  result.reads = edition.reads
  result.pages = edition.pages
  result.filetype = result.edition_format or "Physical Book"
  result.users_count = edition.users_count

  return result
end

function HardcoverApi:normalizeUserBookRead(user_book_read)
  local user_book = user_book_read.user_book
  if type(user_book) ~= "table" then
    return nil
  end

  user_book_read.user_book = nil
  user_book.user_book_reads = { user_book_read }
  return user_book
end

function HardcoverApi:findBooks(title, author, userId)
  if not title or string.match(title, "^%s*$") then
    return {}
  end

  title = title:gsub(":.+", ""):gsub("^%s+", ""):gsub("%s+$", "")
  return self:search(title, author, userId)
end

function HardcoverApi:getRandomToRead(user_id, limit)
  limit = limit or 10

  local read_query = [[
    query ($userId: Int!, $statusId: Int!) {
      user_books(where: { status_id: { _eq: $statusId }, user_id: { _eq: $userId }}) {
        book_id
      }
    }
  ]]
  local results, err = self:query(read_query, { userId = user_id, statusId = HARDCOVER.STATUS.TO_READ })
  if not results or not results.user_books then
    return {}, err
  end

  local ids = _t.map(results.user_books, function(result) return tonumber(result.book_id) end)
  _t.shuffle(ids)

  return self:hydrateBooks(_t.slice(ids, 1, limit), user_id)
end

function HardcoverApi:findUserBook(book_id, user_id)
  -- this may not be adequate, as (it's possible) there could be more than one read in progress? Maybe?
  local read_query = [[
    query ($id: Int!, $userId: Int!) {
      user_books(where: { book_id: { _eq: $id }, user_id: { _eq: $userId }}) {
        ...UserBookParts
      }
    }
  ]] .. user_book_fragment

  local results, err = self:query(read_query, { id = book_id, userId = user_id })
  if not results or not results.user_books then
    return nil, err
  end

  return results.user_books[1]
end

function HardcoverApi:findDefaultEdition(book_id, user_id)
  -- prefer:
  -- 1. most recent matching user read
  -- 2. a user book
  -- 3. default ebook edition
  -- 4. default physical edition
  -- 5. most read book edition
  --
  -- All candidates are fetched in a single request
  local query = [[
    query ($bookId: Int!, $userId: Int!) {
      user_books(limit: 1, where: { book_id: { _eq: $bookId}, user_id: { _eq: $userId }}) {
        edition {
          ...UserEditionParts
        }
        user_book_reads(limit: 1, order_by: {id: desc}) {
          edition {
            ...UserEditionParts
          }
        }
      }
      books_by_pk(id: $bookId) {
        default_physical_edition {
          ...UserEditionParts
        }
        default_ebook_edition {
          ...UserEditionParts
        }
      }
      editions(
        limit: 1
        where: {book_id: {_eq: $bookId}}
        order_by: {users_count: desc_nulls_last}
      ) {
        ...UserEditionParts
      }
    }

    fragment UserEditionParts on editions {
      id
      edition_format
      reading_format_id
      pages
    }
  ]]

  local results = self:query(query, { bookId = book_id, userId = user_id })
  if not results then
    return
  end

  local candidates = {
    _t.dig(results, "user_books", 1, "user_book_reads", 1, "edition"),
    _t.dig(results, "user_books", 1, "edition"),
    _t.dig(results, "books_by_pk", "default_ebook_edition"),
    _t.dig(results, "books_by_pk", "default_physical_edition"),
    _t.dig(results, "editions", 1),
  }

  -- candidates may be nil, so ipairs cannot be used
  for i = 1, 5 do
    if type(candidates[i]) == "table" then
      return candidates[i]
    end
  end
end

function HardcoverApi:createRead(user_book_id, edition_id, page, started_at)
  local query = [[
    mutation InsertUserBookRead($id: Int!, $pages: Int, $editionId: Int, $startedAt: date) {
      insert_user_book_read(user_book_id: $id, user_book_read: {
        progress_pages: $pages,
        edition_id: $editionId,
        started_at: $startedAt,
      }) {
        error
        user_book_read {
          id
          started_at
          finished_at
          edition_id
          progress_pages
          user_book {
            id
            book_id
            status_id
            edition_id
            privacy_setting_id
            rating
          }
        }
      }
    }
  ]]

  local result = self:query(query, { id = user_book_id, pages = page, editionId = edition_id, startedAt = started_at })
  local user_book_read = _t.dig(result, "insert_user_book_read", "user_book_read")
  if user_book_read then
    return self:normalizeUserBookRead(user_book_read)
  end
end

function HardcoverApi:updatePage(user_read_id, edition_id, page, started_at)
  local query = [[
    mutation UpdateBookProgress($id: Int!, $pages: Int, $editionId: Int, $startedAt: date) {
      update_user_book_read(id: $id, object: {
        progress_pages: $pages,
        edition_id: $editionId,
        started_at: $startedAt,
      }) {
        error
        user_book_read {
          id
          started_at
          finished_at
          edition_id
          progress_pages
          user_book {
            id
            book_id
            status_id
            edition_id
            privacy_setting_id
            rating
          }
        }
      }
    }
  ]]

  local result = self:query(query, { id = user_read_id, pages = page, editionId = edition_id, startedAt = started_at })
  local user_book_read = _t.dig(result, "update_user_book_read", "user_book_read")
  if user_book_read then
    return self:normalizeUserBookRead(user_book_read)
  end
end

function HardcoverApi:updateUserBook(book_id, status_id, privacy_setting_id, edition_id)
  if not privacy_setting_id then
    local me = self:me()
    privacy_setting_id = me.account_privacy_setting_id or HARDCOVER.PRIVACY.PUBLIC
  end

  local query = [[
    mutation ($object: UserBookCreateInput!) {
      insert_user_book(object: $object) {
        error
        user_book {
          ...UserBookParts
        }
      }
    }
  ]] .. user_book_fragment

  local update_args = {
    book_id = book_id,
    privacy_setting_id = privacy_setting_id,
    status_id = status_id,
    edition_id = edition_id
  }

  local result = self:query(query, { object = update_args })
  if result and result.insert_user_book then
    return result.insert_user_book.user_book
  end
end

function HardcoverApi:updateRating(user_book_id, rating)
  local query = [[
    mutation ($id: Int!, $rating: numeric) {
      update_user_book(id: $id, object: { rating: $rating }) {
        error
        user_book {
          ...UserBookParts
        }
      }
    }
  ]] .. user_book_fragment

  if rating == 0 or rating == nil then
    rating = json.util.null
  end

  local result = self:query(query, { id = user_book_id, rating = rating })
  if result and result.update_user_book then
    return result.update_user_book.user_book
  end
end

function HardcoverApi:removeRead(user_book_id)
  local query = [[
    mutation($id: Int!) {
      delete_user_book(id: $id) {
        id
      }
    }
  ]]
  local result = self:query(query, { id = user_book_id })
  if result then
    return result.delete_user_book
  end
end

function HardcoverApi:createJournalEntry(object)
  local query = [[
    mutation InsertReadingJournalEntry($object: ReadingJournalCreateType!) {
      insert_reading_journal(object: $object) {
        reading_journal {
          id
        }
      }
    }
  ]]

  local result = self:query(query, { object = object })
  return _t.dig(result, "insert_reading_journal", "reading_journal")
end

return HardcoverApi
