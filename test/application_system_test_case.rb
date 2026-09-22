require "test_helper"
require "capybara/rails"
# Ferrum sleeps 100ms after EVERY click (FERRUM_CLICK_WAIT, read when the gem
# loads, so it would have to be set above this require). ~750 clicks a run
# makes that over a minute of a serial pass, but lowering it to 30ms exposed a
# one-shot read after a click in CardModalTest on a loaded runner, and there
# are more such reads than can be audited in one pass. Left at the default
# until they are; the gain is about fifteen seconds of wall time at four
# workers.
require "capybara/cuprite"
require "tailwindcss/commands"

# The browser renders the COMPILED app/assets/builds/tailwind.css, and nothing
# on the way here rebuilds it: `bin/rails test:system` passes a path argument,
# and any path argument skips test:prepare (railties' test_command.rb) — and
# this app leaves rails/test_unit/railtie off, so there is no test:prepare to
# skip. Only db:test:prepare builds it, which CI runs and a local gate does not.
# Pull, rebase or switch branches across a CSS commit and the browser kept
# rendering the build from before it: 2026-08-14 a stale build made a passing
# fan-arc test look like a geometry bug in someone else's commit; 2026-09-12 it
# failed a locked-feed test twice in the gate run that added this.
#
# So build it here: once per run, in the parent before the workers fork, with
# the gem's own command — no second Rails boot, well under a second, and an
# unchanged stylesheet is rewritten byte-identical. A build failure fails the
# run loudly instead of testing whatever was on disk.
system(*Tailwindcss::Commands.compile_command, exception: true) unless ENV["SKIP_TAILWIND_BUILD"]

# Per-test wall time, one CSV line per test (seconds, class, test — seconds
# first because test names contain commas) — so the next slow test is found by
# `sort -rn tmp/system_timings.csv | head` rather than by inference. Started
# afresh here, in the parent before the workers fork, so it holds one run.
SYSTEM_TIMINGS = Rails.root.join("tmp/system_timings.csv")
SYSTEM_TIMINGS.write("")

# Browser tests (P2-5). Until now the suite was integration-level only, so
# anything that lives in JavaScript could be checked by hand in a browser and
# then only guarded by asserting on source text. The player's keyboard and
# focus behaviour (P2-4) is exactly that shape, and it's what this exists for.
#
# Cuprite rather than Selenium: it drives Chrome over CDP, so there is no
# chromedriver to install or version-match. That's what lets one configuration
# work both on the GitHub runner, where `google-chrome` is on PATH, and in a
# container that only has a Playwright-managed binary.
#
# These do NOT run under `bin/rails test` — Rails keeps test/system out of the
# default set, and CI runs them as their own step. A browser hiccup should not
# be able to take the unit suite, and therefore the deploy, down with it.
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # First existing path wins. BROWSER_PATH overrides everything, then the
  # container's Playwright binary, then whatever a normal Linux CI image has.
  BROWSER_CANDIDATES = [
    ENV["BROWSER_PATH"],
    "/opt/pw-browsers/chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium-browser",
    "/usr/bin/chromium"
  ].compact.freeze

  # nil is a deliberate fallback rather than a failure: Ferrum does its own
  # Chrome detection, so an image that puts the binary somewhere unlisted still
  # works instead of erroring on a path guess.
  def self.browser_path
    BROWSER_CANDIDATES.find { |path| File.executable?(path.to_s) }
  end

  # Say which browser this run drives. The local gate resolves to the
  # container's Playwright build and CI to whatever ubuntu-latest ships, and
  # until now neither log recorded which — a rendering or timing difference
  # between the two had nowhere to be seen. Once per run, in the parent.
  if (announced_browser = browser_path)
    announced_version = `#{announced_browser} --version 2>/dev/null`.strip
    warn "system tests: #{announced_version.empty? ? announced_browser : announced_version} (#{announced_browser})"
  else
    warn "system tests: browser left to Ferrum's own detection"
  end

  Capybara.register_driver(:cuprite_headless) do |app|
    Capybara::Cuprite::Driver.new(
      app,
      window_size: [ 1280, 900 ],
      browser_path: browser_path,
      # --no-sandbox is required in a container running as root and on most CI
      # images; there is no untrusted content here, only our own app.
      browser_options: { "no-sandbox": nil, "disable-gpu": nil, "disable-dev-shm-usage": nil },
      # Nothing outside the test server gets to decide whether CI passes.
      #
      # Fixtures build card art out of URLs like
      # https://images.pexels.com/photos/2/x.jpg — deliberately fake, but the
      # browser doesn't know that and dutifully goes to the internet for them.
      # Ferrum then gives up waiting ("still pending connections: …") and the
      # run fails on a public CDN's opinion of four 404s. That blocked a deploy
      # once already: CI's deploy job only fires when every job is green, so a
      # flake here doesn't just annoy, it stops a ship.
      #
      # Blocked by "isn't the local server" rather than by naming hosts, so the
      # next fixture reaching for a CDN can't reintroduce it — and it covers
      # Clarity, which dismiss_cookie_banner activates by clicking Accept all.
      # file:// is untouched by the pattern; the one-pager embed tests need it.
      # A blocked request fails instantly, which is what a fake URL should do:
      # these assertions are about the DOM carrying the right image, never about
      # the bytes arriving.
      url_blacklist: [ %r{\Ahttps?://(?!127\.0\.0\.1|localhost)}i ],
      # This is the COLD START budget, not a per-command one — the browser is
      # spawned lazily by the first driver call of the run (setup's
      # clear_memory_cache), so the whole of Chrome's first launch has to fit
      # inside it. 30s was enough locally and not on a loaded GitHub runner:
      # the first test of a run died on ProcessTimeoutError while every later
      # test reused the same browser happily. Nothing waits on this number in
      # the passing case, so it costs nothing to make it generous.
      process_timeout: 120,
      timeout: 20,
      headless: true
    )
  end

  driven_by :cuprite_headless

  # The standalone one-pagers under public/ that frame a live Verto in a device
  # mockup. They're forks of one another, so they share the demo constants, the
  # mockup ids and the bezel geometry — which means they share their tests too,
  # rather than only the first one anybody happened to write a test for.
  ONE_PAGERS = %w[ vertonow.html verto-for-research.html ].freeze

  # A copy of a shipped one-pager pointed at this test's server instead of
  # production. Everything else — the boot handshake, the fallback, the sizing —
  # is the shipped code. `dest` is repo-relative and decides how the copy is
  # reached: under tmp/ it's visited over file:// (the cross-origin case), under
  # public/ the app serves it (same origin, so the frame can be introspected).
  def one_pager_copy(source, origin:, token:, dest:)
    # Matched by shape, not by the literal token: the pages point at different
    # demo Vertos and a token is changed whenever the demo is re-cut. A literal
    # that stops matching leaves the copy aimed at production, where the frame
    # is cross-origin and every measurement in these tests raises — loud, but a
    # long way from what actually broke.
    html = Rails.root.join("public", source).read
    { /(const DEMO_ORIGIN\s*=\s*")[^"]+(")/ => "\\1#{origin}\\2",
      /(const DEMO_PATH\s*=\s*")\/play\/[\w-]+(")/ => "\\1/play/#{token}\\2" }.each do |pattern, with|
      raise "#{source}: #{pattern.source} matched nothing — the copy would still point at production" unless html.sub!(pattern, with)
    end

    path = Rails.root.join(dest)
    path.write(html)
    path
  end

  # The cookie banner overlays the bottom of every page and swallows clicks
  # aimed at anything under it, so every test used to click Accept all — a
  # lazy module import plus a click on every page, and the full 2s wait
  # wherever the banner was absent: about 330 executions a run. The cookie the
  # banner's controller reads (cookie_consent_controller.js) is preset instead,
  # before the first visit, in the same shape Accept all would write minus the
  # analytics opt-in. A test OF the banner opts out with
  # `self.real_cookie_banner = true` and gets the real thing.
  class_attribute :real_cookie_banner, default: false

  CONSENT_COOKIE_NAME  = "verto_cookie_consent"
  CONSENT_COOKIE_VALUE = ERB::Util.url_encode({ necessary: true, analytics: false }.to_json).freeze

  def before_setup
    @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    super
  end

  def after_teardown
    super
  ensure
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at
    SYSTEM_TIMINGS.open("a") { |f| f.puts [ elapsed.round(3), self.class.name, name ].join(",") }
  end

  # Poll for a condition, returning whether it came true within the timeout —
  # no raise, so the assertion that follows reports what was actually seen.
  # For a state the SERVER reaches (a debounced autosave landing): a fixed
  # sleep passes only when the machine is quick enough, and under parallel
  # workers it often is not.
  def wait_until(timeout: 10, interval: 0.1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return true if yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep interval
    end
  end

  # Returns once the webfonts have landed AND three consecutive animation
  # frames report the same box for the node — bounded, so a node that never
  # settles cannot hang the test. For a test that READS geometry, or CLICKS
  # something that arrived by animation: the three-second consent guard and
  # the Accept-all click used to give the layout that long to settle by
  # accident, and a phone viewport's first paint or a panel's 0.28s slide can
  # still be moving when the page reports loaded. Three frames rather than two
  # so a slide that has only just started, with its first two reads landing
  # before it moves, cannot pass as settled.
  #
  # The fonts first: every @font-face is font-display: swap, so the first
  # paint is in the fallback face and the text reflows when the woff2 lands —
  # a measurement taken before that swap is of the wrong font. Half the suite
  # reads geometry and nothing else waits on document.fonts.
  #
  # The budget: Cuprite hands evaluate_async_script Capybara's
  # default_max_wait_time as the SCRIPT timeout (cuprite driver.rb,
  # session_wait_time) — 2s in this suite, which never sets it. Ninety frames
  # is 1.5s at 60fps before any font has landed, and a runner with four
  # Chromes on four cores paints a frame every 30-50ms: 2026-09-13 two CI jobs
  # died here on Ferrum::ScriptTimeoutError. So this one call gets its own
  # budget (using_wait_time, not the suite-wide default the retrying matchers
  # use) and the script bounds itself at 80% of it — a wall-clock deadline on
  # every tick, and a timer that finishes it even if no animation frame ever
  # fires — so it always returns: a page that never settles is said on
  # stderr, the way wait_for_stimulus says it, never raised. Returns whether
  # the box settled. Ferrum's own CDP command timeout (`timeout: 20` on the
  # driver) is the ceiling any `timeout:` here can reach.
  def settle_box(node, max_frames: 90, timeout: 10)
    # Below the driver's `timeout: 20` (its CDP command timeout, registered
    # above): past it the driver raises Ferrum::TimeoutError before the script
    # can answer, the opaque error this budget exists to remove.
    raise ArgumentError, "settle_box timeout: must be 1..19s (the driver's own is 20)" unless timeout.between?(1, 19)

    deadline_ms = (timeout * 800).to_i
    result = Capybara.using_wait_time(timeout) do
      page.evaluate_async_script(<<~JS, node)
        const [el, done] = arguments
        const started = performance.now(), deadline = started + #{deadline_ms}
        let last = null, same = 0, frames = 0, finished = false, fonts = false
        const finish = (settled) => {
          if (finished) return
          finished = true
          done({ settled, frames, fonts, ms: Math.round(performance.now() - started) })
        }
        setTimeout(() => finish(false), #{deadline_ms} + 100)
        const tick = () => {
          if (finished) return
          const r = el.getBoundingClientRect()
          const key = [r.x, r.y, r.width, r.height].map(Math.round).join(",")
          same = key === last ? same + 1 : 0
          last = key
          if (same >= 2) return finish(true)
          if (++frames > #{max_frames} || performance.now() > deadline) return finish(false)
          requestAnimationFrame(tick)
        }
        const fontsOrDeadline = Promise.race([
          document.fonts.ready.then(() => { fonts = true }),
          new Promise((resolve) => setTimeout(resolve, #{deadline_ms}))
        ])
        fontsOrDeadline.then(() => requestAnimationFrame(tick))
      JS
    end
    unless result["settled"]
      warn "settle_box: #{node.tag_name}.#{node[:class].to_s.split.join('.')} " \
           "#{result['fonts'] ? 'still moving' : 'never saw the fonts land'} after " \
           "#{result['frames']} frames / #{result['ms']}ms on #{current_path}"
    end
    result["settled"]
  end

  # Click something only once it has stopped moving.
  #
  # Cuprite clicks by COORDINATE: it scrolls the node into view, measures its
  # centre, then dispatches a mouse event there. Anything that resizes between
  # the measure and the dispatch has moved the node out from under the click,
  # and nothing raises — the click lands on whatever is at those coordinates
  # instead and the test simply finds that what it clicked didn't happen.
  #
  # The results page does exactly that: its header condenses as the feed
  # scrolls and expands as it comes back, over a transition, so scrolling a
  # button into view starts a resize. Measured 2026-09-22 while chasing a
  # 1-in-10 failure in FreeformAnswersModalTest — between before and after one
  # click the button moved 434px (y 56 → 490) as the header went 112px → 63px.
  # Scrolling it to the middle first and settling its box removes both halves:
  # the scroll that starts the resize happens before the measurement, and
  # settle_box then waits for the resize to finish.
  #
  # Settling is necessary and, on its own, not sufficient: Cuprite scrolls the
  # node into view AGAIN inside its own click, so a pre-scroll narrows the
  # window without closing it. Pass `until_selector:` and the click is retried
  # until the thing it is supposed to do has happened — the same shape as
  # open_menu in results_scroll_test.rb, and for the same reason.
  #
  # This cannot paper over a handler that doesn't work: every attempt is a
  # real click, so a button wired to nothing fails all of them and the
  # caller's own assertion still fails. Checked that way, by deleting the
  # data-action the panel opens from.
  #
  # Returns whether the expected state arrived; callers assert on it as they
  # would after any click, so a false is a normal failure with a normal
  # message rather than a raise from in here.
  def click_settled(locator = nil, until_selector: nil, attempts: 4, **options)
    attempts.times do
      el = locator.is_a?(Capybara::Node::Element) ? locator : find(:button, locator, **options)
      page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", el)
      settle_box(el)
      el.click
      return true if until_selector.nil?
      return true if page.has_selector?(until_selector, wait: 2)
    end
    false
  end

  # Type keys with no pointer involved. Cuprite's Element#send_keys CLICKS the
  # node at its geometric centre to focus it first (cuprite page.rb) — inside
  # a popover, a modal, or anything mid-animation that click is its own
  # gesture: it closed the wallet popover before Escape was typed, so the test
  # then asserted that a closed popover was closed, and body's centre can land
  # on a modal's backdrop. Focus stays wherever it already is; both Escape
  # handlers in the app are document- or window-scoped. Ferrum's key aliases
  # apply (:escape, :enter, [ :Meta, "z" ]). SystemTestHygieneTest keeps
  # send_keys(:escape) out.
  def press_keys(*keys)
    page.driver.browser.keyboard.type(*keys)
  end

  # A deck shaped like a real one: every Verto created through the app gets
  # DemographicQuestions' tail appended (birth month/year, location, gender),
  # which is what makes Survey#default_consent_gate? true and puts the default
  # consent gate in front of the deck. Hand-built fixture decks have no such
  # tail, so 33 of the 36 files that call agree_to_consent_gate never meet a
  # gate at all. Use this where the gate, or the tail, is part of what is
  # under test; a test about one card's behaviour is fine without it.
  def production_deck(cards, locale: "en")
    DemographicQuestions.append_to(cards, locale: locale)
  end

  # The player writes to sessionStorage and registers a Service Worker, so each
  # test starts from a clean slate rather than inheriting the last one's.
  def setup
    super
    page.driver.clear_memory_cache if page.driver.respond_to?(:clear_memory_cache)
    # Set it, or REMOVE it — never neither. The opt-out used to only skip the
    # set and rely on Capybara's between-test session reset to have cleared
    # what the previous test left, which is an ordering assumption rather than
    # a guarantee: a banner test that lands after a preset one in the same
    # browser sees the preset cookie, finds no banner to click, and fails
    # saying so. Measured 2026-09-13 — the diagnostics CookieBannerTest carries
    # for exactly this caught the cookie ({"necessary":true,"analytics":false},
    # the preset's own shape) on the page that should have had none. Removing
    # it here makes the opt-out true by itself, whatever ran before.
    # clear_cookies rather than remove_cookie: the latter demands a :domain or
    # :url, and setup runs before this test has set anything of its own (the
    # session cookie is minted later, by sign_in_as), so there is nothing here
    # worth keeping.
    if real_cookie_banner
      page.driver.clear_cookies
    else
      page.driver.set_cookie(CONSENT_COOKIE_NAME, CONSENT_COOKIE_VALUE, path: "/")
    end
  end

  # Sign in by minting exactly what a successful form login leaves behind
  # (Authentication#start_new_session_for): one Session row and one signed
  # session_id cookie. The form itself — load the page, type, POST, render a
  # dashboard the test then leaves — was three navigations before the page
  # under test, about 95 times a run; SignInTest drives it for real.
  def sign_in_as(user)
    session = user.sessions.create!(user_agent: "system test", ip_address: "127.0.0.1")
    jar = ActionDispatch::Cookies::CookieJar.build(ActionDispatch::TestRequest.create, {})
    jar.signed[:session_id] = { value: session.id, httponly: true, same_site: :lax }
    page.driver.set_cookie("session_id", jar[:session_id], path: "/", httponly: true, samesite: "Lax")
  end

  # Sign in through the real form. The password field is submitted with Enter
  # deliberately: a generic submit selector on these pages hits the language
  # switcher instead.
  def sign_in_through_form(user, password: "verylongpassword")
    visit new_session_path
    fill_in "email_address", with: user.email_address
    fill_in "password", with: password
    find("input[name=password]").send_keys(:enter)
    assert_no_current_path new_session_path, wait: 5
  end

  # With the consent cookie preset (see setup) there is no banner to dismiss —
  # but the Accept-all click was, by accident, the wait every test relied on:
  # the banner only shows once ITS controller connects, so by the time the
  # click landed the page's module graph had loaded. Keep that wait, and make
  # it explicit: every controller named on the page, connected. It costs the
  # real load time and nothing more. A test that opted into the real banner
  # still clicks it — AND then waits, because the accident it inherited is
  # weaker than it looks: the Accept-all click proves the COOKIE-CONSENT
  # controller has connected and nothing else. Every other controller on the
  # page is still racing importmap, so a real-banner test that reaches for a
  # Stimulus-driven control next is making exactly the bet this method was
  # written to stop making. ResultsAskPanelTest is the first test to take it
  # (real banner, then a click on the Ask pill), and it flaked in CI within
  # half an hour of being written. Both paths now end the same way: every
  # controller named on the page, connected. Kept under this name so the ~160
  # call sites read as they always did.
  def dismiss_cookie_banner
    click_button "Accept all" if real_cookie_banner && has_button?("Accept all", wait: 2)
    wait_for_stimulus
  end

  # Importmap loads modules progressively; a gesture that starts the moment
  # text is on screen can beat a controller to its element — faster than any
  # human. Returns whether every controller connected within the timeout, and
  # says on stderr which did not, so a page paying the whole ceiling is seen
  # in the run's output rather than inferred from its timing.
  def wait_for_stimulus(timeout: 5)
    unconnected = nil
    connected = wait_until(timeout: timeout, interval: 0.05) do
      unconnected = evaluate_script(<<~JS)
        (() => {
          const app = window.Stimulus || window.application
          if (!app) return ["(no Stimulus application on window)"]
          return Array.from(document.querySelectorAll("[data-controller]")).flatMap(el =>
            el.dataset.controller.split(/\s+/).filter(Boolean)
              .filter(id => !app.getControllerForElementAndIdentifier(el, id)))
        })()
      JS
      unconnected.empty?
    end
    warn "wait_for_stimulus: still not connected after #{timeout}s on #{current_path}: #{unconnected.uniq.join(', ')}" unless connected
    connected
  end

  # Get past the survey-level consent gate, if this deck has one.
  #
  # Whether the gate exists is decided server-side (Survey#show_consent_gate?)
  # and is in the first paint: `data-consent-pending` on the player overlay and
  # the banner with its button in the HTML. A consent_gate CARD, hoisted to the
  # front of the deck, shows the same button on its own card and is
  # server-rendered too. So the answer is known the moment `visit` returns,
  # with no wait at all.
  #
  # The idiom this replaces —
  #   click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
  # — waited the full three seconds on every deck WITHOUT a demographic card,
  # which is nearly every fixture deck: about 175 times a run, nine minutes of
  # a serial pass, for a button that was never going to render. A bare player
  # visit costs 0.7s; through that guard it cost 3.7-4.5s.
  # SystemTestHygieneTest keeps the idiom from coming back.
  def agree_to_consent_gate
    return unless has_css?("[data-consent-pending], [data-card-type='consent_gate']", visible: :all, wait: 0)

    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
  end

  # Resizing the WINDOW won't do: Chromium clamps its window to roughly 500px,
  # so a layout under test would quietly stay tall enough to hide the bug. CDP's
  # device-metrics override is the only way to get a genuinely short or narrow
  # viewport.
  #
  # `mobile` defaults true because that is what the first caller
  # (ThankyouOverflowTest) has always passed; measuring a DESKTOP layout wants
  # mobile: false, or Chromium emulates a touch device at desktop dimensions.
  def with_viewport(width, height, mobile: true)
    page.driver.browser.page.command("Emulation.setDeviceMetricsOverride",
                                     width: width, height: height,
                                     deviceScaleFactor: 1, mobile: mobile)
    yield
  ensure
    page.driver.browser.page.command("Emulation.clearDeviceMetricsOverride")
  end
end
