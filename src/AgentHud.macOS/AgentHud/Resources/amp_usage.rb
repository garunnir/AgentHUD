# frozen_string_literal: true
require_relative 'headless_browser'

module AmpUsageReader
  ORIGIN = 'https://ampcode.com'

  def self.fetch(executable, profile, origin: ORIGIN)
    result = HeadlessBrowser.with_page(executable, profile, origin + '/settings') do |browser, session, owner|
      expression = <<~JS
        (() => {
          if (location.origin !== #{JSON.generate(origin)} || !['/settings','/settings/'].includes(location.pathname)) return null;
          const bars = Array.from(document.querySelectorAll('[role="progressbar"][aria-label],progress[aria-label]'));
          function allowance(name) {
            const prefix = name + ': ';
            const matches = bars.filter(b => b.getAttribute('aria-label').startsWith(prefix));
            return matches.length === 1 ? matches[0] : null;
          }
          const agent = allowance('Agent Usage'), orb = allowance('Orb Usage');
          if (!agent || !orb) return null;
          // Walk upward from the two gauges only as far as their shared reset label.
          for (let section = agent.parentElement; section && section !== document.body; section = section.parentElement) {
            if (!section.contains(orb)) continue;
            const lines = section.innerText.split(/\\n+/).map(line => line.trim());
            const prefix = 'Agent and orb usage resets';
            const resets = lines.flatMap((line, i) => {
              if (line.startsWith(prefix + ' ')) return [line];
              if (line === prefix && lines[i + 1]) return [prefix + ' ' + lines[i + 1]];
              return [];
            });
            if (resets.length === 1 && resets[0].length < 160) return [
              'Agent Usage', agent.getAttribute('aria-label').slice('Agent Usage: '.length),
              'Orb Usage', orb.getAttribute('aria-label').slice('Orb Usage: '.length), resets[0]
            ];
          }
          return null;
        })()
      JS
      30.times do
        raise IOError unless Process.ppid == owner
        sleep 0.5
        values = browser.call('Runtime.evaluate', {expression: expression, returnByValue: true}, session).dig('result','value')
        break values if values.is_a?(Array) && values.size == 5 && values.all? { |s| s.is_a?(String) && s.bytesize < 256 }
      end
    end
    result if result.is_a?(Array)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    Signal.trap('TERM') { raise Interrupt }
    puts JSON.generate(AmpUsageReader.fetch(*ARGV))
  rescue StandardError, Interrupt
    puts 'null'
  end
end
