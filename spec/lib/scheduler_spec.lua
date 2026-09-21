describe("Scheduler", function()
  local UIManager
  local Scheduler

  before_each(function()
    UIManager = {
      scheduled = {},
    }

    function UIManager:nextTick(fn)
      table.insert(self.scheduled, { delay = 0, fn = fn })
    end

    function UIManager:scheduleIn(delay, fn)
      table.insert(self.scheduled, { delay = delay, fn = fn })
    end

    function UIManager:unschedule(fn)
      for i = #self.scheduled, 1, -1 do
        if self.scheduled[i].fn == fn then
          table.remove(self.scheduled, i)
        end
      end
    end

    function UIManager:runNext()
      local job = table.remove(self.scheduled, 1)
      job.fn()
      return job
    end

    package.loaded["ui/uimanager"] = UIManager
    package.loaded["hardcover/lib/scheduler"] = nil
    Scheduler = require("hardcover/lib/scheduler")
  end)

  after_each(function()
    package.loaded["ui/uimanager"] = nil
    package.loaded["hardcover/lib/scheduler"] = nil
  end)

  local count = function(t)
    local n = 0
    for _ in pairs(t) do
      n = n + 1
    end
    return n
  end

  describe("withRetries", function()
    it("runs the callback on the next tick", function()
      local calls = 0
      Scheduler:withRetries(3, 2, function()
        calls = calls + 1
      end)

      assert.are.equal(0, calls)
      UIManager:runNext()
      assert.are.equal(1, calls)
    end)

    it("calls the success callback and stops tracking the job on success", function()
      local succeeded = false
      Scheduler:withRetries(3, 2, function(success)
        success()
      end, function()
        succeeded = true
      end)

      assert.are.equal(1, count(Scheduler.retries))
      UIManager:runNext()

      assert.is_true(succeeded)
      assert.are.equal(0, count(Scheduler.retries))
    end)

    it("retries with exponential backoff on failure", function()
      Scheduler:withRetries(3, 2, function(_, fail)
        fail()
      end)

      UIManager:runNext()
      local retry = UIManager:runNext()
      assert.are.equal(8, retry.delay)

      retry = UIManager.scheduled[1]
      assert.are.equal(16, retry.delay)
    end)

    it("calls the fail callback once the retry limit is reached", function()
      local failed = false
      Scheduler:withRetries(2, 2, function(_, fail)
        fail()
      end, nil, function()
        failed = true
      end)

      UIManager:runNext()
      assert.is_false(failed)
      UIManager:runNext()
      assert.is_true(failed)
      assert.are.equal(0, #UIManager.scheduled)
      assert.are.equal(0, count(Scheduler.retries))
    end)

    it("does not run callbacks after being cancelled", function()
      local succeeded = false
      local success_fn
      local cancel = Scheduler:withRetries(3, 2, function(success)
        success_fn = success
      end, function()
        succeeded = true
      end)

      UIManager:runNext()
      cancel()
      success_fn()

      assert.is_false(succeeded)
      assert.are.equal(0, count(Scheduler.retries))
    end)
  end)

  describe("clear", function()
    it("cancels pending jobs and retries", function()
      local calls = 0
      Scheduler:withRetries(3, 2, function(_, fail)
        calls = calls + 1
        fail()
      end)
      Scheduler:withRetries(3, 2, function()
        calls = calls + 1
      end)

      -- first job fails, scheduling a retry
      UIManager:runNext()
      assert.are.equal(1, calls)
      assert.are.equal(2, #UIManager.scheduled)

      Scheduler:clear()

      assert.are.equal(0, #UIManager.scheduled)
      assert.are.equal(0, count(Scheduler.retries))
    end)

    it("ignores results of jobs still running when cleared", function()
      local succeeded = false
      local success_fn
      Scheduler:withRetries(3, 2, function(success)
        success_fn = success
      end, function()
        succeeded = true
      end)

      UIManager:runNext()
      Scheduler:clear()
      success_fn()

      assert.is_false(succeeded)
    end)
  end)
end)
