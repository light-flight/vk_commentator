#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'time'

VK_API_VERSION = '5.199'

TOPIC_COMMENT_RE = %r{vk\.com/topic-(\d+)_(\d+)\?post=(\d+)}i

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

def vk_http
  http = Net::HTTP.new('api.vk.com', 443)
  http.use_ssl = true
  cert_store = OpenSSL::X509::Store.new
  cert_store.set_default_paths
  cert_store.flags = OpenSSL::X509::V_FLAG_NO_CHECK_TIME
  http.cert_store = cert_store
  http
end

def fetch_comment(group_id:, topic_id:, comment_id:, token:)
  uri = URI('https://api.vk.com/method/board.getComments')
  params = {
    'group_id'         => group_id,
    'topic_id'         => topic_id,
    'start_comment_id' => comment_id,
    'count'            => '1',
    'access_token'     => token,
    'v'                => VK_API_VERSION
  }
  uri.query = URI.encode_www_form(params)

  response = vk_http.request(Net::HTTP::Get.new(uri))
  result = JSON.parse(response.body)

  if result['error']
    abort "VK API Error: #{result['error']['error_msg']} (code: #{result['error']['error_code']})"
  end

  items = result.dig('response', 'items') || []
  comment = items.find { |c| c['id'].to_s == comment_id.to_s }
  abort "Comment ##{comment_id} not found." unless comment

  comment
end

load_env!

url = ARGV[0] || "#{ENV['TOPIC_URL']}?post=17"
match = url.match(TOPIC_COMMENT_RE)
abort "Error: invalid URL. Expected: https://vk.com/topic-GROUP_TOPIC?post=N" unless match

group_id, topic_id, comment_id = match[1], match[2], match[3]
token = ENV['VK_TOKEN']
abort 'Error: VK_TOKEN not set. Add it to .env or export it.' unless token

puts "Fetching comment ##{comment_id} from topic-#{group_id}_#{topic_id}..."

comment = fetch_comment(group_id:, topic_id:, comment_id:, token:)
timestamp = comment['date']
time = Time.at(timestamp)

puts
puts "Comment ##{comment_id}"
puts "  Author ID: #{comment['from_id']}"
puts "  Text:      #{comment['text']}"
puts "  Unix:      #{timestamp}"
puts "  UTC:       #{time.utc.strftime('%Y-%m-%d %H:%M:%S.%L UTC')}"
puts "  Local:     #{time.strftime('%Y-%m-%d %H:%M:%S.%L %Z')}"
