# frozen_string_literal: true
require 'json'
require 'securerandom'
require 'fileutils'

module AgentHudStatus
  ROOT = File.expand_path('~/Library/Application Support/AgentHud/activity')
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  STATES = { 'UserPromptSubmit' => 'running', 'PreToolUse' => 'running', 'Stop' => 'completed', 'Interrupt' => 'interrupted', 'StopFailure' => 'failed' }.freeze
  def self.accept(payload, app:, root: ROOT, now: Time.now.to_f * 1000)
    return false unless app == 'chatGPT' && payload.is_a?(Hash)
    id = payload['session_id']; event = payload['hook_event_name']; state = STATES[event]
    return false unless id.is_a?(String) && UUID.match?(id) && state
    return false if payload['agent_id'] || payload['subagent_id']
    id = id.downcase
    turn = payload['turn_id']
    return false if app == 'chatGPT' && (!turn.is_a?(String) || turn.empty? || turn.bytesize > 150)
    return false if turn && (!turn.is_a?(String) || turn.bytesize > 150)
    FileUtils.mkdir_p(root, mode: 0o700)
    directory = File.lstat(root)
    return false unless directory.directory? && !directory.symlink? && directory.uid == Process.uid && (directory.mode & 0o077).zero?
    path = File.join(root, "#{app}-#{id}.json")
    lock = File.open(File.join(root, "#{app}-#{id}.lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
    begin
      return false unless lock.stat.file? && lock.stat.uid == Process.uid && (lock.stat.mode & 0o077).zero?
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
      until lock.flock(File::LOCK_EX | File::LOCK_NB)
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep(0.01)
      end
      previous = nil
      begin
        File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |f|
          previous = JSON.parse(f.read(4097)) if f.stat.file? && f.stat.size <= 4096 && f.stat.uid == Process.uid
        end
      rescue Errno::ENOENT, JSON::ParserError
      end
      previous = nil unless previous.is_a?(Hash) && previous['app'] == app && previous['sessionID'] == id && previous['sequence'].is_a?(Integer)
      # Late events from an older turn cannot finish or revive the current turn.
      if previous && turn && previous['turnID'] != turn && event != 'UserPromptSubmit'
        return false
      end
      if previous && previous['turnID'] == turn && %w[interrupted failed].include?(previous['state'])
        return false if %w[Stop PreToolUse UserPromptSubmit].include?(event)
      end
      if event == 'PreToolUse'
        return false unless previous && previous['state'] == 'running'
      end
      sequence = previous ? previous['sequence'] + 1 : 1
      producer = previous && previous['turnID'] == turn ? previous['producer'] : SecureRandom.uuid
      record = { version: 1, app: app, sessionID: id, state: state, producer: producer,
        eventID: SecureRandom.uuid, sequence: sequence, timestamp: now, turnID: turn,
        source: 'hook', validUntil: now + 120_000 }
      temp = File.join(root, ".#{SecureRandom.uuid}.tmp")
      begin
        File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(JSON.generate(record)) }
        File.rename(temp, path)
      ensure
        File.unlink(temp) if File.exist?(temp)
      end
      true
    ensure
      lock.close
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    data = STDIN.read(1_048_577)
    AgentHudStatus.accept(JSON.parse(data), app: ARGV.fetch(0)) if data.bytesize <= 1_048_576
  rescue StandardError
    # Status observation must never change or block the agent's behavior.
  ensure
    STDOUT.write('{}')
  end
end
