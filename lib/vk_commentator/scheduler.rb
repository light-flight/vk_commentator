# frozen_string_literal: true

module VkCommentator
  # Two-phase waiting: coarse sleep in short chunks (robust to long waits and
  # clock adjustments), then a tight busy-wait for the last moments.
  module Scheduler
    PREWARM_SLACK = 30.0 # seconds before target when connections are opened (RTT probing is rate-limited)
    BUSY_SLACK    = 5.0  # seconds before fire time when busy-wait begins
    CHUNK         = 60.0 # max single sleep() duration

    module_function

    # Sleeps until `time - slack`, re-checking the wall clock every CHUNK seconds.
    def sleep_until(time, slack: 0.0)
      loop do
        remaining = time - Time.now - slack
        break if remaining <= 0

        sleep([remaining, CHUNK].min)
      end
    end

    def busy_wait_until(time)
      nil until Time.now >= time
    end
  end
end
