require "application_system_test_case"

# The signup link continuing on its own, in a real browser.
#
# This file exists because the integration test for it can only prove a
# <script> tag is present in the HTML, and the entire claim of the change is
# that a browser RUNS it. A tag that renders and never fires would pass there
# and strand exactly the people it was written for.
#
# The same reasoning as sign_in_test.rb: every other test reaches an account by
# minting the session or by clicking the button, so this is where the automatic
# path keeps a browser test.
class PlayerSignupContinueTest < ApplicationSystemTestCase
  def a_player = Player.for_email("sc-#{SecureRandom.hex(4)}@test.com")

  test "a signup link signs you in without anyone tapping anything" do
    _link, raw = PlayerSignInLink.mint!(player: a_player,
                                        origin: PlayerSignInLink::ORIGIN_SIGNUP)

    visit player_sign_in_path(raw)

    # Deliberately no click of any kind between the visit and this assertion.
    assert_selector ".you-topbar", wait: 10,
                    text: nil # presence is the whole assertion
  end

  test "an emailed link still waits to be tapped" do
    link, raw = PlayerSignInLink.mint!(player: a_player) # ORIGIN_EMAIL by default

    visit player_sign_in_path(raw)
    assert_selector "form#player-sign-in-continue"

    # Proving that nothing happens, which is the one case a fixed wait is for
    # (see ApplicationSystemTestCase). An emailed link is confirmed by whoever
    # went and fetched it from an inbox; auto-continuing here would hand the
    # account to the first link scanner that follows the GET.
    sleep 1.5

    assert_no_selector ".you-topbar"
    assert_nil link.reload.consumed_at, "loading the page must still consume nothing"
  end
end
