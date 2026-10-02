# The Playverto showcase Verto — one deck that plays every answer type the
# product ships, with real imagery on every card, branching, tokenisation and a
# custom brand.
#
# It lives in the Playverto organisation itself (slug "playverto", the account
# behind PlayvertoStaff) rather than the VertoNow demo org, because its job is
# different from DemoSeeder's: DemoSeeder builds a whole throwaway ACCOUNT
# (partner org, partnership, four Vertos, an admin login) for verification and
# sales demos, and destroys/rebuilds it every run. This builds ONE Verto in a
# real account somebody actually works in, so it is create-only by default —
# `showcase:seed` never touches a deck that already exists unless asked to
# rebuild it.
#
# It is seeded in TEST MODE — a /test/:token link that plays the real thing
# without sign-in, records nothing, and leaves the deck editable. See
# #initialize for why that is the default rather than published.
#
# Usage:
#   bin/rails showcase:seed              # create it in Test Mode if it isn't there
#   bin/rails showcase:test_mode         # put an existing one INTO Test Mode
#   bin/rails showcase:seed FORCE=1      # rebuild it from scratch
#   bin/rails showcase:seed PUBLISH=1 RESPONSES=1   # the live variant, with demo data
#   bin/rails showcase:destroy
#
# Why sport: every bundled asset library the deck draws on — the option icons
# (app/assets/images/option-icons, all sport), the curated photo library
# (verto-library/, sports-people + generic art) and the range reaction
# animations (NpsHelper's Sport group) — is sports-first, so a sports theme is
# the one where the SHIPPED artwork lands on every card without a Pexels key.
class ShowcaseVertoSeeder
  ORG_SLUG   = "playverto"
  VERTO_SLUG = "verto-showcase"

  # Simulated respondents, so the dashboard, the results screen, the region map
  # and the leaderboard all have something to show. [country, label, how_many]
  # — each country is comfortably over Response::MIN_REGION_SAMPLE_SIZE (10)
  # even after the drop-offs below.
  RESPONSE_REGIONS = [
    [ "GB", "Greater London", 9 ], [ "GB", "Greater Manchester", 8 ],
    [ "US", "California", 15 ], [ "ZA", "Western Cape", 15 ],
    [ "AU", "New South Wales", 15 ]
  ].freeze
  RESPONSE_COUNT   = RESPONSE_REGIONS.sum { |_c, _l, n| n }
  COMPLETION_CHANCE = 0.86

  OPEN_ENDED_ANSWERS = [
    "Cheaper sessions, honestly. That's the whole thing for me.",
    "A beginners' night. Turning up alone to a good team is terrifying.",
    "Somewhere to play after 8pm — I don't finish work until seven.",
    "A pitch I can walk to. The nearest one is two buses away.",
    "Someone to go with. I'd play every week if a friend came too.",
    "Fewer leagues, more drop-in. I can't commit to every Sunday."
  ].freeze

  # The 5-point agreement strip (config/tap_scales.yml preset 5). Spelled out
  # on the card rather than left to the historic 3-point default, because the
  # wide scale is the one that fans out over the photo on an arc — the swipe
  # card at its most expressive, which is the point of a showcase.
  TAP_RESPONSES = [
    { "key" => "strongly_disagree", "label" => "Strongly disagree", "emoji" => "❤️", "color" => "#d80027" },
    { "key" => "disagree",          "label" => "Disagree",          "emoji" => "🙁", "color" => "#f0663f" },
    { "key" => "neutral",           "label" => "Neutral",           "emoji" => "😐", "color" => "#f5a623" },
    { "key" => "agree",             "label" => "Agree",             "emoji" => "🙂", "color" => "#4fbf9f" },
    { "key" => "strongly_agree",    "label" => "Strongly agree",    "emoji" => "💚", "color" => "#01eacb" }
  ].freeze
  TAP_KEYS = TAP_RESPONSES.map { |r| r["key"] }.freeze

  # Test Mode by default. The showcase exists to be handed round and edited,
  # and that is exactly the state Test Mode is for: /test/:token plays the real
  # thing without sign-in, records NOTHING, and stays current while the deck is
  # edited — so the editor never locks (Survey#editing_locked?) and no
  # respondent data is ever written against a demonstration deck.
  #
  # `publish: true` mints a /play link instead (or as well), and `responses:
  # true` seeds simulated respondents so the results, map and leaderboard have
  # numbers in them. The second one LOCKS THE DECK: answers are keyed by card
  # index, so a Verto with responses can never be structurally edited again,
  # which is the opposite of what Test Mode is for. Ask for it deliberately.
  def initialize(force: false, responses: false, publish: false)
    @force     = force
    @responses = responses
    @publish   = publish
  end

  def call
    org = Organisation.find_by(slug: ORG_SLUG)
    # Warn rather than abort: this runs from db/seeds.rb, and a missing org
    # there means the seed order changed, not that the whole seed should die.
    if org.nil?
      puts "No organisation with slug #{ORG_SLUG.inspect} — skipping the showcase Verto."
      return nil
    end

    existing = Survey.unscoped.find_by(slug: VERTO_SLUG)
    if existing && !@force
      puts "Showcase Verto already exists (##{existing.id}, #{existing.title.inspect}) — nothing to do."
      puts "Re-run with FORCE=1 to rebuild it from scratch."
      return existing
    end

    survey = nil
    ActiveRecord::Base.transaction do
      existing&.destroy!
      survey = build_verto!(org)
      seed_responses!(survey) if @responses
    end

    print_summary(survey)
    survey
  end

  def destroy!
    survey = Survey.unscoped.find_by(slug: VERTO_SLUG)
    if survey.nil?
      puts "No showcase Verto to remove."
      return
    end
    survey.destroy!
    puts "Removed the showcase Verto (slug #{VERTO_SLUG})."
  end

  # ── the Verto ────────────────────────────────────────────────────────────

  def build_verto!(org)
    survey = Survey.create!(
      organisation: org,
      title: "Verto Showcase — Every Way to Ask",
      theme: "community sport and wellbeing",
      audience_age: "16-40",
      key_insight: "One deck that plays every answer type Verto ships — branching, points, " \
                   "a leaderboard and real imagery on every card.",
      description: "The showcase deck: every answer type, every media kind, in one Verto.",
      default_locale: "en", locales: [ "en" ],
      cards: cards,
      flows: flows,
      logic: true,
      tokenisation_enabled: true,
      token_types: [ { "id" => "pt", "name" => "Play Points", "icon" => "🏅" } ],
      leaderboard_enabled: true,
      show_results_comparison: true,
      compare_note: "See how your answers sit against everyone else who has played this.",
      background_image: asset("backgrounds", "sport.jpg"),
      brand_palette: { "primary" => "#01EACB", "cta" => "#FF1E6F",
                       "bg" => "#101528", "panel" => "#1C2A4A" },
      brand_font: "font-poppins", brand_font_heading: "font-anton",
      brand_answer_tint: true,
      thankyou_title: "That's every answer type. 🏅",
      thankyou_body: "You just played thirteen different ways of asking a question — lists, grids, " \
                     "swipes, sliders, stars, a story and a slider that reacts as you drag it. " \
                     "Same Verto, same two minutes.",
      forward_url: Survey.sanitize_forward_url("playverto.com"),
      slug: VERTO_SLUG,
      # The Test Mode link. Minted at build time whether or not the Verto is
      # also published: a test link is distribution state, independent of
      # published?/editing_locked?, and having one costs nothing.
      test_token: SecureRandom.urlsafe_base64(18)
    )
    survey.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current) if @publish
    survey
  end

  # Bring an EXISTING showcase Verto into Test Mode — mint the test link if it
  # hasn't got one, and take it off /play if it is live. Idempotent, and the
  # only thing that can reach a deck the create-only path has already left
  # alone. Mirrors SurveysController#convert_to_test_mode, including keeping
  # any existing test_token rather than rotating it: that URL may already be in
  # somebody's hands.
  #
  # Provisions the Verto first if it isn't there at all, so one call gets to
  # the same end state from either side.
  def ensure_test_mode!
    survey = Survey.unscoped.find_by(slug: VERTO_SLUG) || call
    return nil if survey.nil?

    attrs = {}
    attrs[:test_token]     = SecureRandom.urlsafe_base64(18) if survey.test_token.blank?
    attrs[:unpublished_at] = Time.current if survey.published?
    survey.update!(attrs) if attrs.any?

    puts "Showcase Verto ##{survey.id} is in Test Mode: /test/#{survey.test_token}"
    puts "  (it had collected #{survey.responses.count} responses, so the deck stays locked)" if survey.responses.exists?
    survey
  end

  # Two lanes off the third card, rejoining on the range card. Named after what
  # a respondent said about themselves, which is what the flow map labels them
  # with; `exit` is what FlowCompiler rewires the last member's `next` to if
  # the deck is later reordered in the editor.
  def flows
    [
      { "id" => "f_players",    "name" => "Plays sport",   "color" => "#01EACB",
        "exit" => { "card" => "c_range" } },
      { "id" => "f_supporters", "name" => "Watches sport", "color" => "#FF1E6F",
        "exit" => { "card" => "c_range" } }
    ]
  end

  # Spec order IS card order IS the positional key every answer is stored under
  # (the same contract app/lib/verto_decks/base.rb spells out) — so reordering
  # this list after responses exist re-points every stored answer. Append, or
  # rebuild with FORCE=1 and accept losing the simulated ones.
  #
  # Card count is deliberate: 18 cards, of which a respondent plays 15 (three
  # spine cards, one three-card lane, then nine shared cards including the
  # demographic tail). That sits inside the Rules of the Game green band (12-16)
  # for the longest path a respondent can take — the showcase has to be able
  # to hold up its own scoreboard.
  #
  # It ended on a contact card until that type was retired (CardTypes.retired?).
  # Dropping it here rather than leaving it in is the point of a showcase deck:
  # it exists to play every answer type the platform HAS, and the player skips
  # a retired card, so keeping one would seed a card nobody would ever see.
  def cards
    DemographicQuestions.append_to([
      welcome_card, consent_card, code_card, router_card,
      # Lane A — people who play. Opens on the points promise: the intro used
      # to render inline on the welcome card, but a points_intro card in the
      # deck supersedes that (Survey#token_intro_index), and the lanes are
      # where the deck can afford a screen each — §1.1's green band tops out
      # at 16 cards on the longest path, and the spine already spends them.
      points_intro_card, grid_one_card, rating_card, tap_card,
      # Lane B — people who watch. Closes on the checkpoint before rejoining,
      # for the same length arithmetic: one milestone screen per lane keeps
      # both lanes at four and the longest path at sixteen.
      grid_many_card, nps_card, scenario_card, checkpoint_card,
      # Rejoin: everyone plays the rest. open_ended sits BEFORE select_many
      # rather than last, because the demographic tail append_to adds below
      # opens with two open_ended cards (birth year, location) — ending the
      # spine on a third would break the no-more-than-two-in-a-row rule that
      # showcase_verto_seeder_test §1.4 enforces. The retired contact card used
      # to sit in that gap and hide the adjacency.
      range_card, prioritise_card, yes_no_card,
      open_ended_card, select_many_card
    ]).then { |list| image_demographic_tail(list) }
  end

  # The birth-year / location / gender tail arrives as platform copy with no
  # imagery, and three bare cards at the end of an otherwise fully-illustrated
  # deck read as the deck running out of steam. Imaged from the Verto THEME
  # only, never the question's own words — the same rule AssetPopulator applies
  # to these cards, and for the same reason: "Gender" is not a stock-photo
  # search anybody wants run.
  def image_demographic_tail(list)
    tail = %w[sports-people-desktop-3.jpg sports-people-desktop-4.jpg sports-people-desktop-5.jpg]
    i = -1
    list.map do |card|
      next card unless card["demographic"]
      i += 1
      card.merge("image" => asset("left-panel", tail[i % tail.size]))
    end
  end

  def welcome_card
    { "cid" => "c_welcome", "type" => "welcome_card",
      "text" => "Every way Verto can ask a question",
      "description" => "Thirteen answer types, one deck, about three minutes. " \
                       "Answer honestly — the results screen at the end is real.",
      "image" => asset("left-panel", "sports-people-desktop-1.jpg"),
      "animate_asset" => true }
  end

  def consent_card
    { "cid" => "c_consent", "type" => "consent_gate",
      "text" => "Before you start",
      "pages" => [
        { "id" => "pg_consent_1",
          "text" => "This is a demonstration Verto. It asks about how you take part in sport " \
                    "where you live, and it exists so you can see every kind of question the " \
                    "platform can ask in one sitting." },
        { "id" => "pg_consent_2",
          "text" => "Your answers are anonymous. They are used to show what the results, the " \
                    "comparison screen and the map look like with real answers in them, and " \
                    "nothing else. You can stop at any point." }
      ],
      "image" => asset("left-panel", "sports-people-desktop-2.jpg") }
  end

  # The respondent code, in the place it belongs: after the consent screens and
  # before the first question, so an identity exists for everything that
  # follows. In the showcase it is a demonstration of the card and nothing more
  # — `recall` is left off (the default), so nothing is ever read back, and the
  # copy says why it is being asked rather than implying the demo needs it.
  def code_card
    { "cid" => "c_code", "type" => "respondent_code",
      "text" => "Make up a code you'll remember",
      "description" => "Part of the demonstration: a code like this is how a Verto matches the " \
                       "same person across repeat runs without ever knowing who they are. Only a " \
                       "one-way hash is stored.",
      "image" => asset("left-panel", "sports-people-desktop-2.jpg") }
  end

  # The branch point. Routing lives on the card, keyed by the CANONICAL option
  # label, exactly like `tokens` and `correct` are (see LogicGraph).
  def router_card
    { "cid" => "c_play_style", "type" => "multiple_choice",
      "text" => "How do you take part in sport these days?",
      "options" => [ "I play regularly", "I play now and then", "I mostly watch and support" ],
      "option_styles" => [
        { "color" => "#01eacb", "icon" => "basketball" },
        { "color" => "#4f7cff", "icon" => "sport-bag" },
        { "color" => "#ff1e6f", "icon" => "whistle" }
      ],
      "image" => asset("left-panel", "sports-people-desktop-3.jpg"),
      "tokens" => {
        "I play regularly" => { "pt" => 5 },
        "I play now and then" => { "pt" => 5 },
        "I mostly watch and support" => { "pt" => 5 }
      },
      "logic" => {
        "routes" => [
          { "match" => { "op" => "equals", "value" => "I play regularly" },
            "to" => { "card" => "c_points_intro" } },
          { "match" => { "op" => "equals", "value" => "I play now and then" },
            "to" => { "card" => "c_points_intro" } }
        ],
        "default" => { "card" => "c_grid_many" }
      } }
  end

  # ── Lane A: people who play ──────────────────────────────────────────────

  # The lane head, so it carries the lane_label and the router's routes point
  # here. Its presence in the deck is what supersedes the inline intro the
  # welcome card used to host.
  def points_intro_card
    { "cid" => "c_points_intro", "type" => "points_intro", "flow_id" => "f_players",
      "lane_label" => "Plays sport",
      "text" => "Points are on offer as you go.",
      "image" => asset("select-art", "select-icon-3.jpg") }
  end

  def grid_one_card
    { "cid" => "c_grid_one", "type" => "select_one_grid", "flow_id" => "f_players",
      "text" => "How often do you play in a typical month?",
      "options" => [ "Once a month", "Two or three times", "Weekly", "Most days" ],
      "option_styles" => [
        { "color" => "#4f7cff", "emoji" => "🗓️" },
        { "color" => "#01eacb", "icon" => "stopwatch" },
        { "color" => "#ffb020", "icon" => "medal" },
        { "color" => "#ff1e6f", "icon" => "trophy" }
      ],
      "image" => asset("select-art", "select-icon-1.jpg"),
      "token_award_mode" => "completion", "token_award" => { "pt" => 4 } }
  end

  def rating_card
    { "cid" => "c_rating", "type" => "rating", "flow_id" => "f_players",
      "text" => "Rate the pitches, courts and gyms you play on.",
      "options" => [ "Poor", "Fair", "Good", "Great", "Excellent" ],
      "image" => asset("left-panel", "sports-people-desktop-4.jpg"),
      "token_award" => { "pt" => 3 } }
  end

  # The five-point response strip fans out over the photo on an arc rather than
  # sitting in a row of circles (TapScales::FAN_THRESHOLD) — hence five here
  # and not the historic three.
  def tap_card
    statements = [
      "I play to keep my head clear",
      "I would play more if it cost less",
      "My club feels welcoming to newcomers",
      "I have to travel too far to play",
      "Playing is how I see my friends"
    ]
    { "cid" => "c_tap", "type" => "tap_card", "flow_id" => "f_players",
      "text" => "Swipe each one — does it sound like you?",
      "options" => statements,
      "responses" => TAP_RESPONSES.map(&:dup),
      "option_images" => %w[
        tap-card-photo-1.jpg tap-card-photo-2.jpg tap-card-photo-3.jpg
        tap-card-photo-4.jpg tap-card-photo-5.jpg
      ].map { |f| asset("swipe-cards", f) },
      "tokens" => statements.index_with { |_s| TAP_KEYS.index_with { |_k| { "pt" => 1 } } },
      "next" => { "card" => "c_range" } }
  end

  # ── Lane B: people who watch ─────────────────────────────────────────────

  def grid_many_card
    { "cid" => "c_grid_many", "type" => "select_many_grid", "flow_id" => "f_supporters",
      "lane_label" => "Watches sport",
      "text" => "What keeps you from playing more often?",
      "options" => [ "No time", "Costs too much", "Nowhere nearby",
                     "No one to go with", "Injury or health", "Not confident" ],
      "option_styles" => [
        { "color" => "#4f7cff", "icon" => "stopwatch" },
        { "color" => "#ffb020", "emoji" => "💷" },
        { "color" => "#0ca7ff", "icon" => "flag" },
        { "color" => "#8b5cf6", "emoji" => "🧑‍🤝‍🧑" },
        { "color" => "#ff1e6f", "emoji" => "🩹" },
        { "color" => "#f0663f", "emoji" => "😬" }
      ],
      "image" => asset("select-art", "select-icon-2.jpg"),
      "token_award_mode" => "completion", "token_award" => { "pt" => 4 } }
  end

  def nps_card
    { "cid" => "c_nps", "type" => "nps", "flow_id" => "f_supporters",
      "text" => "How likely are you to recommend your local club?",
      "options" => (0..10).map(&:to_s),
      "image" => asset("left-panel", "sports-people-desktop-5.jpg"),
      "token_award" => { "pt" => 3 } }
  end

  def scenario_card
    { "cid" => "c_scenario", "type" => "scenario", "flow_id" => "f_supporters",
      "text" => "A free taster session, this Saturday",
      "pages" => [
        { "id" => "pg_taster_1",
          "text" => "A card goes through your door. The club at the end of your road is running " \
                    "a free session on Saturday morning — no kit needed, no sign-up, turn up " \
                    "and someone will show you what to do." },
        { "id" => "pg_taster_2",
          "text" => "You haven't played since school. You don't know anybody who goes. It is " \
                    "the one morning this week you had nothing booked." }
      ],
      "options" => [ "Go along and see", "Give it a miss" ],
      "option_styles" => [
        { "color" => "#01eacb", "icon" => "start-line" },
        { "color" => "#4f7cff", "emoji" => "🛋️" }
      ],
      "image" => asset("left-panel", "sports-people-desktop-1.jpg"),
      "tokens" => { "Go along and see" => { "pt" => 4 }, "Give it a miss" => { "pt" => 4 } } }
  end

  # Lane B's closing milestone — the flow's exit rewires it onto the rejoin,
  # and the explicit next matches what FlowCompiler would write anyway.
  def checkpoint_card
    { "cid" => "c_checkpoint", "type" => "token_checkpoint", "flow_id" => "f_supporters",
      "text" => "Nice one — here's what you've collected so far.",
      "image" => asset("select-art", "select-icon-8.jpg"),
      "next" => { "card" => "c_range" } }
  end

  # ── Rejoin: everyone plays the rest ──────────────────────────────────────

  # A range card carries no still image — its left panel plays the reactive
  # Lottie character that moves as the slider does, so it gets a `range_theme`
  # and a backdrop colour instead.
  def range_card
    { "cid" => "c_range", "type" => "range",
      "text" => "How much does sport belong in your week?",
      # Short stops on purpose: five labels share one track, and the selected
      # one is drawn larger — anything past about eight characters wraps mid-word
      # on a 390px phone well before it reaches the 17-char budget.
      "options" => [ "Not at all", "A little", "Some", "A lot", "Totally" ],
      "range_theme" => "stopwatch", "slider_axis" => "auto",
      "media_bg" => { "color" => "#1c2a4a" },
      "token_award" => { "pt" => 3 } }
  end

  def prioritise_card
    { "cid" => "c_priority", "type" => "prioritise",
      "text" => "Drag these into the order that matters to you.",
      "options" => [ "Cheaper sessions", "Better facilities", "Closer to home",
                     "Friendlier clubs", "More times to choose" ],
      "option_styles" => [
        { "color" => "#ffb020", "emoji" => "💷" },
        { "color" => "#4f7cff", "icon" => "basketball-court" },
        { "color" => "#01eacb", "icon" => "flag" },
        { "color" => "#ff1e6f", "icon" => "whistle" },
        { "color" => "#8b5cf6", "icon" => "stopwatch" }
      ],
      "image" => asset("select-art", "select-icon-4.jpg"),
      "token_award" => { "pt" => 4 } }
  end

  def yes_no_card
    { "cid" => "c_yes_no", "type" => "yes_no",
      "text" => "Would you like to hear about sessions near you?",
      "option_styles" => [
        { "color" => "#01eacb", "emoji" => "👍" },
        { "color" => "#ff1e6f", "emoji" => "👋" }
      ],
      "image" => asset("left-panel", "sports-people-desktop-2.jpg"),
      "token_award_mode" => "completion", "token_award" => { "pt" => 2 } }
  end

  def select_many_card
    { "cid" => "c_select_many", "type" => "select_many",
      "text" => "Which of these have you done in the last year?",
      "options" => [ "Joined a club", "Played with friends", "Watched live sport",
                     "Volunteered or coached", "Followed a fitness plan" ],
      "option_styles" => [
        { "color" => "#01eacb", "icon" => "football-jersey" },
        { "color" => "#4f7cff", "icon" => "basketball" },
        { "color" => "#ffb020", "icon" => "podium" },
        { "color" => "#ff1e6f", "icon" => "whistle" },
        { "color" => "#8b5cf6", "icon" => "kettlebell" }
      ],
      "allow_other" => true,
      "image" => asset("select-art", "select-icon-6.jpg"),
      "token_award_mode" => "completion", "token_award" => { "pt" => 4 } }
  end

  def open_ended_card
    { "cid" => "c_open", "type" => "open_ended",
      "text" => "What would get you playing more? In your own words.",
      "char_limit" => 300,
      "image" => asset("left-panel", "sports-people-desktop-3.jpg"),
      "token_award" => { "pt" => 5 } }
  end


  # ── simulated respondents ────────────────────────────────────────────────

  # Walks the branch graph the way a respondent does (LogicGraph.next_index),
  # so a lane's cards are only answered by the people the router sent down it —
  # a flat pass over `cards` would answer BOTH lanes for everybody and the
  # results page would report two mutually exclusive populations at full size.
  def seed_responses!(survey)
    region_pool = RESPONSE_REGIONS.flat_map { |country, label, n| Array.new(n) { [ country, label ] } }
    cards       = survey.cards
    token_ids   = survey.token_type_ids

    region_pool.each do |region|
      completed  = rand < COMPLETION_CHANCE
      answers    = simulate_answers(cards, region: region, completed: completed)
      created_at = rand(0..24).days.ago - rand(0..23).hours

      Response.create!(
        survey: survey, session_token: SecureRandom.uuid,
        status: completed ? "completed" : "started",
        answers: answers,
        # A few seconds to about forty on each answered question, skewed
        # short, so the showcase's results page carries dwell figures too.
        dwell_ms: answers.keys.index_with { (2_000 + (rand**2 * 38_000)).round },
        token_totals: TokenGrading.totals(cards, answers, token_ids),
        # One identity per simulated respondent, same rule as the player: the
        # digest only exists while a leaderboard is active. Names are minted
        # lazily at first board view.
        player_key_digest: survey.leaderboard_active? ? survey.player_key_digest(SecureRandom.uuid) : nil,
        # The location question is a demographic tail card, so someone who
        # dropped out early never reached it — only tag a region when they did.
        region_country: completed ? region[0] : nil,
        region_label: completed ? region[1] : nil,
        locale: "en",
        consent_agreed_at: completed ? created_at : nil,
        consent_text_snapshot: completed ? survey.effective_consent_text : nil,
        created_at: created_at, updated_at: created_at
      )
    end
  end

  def simulate_answers(cards, region:, completed:)
    answers = {}
    idx     = 0
    steps   = 0
    # Drop-outs stop a few cards in, like a real one. The budget is the belt to
    # resolve_path's braces: a malformed graph must not spin here.
    limit  = completed ? cards.length + 1 : rand(2..6)

    while idx.is_a?(Integer) && idx >= 0 && idx < cards.length && steps < limit
      card = cards[idx]
      steps += 1
      unless CardTypes::NON_QUESTION_TYPES.include?(card["type"].to_s)
        value = answer_value(card, region: region)
        answers[idx.to_s] = { "type" => card["type"], "value" => value } unless value.nil?
      end
      nxt = LogicGraph.next_index(cards, idx, answers)
      break unless nxt.is_a?(Integer)
      idx = nxt
    end

    answers
  end

  def answer_value(card, region:)
    case card["type"]
    when "multiple_choice", "select_one_grid", "scenario"
      Array(card["options"]).sample
    when "yes_no"
      %w[Yes No].sample
    when "select_many", "select_many_grid"
      opts = Array(card["options"])
      opts.sample(rand(1..[ opts.size, 3 ].min))
    when "tap_card"
      scale = TapScales.keys_for(card)
      Array(card["options"]).index_with { scale.sample }
    when "range", "nps"
      rand(Array(card["options"]).size)
    when "rating"
      rand(1..5)
    when "prioritise"
      Array(card["options"]).shuffle
    when "open_ended"
      case card["input"]
      when "month"    then format("%04d-%02d", rand(1986..2009), rand(1..12))
      when "location" then "#{region[0]}|#{region[1]}"
      else OPEN_ENDED_ANSWERS.sample
      end
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # A curated verto-library asset as the digest path the card sanitiser
  # accepts (Survey::ASSET_IMAGE_URL) — the same form AssetPopulator stores.
  def asset(dir, file)
    ActionController::Base.helpers.image_path("verto-library/#{dir}/#{file}")
  end

  def print_summary(survey)
    puts "\nShowcase Verto seeded into #{survey.organisation.name} (#{ORG_SLUG}):"
    puts "  Title      : #{survey.title}"
    puts "  Editor     : /surveys/#{survey.id}"
    puts "  Test link  : /test/#{survey.test_token}   (records nothing, deck stays editable)"
    if survey.published?
      puts "  Play       : /play/#{survey.publish_token}   (also /play/#{survey.slug})"
    else
      puts "  Play       : not published — Test Mode only"
    end
    puts "  Cards      : #{survey.cards.size} in the deck, #{LogicGraph.longest_path(survey.cards)} on the longest path"
    types = survey.cards.map { |c| c["type"] }.uniq
    puts "  Types      : #{types.join(', ')}"
    puts "  Responses  : #{survey.responses.count} (#{survey.responses.where(status: 'completed').count} completed)"
  end
end
