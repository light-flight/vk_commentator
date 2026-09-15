# frozen_string_literal: true

# All times in this project are interpreted as Moscow time unless TZ is set
# explicitly. This must run before any Time.now / strptime call.
ENV['TZ'] ||= 'Europe/Moscow'

require 'logger'

module VkCommentator
  ROOT = File.expand_path('..', __dir__)

  class Error < StandardError; end

  class << self
    attr_writer :logger

    def logger
      @logger ||= build_logger($stdout)
    end

    def build_logger(io)
      io.sync = true if io.respond_to?(:sync=)
      logger = Logger.new(io)
      logger.formatter = proc { |severity, datetime, _, msg| "#{datetime.strftime('%H:%M:%S.%L %Z')} [#{severity}] #{msg}\n" }
      logger
    end
  end
end

require_relative 'vk_commentator/env'
require_relative 'vk_commentator/config'
require_relative 'vk_commentator/vk_client'
require_relative 'vk_commentator/scheduler'
require_relative 'vk_commentator/runner'
