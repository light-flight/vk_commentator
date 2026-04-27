#!/usr/bin/env ruby
# frozen_string_literal: true

# Debug probe: figures out which VK API method to use for posting topic comments
# after `board.createComment` started returning ERROR 3 ("Unknown method passed").
#
# Sends deliberately-broken params (group_id=1, topic_id=1, no message) so VK
# returns ERROR 100 if the method exists, ERROR 3 if it doesn't. **No real
# comments get posted.** Run locally (api round-trip latency doesn't matter).
#
#   ruby probe_vk_methods.rb
#
# Writes NDJSON to .cursor/debug-4c97ea.log + prints to stdout.

ENV['TZ'] ||= 'Europe/Moscow'

require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'fileutils'

# #region agent log
LOG_PATH   = File.expand_path('.cursor/debug-4c97ea.log', __dir__)
SESSION_ID = '4c97ea'
RUN_ID     = "probe-#{Time.now.strftime('%H%M%S')}"

FileUtils.mkdir_p(File.dirname(LOG_PATH))

def log_event(hypothesis_id, location, message, data)
  entry = {
    sessionId:    SESSION_ID,
    runId:        RUN_ID,
    hypothesisId: hypothesis_id,
    timestamp:    (Time.now.to_f * 1000).to_i,
    location:     location,
    message:      message,
    data:         data
  }
  begin
    File.open(LOG_PATH, 'a') { |f| f.puts JSON.generate(entry) }
  rescue StandardError => e
    warn "log_event failed: #{e.message}"
  end
  puts "#{Time.now.strftime('%H:%M:%S.%L')} [#{hypothesis_id}] #{message}"
  puts "  http=#{data[:http]} body=#{data[:body].inspect}"
end
# #endregion

def load_env!
  path = File.expand_path('.env', __dir__)
  return unless File.exist?(path)
  File.foreach(path) do |line|
    line.strip!
    next if line.empty? || line.start_with?('#')
    k, v = line.split('=', 2)
    ENV[k.strip] ||= v.strip if k && v
  end
end

def vk_call(host, path, params)
  uri = URI("https://#{host}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE # probe only — we trust VK by IP/host
  http.open_timeout = 10
  http.read_timeout = 10
  req = Net::HTTP::Post.new(uri.request_uri)
  req.set_form_data(params)
  res = http.request(req)
  [res.code, res.body]
rescue StandardError => e
  ['NETWORK_ERROR', "#{e.class}: #{e.message}"]
end

load_env!
token = ENV['VK_TOKEN']
abort 'VK_TOKEN not set' if token.nil? || token.empty?

# Real group/topic from the user's run (236828463 / 57620976) so probe params
# are at least syntactically plausible — but no `message`, so even if method
# exists, request fails with ERROR 100, not posting anything.
group_id = '236828463'
topic_id = '57620976'

base = { 'group_id' => group_id, 'topic_id' => topic_id, 'access_token' => token }

# H5: baseline — known-good method, proves token / network OK
code, body = vk_call('api.vk.com', '/method/users.get', { 'access_token' => token, 'v' => '5.199' })
log_event('H5', 'probe:users.get@api.vk.com', 'baseline auth/network check', { http: code, body: body[0, 400] })

# H1: current method name (what commentator.rb uses)
code, body = vk_call('api.vk.com', '/method/board.createComment', base.merge('v' => '5.199'))
log_event('H1', 'probe:board.createComment@api.vk.com v=5.199', 'current method, current version', { http: code, body: body[0, 400] })

# H2: alleged rename back to addComment
code, body = vk_call('api.vk.com', '/method/board.addComment', base.merge('v' => '5.199'))
log_event('H2', 'probe:board.addComment@api.vk.com v=5.199', 'alleged rename board.addComment', { http: code, body: body[0, 400] })

# H3: older API version with current method
code, body = vk_call('api.vk.com', '/method/board.createComment', base.merge('v' => '5.131'))
log_event('H3', 'probe:board.createComment@api.vk.com v=5.131', 'current method, older API version', { http: code, body: body[0, 400] })

# H4: topics namespace
code, body = vk_call('api.vk.com', '/method/topics.createComment', base.merge('v' => '5.199'))
log_event('H4', 'probe:topics.createComment@api.vk.com v=5.199', 'alt namespace topics.*', { http: code, body: body[0, 400] })

# --- Round 2 ---

# H6a: read method board.getComments (v=5.199)
code, body = vk_call('api.vk.com', '/method/board.getComments', base.merge('v' => '5.199', 'count' => '1'))
log_event('H6a', 'probe:board.getComments@api.vk.com', 'is board.* read still alive?', { http: code, body: body[0, 400] })

# H6b: board.getTopics
code, body = vk_call('api.vk.com', '/method/board.getTopics',
                     { 'group_id' => group_id, 'access_token' => token, 'v' => '5.199', 'count' => '1' })
log_event('H6b', 'probe:board.getTopics@api.vk.com', 'is board.* read still alive?', { http: code, body: body[0, 400] })

# H7: wall.createComment with owner_id=-group_id, post_id=topic_id
code, body = vk_call('api.vk.com', '/method/wall.createComment',
                     { 'owner_id' => "-#{group_id}", 'post_id' => topic_id, 'access_token' => token, 'v' => '5.199' })
log_event('H7', 'probe:wall.createComment@api.vk.com', 'topic via wall.createComment', { http: code, body: body[0, 400] })

# H8a: discussions.createComment (speculative)
code, body = vk_call('api.vk.com', '/method/discussions.createComment', base.merge('v' => '5.199'))
log_event('H8a', 'probe:discussions.createComment', 'speculative discussions namespace', { http: code, body: body[0, 400] })

# H8b: messages.send to topic — irrelevant API but quick to rule out
code, body = vk_call('api.vk.com', '/method/topics.addComment', base.merge('v' => '5.199'))
log_event('H8b', 'probe:topics.addComment', 'topics + addComment combo', { http: code, body: body[0, 400] })

# H9: api.vk.ru host
code, body = vk_call('api.vk.ru', '/method/board.createComment', base.merge('v' => '5.199'))
log_event('H9a', 'probe:board.createComment@api.vk.ru', 'host migration to api.vk.ru', { http: code, body: body[0, 400] })

code, body = vk_call('api.vk.ru', '/method/users.get', { 'access_token' => token, 'v' => '5.199' })
log_event('H9b', 'probe:users.get@api.vk.ru', 'host migration sanity', { http: code, body: body[0, 400] })

puts
puts "Done. Log: #{LOG_PATH}"
puts 'Decoder:'
puts '  ERROR 3   → метод не существует под таким именем/версией'
puts '  ERROR 100 → метод СУЩЕСТВУЕТ, просто параметры кривые (это нам и надо!)'
puts '  ERROR 15  → метод существует, но токен без прав (тоже валидный сигнал что метод жив)'
puts '  ERROR 5   → токен невалидный (если упадёт users.get — токен мёртв)'
