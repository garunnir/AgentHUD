require 'minitest/autorun'
require 'tmpdir'
require_relative 'status'
class HookStatusTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('agenthud-hook-test-')
    @id = '00000000-0000-0000-0000-000000000001'
  end
  def teardown; FileUtils.remove_entry(@root); end
  def emit(name, turn = 'turn-1', extra = {})
    AgentHudStatus.accept({ 'session_id' => @id, 'turn_id' => turn, 'hook_event_name' => name, 'prompt' => 'do not save body' }.merge(extra), app: 'chatGPT', root: @root, now: 1000)
  end
  def record; JSON.parse(File.read(File.join(@root, "chatGPT-#{@id}.json"))); end
  def test_lifecycle_and_no_body
    assert emit('UserPromptSubmit'); assert_equal 'running', record['state']
    assert emit('PreToolUse'); assert_equal 2, record['sequence']
    assert emit('Stop'); assert_equal 'completed', record['state']
    refute record.to_s.include?('do not save body')
    refute emit('PreToolUse')
  end
  def test_late_stop_and_subagent_do_not_finish_new_turn
    emit('UserPromptSubmit'); emit('UserPromptSubmit', 'turn-2')
    refute emit('Stop', 'turn-1'); assert_equal 'running', record['state']
    refute emit('Stop', 'turn-2', 'agent_id' => 'child')
    assert emit('Interrupt', 'turn-2'); assert_equal 'interrupted', record['state']
  end
  def test_late_stop_does_not_turn_interruption_into_success
    emit('UserPromptSubmit'); emit('Interrupt'); refute emit('Stop')
    assert_equal 'interrupted', record['state']
  end
  def test_terminal_retries_short_lock_contention
    emit('UserPromptSubmit')
    lock = File.open(File.join(@root, "chatGPT-#{@id}.lock"), File::RDWR)
    lock.flock(File::LOCK_EX)
    terminal = Thread.new { emit('Stop') }
    sleep(0.05); lock.close
    assert terminal.value
    assert_equal 'completed', record['state']
  end
  def test_unsafe_paths_and_invalid_source_are_rejected

    refute AgentHudStatus.accept({'session_id'=>'../bad','hook_event_name'=>'Stop'},app:'chatGPT',root:@root)
    refute AgentHudStatus.accept({},app:'other',root:@root)
    refute AgentHudStatus.accept({'session_id'=>@id,'hook_event_name'=>'UserPromptSubmit'},app:'claude',root:@root)
    File.chmod(0o777, @root); refute emit('UserPromptSubmit')
  end
end
