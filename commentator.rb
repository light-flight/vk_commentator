#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'logger'

LOGGER = Logger.new($stdout)
LOGGER.formatter = proc { |severity, datetime, _, msg| "#{datetime.strftime('%H:%M:%S.%L')} [#{severity}] #{msg}\n" }

VK_API_VERSION = '5.199'
VK_API_HOST    = 'api.vk.com'

TOPIC_URL_RE = %r{vk\.com/topic-(\d+)_(\d+)}i

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

def parse_args!
  if ARGV.length < 2
    warn <<~USAGE
      Usage: ruby commentator.rb <message> <time>

      Arguments:
        message  — comment text
        time     — "DD.MM.YY HH:MM:SS", e.g. "19.03.26 19:20:00"

      Environment (.env):
        VK_TOKEN  — access token (get one at https://vkhost.github.io)
        TOPIC_URL — VK topic URL, e.g. "https://vk.com/topic-236828482_56563978"

      Example:
        ruby commentator.rb 'Hello!' '19.03.26 19:20:00'
    USAGE
    exit 1
  end

  token = ENV['VK_TOKEN']
  abort 'Error: VK_TOKEN not set. Add it to .env or export it. Get one at https://vkhost.github.io' unless token

  topic_url = ENV['TOPIC_URL']
  abort 'Error: TOPIC_URL not set. Add it to .env or export it.' unless topic_url

  match = topic_url.match(TOPIC_URL_RE)
  abort "Error: invalid TOPIC_URL. Expected format: https://vk.com/topic-GROUP_ID_TOPIC_ID" unless match

  message     = ARGV[0]
  target_time = Time.strptime(ARGV[1], '%d.%m.%y %H:%M:%S')

  abort "Error: target time #{target_time} is in the past." if target_time < Time.now - 1

  { group_id: match[1], topic_id: match[2], message:, target_time:, token: }
end

def build_form_data(config)
  {
    'group_id'     => config[:group_id],
    'topic_id'     => config[:topic_id],
    'message'      => config[:message],
    'access_token' => config[:token],
    'v'            => VK_API_VERSION
  }
end

def pre_warm_connection
  LOGGER.info "Pre-warming HTTPS connection to #{VK_API_HOST}..."
  http = Net::HTTP.new(VK_API_HOST, 443)
  http.use_ssl      = true
  http.open_timeout = 10
  http.read_timeout = 10
  http.keep_alive_timeout = 120

  cert_store = OpenSSL::X509::Store.new
  cert_store.set_default_paths
  cert_store.flags = OpenSSL::X509::V_FLAG_NO_CHECK_TIME
  http.cert_store = cert_store

  http.start
  LOGGER.info 'Connection established and TLS handshake complete.'
  http
end

def wait_until(target_time)
  remaining = target_time - Time.now
  return if remaining <= 0

  if remaining > 5
    LOGGER.info "Sleeping for #{(remaining - 5).round(1)}s (coarse wait)..."
    sleep(remaining - 5)
  end

  LOGGER.info 'Entering precision busy-wait...'
  nil until Time.now >= target_time
end

def fire!(http, form_data)
  uri = URI("https://#{VK_API_HOST}/method/board.createComment")
  request = Net::HTTP::Post.new(uri.path)
  request.set_form_data(form_data)

  fired_at = Time.now
  response = http.request(request)
  received_at = Time.now

  LOGGER.info "Request fired at:     #{fired_at.strftime('%H:%M:%S.%L')}"
  LOGGER.info "Response received at: #{received_at.strftime('%H:%M:%S.%L')}"
  LOGGER.info "Round-trip time:      #{((received_at - fired_at) * 1000).round(1)}ms"

  result = JSON.parse(response.body)

  if result['error']
    LOGGER.error "VK API Error: #{result['error']['error_msg']} (code: #{result['error']['error_code']})"
    exit 1
  else
    LOGGER.info "Comment posted successfully! comment_id=#{result.dig('response')}"
  end

  result
ensure
  http.finish rescue nil
end

def run
  load_env!
  config    = parse_args!
  form_data = build_form_data(config)

  LOGGER.info "Target: group_id=#{config[:group_id]} topic_id=#{config[:topic_id]}"
  LOGGER.info "Message: #{config[:message].inspect}"
  LOGGER.info "Scheduled for: #{config[:target_time]}"

  http = pre_warm_connection
  wait_until(config[:target_time])
  fire!(http, form_data)
end

run
