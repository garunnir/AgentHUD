# frozen_string_literal: true
require 'json'
require 'timeout'
require 'socket'

module HeadlessBrowser
  # This anonymous pipe communicates only with the browser child we started.
  class Browser
    def initialize(input, output, on_network = nil)
      @on_network = on_network
      @input, @output, @serial = input, output, 0
      @input.sync = true
      @buffer = ''.b
    end

    def close
      @input.write(JSON.generate({id: @serial + 1, method: 'Browser.close'}) + "\0")
    end

    def call(method, params = {}, session = nil)
      id = @serial += 1
      request = {id: id, method: method, params: params}
      request[:sessionId] = session if session
      @input.write(JSON.generate(request) + "\0")
      loop do
        until (index = @buffer.index("\0"))
          @buffer << @output.readpartial(8192)
          raise IOError if @buffer.bytesize > 2_097_152
        end
        message = JSON.parse(@buffer.slice!(0, index + 1).chop)
        @on_network.call(message) if @on_network && message['method'] == 'Network.responseReceived'
        next unless message['id'] == id
        raise IOError if message['error']
        return message.fetch('result')
      end
    end
  end

  # Let Chrome reclaim its orphaned local lock; never remove a lock ourselves.
  def self.profile_busy?(profile)
    owner = File.readlink(File.join(profile, 'SingletonLock'))
    match = /\A(.+)-(\d+)\z/.match(owner)
    return true unless match && match[1].casecmp(Socket.gethostname).zero? && match[2].to_i.between?(2, 2_147_483_647)
    Process.kill(0, match[2].to_i)
    true
  rescue Errno::ENOENT, Errno::ESRCH
    false
  rescue SystemCallError
    true
  end

  def self.with_page(executable, profile, page, on_network: nil)
    owner = Process.ppid
    lock = File.open(File.join(profile,'.hud-title-lock'), File::RDWR | File::CREAT, 0600)
    return {'state'=>'busy'} unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    return {'state'=>'busy'} if profile_busy?(profile)
    command_r, command_w = IO.pipe
    reply_r, reply_w = IO.pipe
    pid = Process.spawn(executable, "--user-data-dir=#{profile}", '--headless', '--remote-debugging-pipe',
                        '--window-size=1440,1000', '--disable-extensions', '--disable-background-mode', '--disable-sync', '--no-first-run',
                        '--no-default-browser-check', 'about:blank', 3=>command_r, 4=>reply_w,
                        in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
    command_r.close
    reply_w.close
    browser = Browser.new(command_w, reply_r, on_network)
    Timeout.timeout(24) do
      target = browser.call('Target.createTarget', {url:'about:blank', background:true}).fetch('targetId')
      session = browser.call('Target.attachToTarget', {targetId:target, flatten:true}).fetch('sessionId')
      browser.call('Network.enable', {}, session) if on_network
      browser.call('Page.navigate', {url:page}, session)
      yield browser, session, owner
    end
  ensure
    if pid
      begin
        Timeout.timeout(5) do
          browser.close if browser
          Process.wait(pid)
        end
      rescue IOError, SystemCallError, Timeout::Error
        begin
          Process.kill('TERM', pid)
          Timeout.timeout(3) { Process.wait(pid) }
        rescue Timeout::Error
          Process.kill('KILL', -pid) rescue nil
          Process.wait(pid) rescue nil
        rescue Errno::ESRCH, Errno::ECHILD
          Process.wait(pid) rescue nil
        end
      end
    end
    [command_r, command_w, reply_r, reply_w, lock].compact.each { |io| io.close unless io.closed? }
  end
end
