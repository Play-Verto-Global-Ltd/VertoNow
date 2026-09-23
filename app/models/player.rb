# A respondent's account. See db/migrate/…_create_players.rb for why this is
# not the creator `User` and why there is no password column.
class Player < ApplicationRecord
  # Mirrors User's own minimum. Named here because the end-card form and its
  # validation message both have to quote the same number.
  MIN_PASSWORD = 12

  # `validations: false`, and the explicit rule below instead. The default
  # macro demands a password on every create, and Player.for_email must go on
  # making passwordless rows: PlayerSignInLink is still the recovery route for
  # anyone who signed up before passwords existed, or who has forgotten theirs
  # (there is no respondent password reset — see PlayerSessionsController).
  has_secure_password validations: false

  # The same floor as User, deliberately. A shorter rule for respondents would
  # be a security decision made on conversion grounds, and this is the one
  # credential standing in front of somebody's answers. allow_nil so the
  # passwordless rows above stay valid.
  validates :password, length: { minimum: MIN_PASSWORD }, allow_nil: true

  has_many :player_sessions,      dependent: :destroy
  has_many :player_sign_in_links, dependent: :delete_all
  has_many :player_identities,    dependent: :delete_all
  has_many :player_claims,        dependent: :delete_all
  has_many :player_email_preferences, dependent: :delete_all
  has_many :player_notifications,     dependent: :delete_all
  has_many :claimed_surveys, -> { distinct }, through: :player_claims, source: :survey

  validates :email_address, presence: true, uniqueness: { case_sensitive: false },
                            format: { with: URI::MailTo::EMAIL_REGEXP }

  # Same normaliser as User. The column is compared and looked up as stored:
  # dev/test are SQLite and production is Postgres, and the two disagree about
  # LOWER() over a column, so the lowercasing happens in Ruby exactly once.
  normalizes :email_address, with: ->(e) { e.to_s.strip.downcase }

  # Longest address the join field will take. RFC 5321 allows 254; anything
  # longer is a paste accident or an attempt to make the index work.
  MAX_EMAIL = 254

  # The name is optional and theirs to set on /you/account; Google's profile
  # fills it in when it can (PlayerOauthSessionsController) and never over a
  # name they typed. Capped because it is drawn in a 160px slot in the bar.
  MAX_NAME = 80
  validates :name, length: { maximum: MAX_NAME }, allow_nil: true
  normalizes :name, with: ->(n) { n.strip }

  # The link in the confirmation mail (PlayerEmailConfirmationsController).
  # Mirrors User's own purpose line for line, and is keyed on the address so
  # that changing it invalidates any link still sitting in an inbox.
  #
  # A week, not the 20 minutes a PlayerSignInLink gets, because the two are
  # different kinds of thing: a sign-in link is a bearer credential and is
  # sized like one, while spending this token only sets a timestamp. It grants
  # nothing, so it can be reusable, unstored and read whenever the person next
  # opens their inbox.
  CONFIRMATION_LIFETIME = 7.days
  generates_token_for :email_confirmation, expires_in: CONFIRMATION_LIFETIME do
    email_address
  end

  def email_verified? = email_verified_at.present?

  # What the corner calls them. The address is the fallback rather than a
  # blank because on a shared device WHICH account you are in is the thing
  # worth knowing, and a name alone does not say it.
  def display_name = name.presence || email_address

  # For the avatar: one grapheme, not one byte, so a name that starts with an
  # accented or a non-Latin letter gets that letter and not half of it.
  def initial = display_name.grapheme_clusters.first.to_s.upcase

  # Stamped the first time someone follows a link from their own inbox, which
  # is the only proof this app ever has that the address belongs to them.
  # Idempotent: a second sign-in must not move the date.
  def verify_email!
    update_column(:email_verified_at, Time.current) unless email_verified?
  end

  # Whether a passwordless row may be given a password by whoever is asking.
  #
  # True only for a shell nothing has happened to. Player.for_email left one of
  # these behind on every join attempt for as long as the emailed link was the
  # only way in — and while the mail was silently failing, that was every
  # attempt ever made. There is nothing behind such a row to take over.
  #
  # A row with claims on it, or one whose address someone has proved by
  # following a link from their own inbox, is a real account: it keeps its
  # password, and a signup quoting that address has to know it.
  def adoptable?
    password_digest.nil? && !email_verified? && player_claims.empty?
  end

  # Find-or-create by address. Deliberately does NOT say which it did: the join
  # endpoint's whole refusal discipline is that it never confirms whether an
  # address is already known (see PlayerController#join).
  def self.for_email(raw)
    email = raw.to_s.strip.downcase.first(MAX_EMAIL)
    return nil unless email.match?(URI::MailTo::EMAIL_REGEXP)

    find_or_create_by!(email_address: email)
  rescue ActiveRecord::RecordNotUnique
    # Two joins with the same address in the same instant; the loser reads the
    # winner's row, as PlayerAlias.ensure_for! does.
    find_by(email_address: email)
  end
end
