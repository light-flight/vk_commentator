# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'json'
require 'securerandom'

module VkCommentator
  # Thin VK API client over Net::HTTP (no gems). Knows how to open pre-warmed
  # keep-alive connections and build/parse API calls.
  class VkClient
    HOST    = 'api.vk.com'
    PORT    = 443
    VERSION = '5.199'

    class ApiError < Error
      attr_reader :code

      def initialize(code, message)
        @code = code.to_i
        super("VK ERROR #{code}: #{message}")
      end

      def hint
        case code
        when 5  then 'токен протух/отозван — перевыпусти и обнови через /token'
        when 6  then 'слишком много запросов в секунду'
        when 9  then 'flood control — сделай тексты уникальнее'
        when 15 then 'нет доступа к методу для этого токена — попробуй другой --method'
        when 17 then 'нужна валидация аккаунта в браузере'
        when 100 then 'неверные параметры (проверь URL топика)'
        when 214 then 'комментарии в топике закрыты'
        end
      end
    end

    attr_reader :token

    def initialize(token:)
      @token = token
    end

    # Opens a TCP+TLS connection and keeps it alive for reuse.
    def self.open_connection(keep_alive: 120)
      http = Net::HTTP.new(HOST, PORT)
      http.use_ssl            = true
      http.open_timeout       = 10
      http.read_timeout       = 10
      http.keep_alive_timeout = keep_alive

      cert_store = OpenSSL::X509::Store.new
      cert_store.set_default_paths
      cert_store.flags = OpenSSL::X509::V_FLAG_NO_CHECK_TIME
      http.cert_store = cert_store

      http.start
      http
    end

    def build_request(method, params)
      request = Net::HTTP::Post.new("/method/#{method}")
      request.set_form_data(params.merge('access_token' => token, 'v' => VERSION))
      request
    end

    # Performs a call on the given (or a fresh) connection and returns the
    # 'response' payload. Raises ApiError on VK-side errors.
    def call(method, params = {}, http: nil)
      request  = build_request(method, params)
      response = http ? http.request(request) : self.class.open_connection.request(request)
      self.class.parse_response(response)
    end

    def self.parse_response(response)
      body = JSON.parse(response.body)
      raise ApiError.new(body['error']['error_code'], body['error']['error_msg']) if body['error']

      body['response']
    rescue JSON::ParserError => e
      raise Error, "unparseable VK response: #{e.message}; body=#{response.body.to_s[0, 200].inspect}"
    end

    # Round-trip time (seconds) of a lightweight API call on this connection.
    # Uses the median of several samples to smooth out jitter.
    def measure_rtt(http, samples: 5)
      rtts = Array.new(samples) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        call('utils.getServerTime', {}, http: http)
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end
      median(rtts)
    end

    def create_comment_request(group_id:, topic_id:, message:, method: :board, guid: SecureRandom.hex(8))
      params =
        case method.to_sym
        when :board
          { 'group_id' => group_id, 'topic_id' => topic_id, 'message' => message, 'guid' => guid }
        when :wall
          { 'owner_id' => "-#{group_id}", 'post_id' => topic_id, 'message' => message, 'guid' => guid }
        else
          raise Error, "unknown method #{method}"
        end
      build_request(method.to_sym == :board ? 'board.createComment' : 'wall.createComment', params)
    end

    def topic_comment(group_id:, topic_id:, comment_id:, http: nil)
      response = call('board.getComments',
                      { 'group_id' => group_id, 'topic_id' => topic_id,
                        'start_comment_id' => comment_id, 'count' => '1' },
                      http: http)
      items = response['items'] || []
      items.find { |c| c['id'].to_s == comment_id.to_s }
    end

    def server_time
      Time.at(call('utils.getServerTime').to_i)
    end

    def whoami
      call('users.get').first
    end

    private

    def median(values)
      sorted = values.sort
      mid = sorted.length / 2
      sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end
  end
end
