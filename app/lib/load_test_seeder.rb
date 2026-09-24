require "zlib"

# Seeds a scratch database for the k6 load-test harness (test/load/).
#
# Two jobs, both additive-only:
#   1. Find-or-create a published, tokenised, leaderboard-enabled Verto under
#      its own dedicated organisation — never touching anything it didn't
#      create itself.
#   2. Bulk-insert N completed responses against it via insert_all!, the same
#      callback-free batch path VertoCsvImporter uses, because the O(N)
#      respondent endpoints (/results, /regions, /scores, /leaderboard) are
#      invisible on an empty table — a load test against 100 rows proves
#      nothing.
#
# It NEVER deletes or updates existing rows (unlike DemoSeeder, which starts
# by destroying its fixed slugs — that class must never run near production;
# this one is safe by construction but still guarded). Re-running appends more
# responses to the same Verto and prints the same play URL.
#
# Guard: refuses to run unless LOAD_TEST_SEED=1, so it can't be triggered by
# a stray rake invocation. It is intended for the throwaway load-test
# environment only — see test/load/README.md.
class LoadTestSeeder
  ORG_NAME     = "Load Test Org"
  ORG_SLUG     = "load-test-org"
  SURVEY_TITLE = "Load Test Verto"

  TOKEN_TYPES = [
    { "id" => "points", "name" => "Points", "icon" => "⭐" }
  ].freeze

  # Deck shape mirrors what test/load/journey.js answers — card indexes are
  # the contract between the two files. Change one, change the other.
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome to the load test" },
    { "type" => "multiple_choice", "text" => "How did you hear about this?",
      "options" => [ "Email", "Social", "Friend", "Other" ],
      "tokens" => { "Email" => { "points" => 2 }, "Social" => { "points" => 3 },
                    "Friend" => { "points" => 4 }, "Other" => { "points" => 1 } } },
    { "type" => "rating", "text" => "How excited are you?", "token_award" => { "points" => 2 } },
    { "type" => "multiple_choice", "text" => "Pick a colour",
      "options" => [ "Red", "Green", "Blue" ] },
    { "type" => "open_ended", "text" => "Tell us one thing you'd change." },
    { "type" => "rating", "text" => "Rate the experience overall" }
  ].freeze

  REGIONS = [ "GB", "FR", "DE", "ES", "IE", nil ].freeze

  # Organisations our own seeders create. db/seeds.rb runs on every deploy
  # (the entrypoint's db:prepare), so a freshly-provisioned scratch database
  # already holds the "playverto" org before this seeder ever runs; the
  # DemoSeeder slugs are equally ours, and so is every managed client account
  # db/seeds.rb provisions on every deploy (ManagedAccountProvisioner, create-
  # only — Alpbach tripped this check on scratch on 2026-09-08). Derived from
  # the provisioner's own list rather than copied: the second and third
  # accounts were each opened without being added here, and the check tripped
  # on scratch again. These are recognisable seed artifacts, not evidence of
  # real accounts — anything OUTSIDE this list is.
  SEEDED_SLUGS = [ "playverto", DemoSeeder::ORG_SLUG, DemoSeeder::PARTNER_SLUG,
                   *ManagedAccountProvisioner.slugs ].freeze

  # The smallest thing that is a valid PNG — 8-bit RGB, one IDAT, no
  # interlace — filled with seeded pseudo-random pixels so the file is about
  # the size asked for (noise doesn't deflate) and stable across re-runs.
  module Png
    SIGNATURE = "\x89PNG\r\n\x1A\n".b
    WIDTH     = 128

    module_function

    def noise(seed:, kb:)
      height = [ (kb * 1024.0 / (WIDTH * 3)).ceil, 1 ].max
      rng    = Random.new(seed)
      rows   = Array.new(height) { "\x00".b + rng.bytes(WIDTH * 3) } # filter byte 0 + RGB row
      encode(WIDTH, height, rows.join)
    end

    def encode(width, height, raw)
      ihdr = [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC") # depth 8, colour type 2 (RGB)
      SIGNATURE + chunk("IHDR", ihdr) + chunk("IDAT", Zlib::Deflate.deflate(raw)) + chunk("IEND", "".b)
    end

    def chunk(type, data)
      body = type.b + data.b
      [ data.bytesize ].pack("N") + body + [ Zlib.crc32(body) ].pack("N")
    end
    private_class_method :encode, :chunk
  end

  class << self
    def run!(responses:, batch_size: 1_000, io: $stdout, images: 0, image_kb: 40)
      unless ENV["LOAD_TEST_SEED"] == "1"
        raise "LoadTestSeeder refuses to run without LOAD_TEST_SEED=1 — it is " \
              "for throwaway load-test databases only (see test/load/README.md)."
      end

      # The flag says "I meant to run the seeder"; this check says "and this is
      # actually a scratch database". A mispasted DATABASE_URL pointing at
      # production nearly slipped through once — an env var can lie about what
      # it is, but a database holding real organisations cannot. Production
      # always carries client organisations beyond the seeded ones, so
      # exempting our own seeders' fixed slugs keeps the tripwire intact.
      foreign = Organisation.where.not(slug: [ ORG_SLUG, *SEEDED_SLUGS ])
      if foreign.exists?
        raise "LoadTestSeeder refuses: this database already holds " \
              "#{foreign.count} organisation(s) that are not the load-test org " \
              "(e.g. #{foreign.first.slug.inspect}). It only ever runs against " \
              "a scratch database — check DATABASE_URL."
      end

      survey   = find_or_create_survey!
      attached = images.positive? ? attach_brand_assets!(survey, images: images, image_kb: image_kb) : 0
      inserted = insert_responses!(survey, count: responses, batch_size: batch_size, io: io)

      io.puts "Verto:       #{survey.title} (id #{survey.id})"
      io.puts "Play path:   /play/#{survey.publish_token}"
      io.puts "Responses:   +#{inserted} this run, #{survey.responses.count} total"
      io.puts "Images:      +#{attached} card image(s) this run, #{survey.card_images.count} total; " \
              "logo #{survey.organisation.logo.attached? ? 'attached' : 'none'}"
      { survey: survey, inserted: inserted, images: attached }
    end

    def find_or_create_survey!
      org = Organisation.find_by(slug: ORG_SLUG) ||
            Organisation.create!(name: ORG_NAME, slug: ORG_SLUG)

      org.surveys.find_by(title: SURVEY_TITLE) || org.surveys.create!(
        title: SURVEY_TITLE, theme: "Load testing", audience_age: "all",
        key_insight: "throughput", default_locale: "en", locales: [ "en" ],
        cards: CARDS.map(&:dup), token_types: TOKEN_TYPES.map(&:dup),
        tokenisation_enabled: true, leaderboard_enabled: true,
        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
      )
    end

    # The full-branding shape the event Verto has (IMAGES=N on the seed task):
    # an organisation logo — the play page draws it through the PROXY route —
    # and a card image on each of the first N cards, stored on the card as a
    # REDIRECT-route Active Storage path exactly as the editor stores an upload
    # (Survey::ACTIVE_STORAGE_IMAGE_URL is what sanitize_image_url lets
    # through). Runs 1–21 measured a text-only deck; these are the requests a
    # real browser adds on top. Each image is deterministic noise of about
    # `image_kb` KB — incompressible, so the bytes on the wire are realistic,
    # and unique per card, so nothing dedupes. Idempotent: the target state is
    # "the first N cards carry an image", so an attached logo and cards that
    # already have one are left alone and a re-run attaches nothing. Returns the
    # number of card images attached this run.
    def attach_brand_assets!(survey, images:, image_kb:)
      org = survey.organisation
      unless org.logo.attached?
        org.logo.attach(io: StringIO.new(Png.noise(seed: 0, kb: [ image_kb, 8 ].min)),
                        filename: "load-test-logo.png", content_type: "image/png")
      end

      cards    = survey.cards.map(&:dup)
      attached = 0
      cards.each_with_index do |card, index|
        break if index >= images         # target state: the FIRST N cards carry an image...
        next if card["image"].present? # ...so a re-run attaches nothing

        blob = ActiveStorage::Blob.create_and_upload!(
          io:           StringIO.new(Png.noise(seed: index + 1, kb: image_kb)),
          filename:     "load-test-card-#{index}.png",
          content_type: "image/png"
        )
        survey.card_images.attach(blob)
        card["image"] = Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
        attached += 1
      end
      survey.update!(cards: cards) if attached.positive?
      attached
    end

    def insert_responses!(survey, count:, batch_size: 1_000, io: $stdout)
      cards    = survey.cards
      type_ids = survey.token_type_ids
      # Continue numbering across runs so session tokens stay globally unique.
      start = survey.responses.where("session_token LIKE 'lt-%'").count
      now   = Time.current
      total = 0

      (0...count).each_slice(batch_size) do |slice|
        rows = slice.map do |offset|
          i       = start + offset
          answers = answers_for(i)
          {
            survey_id: survey.id,
            session_token: "lt-#{i}-#{SecureRandom.hex(6)}",
            answers: answers,
            answered: true,
            status: "completed",
            token_totals: TokenGrading.totals(cards, answers, type_ids),
            player_key_digest: survey.player_key_digest("lt-player-#{i}"),
            region_country: REGIONS[i % REGIONS.length],
            demographic_birth_year: 1960 + (i % 50),
            locale: "en",
            started_at: now - 3600 + (i % 3000),
            completed_at: now - 3300 + (i % 3000),
            created_at: now, updated_at: now
          }
        end
        Response.insert_all!(rows)
        total += rows.length
        io.puts "  inserted #{total}/#{count}" if (total % 10_000).zero?
      end
      total
    end

    # Deterministic variety keyed on the row number, matching CARDS' indexes.
    def answers_for(i)
      {
        "1" => { "type" => "multiple_choice",
                 "value" => CARDS[1]["options"][i % 4] },
        "2" => { "type" => "rating", "value" => 1 + (i % 5) },
        "3" => { "type" => "multiple_choice",
                 "value" => CARDS[3]["options"][i % 3] },
        "4" => { "type" => "open_ended",
                 "value" => "Load-test answer #{i % 17}" },
        "5" => { "type" => "rating", "value" => 1 + ((i / 3) % 5) }
      }
    end
  end
end
