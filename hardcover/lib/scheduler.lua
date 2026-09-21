local UIManager = require("ui/uimanager")

local Scheduler = {
  -- scheduled job -> cancel function, for every job which has not yet finished
  retries = {}
}

function Scheduler:clear()
  for _, cancel in pairs(self.retries) do
    cancel()
  end
end

function Scheduler:withRetries(limit, time_exponent, callback, success_callback, fail_callback)
  time_exponent = time_exponent or 2

  local scheduled_job
  local cancelled = false

  local tries = 0

  local cancel = function()
    cancelled = true
    UIManager:unschedule(scheduled_job)
    self.retries[scheduled_job] = nil
  end

  local success = function()
    if cancelled then
      return
    end

    self.retries[scheduled_job] = nil
    if success_callback then
      success_callback()
    end
  end

  local fail = function()
    if cancelled then
      return
    end

    tries = tries + 1

    if tries < limit then
      UIManager:scheduleIn(2 ^ (time_exponent + tries), scheduled_job)
    else
      self.retries[scheduled_job] = nil
      if fail_callback then
        fail_callback()
      end
    end
  end

  scheduled_job = function()
    if cancelled then
      return
    end

    callback(success, fail)
  end

  self.retries[scheduled_job] = cancel

  UIManager:nextTick(scheduled_job)

  return cancel
end

return Scheduler
