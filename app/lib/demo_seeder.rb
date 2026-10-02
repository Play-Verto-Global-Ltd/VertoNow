# Seeds a fully-featured VertoNow demo account: an organisation, a partner
# organisation, a Collective Impact partnership between them, four Vertos that
# between them exercise every card type, quiz mode, both tokenisation award
# modes (per-answer and completion), a consent gate, a custom thank-you
# screen + forward link, a custom /play link, results comparison, branding,
# a bilingual Verto, and one still-draft (unpublished) Verto — plus
# simulated respondents so results, the dashboard, and the region/map view
# all have real numbers to show.
#
# Usage:
#   DEMO_PASSWORD='a-strong-demo-passphrase' bin/rails demo:seed
#   bin/rails demo:destroy
#
# Re-running `demo:seed` is safe — it destroys and rebuilds only the data
# under the demo organisation's own slug (and its partner org's), so it
# always converges on the same known state.
class DemoSeeder
  ORG_SLUG      = "vertonow-demo"
  PARTNER_SLUG  = "riverside-youth-trust-demo"
  ADMIN_EMAIL   = "demo@vertonow.com"
  PARTNER_EMAIL = "partner-demo@vertonow.com"

  # A respondent gets the quiz/tap-card "correct" answer this often; the rest
  # of the time they pick something else, so results read like real people
  # rather than every question landing at 0% or 100%.
  CORRECT_ANSWER_CHANCE = 0.65

  # A respondent completes the whole Verto this often; the rest bail out a
  # few cards in, so the dashboard shows a realistic completion rate.
  COMPLETION_CHANCE = 0.88

  # Rules of the Game — NPS is the traditional 0-10 scale (11 points, no
  # word labels) on a plain vertical slider.
  NPS_OPTIONS = (0..10).map(&:to_s).freeze

  OPEN_ENDED_ANSWERS = {
    "In one sentence, what's your biggest money goal this year?" => [
      "Build a proper emergency fund so one bad month doesn't wreck me.",
      "Pay off my credit card and actually stay off it.",
      "Start investing something, even if it's small, instead of just saving.",
      "Save enough for a deposit on my first place.",
      "Get to a point where I'm not living payslip to payslip."
    ],
    "What's one thing you'd change about your team?" => [
      "Fewer meetings that could've been a message.",
      "More recognition when people actually go above and beyond.",
      "Clearer priorities — right now everything feels like the top priority.",
      "More trust to just get on with things without check-ins.",
      "Better handovers so knowledge doesn't live in one person's head."
    ],
    "What's one thing that would make campus life easier for you?" => [
      "Cheaper food on campus — it adds up fast.",
      "Lecture recordings for every module, not just some.",
      "More quiet study spaces during exam season.",
      "Better mental health appointment availability.",
      "A clearer map of what support even exists."
    ],
    "What's one change that would make this a better place to live?" => [
      "Better street lighting on the walk from the station.",
      "More for teenagers to actually do in the evenings.",
      "A cleaner, better-used community centre.",
      "More regular contact with the local council.",
      "Something that brings neighbours together more than once a year."
    ]
  }.freeze
  GENERIC_OPEN_ENDED = [ "Hard to put into words, but thanks for asking.", "No strong opinion either way, honestly.", "Just want things to keep improving." ].freeze

  def call
    password = require_password!

    ActiveRecord::Base.transaction do
      destroy_existing!

      @org     = create_organisation!
      @partner = create_partner_organisation!
      create_user!(@org, ADMIN_EMAIL, "Demo Admin", password)
      create_user!(@partner, PARTNER_EMAIL, "Partner Admin", password)
      @partnership = create_partnership!

      @money_matters    = build_money_matters!
      @workplace        = build_workplace_culture!
      @campus           = build_campus_wellness!
      @community_safety = build_community_safety!

      share_into_partnership!(@money_matters)

      # Each Verto below gets several countries (for the global map) *and* more
      # than one sub-region label within at least two of those countries —
      # region display/aggregation is country-level only (see
      # ResolvesResultSegments), so this demonstrates several distinct
      # self-declared sub-regions (e.g. "Greater London" + "Manchester")
      # correctly collapsing into one country total rather than each needing
      # its own dot. Only *completed* responses get tagged with a region (see
      # seed_responses!), so every COUNTRY here is sized well above the Data
      # Commons' minimum group (CorpusEntry::COMMONS_MIN_GROUP, 10 — these
      # Vertos are enrolled in Ask Verto below, and a country under it has no
      # breakdown there) even after ~12% of a cluster don't finish — 15 raw,
      # or two clusters of 8, survives that with room to spare.
      seed_responses!(@money_matters, count: 47, consent: true,
        regions: [
          [ "ZA", "Gauteng", 8 ], [ "ZA", "Western Cape", 8 ],
          [ "GB", "Greater London", 8 ], [ "GB", "Manchester", 8 ],
          [ "US", "California", 15 ]
        ])
      seed_responses!(@workplace, count: 46,
        regions: [
          [ "US", "Texas", 8 ], [ "US", "New York", 8 ],
          [ "GB", "Greater Manchester", 15 ],
          [ "AU", "New South Wales", 15 ]
        ])
      seed_responses!(@campus, count: 46,
        regions: [
          [ "GB", "London", 8 ], [ "GB", "Edinburgh", 8 ],
          [ "ES", "Madrid", 15 ],
          [ "ZA", "Western Cape", 15 ]
        ],
        locale_by_country: { "ES" => "es" })
      # @community_safety stays a draft with zero responses — nothing to seed there.
    end

    # Outside the transaction — enrolment writes its own rows and indexes
    # synchronously, and a demo without it lands on Ask Verto's 0/0/0 empty
    # state, which demos the one thing the feature does when it has nothing.
    enrol_ask_verto!
    tag_sdgs!

    print_summary
  end

  def destroy!
    ActiveRecord::Base.transaction { destroy_existing! }
    puts "Removed the VertoNow demo account (#{ORG_SLUG}) and its partner (#{PARTNER_SLUG})."
  end

  private

  # ── setup ──────────────────────────────────────────────────────────────

  def require_password!
    password = ENV["DEMO_PASSWORD"]
    if password.blank? || password.length < 12
      abort <<~MSG
        Set DEMO_PASSWORD (12+ characters) before running this task, e.g.:
          DEMO_PASSWORD='a-strong-demo-passphrase' bin/rails demo:seed
      MSG
    end
    password
  end

  def destroy_existing!
    Organisation.where(slug: [ ORG_SLUG, PARTNER_SLUG ]).find_each(&:destroy!)
    User.where(email_address: [ ADMIN_EMAIL, PARTNER_EMAIL ]).find_each(&:destroy!)
  end

  def create_organisation!
    Organisation.create!(
      name: "VertoNow Demo", slug: ORG_SLUG,
      default_brand_palette: { "primary" => "#01EACB", "cta" => "#FF1E6F", "bg" => "#151A2E" }
    )
  end

  def create_partner_organisation!
    Organisation.create!(name: "Riverside Youth Trust", slug: PARTNER_SLUG)
  end

  def create_user!(org, email, name, password)
    user = User.create!(name: name, email_address: email, password: password)
    Membership.create!(user: user, organisation: org, role: "admin")
    user
  end

  def create_partnership!
    partnership = Partnership.create!(organisation: @org, name: "Youth Financial Empowerment Coalition", status: "active")
    PartnershipMembership.create!(partnership: partnership, organisation: @partner, status: "active")
    partnership
  end

  def share_into_partnership!(survey)
    PartnershipVerto.find_or_create_by!(partnership: @partnership, survey: survey)
    PartnershipShareSync.ensure_shares_for(partnership: @partnership)
  end

  def safe_slug(candidate)
    Survey.slug_taken?(candidate) ? nil : candidate
  end

  def publish!(survey)
    survey.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  # ── the four Vertos ──────────────────────────────────────────────────────

  # Flagship: quiz mode + tokenisation (both per-answer and completion-mode
  # awards), a consent gate, a custom thank-you screen + forward link, a
  # custom /play link, results comparison, custom branding, published, and
  # shared into the Collective Impact partnership.
  def build_money_matters!
    cards = DemographicQuestions.append_to([
      { "type" => "welcome_card", "text" => "Money Matters: how financially confident are you, really?",
        "description" => "5 minutes, fully anonymous — earn points as you go and see how you compare at the end." },
      { "type" => "multiple_choice", "text" => "What does \"APR\" stand for on a credit card or loan?",
        "options" => [ "Annual Percentage Rate", "Applied Payment Rate", "Average Principal Repayment", "Annual Profit Return", "Adjusted Payment Ratio" ],
        "correct" => "Annual Percentage Rate",
        "explanation" => "APR is the yearly cost of borrowing, including fees — the number to compare when shopping for credit.",
        "tokens" => { "Annual Percentage Rate" => { "coin" => 5 } } },
      { "type" => "select_many", "text" => "Which of these stresses you out about money? Pick all that apply.",
        "options" => [ "Rising living costs", "Not enough savings", "Job security", "Student debt", "Family expectations" ],
        "allow_other" => true, "token_award_mode" => "completion", "token_award" => { "coin" => 3 } },
      { "type" => "select_one_grid", "text" => "Which of these grows your money fastest over 10 years?",
        "options" => [ "Simple interest", "Compound interest", "No interest at all", "Fixed-rate interest" ],
        "correct" => "Compound interest",
        "explanation" => "Compound interest earns returns on your returns, so the gap widens every year it's left alone.",
        "tokens" => { "Compound interest" => { "gem" => 5 } } },
      { "type" => "scenario", "text" => "Your laptop just died — what do you do?",
        "pages" => [
          { "id" => "pg_laptop_1", "text" => "Your laptop dies the week before a big assignment is due. A replacement costs $600 — more than you have spare in your everyday account right now." },
          { "id" => "pg_laptop_2", "text" => "You could put it on a credit card and pay it off over a few months, or dip into the small emergency fund you've been quietly building for the last year." }
        ],
        "options" => [ "Use the emergency fund", "Put it on the credit card" ],
        "correct" => "Use the emergency fund",
        "explanation" => "That's exactly what an emergency fund is for — using it here avoids interest charges, and you can rebuild it once things settle.",
        "tokens" => { "Use the emergency fund" => { "coin" => 5 } } },
      { "type" => "select_many_grid", "text" => "A surprise $500 lands in your account — where does it go?",
        "options" => [ "Emergency savings", "Pay off debt", "Treat myself", "Invest it", "Help family", "Start a side hustle" ],
        "token_award_mode" => "completion", "token_award" => { "coin" => 4 } },
      { "type" => "tap_card", "text" => "Swipe each statement: true or false?",
        "options" => [ "Renting is always wasted money", "Minimum card payments are a smart habit", "Credit scores never change", "A retirement fund grows tax-free", "An emergency fund covers 3-6 months" ],
        "correct" => {
          "Renting is always wasted money" => "no",
          "Minimum card payments are a smart habit" => "no",
          "Credit scores never change" => "no",
          "A retirement fund grows tax-free" => "yes",
          "An emergency fund covers 3-6 months" => "yes"
        },
        "tokens" => {
          "Renting is always wasted money" => { "no" => { "gem" => 3 } },
          "Minimum card payments are a smart habit" => { "no" => { "gem" => 3 } },
          "Credit scores never change" => { "no" => { "gem" => 3 } },
          "A retirement fund grows tax-free" => { "yes" => { "gem" => 3 } },
          "An emergency fund covers 3-6 months" => { "yes" => { "gem" => 3 } }
        } },
      { "type" => "range", "text" => "How confident are you about reaching your financial goals?",
        "options" => [ "Not confident", "Slightly confident", "Moderately confident", "Very confident", "Extremely confident" ],
        "token_award" => { "coin" => 2 } },
      { "type" => "nps", "text" => "How likely are you to recommend a budgeting app to a friend?",
        "options" => NPS_OPTIONS },
      { "type" => "rating", "text" => "Rate how well you manage your money day to day.",
        "options" => [ "Poor", "Fair", "Good", "Great", "Excellent" ], "token_award" => { "gem" => 2 } },
      { "type" => "open_ended", "text" => "In one sentence, what's your biggest money goal this year?" },
      { "type" => "prioritise", "text" => "Rank these financial goals in the order they matter to you.",
        "options" => [ "Buy a home", "Pay off debt", "Build an emergency fund", "Invest for retirement", "Travel" ] },
      { "type" => "token_checkpoint", "text" => "Checkpoint — see your points so far!" }
    ])

    survey = Survey.create!(
      organisation: @org, title: "Money Matters: Financial Wellbeing Pulse Check",
      theme: "health and wealth", audience_age: "18-34",
      key_insight: "How under-35s feel about money, tested against a little financial literacy — quiz + points together.",
      default_locale: "en", locales: [ "en" ], cards: cards,
      quiz: true, tokenisation_enabled: true,
      token_types: [ { "id" => "coin", "name" => "Gold Coins", "icon" => "🪙" }, { "id" => "gem", "name" => "Gems", "icon" => "💎" } ],
      # The leaderboard demo lives here too — the one Verto with points on, so
      # /verify and demos can see the board and the anonymous names.
      leaderboard_enabled: true,
      show_results_comparison: true,
      compare_note: "See how your money mindset compares with everyone else who took this.",
      consent_text: "By continuing you agree to let us use your anonymised answers for research on financial wellbeing among young adults.",
      thankyou_title: "You're in! 🎉",
      thankyou_body: "Thanks for sharing how you really feel about money — your answers just helped build a clearer " \
                     "picture of financial wellbeing for people your age.",
      forward_url: Survey.sanitize_forward_url("vertonow.com"),
      slug: safe_slug("money-matters-demo"),
      brand_palette: { "primary" => "#01EACB", "cta" => "#FF1E6F", "bg" => "#151A2E" }
    )
    publish!(survey)
    survey
  end

  # A plain measurement Verto — no quiz, no points — showing every feature
  # doesn't need to be switched on at once. Different type mix, its own
  # branding, results comparison on.
  def build_workplace_culture!
    cards = DemographicQuestions.append_to([
      { "type" => "welcome_card", "text" => "Workplace Culture Snapshot",
        "description" => "Tell us how it really feels to work here — anonymous, about 4 minutes." },
      { "type" => "rating", "text" => "Rate your overall satisfaction with your current job.",
        "options" => [ "Poor", "Fair", "Good", "Great", "Excellent" ] },
      { "type" => "nps", "text" => "How likely are you to recommend your employer to a friend?",
        "options" => NPS_OPTIONS },
      { "type" => "multiple_choice", "text" => "What matters most to you at work right now?",
        "options" => [ "Fair pay", "Flexible hours", "Career growth", "Good management", "Purposeful work" ] },
      { "type" => "select_many", "text" => "Which of these benefits do you actually use?",
        "options" => [ "Health insurance", "Remote work", "Learning budget", "Gym membership", "Mental health support" ] },
      { "type" => "yes_no", "text" => "Do you feel comfortable raising concerns with your manager?" },
      { "type" => "select_one_grid", "text" => "Which best describes how you like to work?",
        "options" => [ "Deep focus", "Collaborative", "Fast-paced", "Steady & structured" ] },
      { "type" => "select_many_grid", "text" => "What would most improve your day-to-day at work?",
        "options" => [ "More autonomy", "Clearer goals", "Fewer meetings", "Better tools", "Recognition", "Work-life balance" ] },
      { "type" => "tap_card", "text" => "Swipe: does this describe your workplace?",
        "options" => [ "I dread Mondays", "Meetings eat most of my week", "My workload varies week to week", "My manager gives useful feedback", "I'd recommend this team to a friend" ] },
      { "type" => "range", "text" => "How manageable is your current workload?",
        "options" => [ "Way too much", "A bit much", "Just right", "A bit light", "Way too light" ] },
      { "type" => "open_ended", "text" => "What's one thing you'd change about your team?" },
      { "type" => "prioritise", "text" => "Rank these in order of what would keep you here longer.",
        "options" => [ "Higher pay", "More flexibility", "Better culture", "Growth opportunities", "Great teammates" ] }
    ])

    survey = Survey.create!(
      organisation: @org, title: "Workplace Culture Snapshot",
      theme: "workplace culture", audience_age: "22-45",
      key_insight: "A plain measurement Verto — no quiz, no points — reading team sentiment across departments.",
      default_locale: "en", locales: [ "en" ], cards: cards,
      show_results_comparison: true, compare_note: "See how your workplace experience compares with others.",
      slug: safe_slug("workplace-culture-demo"),
      brand_palette: { "primary" => "#4F7CFF", "cta" => "#FFB020", "bg" => "#12141F" }
    )
    publish!(survey)
    survey
  end

  # Quiz mode only (no tokenisation), and bilingual — a couple of cards carry
  # Spanish translations, showing the locales/i18n feature.
  def build_campus_wellness!
    cards = DemographicQuestions.append_to([
      { "type" => "welcome_card", "text" => "Campus Life & Wellness Check",
        "description" => "A quick, honest check-in on how uni life is really going.",
        "i18n" => { "es" => {
          "text" => "Chequeo de vida universitaria y bienestar",
          "description" => "Una revisión rápida y honesta de cómo va realmente la vida universitaria."
        } } },
      { "type" => "yes_no", "text" => "True or false: 7-9 hours of sleep is recommended for adults.",
        "correct" => "Yes",
        "i18n" => { "es" => { "text" => "Verdadero o falso: se recomiendan de 7 a 9 horas de sueño para adultos." } } },
      { "type" => "multiple_choice", "text" => "Which of these best reduces exam stress, per research?",
        "options" => [ "Regular exercise", "All-night cramming", "Skipping meals", "More caffeine", "Energy drinks" ],
        "correct" => "Regular exercise",
        "i18n" => { "es" => {
          "text" => "¿Cuál de estos reduce mejor el estrés de los exámenes, según estudios?",
          "options" => [ "Ejercicio regular", "Estudiar toda la noche", "Saltarse comidas", "Más cafeína", "Bebidas energéticas" ]
        } } },
      { "type" => "rating", "text" => "How would you rate your energy levels this semester?",
        "options" => [ "Poor", "Fair", "Good", "Great", "Excellent" ] },
      { "type" => "select_one_grid", "text" => "Which snack gives more lasting energy?",
        "options" => [ "Mixed nuts", "Sugary soda", "White bread", "Energy drink" ], "correct" => "Mixed nuts" },
      { "type" => "select_many", "text" => "What's been getting in the way of a good night's sleep?",
        "options" => [ "Screen time", "Coursework stress", "Noise", "Late caffeine", "Irregular schedule" ] },
      { "type" => "tap_card", "text" => "Swipe true or false on each of these.",
        "options" => [ "Skipping breakfast helps you focus", "Alcohol improves sleep quality", "Cramming beats spaced revision", "Talking to someone helps with stress", "Short walks boost concentration" ],
        "correct" => {
          "Skipping breakfast helps you focus" => "no",
          "Alcohol improves sleep quality" => "no",
          "Cramming beats spaced revision" => "no",
          "Talking to someone helps with stress" => "yes",
          "Short walks boost concentration" => "yes"
        } },
      { "type" => "nps", "text" => "How likely are you to recommend your course to a friend?",
        "options" => NPS_OPTIONS },
      { "type" => "range", "text" => "How connected do you feel to other students?",
        "options" => [ "Not at all", "A little", "Somewhat", "Mostly", "Very connected" ] },
      { "type" => "select_many_grid", "text" => "Which support services have you used this year?",
        "options" => [ "Counselling", "Study skills", "Career advice", "Peer mentoring", "Financial aid", "Health clinic" ] },
      { "type" => "open_ended", "text" => "What's one thing that would make campus life easier for you?" },
      { "type" => "yes_no", "text" => "Do you know how to access mental health support on campus?" }
    ])

    survey = Survey.create!(
      organisation: @org, title: "Campus Life & Wellness Check",
      theme: "student wellbeing", audience_age: "18-24",
      key_insight: "Quiz-only Verto (no points) mixing wellness habits with a little health literacy — English and Spanish.",
      default_locale: "en", locales: [ "en", "es" ], cards: cards, quiz: true,
      show_results_comparison: true, compare_note: "See how your campus experience compares with other students.",
      slug: safe_slug("campus-wellness-demo"),
      brand_palette: { "primary" => "#8B5CF6", "cta" => "#22D3AA", "bg" => "#1A1230" }
    )
    publish!(survey)
    survey
  end

  # Tokenisation only, still unpublished — shows the dashboard's draft state
  # and a token_checkpoint card without needing a live audience yet.
  def build_community_safety!
    cards = DemographicQuestions.append_to([
      { "type" => "welcome_card", "text" => "Community Safety & Belonging",
        "description" => "Still a draft — help us shape it before it goes live." },
      { "type" => "select_one_grid", "text" => "How safe do you feel walking in your neighbourhood at night?",
        "options" => [ "Very unsafe", "A bit unsafe", "Neutral", "Fairly safe", "Very safe", "Extremely safe" ] },
      { "type" => "select_many", "text" => "Which of these would make your area feel safer?",
        "options" => [ "Better lighting", "More patrols", "Community events", "Neighbourhood watch", "Cleaner streets" ] },
      { "type" => "yes_no", "text" => "Do you know at least one neighbour by name?" },
      { "type" => "select_many_grid", "text" => "Which local services have you used this year?",
        "options" => [ "Community centre", "Local library", "Youth club", "Food bank", "Sports facility", "Health clinic" ] },
      { "type" => "tap_card", "text" => "Swipe: does this describe your street?",
        "options" => [ "I feel like an outsider here", "Speeding traffic worries me", "I know a few faces, not names", "Neighbours look out for each other", "I'd recommend living here" ] },
      { "type" => "range", "text" => "How strong is your sense of belonging in this community?",
        "options" => [ "Not at all", "A little", "Somewhat", "Mostly", "Very strong" ], "token_award" => { "star" => 3 } },
      { "type" => "rating", "text" => "Rate how well local leaders listen to residents.",
        "options" => [ "Poor", "Fair", "Good", "Great", "Excellent" ] },
      { "type" => "open_ended", "text" => "What's one change that would make this a better place to live?" },
      { "type" => "prioritise", "text" => "Rank these community priorities in order of importance.",
        "options" => [ "Safety", "Green spaces", "Local jobs", "Youth activities", "Affordable housing" ] },
      { "type" => "token_checkpoint", "text" => "Checkpoint — see your community stars so far!" }
    ])

    Survey.create!(
      organisation: @org, title: "Community Safety & Belonging",
      theme: "community and belonging", audience_age: "all ages",
      key_insight: "Draft Verto — tokenisation only, no quiz — still being shaped before publishing.",
      default_locale: "en", locales: [ "en" ], cards: cards, tokenisation_enabled: true,
      token_types: [ { "id" => "star", "name" => "Community Stars", "icon" => "⭐" } ],
      brand_palette: { "primary" => "#F59E0B", "cta" => "#01EACB", "bg" => "#1C1408" }
    )
    # Left unpublished (no publish_token) — demonstrates the dashboard's draft state.
  end

  # ── simulated respondents ────────────────────────────────────────────────

  # `regions` is [[country_code, label, how_many], ...] — must sum to `count`,
  # and every country should total comfortably over the Commons' minimum
  # group (CorpusEntry::COMMONS_MIN_GROUP) so the region/map view and Ask
  # Verto's country breakdowns actually have something to show.
  def seed_responses!(survey, count:, regions:, consent: false, locale_by_country: {})
    region_pool = regions.flat_map { |country, label, n| Array.new(n) { [ country, label ] } }
    raise "region pool (#{region_pool.size}) must total `count` (#{count}) for #{survey.title}" unless region_pool.size == count

    cards     = survey.cards
    token_ids = survey.token_type_ids

    count.times do |i|
      completed = rand < COMPLETION_CHANCE
      region    = region_pool[i]
      locale    = locale_by_country[region[0]] || "en"
      answers   = simulate_answers(cards, region: region, completed: completed)

      quiz_result  = survey.quiz? ? QuizGrading.score(cards, answers) : nil
      token_totals = survey.tokenisation_enabled? ? TokenGrading.totals(cards, answers, token_ids) : {}
      created_at   = rand(0..21).days.ago - rand(0..23).hours

      Response.create!(
        survey: survey, session_token: SecureRandom.uuid,
        status: completed ? "completed" : "started",
        answers: answers,
        dwell_ms: simulate_dwell(answers),
        score: quiz_result&.dig(:score), quiz_max: quiz_result&.dig(:max),
        token_totals: token_totals,
        # Same rule as the player: an identity digest exists only while the
        # leaderboard is active. One fresh identity per simulated respondent —
        # without this every seeded row is identity-less and the demo board is
        # empty. Names are minted lazily at first board view.
        player_key_digest: survey.leaderboard_active? ? survey.player_key_digest(SecureRandom.uuid) : nil,
        # The location question sits near the end of the deck (a demographic
        # tail card), so a "started" respondent who dropped off a few cards in
        # never actually reached it — same as a real one wouldn't. Only tag a
        # region when they got that far.
        region_country: completed ? region[0] : nil,
        region_label: completed ? region[1] : nil,
        locale: locale,
        consent_agreed_at: (consent && completed) ? created_at : nil,
        consent_text_snapshot: (consent && completed) ? survey.consent_text : nil,
        created_at: created_at, updated_at: created_at
      )
    end
  end

  # Builds one respondent's full `answers` hash. An incomplete respondent
  # just stops a few cards in (status "started"), like a real drop-off.
  def simulate_answers(cards, region:, completed:)
    cutoff = completed ? cards.length : rand(2..5)
    answers = {}

    cards.each_with_index do |card, idx|
      break if idx >= cutoff
      next if %w[welcome_card token_checkpoint].include?(card["type"])

      value = answer_value(card, region: region)
      next if value.nil?

      entry = { "type" => card["type"], "value" => value }
      entry["other"] = GENERIC_OPEN_ENDED.sample if card["allow_other"] && rand < 0.12
      answers[idx.to_s] = entry
    end

    answers
  end

  # How long each answered question took, so the demo's results page and
  # exports show the dwell figures a live Verto would: a few seconds to about
  # forty, skewed short the way real decks are.
  def simulate_dwell(answers)
    answers.keys.index_with { (2_000 + (rand**2 * 38_000)).round }
  end

  def answer_value(card, region:)
    case card["type"]
    when "multiple_choice", "select_one_grid", "scenario"
      biased_pick(card["options"], card["correct"])
    when "yes_no"
      biased_pick(%w[Yes No], card["correct"])
    when "select_many", "select_many_grid"
      biased_subset(card["options"], card["correct"])
    when "tap_card"
      correct = card["correct"] || {}
      scale   = TapScales.keys_for(card)
      Array(card["options"]).index_with { |statement| biased_direction(correct[statement], scale) }
    when "range", "nps"
      rand(Array(card["options"]).size)
    when "rating"
      rand(1..5)
    when "prioritise"
      Array(card["options"]).shuffle
    when "open_ended"
      open_ended_value(card, region: region)
    end
  end

  def biased_pick(options, correct)
    return options.sample if correct.blank?
    rand < CORRECT_ANSWER_CHANCE ? correct : (options - [ correct ]).sample
  end

  def biased_subset(options, correct)
    return Array(correct).presence || options.sample(1) if correct.present? && rand < CORRECT_ANSWER_CHANCE
    options.sample(rand(1..[ options.size, 3 ].min))
  end

  # `scale` is the card's own answer keys, so a seeded 5-point card gets 5-point
  # answers rather than a yes/no/unsure sample its results page has no bar for.
  def biased_direction(correct_key, scale)
    return scale.sample if correct_key.blank?
    rand < CORRECT_ANSWER_CHANCE ? correct_key : ((scale - [ correct_key ]).presence || scale).sample
  end

  def open_ended_value(card, region:)
    case card["input"]
    when "month"
      format("%04d-%02d", rand(1985..2006), rand(1..12))
    when "location"
      "#{region[0]}|#{region[1]}"
    else
      OPEN_ENDED_ANSWERS.fetch(card["text"], GENERIC_OPEN_ENDED).sample
    end
  end

  # ── summary ──────────────────────────────────────────────────────────────

  # The three answered Vertos are offered and approved into the Ask Verto
  # corpus, the same both-keys step verto:enrol_corpus performs for imports —
  # the demo admin is legitimately both the creator and (for a demo) the
  # reviewer. OpenTextThemer degrades to no-themes without an API key, so this
  # costs nothing and needs nothing; closed questions index fully either way.
  def enrol_ask_verto!
    admin = User.find_by!(email_address: ADMIN_EMAIL)
    [ @money_matters, @workplace, @campus ].each do |survey|
      CorpusEnrolment.new(survey, user: admin, reviewer: admin.email_address).call
    end
  end

  # SDG tags, same posture as enrolment above: outside the transaction, and
  # SdgClassifier degrades to no-tags without an API key, so a keyless demo
  # seeds cleanly and simply shows no SDG chips. The draft is tagged too — it
  # appears on the dashboard, and its questions are as real as the others'.
  def tag_sdgs!
    classifier = SdgClassifier.new
    return unless classifier.configured?

    [ @money_matters, @workplace, @campus, @community_safety ].each do |survey|
      sdgs = classifier.call(survey: survey)
      # nil is "no verdict" (call failed), not "no goals" — store only verdicts.
      survey.update_column(:sdgs, sdgs) if sdgs
    rescue => e
      ErrorReporting.report("DemoSeeder#tag_sdgs", e, survey_id: survey.id)
    end
  end

  def print_summary
    puts "\nVertoNow demo account ready:"
    puts "  Organisation : VertoNow Demo (#{ORG_SLUG})"
    puts "  Admin login  : #{ADMIN_EMAIL} / the password you set in DEMO_PASSWORD"
    puts "  Partner org  : Riverside Youth Trust (#{PARTNER_SLUG}), admin: #{PARTNER_EMAIL}"
    puts "  Partnership     : Youth Financial Empowerment Coalition (Collective Impact)"
    puts "  Vertos:"
    [ @money_matters, @workplace, @campus, @community_safety ].each do |s|
      status = s.published? ? "live" : "draft"
      sdgs = s.reload.sdgs
      sdg_note = sdgs.any? ? ", #{sdgs.map { |n| UnSdgs.label(n) }.join(' ')}" : ""
      puts "    - #{s.title} (#{status}, #{s.responses.count} responses#{sdg_note})"
    end
    puts "  Ask Verto    : #{CorpusEntry.citable.where(organisation_id: @org.id).count} Vertos citable, " \
         "#{CorpusQuestion.joins(:corpus_entry).merge(CorpusEntry.citable.where(organisation_id: @org.id)).count} questions indexed"
  end
end
