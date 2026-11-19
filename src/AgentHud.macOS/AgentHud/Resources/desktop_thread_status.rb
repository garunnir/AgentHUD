# frozen_string_literal: true
require 'time'
require 'uri'
require 'base64'
require_relative 'headless_browser'

module DesktopThreadStatus
  AMP_ID = /\AT-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i
  GEMINI_ID = /\Ac_[0-9a-f]{16}\z/
  TURN_ID = /\Ar_[0-9a-f]{16}\z/
  AMP_LIST = %r{\A/_app/remote/[A-Za-z0-9_-]+/(?:listSidebarRecentThreads|listSidebarFollowedThreadsWithRowDetails)\z}
  STATES = {'working'=>'working', 'idle'=>'completed', 'awaiting_approval'=>'waitingForApproval', 'error'=>'error'}.freeze

  def self.value(pool, ref)
    pool[ref] if ref.is_a?(Integer) && ref >= 0 && ref < pool.length
  end

  def self.date(v)
    v = v.last if v.is_a?(Array) && v.length == 2 && v.first == 'Date'
    Time.iso8601(v).to_f if v.is_a?(String) && v.bytesize < 48
  rescue ArgumentError
    nil
  end

  def self.amp_records(pool, ids)
    return {} unless pool.is_a?(Array) && pool.length <= 50000
    rows = {}
    pool.each do |row|
      next unless row.is_a?(Hash)
      id = value(pool, row['id'])
      next unless ids.include?(id)
      meta = value(pool, row['meta'])
      next unless meta.is_a?(Hash)
      reported = value(pool, meta['lastKnownAgentState'])
      next unless reported.is_a?(Hash)
      state = STATES[value(pool, reported['state'])]
      at = date(value(pool, reported['updatedAt']))
      next unless state && at && at > 0 && at <= Time.now.to_f + 5
      user = value(pool, meta['lastUserMessageAt'])
      next if state == 'completed' && !date(user)
      next if user && (!date(user) || date(user) > at)
      rows[id] = {state:state, at:at}
    end
    rows
  end

  def self.amp(executable, profile, ids)
    requests = []
    observe = lambda do |message|
      if message['method'] == 'Network.responseReceived'
        p = message['params']
        response = p['response']
        u = URI.parse(response['url']) rescue nil
        if u && u.scheme == 'https' && u.host == 'ampcode.com' && u.port == 443 &&
            AMP_LIST.match?(u.path) && response['status'] == 200 && requests.length < 16
          requests << p['requestId']
        end
      end
    end
    HeadlessBrowser.with_page(executable, profile, 'https://ampcode.com/threads', on_network: observe) do |b,s,_|
      rows = {}
      12.times do
        sleep 0.45
        b.call('Runtime.evaluate', {expression:'true'}, s)
        requests.dup.each do |id|
          begin
            body = b.call('Network.getResponseBody', {requestId:id}, s)
          rescue IOError
            next
          end
          requests.delete(id)
          raw = body['base64Encoded'] ? Base64.decode64(body['body']) : body['body']
          next unless raw && raw.bytesize <= 1048576
          envelope = JSON.parse(raw)
          pool = envelope['data']
          pool = JSON.parse(pool) if pool.is_a?(String)
          amp_records(pool, ids).each { |key,v| rows[key]=v if !rows[key] || rows[key][:at] < v[:at] }
        end
        break if !rows.empty? && (ids - rows.keys).empty?
      end
      rows
    end
  end

  def self.gemini(executable, profile, turns)
    HeadlessBrowser.with_page(executable, profile, 'about:blank') do |b,s,_|
      rows = {}
      turns.each do |id,turn|
        url = 'https://gemini.google.com/app/' + id.delete_prefix('c_')
        b.call('Page.navigate', {url:url}, s)
        script = <<~JS
          (() => {
            if (location.origin !== 'https://gemini.google.com' || location.pathname !== #{JSON.generate(URI.parse(url).path)}) return null;
            const stream = [...document.querySelectorAll('user-query,model-response')];
            const m = stream[stream.length-1];
            if (m?.localName !== 'model-response' || stream[stream.length-2]?.localName !== 'user-query') return null;
            const messages = [...m.querySelectorAll('message-content[id]')];
            if (messages.length !== 1 || !messages[0].id.endsWith(#{JSON.generate(turn)})) return null;
            if (m.querySelector('[role="alert"],response-error,.response-error,.response-stopped')) return null;
            const stop = [...document.querySelectorAll('button')].some(e=>e.getClientRects().length && !e.disabled &&
              /^(stop response|stop generating|응답 중지|응답 생성 중지|대답 생성 중지)$/i.test(e.getAttribute('aria-label')||''));
            if (stop) return 'working';
            return m.querySelector('.response-footer.complete') && m.querySelector('copy-button') ? 'completed' : null;
          })()
        JS
        12.times do
          sleep 0.4
          state = b.call('Runtime.evaluate', {expression:script,returnByValue:true}, s).dig('result','value')
          if %w[working completed].include?(state)
            rows[id] = {state:state,turn:turn}
            break
          end
        end
      end
      rows
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    Signal.trap('TERM') { raise Interrupt }
    app, exe, profile = ARGV
    request = JSON.parse(STDIN.read(32768))
    raise ArgumentError unless request.is_a?(Hash)
    rows = case app
    when 'amp'
      ids = request.keys
      raise ArgumentError unless ids.size.between?(1,300) && ids.all? { |id| DesktopThreadStatus::AMP_ID.match?(id) }
      DesktopThreadStatus.amp(exe, profile, ids)
    when 'gemini'
      raise ArgumentError unless request.size.between?(1,3) && request.all? { |id,turn| DesktopThreadStatus::GEMINI_ID.match?(id) && DesktopThreadStatus::TURN_ID.match?(turn) }
      DesktopThreadStatus.gemini(exe, profile, request)
    end
    puts JSON.generate(rows.is_a?(Hash) && !rows.key?('state') ? rows : nil)
  rescue StandardError, Interrupt
    puts 'null'
  end
end
