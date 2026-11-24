# Run with /usr/bin/ruby scripts/test_gemini_background_titles.rb on a Mac with Chrome installed.
require 'socket'
require 'tmpdir'
require_relative '../src/AgentHud.macOS/AgentHud/Resources/gemini_titles'
id = 'c_aaaaaaaaaaaaaaaa'
server = TCPServer.new('127.0.0.1',0)
origin = "http://127.0.0.1:#{server.addr[1]}"
html = '<nav aria-label="Main menu"></nav><nav><a href="/app/aaaaaaaaaaaaaaaa"><span class="conversation-title">Fixture title</span></a><a href="https://example.org/app/aaaaaaaaaaaaaaaa">Wrong host</a></nav><main><a href="/app/aaaaaaaaaaaaaaaa">Unrelated content</a></main>'
Thread.new do
  loop do
    socket = server.accept
    socket.gets
    while (line = socket.gets) && line != "\r\n"; end
    socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: #{html.bytesize}\r\nConnection: close\r\n\r\n#{html}") rescue nil
    socket.close
  end
end
Dir.mktmpdir('agenthud-hidden-fixture-') do |profile|
  result = GeminiTitleReader.fetch('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', profile, [id], page:origin+'/app', origin:origin)
  abort "Headless sidebar lookup failed: #{result['state']}" unless result == {'state'=>'ready','titles'=>{id=>'Fixture title'}}
  File.symlink('fixture-123',File.join(profile,'SingletonLock'))
  abort 'Profile lock was not respected' unless GeminiTitleReader.fetch('/unused',profile,[id]) == {'state'=>'busy'}
  puts 'Headless Chrome rendered the fixture; only the allowed sidebar title was returned; a locked profile was skipped.'
end
