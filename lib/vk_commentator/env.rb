# frozen_string_literal: true

module VkCommentator
  # Minimal .env reader/writer (no gems). Format: KEY=VALUE, '#' comments.
  module Env
    DEFAULT_PATH = File.join(ROOT, '.env')

    module_function

    def read(path = DEFAULT_PATH)
      return {} unless File.exist?(path)

      File.foreach(path).each_with_object({}) do |line, acc|
        line = line.strip
        next if line.empty? || line.start_with?('#')

        key, value = line.split('=', 2)
        acc[key.strip] = value.to_s.strip if key && value
      end
    end

    # Populates ENV without overriding variables already present in the process.
    def load!(path = DEFAULT_PATH)
      read(path).each { |k, v| ENV[k] ||= v }
    end

    # Sets/replaces KEY=VALUE in the file, preserving other lines and comments.
    # Also updates the current process ENV so callers see the new value at once.
    def update!(key, value, path = DEFAULT_PATH)
      lines = File.exist?(path) ? File.readlines(path, chomp: true) : []
      replaced = false

      lines.map! do |line|
        if line.strip.start_with?("#{key}=")
          replaced = true
          "#{key}=#{value}"
        else
          line
        end
      end
      lines << "#{key}=#{value}" unless replaced

      File.write(path, lines.join("\n") + "\n")
      File.chmod(0o600, path)
      ENV[key] = value
    end
  end
end
