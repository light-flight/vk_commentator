# frozen_string_literal: true

require 'rbconfig'

module VkCommentator
  # Spawns commentator.rb as a detached process per job, watches it finish,
  # and re-attaches / re-spawns jobs after a bot restart.
  class JobManager
    RUNNER = File.join(ROOT, 'commentator.rb')

    def initialize(store, logger: VkCommentator.logger, &on_finish)
      @store     = store
      @logger    = logger
      @on_finish = on_finish
      @watchers  = {}
    end

    def start(job)
      args = [RbConfig.ruby, RUNNER,
              '-u', job.url,
              '-t', job.time_str,
              '-f', job.messages_path,
              '--method', job.method.to_s,
              '--lead-ms', job.lead_ms.to_s,
              '--result', job.result_path,
              '--job-id', job.id.to_s]
      args << '--dry-run' if job.dry_run?

      File.write(job.log_path, '') unless File.exist?(job.log_path)
      pid = Process.spawn(*args, chdir: ROOT, out: [job.log_path, 'a'], err: [:child, :out], pgroup: true)
      @store.update(job) { |a| a['pid'] = pid; a['status'] = 'scheduled' }
      @logger.info "job ##{job.id}: spawned pid=#{pid} for #{job.time_str}"
      watch(job, own_child: true)
      job
    end

    def cancel(job)
      @watchers.delete(job.id)&.kill
      if job.pid_alive?
        begin
          Process.kill('TERM', -job.pid) # whole process group
        rescue Errno::ESRCH, Errno::EPERM
          Process.kill('TERM', job.pid) rescue nil
        end
        Process.detach(job.pid) # reap if it is our child, otherwise a no-op
      end
      @store.update(job) { |a| a['status'] = 'cancelled'; a['pid'] = nil }
    end

    # Called once on bot boot: re-attach to survivors, respawn the rest.
    def restore
      @store.active.each do |job|
        if job.pid_alive?
          @logger.info "job ##{job.id}: pid=#{job.pid} still running, re-attaching"
          watch(job, own_child: false)
        elsif job.result
          finish(job)
        elsif job.target_time > Time.now + 2
          @logger.info "job ##{job.id}: process lost, respawning"
          start(job)
        else
          @logger.warn "job ##{job.id}: missed (target #{job.time_str} in the past, no result)"
          @store.update(job) { |a| a['status'] = 'missed' }
          @on_finish&.call(job)
        end
      end
    end

    private

    def watch(job, own_child:)
      @watchers[job.id] = Thread.new do
        wait_for_exit(job.pid, own_child: own_child)
        finish(@store.find(job.id) || job)
      rescue StandardError => e
        @logger.error "job ##{job.id}: watcher crashed: #{e.class}: #{e.message}"
      ensure
        @watchers.delete(job.id)
      end
    end

    def wait_for_exit(pid, own_child:)
      if own_child
        Process.wait(pid)
      else
        sleep 1 while process_alive?(pid)
      end
    rescue Errno::ECHILD
      sleep 1 while process_alive?(pid)
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def finish(job)
      return if job.status == 'cancelled'

      result = job.result
      status = result ? result['status'] : 'failed'
      @store.update(job) { |a| a['status'] = status; a['pid'] = nil }
      @logger.info "job ##{job.id}: finished with status=#{status}"
      @on_finish&.call(job)
    end
  end
end
