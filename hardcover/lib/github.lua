local http = require("socket.http")
local json = require("json")
local socketutil = require("socketutil")

local NetworkManager = require("ui/network/manager")

local VERSION = require("hardcover_version")

local RELEASE_API = "https://api.github.com/repos/billiam/hardcoverapp.koplugin/releases?per_page=1"

local Github = {}

-- Returns the newest release tag if it is newer than the installed version
function Github:newestRelease()
  if not NetworkManager:isConnected() then
    return
  end

  local responseBody = {}
  socketutil:set_timeout(5, 10)
  local _, code = http.request {
    url = RELEASE_API,
    sink = socketutil.table_sink(responseBody),
  }
  socketutil:reset_timeout()

  if code ~= 200 and code ~= 304 then
    return
  end

  local decoded, data = pcall(json.decode, table.concat(responseBody), json.decode.simple)
  if not decoded or type(data) ~= "table" or #data == 0 or type(data[1].tag_name) ~= "string" then
    return
  end

  local tag = data[1].tag_name
  local version_string = tag:gsub("^[vV]", "")
  local index = 1
  for str in string.gmatch(version_string, "([^.]+)") do
    local part = tonumber(str)
    if not part then
      -- unrecognized version format (e.g. pre-release suffix)
      return
    end

    local current = VERSION[index] or 0
    if part < current then
      return
    elseif part > current then
      return tag
    end
    index = index + 1
  end
end

return Github
