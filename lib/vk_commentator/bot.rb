# frozen_string_literal: true

require 'open3'
require_relative 'telegram'
require_relative 'job_store'
require_relative 'job_manager'

module VkCommentator
  # Telegram front-end: one whitelisted user configures jobs from a phone,
  # the bot schedules them on the VPS and reports results back.
  class Bot
    COMMANDS = {
      'new'    => 'Запланировать комментарии',
      'list'   => 'Список заданий',
      'cancel' => 'Отменить задание: /cancel <id>',
      'dryrun' => 'Холостой прогон задания через 45с: /dryrun <id>',
      'log'    => 'Лог задания: /log <id>',
      'status' => 'Часы, NTP, пинг до VK, токен',
      'lead'   => 'Упреждение по умолчанию: /lead <ms>',
      'token'  => 'Обновить VK_TOKEN: /token vk1.a...',
      'check'  => 'Server-side время комментария: /check <url?post=N>',
      'help'   => 'Справка'
    }.freeze

    DRYRUN_DELAY = 45 # seconds; must exceed Scheduler::PREWARM_SLACK

    E = Telegram.method(:escape)

    def initialize(tg_token:, user_id:, store: JobStore.new, logger: VkCommentator.logger)
      @tg       = Telegram.new(tg_token)
      @user_id  = user_id.to_i
      @store    = store
      @logger   = logger
      @sessions = {}
      @manager  = JobManager.new(store, logger: logger) { |job| report(job) }
    end

    def run
      @logger.info "bot: starting (whitelist user_id=#{@user_id})"
      @tg.set_my_commands(COMMANDS) rescue nil
      @manager.restore
      poll_forever
    end

    private

    # ---------------------------------------------------------------- polling

    def poll_forever
      offset = nil
      loop do
        updates = @tg.get_updates(offset: offset)
        updates.each do |u|
          offset = u['update_id'] + 1
          handle_update(u)
        end
      rescue Interrupt, SignalException
        @logger.info 'bot: shutting down'
        break
      rescue StandardError => e
        @logger.error "bot: poll error #{e.class}: #{e.message}"
        sleep 5
      end
    end

    def handle_update(update)
      if (msg = update['message'])
        return deny(msg['from']) unless allowed?(msg['from'])

        handle_message(msg)
      elsif (cb = update['callback_query'])
        return @tg.answer_callback_query(cb['id'], text: 'Нет доступа') unless allowed?(cb['from'])

        handle_callback(cb)
      end
    rescue StandardError => e
      @logger.error "bot: handler error #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      chat = update.dig('message', 'chat', 'id') || update.dig('callback_query', 'message', 'chat', 'id')
      say(chat, "Ошибка: #{E[e.message]}") if chat
    end

    def allowed?(from) = from && from['id'].to_i == @user_id

    def deny(from)
      @logger.warn "bot: ignored message from user_id=#{from && from['id']} (@#{from && from['username']})"
    end

    def say(chat_id, text, **opts) = @tg.send_message(chat_id, text, **opts)

    # --------------------------------------------------------------- messages

    def handle_message(msg)
      chat_id = msg['chat']['id']
      text    = msg['text'].to_s.strip
      return if text.empty?

      if text.start_with?('/')
        cmd, arg = text[1..].split(/\s+/, 2)
        cmd = cmd.split('@').first.downcase
        return handle_command(cmd, arg.to_s.strip, msg) unless cmd == 'done'
      end

      if (session = @sessions[chat_id])
        wizard_step(chat_id, session, text)
      else
        say(chat_id, "Не понял. /new — новое задание, /help — справка.")
      end
    end

    def handle_command(cmd, arg, msg)
      chat_id = msg['chat']['id']
      case cmd
      when 'start', 'help' then cmd_help(chat_id)
      when 'new'           then cmd_new(chat_id)
      when 'list'          then cmd_list(chat_id)
      when 'cancel'        then cmd_cancel(chat_id, arg)
      when 'dryrun'        then cmd_dryrun(chat_id, arg)
      when 'log'           then cmd_log(chat_id, arg)
      when 'status'        then cmd_status(chat_id)
      when 'lead'          then cmd_lead(chat_id, arg)
      when 'token'         then cmd_token(chat_id, arg, msg)
      when 'check'         then cmd_check(chat_id, arg)
      else say(chat_id, "Неизвестная команда /#{E[cmd]}. /help")
      end
    end

    def cmd_help(chat_id)
      lines = COMMANDS.map { |c, d| "/#{c} — #{E[d]}" }
      say(chat_id, "<b>VK commentator</b>\n\n#{lines.join("\n")}\n\n" \
                   "Время всегда в МСК. Стреляю с упреждением RTT/2 + lead_ms, " \
                   "чтобы запрос пришёл на VK ровно в цель.")
    end

    # ------------------------------------------------------------------ wizard

    def cmd_new(chat_id)
      @sessions[chat_id] = { step: :url, data: { messages: [] } }
      say(chat_id, "Шаг 1/3. Пришли ссылку на обсуждение:\n<code>https://vk.com/topic-XXX_YYY</code>\n\n/cancel — прервать")
    end

    def wizard_step(chat_id, session, text)
      data = session[:data]
      case session[:step]
      when :url
        data[:group_id], data[:topic_id] = Config.parse_topic_url(text)
        data[:url] = "https://vk.com/topic-#{data[:group_id]}_#{data[:topic_id]}"
        session[:step] = :time
        say(chat_id, "Шаг 2/3. Время отправки (МСК):\n<code>DD.MM.YY HH:MM:SS</code>, " \
                     "например <code>08.05.26 22:00:00</code>\n" \
                     "Можно коротко <code>22:00:00</code> — ближайшее такое время.")
      when :time
        data[:target_time] = parse_time_input(text)
        session[:step] = :messages
        say(chat_id, "Шаг 3/3. Пришли тексты комментариев — каждая строка станет отдельным комментарием. " \
                     "Можно несколькими сообщениями. Когда закончишь — /done")
      when :messages
        if text == '/done'
          return say(chat_id, 'Пока ни одного текста. Пришли хотя бы один.') if data[:messages].empty?

          session[:step] = :confirm
          return confirm(chat_id, data)
        end
        data[:messages].concat(text.lines.map(&:strip).reject(&:empty?))
        say(chat_id, "Принято, всего #{data[:messages].length}. Ещё или /done")
      when :confirm
        say(chat_id, 'Нажми кнопку под превью или /cancel')
      end
    rescue Config::InvalidError => e
      say(chat_id, "#{E[e.message]}\nПопробуй ещё раз или /cancel")
    end

    # Accepts full 'DD.MM.YY HH:MM:SS', 'DD.MM.YY HH:MM' or bare 'HH:MM[:SS]' (next occurrence).
    def parse_time_input(text)
      text = text.strip
      text = "#{text}:00" if text.match?(/\A\d{2}\.\d{2}\.\d{2} \d{2}:\d{2}\z/) || text.match?(/\A\d{1,2}:\d{2}\z/)
      if text.match?(/\A\d{1,2}:\d{2}:\d{2}\z/)
        today = Time.now.strftime('%d.%m.%y')
        t = Config.parse_time("#{today} #{text.rjust(8, '0')}")
        t += 86_400 if t < Time.now
        return t
      end
      t = Config.parse_time(text)
      raise Config::InvalidError, "время #{text} уже прошло" if t < Time.now
      t
    end

    def confirm(chat_id, data)
      warn_dup = data[:messages].uniq.length < data[:messages].length
      preview  = data[:messages].each_with_index.map { |m, i| "#{i + 1}. #{E[m]}" }.join("\n")
      text = "<b>Проверь:</b>\n" \
             "Топик: #{data[:url]}\n" \
             "Время: <b>#{data[:target_time].strftime('%d.%m.%y %H:%M:%S')} МСК</b> (через #{human_delta(data[:target_time])})\n" \
             "Метод: #{default_method}, lead_ms: #{default_lead_ms}\n" \
             "Комментарии (#{data[:messages].length}):\n#{preview}"
      text += "\n\n⚠️ Есть одинаковые тексты — VK может ответить flood control (error 9). " \
              "Кнопка «уникализировать» добавит невидимые символы." if warn_dup

      buttons = [[{ 'text' => '🚀 Запланировать', 'callback_data' => 'confirm:live' },
                  { 'text' => '🧪 Dry-run', 'callback_data' => 'confirm:dry' }]]
      buttons << [{ 'text' => '✨ Уникализировать тексты', 'callback_data' => 'confirm:uniq' }] if warn_dup
      buttons << [{ 'text' => '✖️ Отмена', 'callback_data' => 'confirm:cancel' }]
      say(chat_id, text, reply_markup: { 'inline_keyboard' => buttons })
    end

    def handle_callback(cb)
      chat_id = cb['message']['chat']['id']
      action  = cb['data'].to_s
      @tg.answer_callback_query(cb['id'])

      unless action.start_with?('confirm:') && (session = @sessions[chat_id]) && session[:step] == :confirm
        return @tg.edit_message_reply_markup(chat_id, cb['message']['message_id'])
      end

      data = session[:data]
      case action
      when 'confirm:uniq'
        data[:messages] = uniquify(data[:messages])
        @tg.edit_message_reply_markup(chat_id, cb['message']['message_id'])
        confirm(chat_id, data)
      when 'confirm:cancel'
        @sessions.delete(chat_id)
        @tg.edit_message_reply_markup(chat_id, cb['message']['message_id'])
        say(chat_id, 'Отменено.')
      when 'confirm:live', 'confirm:dry'
        @sessions.delete(chat_id)
        @tg.edit_message_reply_markup(chat_id, cb['message']['message_id'])
        job = schedule(data, chat_id: chat_id, dry_run: action == 'confirm:dry')
        say(chat_id, "#{job.dry_run? ? '🧪 Dry-run' : '🚀 Задание'} <b>##{job.id}</b> запланировано на " \
                     "<b>#{job.time_str} МСК</b> (через #{human_delta(job.target_time)}).\n" \
                     "Отчёт пришлю сюда. /list — все задания, /cancel #{job.id} — отменить.")
      end
    end

    # Appends a distinct number of zero-width spaces to repeated texts.
    def uniquify(messages)
      seen = Hash.new(0)
      messages.map do |m|
        n = seen[m]
        seen[m] += 1
        n.zero? ? m : m + ("\u200B" * n)
      end
    end

    def schedule(data, chat_id:, dry_run:, target_time: data[:target_time], lead_ms: default_lead_ms)
      target_time = Time.at(target_time.to_i) # runner takes whole seconds
      raise Config::InvalidError, 'время уже прошло' if target_time < Time.now + 1

      job = @store.create(url: data[:url], group_id: data[:group_id], topic_id: data[:topic_id],
                          target_time: target_time, messages: data[:messages], chat_id: chat_id,
                          method: default_method, lead_ms: lead_ms, dry_run: dry_run)
      @manager.start(job)
    end

    # ---------------------------------------------------------------- commands

    def cmd_list(chat_id)
      jobs = @store.all
      return say(chat_id, 'Заданий нет. /new') if jobs.empty?

      lines = jobs.last(20).map do |j|
        badge = j.active? ? "⏳ через #{human_delta(j.target_time)}" : status_badge(j.status)
        "<b>##{j.id}</b> #{j.time_str} · #{j.messages.length} шт. · #{j.dry_run? ? 'dry · ' : ''}#{badge}\n" \
          "   #{j.url}"
      end
      say(chat_id, lines.join("\n"))
    end

    def cmd_cancel(chat_id, arg)
      if @sessions.delete(chat_id) && arg.empty?
        return say(chat_id, 'Мастер прерван.')
      end

      job = find_job(chat_id, arg) or return
      return say(chat_id, "##{job.id} уже #{status_badge(job.status)}, отменять нечего.") unless job.active?

      @manager.cancel(job)
      say(chat_id, "Задание ##{job.id} отменено.")
    end

    def cmd_dryrun(chat_id, arg)
      job = find_job(chat_id, arg) or return
      data = { url: job.url, group_id: job.group_id, topic_id: job.topic_id, messages: job.messages }
      dry = schedule(data, chat_id: chat_id, dry_run: true, target_time: Time.now + DRYRUN_DELAY, lead_ms: job.lead_ms)
      say(chat_id, "🧪 Dry-run ##{dry.id} по заданию ##{job.id} стартует через #{DRYRUN_DELAY}с: " \
                   'прогрев, замер RTT, холостой выстрел. Отчёт пришлю.')
    end

    def cmd_log(chat_id, arg)
      job = find_job(chat_id, arg) or return
      return say(chat_id, "Лога для ##{job.id} ещё нет.") unless File.exist?(job.log_path)

      tail = File.readlines(job.log_path).last(30).join
      say(chat_id, "<b>##{job.id}</b> log:\n<pre>#{E[tail.empty? ? '(пусто)' : tail]}</pre>")
    end

    def cmd_status(chat_id)
      lines = ["Время VPS: <b>#{Time.now.strftime('%d.%m.%y %H:%M:%S %Z')}</b>"]
      lines << "NTP: #{E[ntp_status]}"
      lines << vk_status
      lines << "lead_ms по умолчанию: #{default_lead_ms}, метод: #{default_method}"
      active = @store.active
      lines << "Активных заданий: #{active.length}#{active.empty? ? '' : " (#{active.map { |j| "##{j.id}" }.join(', ')})"}"
      say(chat_id, lines.join("\n"))
    end

    def cmd_lead(chat_id, arg)
      return say(chat_id, "Сейчас lead_ms = #{default_lead_ms}. Задать: /lead 7.5 (может быть отрицательным)") if arg.empty?

      value = Float(arg) rescue nil
      return say(chat_id, 'Нужно число миллисекунд, например /lead 5') unless value

      Env.update!('LEAD_MS', value.to_s)
      say(chat_id, "lead_ms = #{value}. Применится к новым заданиям.")
    end

    def cmd_token(chat_id, arg, msg)
      @tg.delete_message(chat_id, msg['message_id'])
      return say(chat_id, 'Формат: /token vk1.a.XXXX (сообщение будет удалено из чата)') unless arg.match?(/\Avk1\.a\.\S+\z/)

      user = VkClient.new(token: arg).whoami
      Env.update!('VK_TOKEN', arg)
      say(chat_id, "Токен обновлён: #{E[user['first_name']]} #{E[user['last_name']]} (id#{user['id']}). " \
                   'Применится к новым заданиям.')
    rescue VkClient::ApiError => e
      say(chat_id, "Токен не принят: #{E[e.message]}")
    end

    def cmd_check(chat_id, arg)
      group_id, topic_id, comment_id = Config.parse_comment_url(arg)
      comment = vk_client.topic_comment(group_id: group_id, topic_id: topic_id, comment_id: comment_id)
      return say(chat_id, "Комментарий ##{comment_id} не найден.") unless comment

      date = Time.at(comment['date'])
      say(chat_id, "Комментарий ##{comment_id}\nАвтор: id#{comment['from_id']}\nТекст: #{E[comment['text']]}\n" \
                   "Server date: <b>#{date.strftime('%d.%m.%y %H:%M:%S %Z')}</b> (unix #{comment['date']})")
    rescue Config::InvalidError, VkClient::ApiError => e
      say(chat_id, E[e.message])
    end

    # ------------------------------------------------------------------ report

    def report(job)
      chat_id = job.chat_id or return
      result  = job.result
      head    = "#{status_badge(job.status)} <b>##{job.id}</b> · #{job.time_str} МСК\n#{job.url}"

      unless result
        tail = File.exist?(job.log_path) ? File.readlines(job.log_path).last(8).join : ''
        return say(chat_id, "#{head}\nРезультата нет.#{tail.empty? ? '' : "\n<pre>#{E[tail]}</pre>"}")
      end

      fire = Time.iso8601(result['fire_time'])
      meta = "RTT #{result['rtt_ms']}ms · lead #{result['lead_ms']}ms · выстрел #{fire.strftime('%H:%M:%S.%L')} " \
             "(#{((fire - job.target_time) * 1000).round(1)}ms к цели)"
      shots = result['shots'].map do |s|
        fired = Time.iso8601(s['fired_at']).strftime('%H:%M:%S.%L')
        if s['error']
          "❌ [#{s['index']}] #{fired} — #{E[s['error']]}#{s['hint'] ? " (#{E[s['hint']]})" : ''}"
        elsif job.dry_run?
          "🧪 [#{s['index']}] #{fired} — не отправлено"
        else
          srv = s['server_date'] ? Time.iso8601(s['server_date']).strftime('%H:%M:%S') : '?'
          "✅ [#{s['index']}] #{fired} · rtt #{s['rtt_ms']}ms · server #{srv} · #{s['comment_url']}"
        end
      end
      say(chat_id, [head, meta, *shots].join("\n"))
    rescue StandardError => e
      @logger.error "bot: report failed for ##{job.id}: #{e.class}: #{e.message}"
    end

    # ----------------------------------------------------------------- helpers

    def find_job(chat_id, arg)
      if arg !~ /\A\d+\z/
        say(chat_id, 'Укажи номер задания, например /cancel 3. Список — /list')
        return nil
      end
      @store.find(arg) || (say(chat_id, "Задания ##{arg} нет.") && nil)
    end

    def status_badge(status)
      { 'scheduled' => '⏳ запланировано', 'running' => '🏃 выполняется', 'done' => '✅ выполнено',
        'partial' => '⚠️ частично', 'failed' => '❌ ошибка', 'dry_run' => '🧪 dry-run завершён',
        'missed' => '💀 пропущено', 'cancelled' => '✖️ отменено' }[status] || status
    end

    def human_delta(time)
      secs = (time - Time.now).round
      return 'уже' if secs <= 0

      d, r = secs.divmod(86_400)
      h, r = r.divmod(3600)
      m, s = r.divmod(60)
      parts = []
      parts << "#{d}д" if d.positive?
      parts << "#{h}ч" if h.positive?
      parts << "#{m}м" if m.positive? && d.zero?
      parts << "#{s}с" if d.zero? && h.zero?
      parts.join(' ')
    end

    def default_lead_ms = Env.read.fetch('LEAD_MS', ENV.fetch('LEAD_MS', '0')).to_f
    def default_method  = Env.read.fetch('VK_METHOD', ENV.fetch('VK_METHOD', 'board'))

    def vk_client = VkClient.new(token: Env.read.fetch('VK_TOKEN', ENV['VK_TOKEN'].to_s))

    def vk_status
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      http    = VkClient.open_connection
      client  = vk_client
      user    = client.whoami
      rtt     = client.measure_rtt(http, samples: 3)
      http.finish
      tls_ms  = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      "VK: токен ок (#{E[user['first_name']]} #{E[user['last_name']]}), RTT #{(rtt * 1000).round(1)}ms, " \
        "handshake+3 вызова #{tls_ms}ms"
    rescue StandardError => e
      "VK: ❌ #{E[e.message]}"
    end

    def ntp_status
      out, status = Open3.capture2e('chronyc', 'tracking')
      return 'chrony недоступен' unless status.success?

      offset = out[/System time\s*:\s*([^\n]+)/, 1]
      leap   = out[/Leap status\s*:\s*([^\n]+)/, 1]
      "#{offset} (#{leap})"
    rescue Errno::ENOENT
      out, status = Open3.capture2e('timedatectl', 'show', '-p', 'NTPSynchronized', '--value')
      status.success? ? "timedatectl NTPSynchronized=#{out.strip}" : 'нет chrony/timedatectl'
    end
  end
end
