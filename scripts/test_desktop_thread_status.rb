require 'minitest/autorun'
require_relative '../src/AgentHud.macOS/AgentHud/Resources/desktop_thread_status'
class PollTest < Minitest::Test
  ID='T-00000000-0000-4000-8000-000000000001'
  def test_pooled_amp_state_is_bound_to_its_own_thread
    pool=[{}, {'id'=>2,'meta'=>3}, ID, {'lastKnownAgentState'=>4,'lastUserMessageAt'=>7}, {'state'=>5,'updatedAt'=>6}, 'idle','2024-11-18T03:04:05Z','2024-11-18T03:04:00Z']
    rows=DesktopThreadStatus.amp_records(pool,[ID])
    assert_equal 'completed',rows.fetch(ID).fetch(:state)
    pool[7]='2024-11-18T03:05:00Z'
    assert_empty DesktopThreadStatus.amp_records(pool,[ID])
    pool[4]={'state'=>-1,'updatedAt'=>6}
    assert_empty DesktopThreadStatus.amp_records(pool,[ID])
  end
end

class PollTest
  def test_missing_user_turn_and_other_threads_do_not_complete
    pool=[{}, {'id'=>2,'meta'=>3}, ID, {'lastKnownAgentState'=>4}, {'state'=>5,'updatedAt'=>6}, 'idle','2024-01-01T13:00:00Z']
    assert_empty DesktopThreadStatus.amp_records(pool,[ID])
    pool[3]['lastUserMessageAt']=7
    pool << ['Date','2024-01-01T12:00:00Z']
    assert_empty DesktopThreadStatus.amp_records(pool,[])
    pool[5]='working'
    assert_equal 'working',DesktopThreadStatus.amp_records(pool,[ID]).fetch(ID)[:state]
  end
end
