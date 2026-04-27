#!/usr/bin/env ruby
# frozen_string_literal: true

ENV['TZ'] ||= 'Europe/Moscow'

require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'logger'
require 'optparse'

$stdout.sync = true
$stderr.sync = true

LOGGER = Logger.new($stdout)
LOGGER.formatter = proc { |severity, datetime, _, msg| "#{datetime.strftime('%H:%M:%S.%L %Z')} [#{severity}] #{msg}\n" }

VK_API_VERSION = '5.199'
VK_API_HOST    = 'api.vk.com'
VK_API_PATH    = '/method/board.createComment'

TOPIC_URL_RE = %r{vk\.com/topic-(\d+)_(\d+)}i

Thread.report_on_exception = false

def load_env!
  env_path = File.join(__dir__, '.env')
  return unless File.exist?(env_path)

  File.foreach(env_path) do |line|
    line.strip!
    next if line.empty? || line.start_with?('#')

    key, value = line.split('=', 2)
    ENV[key.strip] ||= value.strip if key && value
  end
end

def build_option_parser(options)
  OptionParser.new do |opts|
    opts.banner = <<~BANNER
      Usage: ruby commentator.rb -u <url> -t <time> -m <msg> [-m <msg> ...] [options]

      Posts one or more comments to a VK topic at exactly the specified moment.
      Each comment is fired from its own pre-warmed HTTPS connection in a dedicated
      thread, so all messages leave the machine within microseconds of each other.

      Required:
    BANNER

    opts.on('-u URL', '--url URL', 'VK topic URL, e.g. https://vk.com/topic-236828463_57620976') { |v| options[:url] = v }
    opts.on('-t TIME', '--time TIME', 'Target time "DD.MM.YY HH:MM:SS", e.g. "08.05.26 22:00:00"') { |v| options[:time] = v }
    opts.on('-m MSG', '--message MSG', 'Comment text (repeatable for multiple comments)') { |v| options[:messages] << v }
    opts.on('-f FILE', '--messages-file FILE', 'File with one message per line (alternative to -m)') { |v| options[:messages_file] = v }

    opts.separator ''
    opts.separator 'Optional:'
    opts.on('--dry-run', 'Pre-warm connections and wait, but do not actually send requests') { options[:dry_run] = true }
    opts.on('-h', '--help', 'Show this help') { warn opts; exit 0 }

    opts.separator ''
    opts.separator 'Environment (.env):'
    opts.separator '  VK_TOKEN  long-lived access token with `wall` scope (and `offline` for indefinite TTL)'
    opts.separator ''
    opts.separator 'Examples:'
    opts.separator "  ruby commentator.rb -u 'https://vk.com/topic-236828463_57620976' \\"
    opts.separator "    -t '08.05.26 22:00:00' -m 'Hello' -m 'World'"
    opts.separator ''
    opts.separator '  ruby commentator.rb -u <url> -t <time> -f messages.txt --dry-run'
  end
end

def parse_args!
  options = { messages: [], dry_run: false }
  parser  = build_option_parser(options)

  begin
    parser.parse!
  rescue OptionParser::ParseError => e
    warn parser
    abort "Error: #{e.message}"
  end

  abort_with(parser, '--url is required.')  unless options[:url]
  abort_with(parser, '--time is required.') unless options[:time]

  if options[:messages_file]
    abort "Error: messages file '#{options[:messages_file]}' does not exist." unless File.exist?(options[:messages_file])
    file_msgs = File.readlines(options[:messages_file], chomp: true).reject(&:empty?)
    options[:messages].concat(file_msgs)
  end

  abort_with(parser, 'at least one message is required (-m or -f).') if options[:messages].empty?

  token = ENV['VK_TOKEN']
  abort 'Error: VK_TOKEN not set in .env or environment.' if token.nil? || token.empty?

  match = options[:url].match(TOPIC_URL_RE)
  abort "Error: invalid URL '#{options[:url]}'. Expected https://vk.com/topic-GROUP_ID_TOPIC_ID." unless match

  target_time =
    begin
      Time.strptime(options[:time], '%d.%m.%y %H:%M:%S')
    rescue ArgumentError => e
      abort "Error: invalid time '#{options[:time]}'. Expected DD.MM.YY HH:MM:SS, e.g. '08.05.26 22:00:00'. (#{e.message})"
    end

  if target_time < Time.now - 1
    abort "Error: target time #{target_time} is in the past."
  end

  {
    group_id:    match[1],
    topic_id:    match[2],
    messages:    options[:messages],
    target_time: target_time,
    token:       token,
    dry_run:     options[:dry_run]
  }
end

def abort_with(parser, msg)
  warn parser
  warn ''
  abort "Error: #{msg}"
end

def build_form_data(config, message)
  {
    'group_id'     => config[:group_id],
    'topic_id'     => config[:topic_id],
    'message'      => message,
    'access_token' => config[:token],
    'v'            => VK_API_VERSION
  }
end

def pre_warm_connection(index)
  http = Net::HTTP.new(VK_API_HOST, 443)
  http.use_ssl            = true
  http.open_timeout       = 10
  http.read_timeout       = 10
  http.keep_alive_timeout = 120

  cert_store = OpenSSL::X509::Store.new
  cert_store.set_default_paths
  cert_store.flags = OpenSSL::X509::V_FLAG_NO_CHECK_TIME
  http.cert_store = cert_store

  http.start
  LOGGER.info "[#{index}] HTTPS connection established"
  http
end

def pre_warm_connections(count)
  LOGGER.info "Pre-warming #{count} HTTPS connection(s) to #{VK_API_HOST}..."
  count.times.map { |i| pre_warm_connection(i) }
end

def build_request(form_data)
  request = Net::HTTP::Post.new(VK_API_PATH)
  request.set_form_data(form_data)
  request
end

def coarse_sleep_until(target_time, slack: 5)
  remaining = target_time - Time.now
  return if remaining <= slack

  LOGGER.info "Sleeping #{(remaining - slack).round(1)}s (coarse wait, leaving #{slack}s for busy-wait)..."
  sleep(remaining - slack)
end

def precise_busy_wait(target_time)
  nil until Time.now >= target_time
end

def fire_all!(target_time, connections, requests, dry_run:)
  LOGGER.info "Arming #{connections.length} thread(s) for precision busy-wait..."

  threads = connections.zip(requests).map.with_index do |(http, req), i|
    Thread.new do
      precise_busy_wait(target_time)
      fired_at = Time.now
      begin
        response    = dry_run ? nil : http.request(req)
        received_at = Time.now
        [i, fired_at, received_at, response, nil]
      rescue StandardError => e
        [i, fired_at, Time.now, nil, e]
      end
    end
  end

  results = threads.map(&:value)
  log_results(results, dry_run: dry_run)
  results
ensure
  connections.each { |http| http.finish rescue nil }
end

def log_results(results, dry_run:)
  results.each { |r| log_one_result(*r, dry_run: dry_run) }
end

def log_one_result(index, fired_at, received_at, response, error, dry_run:)
  fire_str = fired_at.strftime('%H:%M:%S.%L')
  rtt_ms   = ((received_at - fired_at) * 1000).round(1)

  if dry_run
    LOGGER.info "[#{index}] DRY-RUN fired_at=#{fire_str} (no request sent)"
    return
  end

  if error
    LOGGER.error "[#{index}] fired=#{fire_str} rtt=#{rtt_ms}ms NETWORK ERROR: #{error.class}: #{error.message}"
    return
  end

  result = JSON.parse(response.body)
  if result['error']
    LOGGER.error "[#{index}] fired=#{fire_str} rtt=#{rtt_ms}ms VK ERROR #{result['error']['error_code']}: #{result['error']['error_msg']}"
  else
    LOGGER.info "[#{index}] fired=#{fire_str} rtt=#{rtt_ms}ms comment_id=#{result['response']}"
  end
rescue JSON::ParserError => e
  LOGGER.error "[#{index}] fired=#{fire_str} rtt=#{rtt_ms}ms PARSE ERROR: #{e.message}; body=#{response&.body&.slice(0, 200).inspect}"
end

def mode_label(config)
  config[:dry_run] ? 'DRY-RUN' : 'LIVE'
end

def run
  load_env!
  config = parse_args!

  LOGGER.info "Target:    group_id=#{config[:group_id]} topic_id=#{config[:topic_id]}"
  LOGGER.info "Messages:  #{config[:messages].length} item(s)"
  config[:messages].each_with_index { |m, i| LOGGER.info "  [#{i}] #{m.inspect}" }
  LOGGER.info "Scheduled: #{config[:target_time].strftime('%Y-%m-%d %H:%M:%S %Z')} (now: #{Time.now.strftime('%Y-%m-%d %H:%M:%S %Z')})"
  LOGGER.info "Mode:      #{mode_label(config)}"

  connections = pre_warm_connections(config[:messages].length)
  requests    = config[:messages].map { |m| build_request(build_form_data(config, m)) }

  coarse_sleep_until(config[:target_time])
  fire_all!(config[:target_time], connections, requests, dry_run: config[:dry_run])
end

run
