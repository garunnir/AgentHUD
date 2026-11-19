# Runs the Amp reader against a local settings page using an isolated test profile.
require 'socket'
require 'tmpdir'
require_relative '../src/AgentHud.macOS/AgentHud/Resources/amp_usage'
server = TCPServer.new('127.0.0.1', 0)
origin = "http://127.0.0.1:#{server.addr[1]}"
html = '<section><div role="progressbar" aria-label="Agent Usage: &gt;99.5% remaining"></div><div role="progressbar" aria-label="Orb Usage: 42.3% remaining"></div><p>Agent and orb usage resets<br>Dec 18, 2026, 8:28 AM</p></section>'
Thread.new do
  loop do
    socket = server.accept
    while (line = socket.gets) && line != "\r\n"; end
    socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: #{html.bytesize}\r\nConnection: close\r\n\r\n#{html}") rescue nil
    socket.close
  end
end
Dir.mktmpdir('amp-usage-test-') do |profile|
  result = AmpUsageReader.fetch('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', profile, origin: origin)
  expected = ['Agent Usage', '>99.5% remaining', 'Orb Usage', '42.3% remaining', 'Agent and orb usage resets Dec 18, 2026, 8:28 AM']
  abort 'Unexpected allowance or reset' unless result == expected
  lock = File.join(profile, 'SingletonLock')
  File.symlink("#{Socket.gethostname}-#{Process.pid}", lock)
  abort 'Live owner ignored' unless HeadlessBrowser.profile_busy?(profile)
  File.unlink(lock)
  child = Process.spawn('/usr/bin/true')
  Process.wait(child)
  File.symlink("#{Socket.gethostname}-#{child}", lock)
  abort 'Orphaned local lock blocked recovery' if HeadlessBrowser.profile_busy?(profile)
  File.unlink(lock)
  File.symlink('fixture-123', lock)
  abort 'Profile lock ignored' unless AmpUsageReader.fetch('/unused', profile, origin: origin).nil?
  puts 'Amp headless projection and profile lock verified'
end
