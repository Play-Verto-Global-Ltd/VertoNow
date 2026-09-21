require "application_system_test_case"

# The one-pagers under public/ are sent around as downloaded HTML files, and
# their laptop mockup frames a live Verto. That only works because the player
# opts into being framed by `file:` as well as 'self'
# (PlayerController#allow_embedding) — a local page's origin is opaque, so
# Chrome matches it against neither 'self' nor even '*'. Nothing about that is
# visible from an integration test: it lives in the browser's framing rules, so
# it's pinned here instead.
#
# Every page in ONE_PAGERS gets both tests. They're forks of one file, and the
# framing contract is a property of the shipped shell, not of whichever copy
# happened to be written first.
class OnePagerEmbedTest < ApplicationSystemTestCase
  def copy_of(pager, origin, token)
    one_pager_copy(pager, origin: origin, token: token,
                   dest: "tmp/one_pager_embed_#{File.basename(pager, '.html')}_#{Process.pid}.html")
  end

  def published_survey
    org = Organisation.create!(name: "Embed Co", slug: "embed-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "Embedded demo", theme: "Embedded demo", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Welcome to the demo" },
        { "type" => "multiple_choice", "text" => "Coffee or tea?", "options" => [ "Coffee", "Tea" ] }
      ],
      publish_token: SecureRandom.urlsafe_base64(18),
      published_at: Time.current
    )
  end

  ONE_PAGERS.each do |pager|
    test "#{pager} opened from disk plays the real Verto in the laptop" do
      survey = published_survey
      origin = Capybara.current_session.server.base_url
      copy   = copy_of(pager, origin, survey.publish_token)

      # Boot the player ONCE before framing it, so its cold start is not
      # inside the page's own patience. The one-pager gives up on the live
      # Verto after six seconds and falls back to its built-in demo
      # (`setTimeout(() => finish(false), 6000)`) — a deliberate product
      # choice, because a marketing page must not show a blank laptop for
      # twenty seconds. On a loaded runner this test is often the first in its
      # worker to render /play/ at all, so it paid template compilation and an
      # uncached asset fetch inside that budget, lost the race, and got the
      # fallback — at which point the 15s wait below can never be satisfied,
      # however long it is. CI 35616357129 went red exactly there.
      #
      # It changes nothing about what is under test: the framing contract is
      # still asserted against a cold FILE and a real cross-origin frame.
      visit "#{origin}/play/#{survey.publish_token}"
      assert_selector "body", wait: 15

      visit "file://#{copy}"

      # is-live is only set once the embedded player has actually announced
      # itself — cross-origin, so it can't be faked by the frame merely existing.
      # If this fails, the file fell back to its own built-in demo.
      assert_selector "#demoMockup.is-live", wait: 15
      # …and the built-in demo stays out of the way while the real thing plays.
      assert_no_selector "#vertoDemo.is-on"

      # Not asserted from inside the frame: it's cross-origin here (file://
      # parent), which is the very thing under test, and the driver can't step
      # into it. The is-live check above is the stronger signal anyway — it's set
      # only when the embedded player posts verto:ready, so it cannot pass unless
      # the real player booted in there.
      assert_equal "#{origin}/play/#{survey.publish_token}",
        find(".screen-embed", visible: :all)[:src]
    ensure
      FileUtils.rm_f(copy) if copy
    end

    test "#{pager} falls back to the built-in demo when the Verto is unreachable" do
      # Nothing listening on that port, so the frame can never boot.
      copy = copy_of(pager, "http://127.0.0.1:1", "nope")

      visit "file://#{copy}"

      # An unreachable Verto must leave something playable behind, not an empty
      # laptop — that's the whole point of keeping the built-in deck around.
      assert_selector "#vertoDemo.is-on", wait: 20
      assert_no_selector "#demoMockup.is-live"
    ensure
      FileUtils.rm_f(copy) if copy
    end
  end
end
