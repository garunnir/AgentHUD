# frozen_string_literal: true
require 'json'
require_relative 'headless_browser'

module GeminiTitleReader
  HOME_PAGE = 'https://gemini.google.com/app'

  def self.expression(ids, origin)
    <<~JS
      (() => {
        if (location.origin !== #{JSON.generate(origin)} ||
            !/^\\/(?:u\\/\\d+\\/)?app\\/?$/.test(location.pathname))
          return {state: location.hostname === 'accounts.google.com' ? 'signin' : 'loading'};
        const wanted = new Set(#{JSON.generate(ids)}), titles = {}, conflicts = new Set();
        const menus = document.querySelectorAll('side-navigation-v2, conversations-list, [aria-label="측면 탐색 메뉴"], [aria-label="Side navigation menu"], nav, [role="navigation"]');
        if (!menus.length) return {state:'loading'};
        let seen = 0;
        const links = new Set(Array.from(menus).flatMap(menu => Array.from(menu.querySelectorAll('a[href]'))));
        for (const a of Array.from(links).slice(0, 500)) {
          const u = new URL(a.href), m = /^\\/(?:u\\/\\d+\\/)?app\\/([0-9a-f]{16})\\/?$/.exec(u.pathname);
          if (u.origin !== location.origin || !m || u.search || u.hash) continue;
          seen++;
          const id = 'c_' + m[1];
          if (!wanted.has(id)) continue;
          const label = (a.querySelector('.conversation-title')?.textContent || a.getAttribute('aria-label') || a.innerText || '').trim();
          if (!label || label.length > 512) continue;
          if (titles[id] && titles[id] !== label) conflicts.add(id);
          titles[id] = label;
        }
        for (const id of conflicts) delete titles[id];
        return {state: seen ? 'ready' : 'loading', titles};
      })()
    JS
  end

  def self.fetch(executable, profile, ids, page: HOME_PAGE, origin: 'https://gemini.google.com')
    HeadlessBrowser.with_page(executable, profile, page) do |browser, session, owner|
      script = expression(ids, origin)
      best = {}
      30.times do
        raise IOError unless Process.ppid == owner
        sleep 0.5
        result = browser.call('Runtime.evaluate', {expression:script, returnByValue:true}, session).dig('result','value')
        next unless result.is_a?(Hash)
        return result if result['state'] == 'signin'
        if result['state'] == 'ready'
          best = result.fetch('titles', {})
          return result if (ids - best.keys).empty?
        end
      end
      return {'state'=>best.empty? ? 'unavailable' : 'ready','titles'=>best}
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    Signal.trap('TERM') { raise Interrupt }
    executable, profile = ARGV
    ids = JSON.parse(STDIN.read(8192))
    raise ArgumentError unless ids.is_a?(Array) && ids.size.between?(1,300) && ids.all? { |id| /\Ac_[0-9a-f]{16}\z/.match?(id) }
    puts JSON.generate(GeminiTitleReader.fetch(executable, profile, ids))
  rescue StandardError, Interrupt
    puts '{"state":"unavailable"}'
  end
end
