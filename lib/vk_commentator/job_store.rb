# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'

module VkCommentator
  # One scheduled job persisted as jobs/<id>.json (+ .messages.txt, .log, .result.json).
  class Job
    STATUSES = %w[scheduled running done partial failed dry_run missed cancelled].freeze
    ACTIVE   = %w[scheduled running].freeze

    attr_reader :id, :dir
    attr_accessor :attrs

    def initialize(id, dir, attrs)
      @id    = id
      @dir   = dir
      @attrs = attrs
    end

    %w[url group_id topic_id messages status pid chat_id method lead_ms dry_run created_at].each do |key|
      define_method(key) { attrs[key] }
    end

    def target_time  = Time.iso8601(attrs['target_time'])
    def active?      = ACTIVE.include?(status)
    def dry_run?     = !!dry_run
    def base_path    = File.join(dir, id.to_s)
    def json_path    = "#{base_path}.json"
    def messages_path = "#{base_path}.messages.txt"
    def log_path      = "#{base_path}.log"
    def result_path   = "#{base_path}.result.json"

    def result
      return nil unless File.exist?(result_path)

      JSON.parse(File.read(result_path))
    end

    def time_str = target_time.strftime('%d.%m.%y %H:%M:%S')

    def pid_alive?
      return false unless pid

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end
  end

  class JobStore
    def initialize(dir = File.join(ROOT, 'jobs'))
      @dir   = dir
      @mutex = Mutex.new
      FileUtils.mkdir_p(dir)
    end

    def create(url:, group_id:, topic_id:, target_time:, messages:, chat_id:, method: 'board', lead_ms: 0.0, dry_run: false)
      @mutex.synchronize do
        id  = next_id
        job = Job.new(id, @dir, {
          'id'          => id,
          'url'         => url,
          'group_id'    => group_id,
          'topic_id'    => topic_id,
          'target_time' => target_time.iso8601(3),
          'messages'    => messages,
          'chat_id'     => chat_id,
          'method'      => method,
          'lead_ms'     => lead_ms,
          'dry_run'     => dry_run,
          'status'      => 'scheduled',
          'pid'         => nil,
          'created_at'  => Time.now.iso8601
        })
        File.write(job.messages_path, messages.join("\n") + "\n")
        persist(job)
        job
      end
    end

    def all
      Dir[File.join(@dir, '*.json')].reject { |f| f.end_with?('.result.json') }
                                    .filter_map { |f| load(f) }
                                    .sort_by(&:id)
    end

    def active = all.select(&:active?)

    def find(id)
      path = File.join(@dir, "#{id.to_i}.json")
      File.exist?(path) ? load(path) : nil
    end

    def update(job)
      @mutex.synchronize do
        yield job.attrs if block_given?
        persist(job)
      end
      job
    end

    def delete(job)
      @mutex.synchronize do
        [job.json_path, job.messages_path, job.log_path, job.result_path].each { |p| FileUtils.rm_f(p) }
      end
    end

    private

    def load(path)
      attrs = JSON.parse(File.read(path))
      Job.new(attrs['id'], @dir, attrs)
    rescue JSON::ParserError
      nil
    end

    def persist(job)
      tmp = "#{job.json_path}.tmp"
      File.write(tmp, JSON.pretty_generate(job.attrs))
      File.rename(tmp, job.json_path)
    end

    def next_id
      ids = Dir[File.join(@dir, '*.json')].map { |f| File.basename(f, '.json').to_i }
      (ids.max || 0) + 1
    end
  end
end
