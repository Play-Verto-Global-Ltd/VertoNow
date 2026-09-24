require "test_helper"

class LoadTestSeederTest < ActiveSupport::TestCase
  def with_seed_flag(value)
    old = ENV["LOAD_TEST_SEED"]
    ENV["LOAD_TEST_SEED"] = value
    yield
  ensure
    old.nil? ? ENV.delete("LOAD_TEST_SEED") : ENV["LOAD_TEST_SEED"] = old
  end

  test "refuses to run without the explicit LOAD_TEST_SEED flag" do
    with_seed_flag(nil) do
      err = assert_raises(RuntimeError) { LoadTestSeeder.run!(responses: 1, io: StringIO.new) }
      assert_match(/LOAD_TEST_SEED=1/, err.message)
      assert_nil Organisation.find_by(slug: LoadTestSeeder::ORG_SLUG)
    end
  end

  test "seeds a published tokenised leaderboard Verto and N completed responses" do
    result = with_seed_flag("1") { LoadTestSeeder.run!(responses: 25, batch_size: 10, io: StringIO.new) }
    survey = result[:survey]

    assert_equal 25, result[:inserted]
    assert survey.published_at.present?
    assert survey.tokenisation_enabled?
    assert survey.leaderboard_enabled?
    assert_equal 25, survey.responses.count

    resp = survey.responses.order(:id).first
    assert resp.answered?
    assert_equal "completed", resp.status
    assert resp.player_key_digest.present?
    # Token totals are computed server-side from the stored answers, the same
    # way #submit does it — the leaderboard scan sums exactly this column.
    assert_equal TokenGrading.totals(survey.cards, resp.answers, survey.token_type_ids),
                 resp.token_totals
  end

  test "re-running appends to the same Verto instead of duplicating it" do
    with_seed_flag("1") do
      first = LoadTestSeeder.run!(responses: 5, io: StringIO.new)
      again = LoadTestSeeder.run!(responses: 5, io: StringIO.new)

      assert_equal first[:survey].id, again[:survey].id
      assert_equal 1, Organisation.where(slug: LoadTestSeeder::ORG_SLUG).count
      assert_equal 10, first[:survey].responses.count
      assert_equal 10, first[:survey].responses.distinct.count(:session_token)
    end
  end

  test "refuses a database that already holds real organisations, touching nothing" do
    # The env flag proves intent; this guard proves the TARGET. A mispasted
    # DATABASE_URL pointing at production must stop the seeder dead, however
    # the environment is labelled.
    org = Organisation.create!(name: "Bystander", slug: "bystander-#{SecureRandom.hex(3)}")
    survey = org.surveys.create!(
      title: "Untouched", theme: "t", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
    survey.responses.create!(session_token: "bystander-row", answers: {}, status: "completed")
    before = survey.responses.order(:id).pluck(:id, :updated_at)

    err = with_seed_flag("1") do
      assert_raises(RuntimeError) { LoadTestSeeder.run!(responses: 3, io: StringIO.new) }
    end

    assert_match(/scratch database/, err.message)
    assert_equal before, survey.responses.order(:id).pluck(:id, :updated_at)
    assert_nil Organisation.find_by(slug: LoadTestSeeder::ORG_SLUG), "the refusal must come before any write"
  end

  test "tolerates the organisations our own seeders create" do
    # The scratch environment's entrypoint runs db:prepare, which seeds the
    # "playverto" org on every deploy — the guard must not refuse the very
    # database it was built for. DemoSeeder's fixed slugs are equally ours.
    LoadTestSeeder::SEEDED_SLUGS.each do |slug|
      Organisation.create!(name: slug.titleize, slug: slug)
    end

    result = with_seed_flag("1") { LoadTestSeeder.run!(responses: 2, io: StringIO.new) }
    assert_equal 2, result[:inserted]
  end
test "IMAGES attaches a logo and a redirect-mode card image per card, idempotently" do
  result = with_seed_flag("1") { LoadTestSeeder.run!(responses: 2, batch_size: 2, images: 3, image_kb: 2, io: StringIO.new) }
  survey = result[:survey].reload

  assert_equal 3, result[:images]
  assert survey.organisation.logo.attached?
  assert_equal 3, survey.card_images.count
  imaged = survey.cards.select { |c| c["image"].present? }
  assert_equal 3, imaged.size
  # Exactly the path shape an editor upload leaves on a card, which is what
  # sanitize_image_url keeps and what journey.js's extractor looks for.
  imaged.each { |c| assert_match Survey::ACTIVE_STORAGE_IMAGE_URL, c["image"] }
  imaged.each { |c| assert_includes c["image"], "/rails/active_storage/blobs/redirect/" }

  blobs = survey.card_images.blobs.to_a
  assert_equal 3, blobs.map(&:checksum).uniq.size, "each card gets its own bytes"
  blobs.each do |blob|
    assert_equal "image/png", blob.content_type
    assert blob.byte_size.between?(1_500, 4_000), "~2 KB asked for, got #{blob.byte_size}"
    assert blob.download.start_with?("\x89PNG".b)
  end

  again = with_seed_flag("1") { LoadTestSeeder.run!(responses: 1, batch_size: 1, images: 3, image_kb: 2, io: StringIO.new) }
  assert_equal 0, again[:images]
  assert_equal 3, survey.reload.card_images.count
end

test "without IMAGES nothing is attached" do
  result = with_seed_flag("1") { LoadTestSeeder.run!(responses: 1, io: StringIO.new) }
  assert_equal 0, result[:images]
  assert_equal 0, result[:survey].card_images.count
  refute result[:survey].organisation.logo.attached?
end
test "refuses a database that holds an organisation which is not a seed artifact" do
  Organisation.create!(name: "Real Client", slug: "real-client-#{SecureRandom.hex(3)}")

  err = with_seed_flag("1") { assert_raises(RuntimeError) { LoadTestSeeder.run!(responses: 1, io: StringIO.new) } }

  assert_match(/refuses: this database already holds 1 organisation/, err.message)
  assert_nil Organisation.find_by(slug: LoadTestSeeder::ORG_SLUG), "nothing is seeded on refusal"
end

test "tolerates the organisations db/seeds.rb provisions on every deploy" do
  # A fresh scratch database the moment db:prepare has run its seeds: every
  # managed client account, provisioned the way seeds provision them, so a
  # new account left out of SEEDED_SLUGS trips this test rather than scratch.
  ManagedAccountProvisioner.all.each { |provisioner| provisioner.new.call }
  Organisation.find_or_create_by!(slug: "playverto") { |o| o.name = "Playverto" }

  result = with_seed_flag("1") { LoadTestSeeder.run!(responses: 1, io: StringIO.new) }

  assert_equal 1, result[:inserted]
end
end
