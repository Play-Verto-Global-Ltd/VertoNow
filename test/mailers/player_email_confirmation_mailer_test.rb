require "test_helper"

# The one mail a password signup is sent: proof the address is theirs.
class PlayerEmailConfirmationMailerTest < ActionMailer::TestCase
  def player(locale: nil)
    Player.create!(email_address: "pecm-#{SecureRandom.hex(4)}@test.com", preferred_locale: locale)
  end

  def survey(org_name: "Haverley Town Council")
    org = Organisation.create!(name: org_name, slug: "pecm-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: "Car-free High Street", audience_age: "all",
      key_insight: "x", default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  test "it is addressed to the player and its link confirms that player" do
    pl = player
    mail = PlayerEmailConfirmationMailer.confirm(pl, survey)

    assert_equal [ pl.email_address ], mail.to
    token = mail.html_part.body.to_s[%r{/you/confirm/([^"?<\s]+)}, 1]
    assert token, "the link is the whole email"
    assert_equal pl, Player.find_by_token_for(:email_confirmation, CGI.unescape(token))
  end

  test "the subject names the organisation, and the body the Verto" do
    mail = PlayerEmailConfirmationMailer.confirm(player, survey(org_name: "Riverside Youth Trust"))

    assert_match(/Riverside Youth Trust/, mail.subject)
    assert_match(/Car-free High Street/, mail.text_part.body.to_s)
  end

  test "with no survey it falls back to a plain subject and intro" do
    mail = PlayerEmailConfirmationMailer.confirm(player, nil)

    assert_equal I18n.t("player_email_confirmation_mailer.subject"), mail.subject
    assert_match I18n.t("player_email_confirmation_mailer.intro"), mail.text_part.body.to_s
  end

  test "both parts say it signs nobody in, when it expires, and how to walk away" do
    mail = PlayerEmailConfirmationMailer.confirm(player, survey)

    [ mail.html_part, mail.text_part ].each do |part|
      body = part.body.to_s
      assert_match(/7 days/, body)
      assert_match(/already signed in/, body)
      assert_match(/ignore this email/, body)
      assert_match %r{/you/account}, body, "a stranger's address needs a way to delete what was made"
    end
  end

  test "it arrives in the player's language, and its link opens in it" do
    mail = PlayerEmailConfirmationMailer.confirm(player(locale: "fr"), survey)

    assert_equal I18n.t("player_email_confirmation_mailer.subject_org", org: "Haverley Town Council", locale: :fr),
                 mail.subject
    assert_match(/locale=fr/, mail.text_part.body.to_s)
  end

  test "each mail threads on its own" do
    pl = player
    a = PlayerEmailConfirmationMailer.confirm(pl, nil)
    b = PlayerEmailConfirmationMailer.confirm(pl, nil)
    assert_not_equal a["X-Entity-Ref-ID"].to_s, b["X-Entity-Ref-ID"].to_s
  end
end
