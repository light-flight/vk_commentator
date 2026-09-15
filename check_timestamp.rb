#!/usr/bin/env ruby
# frozen_string_literal: true

# Prints the server-side timestamp of a topic comment.
# Usage: ruby check_timestamp.rb 'https://vk.com/topic-GROUP_TOPIC?post=N'

require_relative 'lib/vk_commentator'

VkCommentator::Env.load!

url = ARGV[0] or abort 'Usage: ruby check_timestamp.rb "https://vk.com/topic-GROUP_TOPIC?post=N"'
token = ENV['VK_TOKEN']
abort 'Error: VK_TOKEN not set. Add it to .env or export it.' if token.nil? || token.empty?

begin
  group_id, topic_id, comment_id = VkCommentator::Config.parse_comment_url(url)
rescue VkCommentator::Config::InvalidError => e
  abort "Error: #{e.message}"
end

puts "Fetching comment ##{comment_id} from topic-#{group_id}_#{topic_id}..."

begin
  comment = VkCommentator::VkClient.new(token: token)
                                   .topic_comment(group_id: group_id, topic_id: topic_id, comment_id: comment_id)
rescue VkCommentator::Error => e
  abort "Error: #{e.message}"
end
abort "Comment ##{comment_id} not found." unless comment

time = Time.at(comment['date'])
puts
puts "Comment ##{comment_id}"
puts "  Author ID: #{comment['from_id']}"
puts "  Text:      #{comment['text']}"
puts "  Unix:      #{comment['date']}"
puts "  UTC:       #{time.utc.strftime('%Y-%m-%d %H:%M:%S UTC')}"
puts "  Local:     #{time.strftime('%Y-%m-%d %H:%M:%S %Z')}"
