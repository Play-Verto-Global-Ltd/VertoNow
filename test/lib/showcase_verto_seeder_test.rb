require "test_helper"

# The showcase deck is the shop window for the Rules of the Game AND for the
# answer types themselves, so both are pinned here: it must keep playing every
# type, and it must keep scoring green against the same rules the editor checks
# live (app/javascript/lib/verto_rules.js).
#
# Deck definitions only — nothing here touches the database.
class ShowcaseVertoSeederTest < ActiveSupport::TestCase
  NON_QUESTION = CardTypes::NON_QUESTION_TYPES

  def cards
    @cards ||= ShowcaseVertoSeeder.new.cards
  end

  test "the deck plays every pickable answer type" do
    missing = CardTypes.pickable.map(&:first) - cards.map { |c| c["type"] }
    assert_empty missing, "showcase deck never uses: #{missing.join(', ')}"
  end

  # §1.1 — the scored unit is the longest path ONE respondent can take, not the
  # flat deck: the two lanes are alternatives, so the deck is longer than the
  # play. Mirrors analyzeVerto's longestPathLength.
  test "the longest path a respondent can take lands in the green 12-16 band" do
    assert_includes 12..16, LogicGraph.longest_path(cards)
  end

  test "every branch target resolves and no card is stranded" do
    assert_empty LogicGraph.unreachable(cards), "cards no route reaches"
    cids = cards.map { |c| c["cid"] }.compact
    cards.each do |card|
      Array(card.dig("logic", "routes")).each do |route|
        assert_includes cids, route.dig("to", "card"), "#{card['cid']}: dangling route target"
      end
      if (default = card.dig("logic", "default"))
        assert_includes cids, default["card"], "#{card['cid']}: dangling default target"
      end
      assert_includes cids, card.dig("next", "card"), "#{card['cid']}: dangling next" if card["next"]
    end
  end

  test "every flow a card claims exists, and exits onto a real card" do
    flow_ids = ShowcaseVertoSeeder.new.flows.map { |f| f["id"] }
    cids     = cards.map { |c| c["cid"] }.compact
    cards.filter_map { |c| c["flow_id"] }.uniq.each do |id|
      assert_includes flow_ids, id, "card claims unknown flow #{id}"
    end
    ShowcaseVertoSeeder.new.flows.each do |flow|
      assert_includes cids, flow.dig("exit", "card"), "#{flow['id']}: exit target"
    end
  end

  # §2 — question text targets 50-70 chars, and text + description together
  # must clear the 100-char hard cap. Demographic cards are platform copy and
  # are exempt in the editor's own analysis, so they're exempt here too.
  test "every authored question clears the 70/100 char text budget" do
    scored_cards.each do |card|
      assert_operator card["text"].length, :<=, 70, "over 70: #{card['text'].inspect}"
      total = card["text"].length + card["description"].to_s.length
      assert_operator total, :<=, 100, "text + description over 100: #{card['text'].inspect}"
    end
  end

  # §3 — answer counts, per type (COUNT_RULES).
  test "every card carries the answer count its type calls for" do
    scored_cards.each do |card|
      n = Array(card["options"]).size
      case card["type"]
      when "multiple_choice", "select_many"
        assert_includes [ 3, 5 ], n, "#{card['text']}: image lists are an odd 3-5"
      when "select_one_grid", "select_many_grid"
        assert_includes 4..10, n, "#{card['text']}: grids are 4-10"
        assert_equal 0, n % 2, "#{card['text']}: grids are an even count"
      when "prioritise" then assert_includes 4..5, n, card["text"]
      when "tap_card"   then assert_includes 5..8, n, card["text"]
      when "scenario"   then assert_includes 2..3, n, card["text"]
      when "range"      then assert_equal Survey::RANGE_POINTS, n, card["text"]
      when "rating"     then assert_equal 5, n, card["text"]
      when "nps"        then assert_equal (0..10).map(&:to_s), card["options"], card["text"]
      end
    end
  end

  # §2 — per-type answer-label budgets (OPTION_LIMITS). The two that are
  # enforced rather than advised (grids at 20, range at 17) are the ones a
  # respondent's phone actually breaks on.
  test "every answer label is inside its per-type budget" do
    limits = { "multiple_choice" => 40, "select_many" => 40, "prioritise" => 40,
               "select_one_grid" => 20, "select_many_grid" => 20,
               "range" => 17, "rating" => 20, "nps" => 20,
               "tap_card" => 40, "scenario" => 40 }
    scored_cards.each do |card|
      limit = limits[card["type"]] or next
      Array(card["options"]).each do |opt|
        assert_operator opt.length, :<=, limit, "#{card['type']}: #{opt.inspect} over #{limit}"
      end
    end
  end

  test "every scenario and consent page is inside the page budget" do
    cards.select { |c| Survey::PAGED_TYPES.include?(c["type"]) }.each do |card|
      pages = Array(card["pages"])
      assert_includes 1..5, pages.size, card["text"]
      pages.each { |p| assert_operator p["text"].length, :<=, 400, "page over 400: #{p['text'].inspect}" }
    end
  end

  # §1.4 — never more than two of a type back to back, judged per group a
  # respondent plays straight through (the spine, then each lane) exactly as
  # varietyCheck does.
  test "no group runs the same answer type more than twice in a row" do
    flow_ids = ShowcaseVertoSeeder.new.flows.map { |f| f["id"] }
    groups   = [ cards.reject { |c| flow_ids.include?(c["flow_id"]) } ] +
               flow_ids.map { |id| cards.select { |c| c["flow_id"] == id } }
    groups.each do |group|
      types = group.reject { |c| NON_QUESTION.include?(c["type"]) }.map { |c| c["type"] }
      run   = types.each_cons(3).find { |a, b, c| a == b && b == c }
      assert_nil run, "#{run&.first} appears 3+ times in a row"
    end
  end

  # §1.3 — one welcome card, and it comes first.
  test "the deck opens on exactly one welcome card" do
    assert_equal 1, cards.count { |c| c["type"] == "welcome_card" }
    assert_equal "welcome_card", cards.first["type"]
  end

  # Imagery is half the point of the showcase: every card that CAN carry media
  # has some. A range card is the exception by design — its left panel plays
  # the reactive animation its `range_theme` names, and the model refuses a
  # still image alongside it.
  test "every card carries media of some kind" do
    cards.each do |card|
      media =
        case card["type"]
        # A demographic card carries a fixed image and never a reaction
        # animation — image_demographic_tail gives it one, and AssetPopulator
        # excludes these cards from media population for the same reason it
        # excludes scaffolding. The age slider is a `range` card, so without
        # this branch it would be asked for a theme nothing intends it to have.
        when "range"    then card["demographic"] ? card["image"] : card["range_theme"]
        when "tap_card" then Array(card["option_images"]).presence&.all?(&:present?)
        else                 card["image"]
        end
      assert media.present?, "#{card['type']} (#{card['cid']}) has no media"
    end
  end

  test "every option style names a real icon and a real colour" do
    cards.each do |card|
      Array(card["option_styles"]).compact.each do |style|
        if style["icon"].present?
          assert OptionIconLibrary.valid_id?(style["icon"]), "unknown icon #{style['icon'].inspect}"
        end
        assert BrandPalette.valid_hex?(style["color"]), "bad colour #{style['color'].inspect}" if style["color"]
        assert style["icon"].present? || style["emoji"].present?,
               "#{card['type']}: an option style with neither icon nor emoji"
      end
    end
  end

  test "the range card names a real reaction animation" do
    # Demographic range cards excluded: the age slider is a form field, not an
    # opinion scale, and a character reacting to someone's age band is not the
    # product. AssetPopulator never assigns one either.
    cards.select { |c| c["type"] == "range" && !c["demographic"] }.each do |card|
      assert_includes NpsHelper::RANGE_THEMES, card["range_theme"], card["text"]
    end
  end

  # Points config has to match the answers it grades, or a respondent earns
  # nothing on a card the editor shows as awarding.
  test "every tokens map keys off answers the card actually offers" do
    cards.each do |card|
      tokens = card["tokens"]
      next unless tokens.is_a?(Hash)
      case card["type"]
      when "tap_card"
        assert_equal Array(card["options"]).sort, tokens.keys.sort, "#{card['cid']}: statements"
        scale = TapScales.keys_for(card)
        tokens.each_value { |by_key| assert_equal scale.sort, by_key.keys.sort, "#{card['cid']}: scale" }
      else
        assert_empty tokens.keys - Array(card["options"]), "#{card['cid']}: options"
      end
    end
  end

  # ── how it lands in the account ──────────────────────────────────────────
  # Test Mode, not published: the showcase is handed round and edited, and a
  # published deck is locked (Survey#editing_locked?) and collecting for real.

  test "seeds in Test Mode — a test link, no /play link, no responses" do
    survey = seed!
    assert survey.test_playable?, "no test link minted"
    assert_not survey.published?, "showcase should not be published by default"
    assert_not survey.editing_locked?, "the deck must stay editable"
    assert_equal 0, survey.responses.count
  end

  test "publishing and simulated respondents are opt-in" do
    survey = seed!(publish: true, responses: true)
    assert survey.published?
    assert survey.test_playable?, "a published showcase keeps its test link too"
    assert_equal ShowcaseVertoSeeder::RESPONSE_COUNT, survey.responses.count
  end

  test "ensure_test_mode! takes a published showcase off /play and keeps its test link" do
    survey = seed!(publish: true)
    token  = survey.test_token

    ShowcaseVertoSeeder.new.ensure_test_mode!
    survey.reload

    assert_not survey.published?, "should have come off /play"
    assert survey.test_playable?
    assert_equal token, survey.test_token, "an existing test link must not be rotated"
  end

  test "ensure_test_mode! provisions the Verto when it isn't there at all" do
    playverto_org
    survey = ShowcaseVertoSeeder.new.ensure_test_mode!
    assert survey.test_playable?
    assert_not survey.published?
  end

  private

  def playverto_org
    Organisation.find_or_create_by!(slug: ShowcaseVertoSeeder::ORG_SLUG) { |o| o.name = "Playverto" }
  end

  def seed!(**opts)
    playverto_org
    ShowcaseVertoSeeder.new(force: true, **opts).call
  end

  # The cards the editor's per-card analysis actually scores: questions, minus
  # the demographic tail (a fixed platform taxonomy the creator can't edit, and
  # exempt from the count/label rules in analyzeCard for that reason).
  def scored_cards
    cards.reject { |c| NON_QUESTION.include?(c["type"]) || c["demographic"] }
  end
end
