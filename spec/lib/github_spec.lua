describe("Github", function()
  local Github
  local response
  local connected

  before_each(function()
    connected = true
    response = { code = 200, body = "[]", data = {} }

    package.loaded["socket.http"] = {
      request = function(request)
        request.sink(response.body)
        request.sink(nil)
        return 1, response.code
      end
    }
    package.loaded["json"] = {
      decode = setmetatable({ simple = {} }, {
        __call = function()
          if response.data == "invalid" then
            error("invalid json")
          end
          return response.data
        end
      })
    }
    package.loaded["socketutil"] = {
      set_timeout = function() end,
      reset_timeout = function() end,
      table_sink = function(t)
        return function(chunk)
          if chunk then
            table.insert(t, chunk)
          end
          return 1
        end
      end
    }
    package.loaded["ui/network/manager"] = {
      isConnected = function()
        return connected
      end
    }
    package.loaded["hardcover_version"] = { 0, 4, 0 }
    package.loaded["hardcover/lib/github"] = nil
    Github = require("hardcover/lib/github")
  end)

  after_each(function()
    for _, name in ipairs({ "socket.http", "json", "socketutil", "ui/network/manager", "hardcover_version", "hardcover/lib/github" }) do
      package.loaded[name] = nil
    end
  end)

  local release = function(tag)
    response.data = { { tag_name = tag } }
  end

  describe("newestRelease", function()
    it("returns a newer release", function()
      release("0.5.0")
      assert.are.equal("0.5.0", Github:newestRelease())
    end)

    it("returns nil for the current release", function()
      release("0.4.0")
      assert.is_nil(Github:newestRelease())
    end)

    it("returns nil for an older release", function()
      release("0.3.9")
      assert.is_nil(Github:newestRelease())
    end)

    it("supports tags with a v prefix", function()
      release("v1.0.0")
      assert.are.equal("v1.0.0", Github:newestRelease())
    end)

    it("supports tags with more version parts than the current version", function()
      release("0.4.0.1")
      assert.are.equal("0.4.0.1", Github:newestRelease())
    end)

    it("returns nil for unrecognized version formats", function()
      release("0.4.x")
      assert.is_nil(Github:newestRelease())
    end)

    it("returns nil when offline", function()
      connected = false
      release("0.5.0")
      assert.is_nil(Github:newestRelease())
    end)

    it("returns nil for unsuccessful responses", function()
      release("0.5.0")
      response.code = 500
      assert.is_nil(Github:newestRelease())
    end)

    it("returns nil for invalid responses", function()
      response.data = "invalid"
      assert.is_nil(Github:newestRelease())
    end)

    it("returns nil when there are no releases", function()
      response.data = {}
      assert.is_nil(Github:newestRelease())
    end)
  end)
end)
