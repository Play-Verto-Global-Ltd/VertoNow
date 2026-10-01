require "test_helper"
require Rails.root.join("db/migrate/20261001090000_open_comparison_for_vertos_with_accounts")

# The backfill that opens the comparison for the Vertos accounts already depend
# on. The migration is data-only, so what matters is exactly which rows it
# touches: it overwrites a creator's stored false, and must do that for no
# Verto an account has no stake in.
class OpenComparisonForVertosWithAccountsTest < ActiveSupport::TestCase
  def verto(**attrs)
    org = Organisation.create!(name: "O", slug: "oc-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x", default_locale: "en",
      locales: [ "en" ], cards: [ { "type" => "welcome_card", "text" => "Hi" } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  def claimed(survey)
    response = survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answered: true)
    PlayerClaim.claim!(player: Player.for_email("oc-#{SecureRandom.hex(3)}@test.com"),
                       response: response, source: "signup")
  end

  def migrate_up
    ActiveRecord::Migration.suppress_messages { OpenComparisonForVertosWithAccounts.new.migrate(:up) }
  end

  test "it opens a Verto that offers accounts, and one an account already holds" do
    asks     = verto(join_prompt_enabled: true, show_results_comparison: false)
    held     = verto(show_results_comparison: false)
    claimed(held)

    migrate_up

    assert asks.reload.show_results_comparison?
    assert held.reload.show_results_comparison?, "signed in to it now, even with the ask since turned off"
  end

  test "it leaves every other Verto as its creator had it" do
    untouched = verto(show_results_comparison: false)
    open      = verto(show_results_comparison: true)

    migrate_up

    assert_not untouched.reload.show_results_comparison?, "no account depends on it, so it stays closed"
    assert open.reload.show_results_comparison?
  end

  test "it does not touch updated_at, which the creator dashboard orders by" do
    s = verto(join_prompt_enabled: true, show_results_comparison: false)
    s.update_columns(updated_at: 3.days.ago)
    before = s.reload.updated_at

    migrate_up

    assert_equal before, s.reload.updated_at
  end

  test "running it twice changes nothing the second time" do
    s = verto(join_prompt_enabled: true, show_results_comparison: false)

    migrate_up
    migrate_up

    assert s.reload.show_results_comparison?
  end
end
