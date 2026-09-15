#!/usr/bin/env ruby
# frozen_string_literal: true

# Telegram bot: schedule VK topic comments from your phone, fire from the VPS.
#
# .env:
#   VK_TOKEN=vk1.a....            user token (wall,groups,offline)
#   TELEGRAM_BOT_TOKEN=123:ABC    from @BotFather
#   TELEGRAM_USER_ID=12345678     your numeric Telegram id (@userinfobot); everyone else is ignored
#   LEAD_MS=0                     optional, default extra lead in ms (also settable via /lead)
#   VK_METHOD=board               optional, board | wall

require_relative 'lib/vk_commentator'
require_relative 'lib/vk_commentator/bot'

Thread.report_on_exception = false
VkCommentator::Env.load!

tg_token = ENV['TELEGRAM_BOT_TOKEN'].to_s
user_id  = ENV['TELEGRAM_USER_ID'].to_s
abort 'Error: TELEGRAM_BOT_TOKEN not set in .env' if tg_token.empty?
abort 'Error: TELEGRAM_USER_ID not set in .env (numeric id, see @userinfobot)' unless user_id.match?(/\A\d+\z/)
warn 'Warning: VK_TOKEN not set in .env — jobs will fail until /token is used' if ENV['VK_TOKEN'].to_s.empty?

VkCommentator::Bot.new(tg_token: tg_token, user_id: user_id).run
