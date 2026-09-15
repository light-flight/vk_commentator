# frozen_string_literal: true

require 'json'
require 'fileutils'

module VkCommentator
  # Executes one Config: waits, pre-warms N connections, measures RTT,
  # fires all comments with lead compensation, verifies server-side timestamps
  # and writes a structured result file.
  class Runner
    RTT_SAMPLES  = 3
    VERIFY_DELAY = 1.5 # seconds to wait before asking VK for the comment's date

    Shot = Struct.new(:index, :message, :fired_at, :received_at, :comment_id, :error, keyword_init: true) do
      def ok?         = error.nil?
      def rtt_ms      = ((received_at - fired_at) * 1000).round(1)
      def fired_str   = fired_at.strftime('%H:%M:%S.%L')
    end

    attr_reader :config, :client, :logger, :summary

    def initialize(config, client: VkClient.new(token: config.token), logger: VkCommentator.logger)
      @config  = config
      @client  = client
      @logger  = logger
      @summary = nil
    end

    def run
      log_header
      Scheduler.sleep_until(config.target_time, slack: Scheduler::PREWARM_SLACK)

      connections = pre_warm_connections(config.messages.length)
      rtt         = measure_rtt(connections)
      fire_time   = compute_fire_time(rtt)
      requests    = build_requests

      shots = fire!(fire_time, connections, requests)
      log_shots(shots)
      server_dates = config.dry_run ? {} : verify_server_dates(shots, connections.first)

      @summary = build_summary(shots, rtt, fire_time, server_dates)
      write_result!
      @summary
    ensure
      Array(connections).each { |http| http.finish rescue nil }
    end

    private

    def log_header
      logger.info "Target:    #{config.topic_url} (group_id=#{config.group_id} topic_id=#{config.topic_id})"
      logger.info "Messages:  #{config.messages.length} item(s)"
      config.messages.each_with_index { |m, i| logger.info "  [#{i}] #{m.inspect}" }
      logger.info "Scheduled: #{config.target_time.strftime('%Y-%m-%d %H:%M:%S %Z')} (now: #{Time.now.strftime('%Y-%m-%d %H:%M:%S %Z')})"
      logger.info "Method:    #{config.method == :board ? 'board.createComment' : 'wall.createComment'}"
      logger.info "Mode:      #{config.dry_run ? 'DRY-RUN' : 'LIVE'}#{config.lead_ms.zero? ? '' : " lead_ms=#{config.lead_ms}"}"
    end

    def pre_warm_connections(count)
      logger.info "Pre-warming #{count} HTTPS connection(s) to #{VkClient::HOST}..."
      count.times.map do |i|
        http = VkClient.open_connection
        logger.info "[#{i}] HTTPS connection established"
        http
      end
    end

    # Median RTT across all connections (seconds). Also keeps the TLS sessions hot.
    def measure_rtt(connections)
      rtts = connections.each_with_index.map do |http, i|
        sleep VkClient::RATE_GAP if i.positive? # stay under VK's ~3 req/s per token
        client.measure_rtt(http, samples: RTT_SAMPLES)
      end
      rtt  = rtts.sort[rtts.length / 2]
      logger.info "RTT:       #{(rtt * 1000).round(1)}ms (median of #{RTT_SAMPLES} samples x #{connections.length} conn)"
      rtt
    rescue StandardError => e
      logger.warn "RTT measurement failed (#{e.class}: #{e.message}); firing without RTT compensation"
      0.0
    end

    # Fire early so the request *arrives* at VK at the target moment:
    # one-way latency ~ RTT/2, plus a manual correction from calibration runs.
    def compute_fire_time(rtt)
      offset = rtt / 2.0 + config.lead_ms / 1000.0
      fire_time = config.target_time - offset
      logger.info "Fire at:   #{fire_time.strftime('%H:%M:%S.%L')} (target - #{(offset * 1000).round(1)}ms)"
      fire_time
    end

    def build_requests
      config.messages.map do |message|
        client.create_comment_request(group_id: config.group_id, topic_id: config.topic_id,
                                      message: message, method: config.method)
      end
    end

    # Worker threads sit blocked on their own queue (no GVL contention) while the
    # main thread does the single precise busy-wait, then releases all of them.
    def fire!(fire_time, connections, requests)
      logger.info "Arming #{connections.length} thread(s)..."
      gates   = connections.map { Queue.new }
      threads = connections.zip(requests, gates).map.with_index do |(http, request, gate), i|
        Thread.new do
          gate.pop
          fired_at = Time.now
          begin
            response    = config.dry_run ? nil : http.request(request)
            received_at = Time.now
            Shot.new(index: i, message: config.messages[i], fired_at: fired_at, received_at: received_at,
                     comment_id: response && VkClient.parse_response(response))
          rescue StandardError => e
            Shot.new(index: i, message: config.messages[i], fired_at: fired_at, received_at: Time.now, error: e)
          end
        end
      end

      Scheduler.sleep_until(fire_time, slack: Scheduler::BUSY_SLACK)
      Scheduler.busy_wait_until(fire_time)
      gates.each { |g| g << :go }
      threads.map(&:value)
    end

    def log_shots(shots)
      shots.each do |s|
        if config.dry_run
          logger.info "[#{s.index}] DRY-RUN fired_at=#{s.fired_str} (no request sent)"
        elsif s.ok?
          logger.info "[#{s.index}] fired=#{s.fired_str} rtt=#{s.rtt_ms}ms comment_id=#{s.comment_id}"
        else
          logger.error "[#{s.index}] fired=#{s.fired_str} rtt=#{s.rtt_ms}ms #{s.error.class}: #{s.error.message}"
        end
      end
    end

    # VK exposes the comment's server-side `date` with 1s granularity; useful to
    # calibrate --lead-ms across the second boundary.
    def verify_server_dates(shots, http)
      ok = shots.select(&:ok?)
      return {} if ok.empty?

      sleep VERIFY_DELAY
      ok.each_with_object({}) do |shot, acc|
        comment = client.topic_comment(group_id: config.group_id, topic_id: config.topic_id,
                                       comment_id: shot.comment_id, http: http)
        next unless comment

        date = Time.at(comment['date'])
        acc[shot.index] = date
        logger.info "[#{shot.index}] server date=#{date.strftime('%H:%M:%S %Z')} (#{config.comment_url(shot.comment_id)})"
      rescue StandardError => e
        logger.warn "[#{shot.index}] server date check failed: #{e.class}: #{e.message}"
      end
    end

    def build_summary(shots, rtt, fire_time, server_dates)
      status =
        if config.dry_run          then 'dry_run'
        elsif shots.all?(&:ok?)    then 'done'
        elsif shots.none?(&:ok?)   then 'failed'
        else                            'partial'
        end

      {
        'job_id'      => config.job_id,
        'status'      => status,
        'method'      => config.method.to_s,
        'target_time' => config.target_time.iso8601(3),
        'fire_time'   => fire_time.iso8601(3),
        'rtt_ms'      => (rtt * 1000).round(1),
        'lead_ms'     => config.lead_ms,
        'shots'       => shots.map { |s| shot_to_h(s, server_dates[s.index]) }
      }
    end

    def shot_to_h(shot, server_date)
      h = {
        'index'       => shot.index,
        'message'     => shot.message,
        'fired_at'    => shot.fired_at.iso8601(3),
        'rtt_ms'      => shot.rtt_ms,
        'comment_id'  => shot.comment_id,
        'comment_url' => shot.comment_id && config.comment_url(shot.comment_id),
        'server_date' => server_date&.iso8601
      }
      if shot.error
        h['error'] = shot.error.message
        h['hint']  = shot.error.respond_to?(:hint) ? shot.error.hint : nil
      end
      h
    end

    def write_result!
      return unless config.result_path

      FileUtils.mkdir_p(File.dirname(config.result_path))
      File.write(config.result_path, JSON.pretty_generate(summary))
      logger.info "Result written to #{config.result_path}"
    end
  end
end
