# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module VkCommentator
  # Minimal Telegram Bot API client (long polling, no gems).
  class Telegram
    HOST         = 'api.telegram.org'
    POLL_TIMEOUT = 30

    class ApiError < Error; end

    def initialize(token)
      @token = token
    end

    def get_updates(offset: nil, timeout: POLL_TIMEOUT)
      params = { 'timeout' => timeout, 'allowed_updates' => %w[message callback_query].to_json }
      params['offset'] = offset if offset
      call('getUpdates', params, read_timeout: timeout + 10)
    end

    def send_message(chat_id, text, reply_markup: nil, disable_preview: true)
      params = { 'chat_id' => chat_id, 'text' => text, 'parse_mode' => 'HTML',
                 'disable_web_page_preview' => disable_preview }
      params['reply_markup'] = reply_markup.to_json if reply_markup
      call('sendMessage', params)
    end

    def edit_message_reply_markup(chat_id, message_id, reply_markup: nil)
      params = { 'chat_id' => chat_id, 'message_id' => message_id }
      params['reply_markup'] = (reply_markup || { 'inline_keyboard' => [] }).to_json
      call('editMessageReplyMarkup', params)
    rescue ApiError
      nil # message unchanged / too old — not important
    end

    def delete_message(chat_id, message_id)
      call('deleteMessage', 'chat_id' => chat_id, 'message_id' => message_id)
    rescue ApiError
      false
    end

    def answer_callback_query(id, text: nil)
      params = { 'callback_query_id' => id }
      params['text'] = text if text
      call('answerCallbackQuery', params)
    rescue ApiError
      nil
    end

    def set_my_commands(commands)
      call('setMyCommands', 'commands' => commands.map { |c, d| { 'command' => c, 'description' => d } }.to_json)
    end

    def self.escape(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end

    private

    def call(method, params, read_timeout: 20)
      uri  = URI("https://#{HOST}/bot#{@token}/#{method}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = true
      http.open_timeout = 10
      http.read_timeout = read_timeout

      request = Net::HTTP::Post.new(uri.path)
      request.set_form_data(params)
      body = JSON.parse(http.request(request).body)
      raise ApiError, "#{method}: #{body['description']} (#{body['error_code']})" unless body['ok']

      body['result']
    rescue JSON::ParserError => e
      raise ApiError, "#{method}: bad JSON (#{e.message})"
    end
  end
end
