# The one email a respondent who signed up with an address and a password is
# sent: a link that proves they can read that inbox.
#
# Without it they are signed in, hold their claims and see their results — and
# are excluded from every mail a creator ever sends about any of it, because
# PlayerAudience only writes to an address someone has proved. The password
# door never proved one. This is the way through that gate, not a new gate:
# nothing a respondent can do today waits on it.
#
# Copied from PlayerSignInMailer rather than the creator's
# EmailConfirmationsMailer, for the two things a respondent mail needs and that
# one lacks: an explicit locale (a mailer runs in a Solid Queue job with no
# request, so no Current.locale) and a threading hint so a resend does not
# stack under the original and get missed. The subject names the ORGANISATION
# for the same reason the sign-in mail's does — we are the "via".
class PlayerEmailConfirmationMailer < ApplicationMailer
  def confirm(player, survey)
    @player   = player
    @survey   = survey
    @org_name = survey&.organisation&.name
    @days     = (Player::CONFIRMATION_LIFETIME / 1.day).to_i
    locale    = SupportedLocales.coerce(player.preferred_locale)

    # The locale rides in the link: nothing else would carry it, so a mail
    # written in the respondent's language would otherwise open a page in the
    # browser's.
    @url        = player_email_confirmation_url(player.generate_token_for(:email_confirmation), locale: locale)
    @delete_url = you_account_url(anchor: "delete", locale: locale)

    I18n.with_locale(locale) do
      headers["X-Entity-Ref-ID"] = SecureRandom.uuid
      mail(
        to:       player.email_address,
        subject:  @org_name.present? ? t("player_email_confirmation_mailer.subject_org", org: @org_name)
                                     : t("player_email_confirmation_mailer.subject"),
        reply_to: ENV["MAIL_REPLY_TO"].presence
      )
    end
  end
end
