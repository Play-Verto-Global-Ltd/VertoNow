require "test_helper"

# The Privacy Notice's §15 minimum age for an account, as one rule: under 16
# never, under 18 never where local law says 18, and "we don't know" kept apart
# from "no".
class AccountAgeTest < ActiveSupport::TestCase
  def response(band: nil, year: nil, country: nil)
    Response.new(demographic_age_band: band, demographic_birth_year: year, region_country: country)
  end

  def survey(country: nil) = Survey.new(audience_country: country)

  test "16 is the minimum, and the bands are judged whole" do
    assert_equal :too_young, AccountAge.verdict(response(band: "under_16"), survey)
    assert_equal :eligible,  AccountAge.verdict(response(band: "16_17"), survey)
    assert_equal :eligible,  AccountAge.verdict(response(band: "65_plus"), survey)
  end

  test "where local law says 18, a 16-17 is too young" do
    assert_equal :too_young, AccountAge.verdict(response(band: "16_17", country: "IN"), survey)
    assert_equal :eligible,  AccountAge.verdict(response(band: "18_24", country: "IN"), survey)
    assert_equal 18, AccountAge.min_age(response(country: "ZA"), survey)
  end

  test "the respondent's own country wins over the Verto's audience country" do
    assert_equal :too_young, AccountAge.verdict(response(band: "16_17"), survey(country: "IN"))
    assert_equal :eligible,  AccountAge.verdict(response(band: "16_17", country: "GB"), survey(country: "IN"))
  end

  test "no age on record is unknown, not a refusal" do
    assert_equal :unknown, AccountAge.verdict(response, survey)
    assert_equal :unknown, AccountAge.verdict(nil, survey)
    assert_equal 16, AccountAge.min_age(nil, nil)
  end

  # A birth year can't say whether this year's birthday has been, so it is
  # read at the younger of the two ages it allows.
  test "a legacy birth year is read at its lowest age" do
    this_year = Date.current.year
    assert_equal :too_young, AccountAge.verdict(response(year: this_year - 16), survey)
    assert_equal :eligible,  AccountAge.verdict(response(year: this_year - 17), survey)
  end

  test "every higher minimum is keyed by a real country code" do
    AccountAge::HIGHER_MIN.each_key { |code| assert WorldRegions.valid?(code), code }
  end
end
