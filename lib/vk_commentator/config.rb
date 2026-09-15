# frozen_string_literal: true

require 'time'

module VkCommentator
  # Validated, immutable description of one "fire N comments at T" job.
  class Config
    class InvalidError < Error; end

    TOPIC_URL_RE   = %r{vk\.com/topic-(\d+)_(\d+)}i
    COMMENT_URL_RE = %r{vk\.com/topic-(\d+)_(\d+)\?post=(\d+)}i
    TIME_FORMAT    = '%d.%m.%y %H:%M:%S'
    METHODS        = %i[board wall].freeze

    attr_reader :group_id, :topic_id, :messages, :target_time, :token,
                :dry_run, :method, :lead_ms, :result_path, :job_id

    def initialize(group_id:, topic_id:, messages:, target_time:, token:,
                   dry_run: false, method: :board, lead_ms: 0, result_path: nil, job_id: nil)
      @group_id    = group_id.to_s
      @topic_id    = topic_id.to_s
      @messages    = Array(messages).map(&:to_s).reject(&:empty?).freeze
      @target_time = target_time
      @token       = token.to_s
      @dry_run     = dry_run ? true : false
      @method      = method.to_sym
      @lead_ms     = lead_ms.to_f
      @result_path = result_path
      @job_id      = job_id
      validate!
    end

    # Builds a Config from raw user input (strings), raising InvalidError with a
    # human-readable message on any problem.
    def self.build(url:, time:, messages:, token:, **opts)
      group_id, topic_id = parse_topic_url(url)
      target_time        = parse_time(time)
      new(group_id: group_id, topic_id: topic_id, messages: messages,
          target_time: target_time, token: token, **opts)
    end

    def self.parse_topic_url(url)
      match = url.to_s.match(TOPIC_URL_RE)
      raise InvalidError, "invalid URL '#{url}'. Expected https://vk.com/topic-GROUP_ID_TOPIC_ID." unless match

      [match[1], match[2]]
    end

    def self.parse_comment_url(url)
      match = url.to_s.match(COMMENT_URL_RE)
      raise InvalidError, "invalid URL '#{url}'. Expected https://vk.com/topic-GROUP_TOPIC?post=N." unless match

      [match[1], match[2], match[3]]
    end

    # Time strings are always interpreted in the process TZ (Europe/Moscow by default).
    def self.parse_time(str)
      Time.strptime(str.to_s, TIME_FORMAT)
    rescue ArgumentError => e
      raise InvalidError, "invalid time '#{str}'. Expected DD.MM.YY HH:MM:SS, e.g. '08.05.26 22:00:00'. (#{e.message})"
    end

    def topic_url
      "https://vk.com/topic-#{group_id}_#{topic_id}"
    end

    def comment_url(comment_id)
      "#{topic_url}?post=#{comment_id}"
    end

    def to_h
      {
        'job_id'      => job_id,
        'group_id'    => group_id,
        'topic_id'    => topic_id,
        'messages'    => messages,
        'target_time' => target_time.iso8601(3),
        'dry_run'     => dry_run,
        'method'      => method.to_s,
        'lead_ms'     => lead_ms
      }
    end

    private

    def validate!
      raise InvalidError, 'at least one message is required.' if messages.empty?
      raise InvalidError, 'VK_TOKEN not set in .env or environment.' if token.empty?
      raise InvalidError, "unknown API method '#{method}'. Use one of: #{METHODS.join(', ')}." unless METHODS.include?(method)
      raise InvalidError, "target time #{target_time} is in the past." if target_time < Time.now - 1
    end
  end
end
