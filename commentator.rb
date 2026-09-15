#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/vk_commentator'
require 'optparse'

Thread.report_on_exception = false

def build_option_parser(options)
  OptionParser.new do |opts|
    opts.banner = <<~BANNER
      Usage: ruby commentator.rb -u <url> -t <time> -m <msg> [-m <msg> ...] [options]

      Posts one or more comments to a VK topic at exactly the specified moment.
      Each comment is fired from its own pre-warmed HTTPS connection in a dedicated
      thread, so all messages leave the machine within microseconds of each other.
      Requests are sent RTT/2 (+ --lead-ms) early so they *arrive* at VK on time.

      Required:
    BANNER

    opts.on('-u URL', '--url URL', 'VK topic URL, e.g. https://vk.com/topic-236828463_57620976') { |v| options[:url] = v }
    opts.on('-t TIME', '--time TIME', 'Target time "DD.MM.YY HH:MM:SS" (Europe/Moscow), e.g. "08.05.26 22:00:00"') { |v| options[:time] = v }
    opts.on('-m MSG', '--message MSG', 'Comment text (repeatable for multiple comments)') { |v| options[:messages] << v }
    opts.on('-f FILE', '--messages-file FILE', 'File with one message per line (alternative to -m)') { |v| options[:messages_file] = v }

    opts.separator ''
    opts.separator 'Optional:'
    opts.on('--dry-run', 'Pre-warm connections and wait, but do not actually send requests') { options[:dry_run] = true }
    opts.on('--method NAME', %w[board wall], 'API method: board (board.createComment, default) or wall (wall.createComment)') { |v| options[:method] = v.to_sym }
    opts.on('--lead-ms MS', Float, 'Extra milliseconds to fire early on top of RTT/2 (default 0; may be negative)') { |v| options[:lead_ms] = v }
    opts.on('--result FILE', 'Write structured JSON result to FILE') { |v| options[:result_path] = v }
    opts.on('--job-id ID', 'Job identifier to embed in the result (used by bot.rb)') { |v| options[:job_id] = v }
    opts.on('-h', '--help', 'Show this help') { warn opts; exit 0 }

    opts.separator ''
    opts.separator 'Environment (.env):'
    opts.separator '  VK_TOKEN  long-lived access token with `wall,groups` scope (and `offline` for indefinite TTL)'
    opts.separator ''
    opts.separator 'Examples:'
    opts.separator "  ruby commentator.rb -u 'https://vk.com/topic-236828463_57620976' \\"
    opts.separator "    -t '08.05.26 22:00:00' -m 'Hello' -m 'World'"
    opts.separator ''
    opts.separator '  ruby commentator.rb -u <url> -t <time> -f messages.txt --dry-run'
  end
end

def abort_with(parser, msg)
  warn parser
  warn ''
  abort "Error: #{msg}"
end

def parse_config!
  options = { messages: [], dry_run: false, method: :board, lead_ms: 0.0 }
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
    options[:messages].concat(File.readlines(options[:messages_file], chomp: true).reject(&:empty?))
  end
  abort_with(parser, 'at least one message is required (-m or -f).') if options[:messages].empty?

  VkCommentator::Config.build(
    url:         options[:url],
    time:        options[:time],
    messages:    options[:messages],
    token:       ENV['VK_TOKEN'].to_s,
    dry_run:     options[:dry_run],
    method:      options[:method],
    lead_ms:     options[:lead_ms],
    result_path: options[:result_path],
    job_id:      options[:job_id]
  )
rescue VkCommentator::Config::InvalidError => e
  abort "Error: #{e.message}"
end

VkCommentator::Env.load!
config  = parse_config!
summary = VkCommentator::Runner.new(config).run
exit(summary['status'] == 'failed' ? 1 : 0)
