class Survey < ApplicationRecord
  belongs_to :organisation
  has_many :responses, dependent: :destroy
  has_many :survey_shares, dependent: :destroy
  # Named share links — extra /play/ addresses for this Verto, each with its own
  # respondent-facing overrides. See SurveyLink.
  has_many :survey_links, dependent: :destroy
  # Explicit open/close cycles of running the same Verto again to measure
  # change — see start_next_wave! for why these are real records rather than
  # a derived time window.
  has_many :survey_waves, -> { order(:position) }, dependent: :destroy
  has_many :partnership_vertos, dependent: :destroy
  has_many :report_renders, dependent: :destroy
  # Free-text answers held for moderation — see HeldText. delete_all: the
  # responses (declared above, so destroyed first) already take theirs with
  # them; this catches nothing in practice and costs one DELETE.
  has_many :held_texts, dependent: :delete_all
  # Accounts that kept this Verto. delete_all for the same reason as
  # held_texts: the responses declared above take theirs first, and this
  # catches whatever a direct survey destroy would otherwise leave behind a
  # RESTRICT foreign key.
  has_many :player_claims, dependent: :delete_all
  # Told-them records, same delete_all reasoning as player_claims above.
  has_many :player_notifications, dependent: :delete_all
  has_many :flow_generations, dependent: :destroy
  # Language check — the per-(card, language) review state, the notes left on
  # those lines, and the shareable links that let somebody without an account
  # leave either. All three go with the Verto: they are commentary on THIS
  # deck's wording and mean nothing without it.
  has_many :language_checks, dependent: :delete_all
  has_many :language_check_notes, dependent: :delete_all
  has_many :language_check_links, dependent: :destroy
  # Per-language translation runs — what the Language check rail reads to say
  # whether a language is coming, done, or failed. See SurveyTranslation.
  has_many :survey_translations, dependent: :delete_all
  # Builds outlive the Verto they produced — they're the account's generation
  # log, deleted with the organisation, not the survey. Nullify rather than
  # nothing because verto_builds.survey_id carries a real FK: without this,
  # destroying a survey that a build points at raises InvalidForeignKey
  # (bitten in production by verto:import_csv rebuilding an org whose
  # placeholder Verto was wizard-built).
  has_many :verto_builds, dependent: :nullify
  # The Verto's Ask Verto consent record. Destroyed with it, so a deleted Verto
  # cannot leave a corpus entry that still reads as citable.
  has_one :corpus_entry, dependent: :destroy
  # The leaderboard's anonymous names. Scoped to the Verto (a name is an
  # identity on ONE board) and gone with it.
  has_many :player_aliases, dependent: :destroy
  # Derived rows (see LeaderboardStanding) — delete_all, not destroy: there are
  # no callbacks to run and a big board would destroy row-by-row for nothing.
  has_many :leaderboard_standings, dependent: :delete_all
  # Same contract as player_aliases for the responder names the export and
  # results page group by.
  has_many :respondent_aliases, dependent: :destroy
  has_many :contact_details, dependent: :destroy

  # Creator-uploaded card/background imagery. Previously these lived inline in
  # the `cards` JSON as base64 data-URLs, which meant every render of a Verto
  # re-materialized several MB of image data into memory — the acknowledged
  # driver behind the production 502s on a 512MB instance (P1-7). Now the bytes
  # live in Active Storage (a persistent Render disk) and the cards JSON keeps
  # only a short /rails/active_storage/... path.
  #
  # Attached to the Verto, not the organisation, so they purge with it and stay
  # out of the account's curated brand-asset library (Organisation#assets).
  has_many_attached :card_images

  CARD_IMAGE_CONTENT_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze
  # Matches the client-side downscale budget (1600px longest edge, WebP q0.82);
  # generous enough for an image that skipped downscaling, small enough that a
  # deck can't fill the disk.
  CARD_IMAGE_MAX_BYTES = 3.megabytes

  scope :recent,   -> { order(updated_at: :desc) }
  scope :kept,     -> { where(deleted_at: nil) }
  scope :archived, -> { where.not(deleted_at: nil) }

  # Range cards are always a 5-point scale (see RANGE_POINTS). Enforced on the
  # way in so every authoring path is covered by one rule, and skipped once a
  # Verto is live or has been answered: a stored answer is an INDEX into the
  # scale it was collected on, so resizing an answered card's options would
  # silently re-point every response already gathered. Guarded on
  # editing_locked? rather than published? because a deck CAN reach a save with
  # responses behind it — an account LiveEditAccess allows past the lock saves
  # live and closed decks — and what protects the stored answers is that the
  # normaliser never touches a card anyone has answered, not that the save is
  # refused.
  before_save :enforce_range_scale, if: -> { will_save_change_to_cards? && !editing_locked? }

  # An option label's own emoji belongs in that option's icon tile, not beside
  # its words. Same guard as above and for the same reason: an option label is
  # the answer key for responses already collected, so an answered Verto is
  # never rewritten. See hoist_option_label_emoji! for the full rules.
  before_save :hoist_option_label_emoji, if: -> { will_save_change_to_cards? && !editing_locked? }

  # Inline base64 images never reach a column. CardImageStore and the backfill
  # task moved the EXISTING data-URLs out (P1-7), but the door stayed open:
  # sanitize_image_url still accepts a data-URL, so every write path — the
  # editor's upload fallback, background and consent images, imports, generated
  # decks — could put megabytes of base64 straight back. Cleaning up history
  # without closing the door just means doing it again.
  #
  # Here rather than in the sanitizers because it catches every path at once,
  # including the ones no sanitizer covers, and because it needs a persisted
  # survey to attach a blob to.
  before_save  :externalize_inline_images
  after_create :externalize_inline_images_after_create

  # Large AI-generated TEXT columns only needed on the results path. Omit them
  # everywhere else (editor, dashboard, player, preview) so multi-KB blobs
  # aren't loaded into every row for nothing — a pure baseline memory saving.
  # A record loaded this way must not write these columns (they're absent);
  # the results path and surveys#update load the full row.
  HEAVY_REPORT_COLUMNS = %w[results_summary results_report].freeze
  scope :without_report_text, -> { select(column_names - HEAVY_REPORT_COLUMNS) }

  def deleted?
    deleted_at.present?
  end

  # Languages this Verto exists in, primary (default_locale) first. Legacy
  # Vertos with no `locales` set fall back to just their primary language.
  def verto_locales
    ([ default_locale ] + SupportedLocales.sanitize_list(read_attribute(:locales), fallback: [])).uniq
  end

  # Translation languages — everything except the primary.
  def secondary_locales
    verto_locales - [ default_locale ]
  end

  def multilingual?
    verto_locales.size > 1
  end

  # The Verto content language to render for a viewer: the first preferred
  # candidate the Verto exists in, else its primary language.
  def display_locale_for(*preferred)
    preferred.flatten.compact.map(&:to_s).find { |l| verto_locales.include?(l) } || default_locale
  end

  # Re-point the Verto at a different primary language, swapping canonical and
  # translated text so nothing is lost: today's canonical fields move into
  # i18n[old primary], and i18n[new primary] becomes the canonical text.
  #
  # Guarded hard, because the canonical text is more than words. Stored answers
  # carry canonical option labels, and quiz `correct` and the token map are
  # KEYED by them — so the swap is only legal while nobody has answered and the
  # deck is still editable, and label-keyed structures are remapped positionally
  # (option order is the identity, exactly the invariant SurveyTranslator
  # preserves). A card whose translation is missing or misaligned keeps its
  # canonical text for that field — visible in the editor, never corrupting.
  def switch_primary_locale!(new_locale)
    new_locale = new_locale.to_s
    return false if new_locale == default_locale
    raise ArgumentError, "not one of this Verto's languages" unless verto_locales.include?(new_locale)
    raise ArgumentError, "questions are locked" if editing_locked?
    raise ArgumentError, "already has responses" if responses.exists?

    old_locale = default_locale
    swapped = Array(cards).map { |c| self.class.swap_card_primary(c, old_locale, new_locale) }
    update!(
      cards:          swapped,
      default_locale: new_locale,
      locales:        ([ new_locale ] + (verto_locales - [ new_locale ])).uniq
    )
    true
  end

  # One card's half of the swap above. Class method so it is testable on a bare
  # hash; returns a new hash, never mutates.
  def self.swap_card_primary(card, old_locale, new_locale)
    return card unless card.is_a?(Hash)

    entry = card.dig("i18n", new_locale)
    out = card.dup
    old_entry = {
      "text"        => card["text"].to_s,
      "description" => card["description"].presence,
      "options"     => (card["options"].presence if card["options"].is_a?(Array)),
      "pages"       => (Array(card["pages"]).map { |p| p.slice("id", "text") }.presence if card["pages"].is_a?(Array)),
      "explanation" => card["explanation"].presence,
      "modal_title" => card["modal_title"].presence,
      "modal_body"  => card["modal_body"].presence,
      "nps_low_label"  => card["nps_low_label"].presence,
      "nps_high_label" => card["nps_high_label"].presence,
      "responses"   => (Array(card["responses"]).map { |r| r["label"].to_s }.presence if card["responses"].is_a?(Array))
    }.compact

    if entry.is_a?(Hash)
      out["text"]        = entry["text"] if entry["text"].present?
      out["description"] = entry["description"] if entry["description"].present?
      out["explanation"] = entry["explanation"] if entry["explanation"].present?
      # The modal's words move with the rest. Its rich-text layer does not:
      # `modal_body_html` describes the OLD language's characters, so promoting
      # a translation without dropping it would leave formatting spans pointing
      # at text that is no longer there — the sanitiser's equivalence check
      # drops it on the next save anyway, and doing it here keeps the swap
      # atomic rather than one-save-later.
      if entry["modal_title"].present? || entry["modal_body"].present?
        out["modal_title"] = entry["modal_title"] if entry["modal_title"].present?
        out["modal_body"]  = entry["modal_body"]  if entry["modal_body"].present?
        out.delete("modal_body_html")
      end
      # The NPS anchor lines move like explanation: plain scalars, per field.
      NPS_ANCHOR_KEYS.each { |k| out[k] = entry[k] if entry[k].present? }

      # Pages swap by id — the id is the page's identity across languages.
      if out["pages"].is_a?(Array) && entry["pages"].is_a?(Array)
        by_id = entry["pages"].each_with_object({}) { |p, h| h[p["id"].to_s] = p["text"] if p.is_a?(Hash) }
        out["pages"] = out["pages"].map do |p|
          t = p.is_a?(Hash) ? by_id[p["id"].to_s] : nil
          t.present? ? p.merge("text" => t) : p
        end
      end

      # Options swap positionally — and only when the counts agree, because a
      # short translation would silently shear labels off the end. When they
      # swap, everything keyed by the old canonical labels moves with them.
      old_options = Array(card["options"])
      new_options = Array(entry["options"])
      if old_options.any? && new_options.length == old_options.length
        mapping = old_options.map.with_index { |o, i| [ o.to_s, new_options[i].to_s ] }.to_h
        out["options"] = new_options
        out["correct"] = remap_canonical_labels(card["correct"], mapping) if card.key?("correct")
        out["tokens"]  = card["tokens"].transform_keys { |k| mapping.fetch(k.to_s, k) } if card["tokens"].is_a?(Hash)
      end

      # Tap scale labels are positional too, alongside stable keys.
      resp_labels = Array(entry["responses"])
      if out["responses"].is_a?(Array) && resp_labels.length == out["responses"].length
        out["responses"] = out["responses"].each_with_index.map do |r, i|
          resp_labels[i].to_s.strip.present? ? r.merge("label" => resp_labels[i].to_s.strip) : r
        end
      end
    end

    i18n = (card["i18n"] || {}).except(new_locale).merge(old_locale => old_entry)
    out.merge("i18n" => i18n)
  end

  # `correct` is a canonical label (choice), an array of them (select-many), or
  # a {statement => response_key} hash (tap) — statements are the labels there.
  def self.remap_canonical_labels(correct, mapping)
    case correct
    when String then mapping.fetch(correct, correct)
    when Array  then correct.map { |c| mapping.fetch(c.to_s, c) }
    when Hash   then correct.transform_keys { |k| mapping.fetch(k.to_s, k) }
    else correct
    end
  end

  # Returns a copy of `cards` with `translated` (an array, aligned per-card, of
  # { "text", "description", "options" }) merged into each card's i18n[locale].
  # Structural fields are untouched, so positional answer alignment is preserved.
  def self.merge_card_translations(cards, locale, translated)
    Array(cards).each_with_index.map do |card, i|
      t = translated[i]
      next card unless t.is_a?(Hash)

      entry = {
        "text"        => t["text"].to_s,
        "description" => t["description"].presence,
        "options"     => Array(t["options"]),
        # Scenario narrative pages and quiz answer feedback — respondent-facing
        # copy that would otherwise sit in the source language in every
        # secondary locale. Only written when the translation carried them, so
        # an ordinary question card's i18n entry stays the same shape as before.
        "pages"       => Array(t["pages"]).presence,
        "explanation" => t["explanation"].presence,
        # The intro modal's words. Respondent-facing copy like everything else
        # here, so a Spanish respondent meets a Spanish modal rather than the
        # creator's English over a translated question.
        "modal_title" => t["modal_title"].presence,
        "modal_body"  => t["modal_body"].presence,
        # The anchor lines beside an NPS scale's ends — the words that tell a
        # respondent what 0 and 10 mean, so they had better be in their language.
        "nps_low_label"  => t["nps_low_label"].presence,
        "nps_high_label" => t["nps_high_label"].presence
      }.compact
      card.merge("i18n" => (card["i18n"] || {}).merge(locale.to_s => entry))
    end
  end

  # Add languages to this Verto and say which ones were actually new.
  #
  # Two screens offer this — the editor's Language settings and the Language
  # check screen's own sidebar — and they must mean the same thing, because the
  # thing they mean is "translate the deck into these": a second implementation
  # that forgot to enqueue, or enqueued for a language already carried (which
  # would re-translate over hand-edited wording), is a bug nobody would see
  # until a reviewer's Spanish quietly reverted. The caller enqueues; this
  # decides what is new.
  #
  # Never removes. Both callers that DESELECT a language go through a full
  # replacement of `locales` instead, because unticking is a different act with
  # a different guarantee (the translation stays stored, so re-ticking is
  # instant) and folding the two together would make one of them lie.
  def add_locales!(codes)
    wanted = SupportedLocales.sanitize_list(codes, fallback: [])
    added  = wanted - verto_locales
    return [] if added.empty?

    update!(locales: (verto_locales + added).uniq)
    added
  end

  # The languages this Verto OFFERS but cannot actually serve: the switcher
  # lists them, the platform's own chrome translates, and then every card reads
  # in the primary language because no entry was ever written for them.
  #
  # Adding a language is not the only way to end up here. A DUPLICATE inherits
  # `locales` and whatever i18n the cards happened to carry, and enqueues
  # nothing — so copying a Verto whose Spanish never landed produced a second
  # Verto claiming Spanish just as falsely, with no run recorded anywhere to
  # say so. Reported from a live study: the language switcher worked, the
  # buttons turned Spanish, and every question stayed in English.
  #
  # The per-card test is TranslateLocalesJob's own, deliberately: "needs
  # translating" has to mean the same thing to the code that asks for a run and
  # the code that performs one, or one of them re-runs work the other thinks is
  # finished. A locale the job would find nothing missing for is not returned
  # here either.
  def locales_awaiting_translation
    deck = Array(cards)
    return [] if deck.empty?

    verto_locales.reject { |loc| loc == default_locale }
                 .select { |loc| deck.any? { |c| c.is_a?(Hash) && c.dig("i18n", loc).blank? } }
  end

  # ── Language check edits ───────────────────────────────────────────────────
  # Write one line's wording back into the deck, from the Language check screen.
  # This is the "and all edits appear in the Verto itself" half of that feature:
  # there is no parallel store of suggested text, a reviewer's fix IS the card's
  # text the moment they save it, and the player serves it on the next request.
  #
  # `fields` is a subset of LanguageCheckLines::FIELDS, as typed. What it may
  # change depends entirely on which language is being edited, and the reason is
  # that the two are not the same kind of thing:
  #
  #   * A SECONDARY language's words are labels for someone else's answers.
  #     Nothing is keyed by them — responses are stored against the canonical
  #     option (see merge_card_translations) — so they are always safe to edit,
  #     live Verto or not.
  #   * The PRIMARY language's option labels ARE the answer key. Stored answers
  #     carry them, and quiz `correct` and the token map are keyed by them. So
  #     canonical lists are editable only while the deck still is
  #     (editing_locked?), exactly the guard switch_primary_locale! uses, and
  #     for exactly the same reason. Question text and sub-text carry no keys
  #     and stay editable — fixing a typo in a live question is the single most
  #     common thing a reviewer will want to do.
  #
  # List fields are written POSITIONALLY and never resized: option N in any
  # language is a label for option N. A submitted list longer or shorter than
  # the canonical one is truncated/padded against it rather than rejected, so a
  # reviewer cannot shear a deck's alignment by adding a line in a textarea.
  #
  # Returns true when something actually changed; false when the edit was a
  # no-op, so the caller can leave the revision counter (and the row's
  # edited_at) alone rather than logging an edit nobody made.
  def apply_language_edit!(cid:, locale:, fields:)
    locale = locale.to_s
    raise ArgumentError, "not one of this Verto's languages" unless verto_locales.include?(locale)

    deck  = Array(cards).deep_dup
    index = deck.index { |c| c.is_a?(Hash) && c["cid"].to_s == cid.to_s }
    return false if index.nil?

    updated = self.class.apply_card_language_edit(
      deck[index], locale, fields,
      primary: default_locale, structural: !editing_locked?
    )
    return false if updated == deck[index]

    deck[index] = updated
    # increment! would issue its own UPDATE; one write for both keeps the deck
    # and the revision that describes it in a single statement.
    update!(cards: deck, translations_revision: translations_revision + 1)
    true
  end

  # One card's half of the edit above. Class method so it is testable on a bare
  # hash; returns a new hash, never mutates.
  def self.apply_card_language_edit(card, locale, fields, primary:, structural:)
    return card unless card.is_a?(Hash)
    submitted = (fields || {}).stringify_keys.slice(*LanguageCheckLines::FIELDS)
    return card if submitted.empty?

    locale == primary.to_s ?
      apply_canonical_edit(card, submitted, structural: structural) :
      apply_translation_edit(card, locale, submitted)
  end

  # The primary language: canonical fields, written in place. See the list
  # restriction in apply_language_edit!.
  #
  # Every field edited here drops its rich-text twin (`text_html`,
  # `description_html`, `options_html`, a page's `html`). Those are
  # presentation-only copies of the SAME words, and the player renders the twin
  # in preference to the plain text whenever the two still agree
  # (ApplicationHelper#rich_card_text). Leaving a twin behind after rewriting
  # the words underneath it means the respondent keeps reading the old
  # sentence, in bold — the reviewer's fix landing in the column and never
  # reaching the screen, which is the worst failure this feature could have.
  # Dropping it is also exactly what sanitize_cards_images! would do on the
  # next editor save (clean_equivalent refuses a diverged twin); doing it here
  # means the deck is never briefly serving one.
  def self.apply_canonical_edit(card, submitted, structural:)
    out = card.dup

    LanguageCheckLines::SCALAR_FIELDS.each do |field|
      next unless submitted.key?(field)
      # `text` is a question and must not be blanked — a card with no words is
      # not an edit, it is a card nobody can answer. Sub-text and a quiz
      # explanation are genuinely optional, so clearing them is a real choice.
      value = submitted[field].to_s.strip
      next if field == "text" && value.blank?
      # The two scale captions carry the same rules the cards sanitiser applies
      # (NpsHelper::NPS_ANCHOR_MAX, and only on an NPS card) — this path writes
      # straight onto the deck, and a locked Verto is never re-sanitised, so
      # there is nowhere else for them to be enforced.
      next if Survey::NPS_ANCHOR_KEYS.include?(field) && out["type"].to_s != "nps"
      value = value.first(NpsHelper::NPS_ANCHOR_MAX) if Survey::NPS_ANCHOR_KEYS.include?(field)
      next if out[field].to_s == value
      out[field] = value
      out.delete("#{field}_html")
    end

    if structural
      if submitted.key?("options") && out["options"].is_a?(Array)
        aligned = align_labels(out["options"], submitted["options"])
        if aligned != out["options"]
          # Per slot: a twin is only stale for the option whose words moved, and
          # dropping the whole array would strip formatting a reviewer never
          # touched.
          if out["options_html"].is_a?(Array)
            html = Array(out["options_html"])
            out["options_html"] = aligned.each_with_index.map do |label, i|
              label == out["options"][i] ? html[i] : nil
            end
          end
          out["options"] = aligned
        end
      end
      if submitted.key?("responses") && out["responses"].is_a?(Array)
        labels = align_labels(out["responses"].map { |r| r.is_a?(Hash) ? r["label"].to_s : "" },
                              submitted["responses"])
        out["responses"] = out["responses"].each_with_index.map do |r, i|
          r.is_a?(Hash) && labels[i].present? ? r.merge("label" => labels[i]) : r
        end
      end
    end

    if submitted.key?("pages") && out["pages"].is_a?(Array)
      by_id = page_texts(submitted["pages"])
      out["pages"] = out["pages"].map do |p|
        next p unless p.is_a?(Hash)
        text = by_id[p["id"].to_s].to_s
        next p if text.blank? || text == p["text"].to_s
        p.merge("text" => text).except("html")
      end
    end

    out
  end

  # A secondary language: the card's i18n entry for that locale, in the shape
  # merge_card_translations writes and the player reads.
  def self.apply_translation_edit(card, locale, submitted)
    entry = card.dig("i18n", locale)
    entry = {} unless entry.is_a?(Hash)
    entry = entry.dup

    LanguageCheckLines::SCALAR_FIELDS.each do |field|
      next unless submitted.key?(field)
      value = submitted[field].to_s.strip
      next if Survey::NPS_ANCHOR_KEYS.include?(field) && card["type"].to_s != "nps"
      value = value.first(NpsHelper::NPS_ANCHOR_MAX) if Survey::NPS_ANCHOR_KEYS.include?(field)
      # Blank removes the override, which is not the same as storing "". The
      # player falls back to the primary language for a missing field, so
      # clearing a translation means "show the original here" — a real and
      # useful answer for a brand name a translator should have left alone.
      value.blank? ? entry.delete(field) : entry[field] = value
    end

    LanguageCheckLines::LIST_FIELDS.each do |field|
      next unless submitted.key?(field)
      canonical = field == "responses" ?
        Array(card["responses"]).map { |r| r.is_a?(Hash) ? r["label"].to_s : "" } :
        Array(card[field]).map(&:to_s)
      next if canonical.empty?
      entry[field] = align_labels(canonical, submitted[field], blank_to: "")
    end

    if submitted.key?("pages") && card["pages"].is_a?(Array)
      by_id = page_texts(submitted["pages"])
      entry["pages"] = Array(card["pages"]).filter_map do |p|
        next unless p.is_a?(Hash) && p["id"].present?
        { "id" => p["id"].to_s, "text" => by_id[p["id"].to_s].to_s }
      end
    end

    entry = entry.reject { |_, v| v.is_a?(String) && v.blank? }
    i18n  = (card["i18n"] || {}).dup
    entry.empty? ? i18n.delete(locale) : i18n[locale] = entry
    out = card.dup
    i18n.empty? ? out.delete("i18n") : out["i18n"] = i18n
    out
  end

  # Positional, never resizing: the canonical list decides how many labels
  # there are, because its length is the alignment every stored answer depends
  # on. A submitted slot that is blank keeps the canonical label (the primary
  # language) or becomes "" (a translation, where blank means "fall back"),
  # depending on which side is being written.
  def self.align_labels(canonical, submitted, blank_to: nil)
    given = Array(submitted).map { |v| v.to_s.strip }
    canonical.each_with_index.map do |canon, i|
      value = given[i].to_s
      value.present? ? value : (blank_to.nil? ? canon.to_s : blank_to)
    end
  end

  def self.page_texts(submitted)
    Array(submitted).each_with_object({}) do |p, h|
      next unless p.is_a?(Hash) && p["id"].present?
      h[p["id"].to_s] = p["text"].to_s.strip
    end
  end

  # Carry the database's wording forward over an editor payload that provably
  # could not have seen it.
  #
  # SurveysController#update replaces `cards` wholesale from the editor's DOM,
  # i18n entries included — rebuilt from a store seeded once at page load. So an
  # editor tab opened before a reviewer fixed the French writes the old French
  # back on its next autosave, and nothing says so. `pairs` is the set of
  # (cid, locale) the Language check screen has changed since the revision the
  # client was rendered at; only those are overruled, so the creator's own
  # translation edits in that same tab still land.
  #
  # Same shape and same reasoning as keep_setup_media — see its comment for the
  # general case of two writers holding different truths about one deck.
  def self.keep_reviewed_translations(existing, incoming, pairs, primary:)
    return incoming if pairs.blank?

    by_cid = Array(existing).each_with_object({}) do |c, h|
      h[c["cid"].to_s] = c if c.is_a?(Hash) && c["cid"].present?
    end
    wanted = pairs.group_by { |cid, _| cid.to_s }.transform_values { |ps| ps.map(&:last).map(&:to_s) }

    Array(incoming).map do |card|
      next card unless card.is_a?(Hash)
      locales = wanted[card["cid"].to_s]
      next card if locales.blank?
      stored = by_cid[card["cid"].to_s]
      next card unless stored.is_a?(Hash)

      locales.reduce(card) do |out, locale|
        if locale == primary.to_s
          # The primary language's words are the card's own fields. Only the
          # ones the Language check screen can write are carried — the rest of
          # the card (type, imagery, branching, token map) is the editor's to
          # change and must pass through untouched.
          kept = stored.slice(*(LanguageCheckLines::SCALAR_FIELDS + %w[options responses pages]))
          out.merge(kept.compact)
        else
          entry = stored.dig("i18n", locale)
          i18n  = (out["i18n"] || {}).dup
          entry.is_a?(Hash) ? i18n[locale] = entry : i18n.delete(locale)
          i18n.empty? ? out.except("i18n") : out.merge("i18n" => i18n)
        end
      end
    end
  end

  # The creator's AI-report brief (goal / audience / length), stored as JSON
  # text so count-triggered regenerations reuse it. Always returns a Hash.
  def results_report_brief_data
    JSON.parse(results_report_brief.presence || "{}")
  rescue JSON::ParserError
    {}
  end

  # This Verto's own palette (the three user-set roles). Legacy Vertos with no
  # palette fall back to the Playverto default so they render unchanged.
  def brand_palette
    read_attribute(:brand_palette).presence || BrandPalette::DEFAULT
  end

  def resolved_brand_palette
    BrandPalette.resolve(brand_palette)
  end

  # Accept only an uploaded data-image URL or an app-rooted image asset path,
  # so the value is safe to drop into an inline `style` attribute. Anything
  # else (or blank) clears the background.
  DATA_IMAGE_URL  = %r{\Adata:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\s]+\z}
  # The extensions a same-origin image path may end in. Named once and
  # interpolated into the two patterns below, because uploaders have to name a
  # blob so that it PASSES those patterns (see Survey.image_extension?) — and a
  # rule spelled out separately in each place that needs it is how BUG-031/032
  # happened. `image/jpeg` is stored as `.jpg`, but a creator's own file may
  # well be `.jpeg`, so both are accepted.
  IMAGE_EXTENSIONS = %w[png jpg jpeg webp svg gif].freeze
  IMAGE_EXT_GROUP  = "(?:#{IMAGE_EXTENSIONS.join('|')})".freeze
  ASSET_IMAGE_URL = %r{\A/[\w\-./]+\.#{IMAGE_EXT_GROUP}\z}i
  # Same-origin Active Storage image paths — the organisation brand-asset
  # library (and logos). Broader than ASSET_IMAGE_URL because a signed-id path
  # segment can carry base64url characters ASSET_IMAGE_URL's charset excludes,
  # and blob URLs may append a query. Still anchored to the app's OWN
  # /rails/active_storage/ mount and an image extension, and it excludes quotes/
  # angles/whitespace so it stays safe inside an inline `url('…')` style.
  ACTIVE_STORAGE_IMAGE_URL = %r{\A/rails/active_storage/[^\s'"<>?]+\.#{IMAGE_EXT_GROUP}(?:\?[^\s'"<>]*)?\z}i
  # Same-origin Active Storage animation JSON — the ONLY form a card `lottie`
  # value may take. Pasted LottieFiles URLs are fetched, scrubbed and stored by
  # CardLottieStore first (see there for why hotlinking was rejected), so an
  # external URL reaching this sanitiser is always dropped.
  ACTIVE_STORAGE_LOTTIE_URL = %r{\A/rails/active_storage/[^\s'"<>?]+\.json(?:\?[^\s'"<>]*)?\z}i
  # Pexels CDN URLs (host-whitelisted) so editor-picked and auto-populated
  # stock photos survive the sanitizer. No quotes/parens, so it stays safe to
  # interpolate into an inline `url('…')` style.
  PEXELS_IMAGE_URL = %r{\Ahttps://images\.pexels\.com/[\w\-./]+\.(?:png|jpe?g|webp)(?:\?[\w%\-=&.+]*)?\z}i
  # Photographer-credit link target: a pexels.com page (the photographer's
  # profile). Doubles as the "link back to Pexels" the API guidelines ask for.
  PEXELS_CREDIT_URL = %r{\Ahttps://(?:www\.)?pexels\.com/[\w@\-./?=&%]*\z}i
  MAX_CREDIT_NAME   = 80
  MAX_LANE_LABEL    = 60 # branch name shown on the flow map (stored on the entry card)
  MAX_CARD_SUBJECT  = 60 # CardSubjectExtractor's photographable-noun-phrase stamp
  MAX_SCENARIO_PAGES       = 6
  MAX_SCENARIO_PAGE_LENGTH = 600
  # The intro modal — a creator-written pop-up shown OVER the card it explains,
  # the first time a respondent lands on it.
  #
  # Stored as two flat scalars on the card rather than as a card of its own,
  # and that is the whole design. A card's INDEX in `cards` is the key every
  # stored answer is filed under, so a modal inserted as a card would re-point
  # every answer after it and no Verto that has collected anything could ever
  # gain one. Hung on the card it explains, it changes no positions — which is
  # also what "appears over the NEXT question" means, stated as data.
  #
  # Flat scalars rather than a nested hash because the translation machinery is
  # built around field families: adding these two to
  # LanguageCheckLines::SCALAR_FIELDS is the whole of their translation,
  # review and write-back story (see apply_translation_edit / apply_primary_edit).
  MAX_MODAL_TITLE = 120
  MAX_MODAL_BODY  = 600
  # The plain-language "what this card tells you" line in the Why panel. Free
  # text, so bounded rather than allowlisted — the competency and condition
  # beside it are checked against Framework instead.
  MAX_OUTCOME_LENGTH       = 200
  # Card types whose content is stored as `pages` — a bounded array of
  # { id, text }. They share one sanitiser, one page-turn widget
  # (scenario_controller.js) and the same id-keyed translation handling.
  PAGED_TYPES = %w[scenario consent_gate].freeze

  # Card types whose options can carry per-option visual overrides
  # (`option_styles`: color / icon / emoji). The tile-and-label answer shapes —
  # scale, swipe and free-text types have no per-option tile to style.
  OPTION_STYLE_TYPES = %w[multiple_choice select_many prioritise yes_no select_one_grid select_many_grid scenario].freeze

  # The two types a respondent can tick more than one answer on, and so the
  # only two a choice CEILING means anything on. Every other type is
  # single-answer by construction — `max_choices` is dropped anywhere else.
  MULTI_SELECT_TYPES = %w[select_many select_many_grid].freeze
  # Below two a "limit" is just single-select wearing a checkbox, and the type
  # to reach for is multiple_choice.
  MIN_MAX_CHOICES = 2

  # ── Verto typeface ───────────────────────────────────────────────────────
  # The font a Verto is set in, picked in the Design panel beside its colours.
  # Deliberately the SAME seven families the rich-text toolbar already offers
  # per text selection (RichTextSanitizer::FONT_CLASSES is the authority, so
  # the two can't drift): every one is self-hosted under public/fonts and
  # already loaded, so a Verto font costs no extra request and needs nothing
  # added to the CSP. The stored value is the class token; nil = the platform
  # default. The CSS stack lives here because the browser needs a real
  # font-family value, not a class, when it comes through a custom property.
  BRAND_FONTS = {
    "font-abeezee"  => { label: "ABeeZee", stack: %('ABeeZee', sans-serif) },
    "font-alata"    => { label: "Alata",   stack: %('Alata', sans-serif) },
    "font-poppins"  => { label: "Poppins", stack: %('Poppins', sans-serif) },
    "font-lora"     => { label: "Lora",    stack: %('Lora', serif) },
    "font-spectral" => { label: "Spectral", stack: %('Spectral', serif) },
    "font-anton"    => { label: "Anton",   stack: %('Anton', sans-serif) },
    "font-caveat"   => { label: "Caveat",  stack: %('Caveat', cursive) }
  }.freeze

  # Allowlist-or-nil, the same shape every other creator-supplied style value
  # takes — the value reaches an inline `style` attribute, so nothing that
  # isn't a known token may pass.
  def self.sanitize_brand_font(value)
    v = value.to_s.strip
    BRAND_FONTS.key?(v) ? v : nil
  end

  # The CSS font stacks for this Verto, or nil where it uses the default.
  # `brand_font` is the BODY face and the base for the whole Verto;
  # `brand_font_heading` overrides it for questions and titles only. A blank
  # heading font means headings follow the body — which is what every Verto
  # did before headings were separable, so nothing changes until it's set.
  def brand_font_stack
    BRAND_FONTS.dig(brand_font.to_s, :stack)
  end

  def brand_font_heading_stack
    BRAND_FONTS.dig(brand_font_heading.to_s, :stack)
  end

  # Free-text answer length. This used to be a hardcoded 200 in the card
  # partial, and it was advisory only — no maxlength on the textarea and no
  # server check anywhere, so the counter turned pink and the answer saved in
  # full regardless. Now it's per-card and actually enforced.
  # A rating card is always five stars. Answers are stored as the star NUMBER
  # and results count 1..5, so this is the card type's contract rather than a
  # function of how many captions a particular card happens to carry — a card
  # with only min/max labels is still a five-star card.
  RATING_STARS = 5

  DEFAULT_FREE_TEXT_LIMIT = 200
  # Bounds on what a creator can choose. The floor keeps a limit from being set
  # so low the question can't be answered; the ceiling keeps a single answer from
  # becoming the thing that bloats the answers JSON.
  FREE_TEXT_LIMIT_RANGE = (20..2000).freeze
  # Offered in the editor. The default is in the list so the control always shows
  # the current value, including on decks that never set one.
  FREE_TEXT_LIMIT_PRESETS = [ 80, 140, DEFAULT_FREE_TEXT_LIMIT, 500, 1000 ].freeze

  # Every Range card is a 5-point scale — never 4, never 3. An even scale has
  # no true centre, so someone who genuinely sits in the middle is forced to
  # lean; and a deck mixing 3-, 4- and 5-point sliders can't be compared card
  # to card. The AI prompts ask for exactly 5, but a model can drift and the
  # importers map whatever the source form used (a Google Forms 1–4 linear
  # scale arrives as four labels), so the count is enforced here rather than
  # trusted upstream.
  RANGE_POINTS = 5

  # Names any stop a scale doesn't name itself — the same 5-point agree scale
  # the editor's "Add question" flow already fills a new range card with, so a
  # card repaired here is indistinguishable from one authored in the UI. Every
  # stop must end up named: an unlabelled one reads as a gap on the track, and
  # the editor's autosave drops blank labels, which would shorten the scale
  # again on the next save.
  RANGE_DEFAULT_LABELS = [
    "Strongly disagree", "Disagree", "Neutral", "Agree", "Strongly agree"
  ].freeze
  # Pexels video CDN (host-whitelisted) — the streamable mp4 for a card's
  # left-panel video. Posters are images.pexels.com URLs (sanitize_image_url).
  PEXELS_VIDEO_URL  = %r{\Ahttps://videos\.pexels\.com/[\w\-./]+\.mp4(?:\?[\w%\-=&.+]*)?\z}i

  # Cap on a stored base64 image. The client downscales uploads to ~1600px
  # WebP/JPEG (typically well under 1MB), so this is a defense-in-depth backstop
  # against an oversized blob slipping through: those inline data URLs are
  # re-materialised on every editor/preview/player render and were the main
  # memory driver behind the production 502s. Generous headroom over a normal
  # downscaled image; reject anything larger rather than persist it.
  MAX_BACKGROUND_DATA_URL_BYTES = 3_000_000

  # Coerce every range card's `options` to exactly RANGE_POINTS labels. Other
  # card types are untouched. Applied on save (see enforce_range_scale) so it
  # covers every authoring path — AI generation, the PDF/Forms/manual
  # importers, the CSV importer, templates and the editor's autosave — instead
  # of each one having to remember.
  # The stops a scale can't name itself are named from `fill` — resolved in
  # `locale` (a Verto's default_locale from enforce_range_scale), so a French
  # deck's repaired stop says "Plutôt d'accord", not "Agree". English constant
  # as the last-resort fallback, same as everywhere else.
  def self.localized_range_labels(locale = nil)
    labels = I18n.t("defaults.range", locale: locale.presence || I18n.locale,
                                      default: RANGE_DEFAULT_LABELS)
    return RANGE_DEFAULT_LABELS unless labels.is_a?(Array) && labels.size == RANGE_DEFAULT_LABELS.size
    labels.map(&:to_s)
  rescue I18n::InvalidLocale
    RANGE_DEFAULT_LABELS
  end

  def self.normalize_range_cards!(cards, fill: RANGE_DEFAULT_LABELS)
    Array(cards).map do |card|
      next card unless card.is_a?(Hash) && card["type"].to_s == "range"
      # The age slider is a range card by construction, not by choice: it
      # reuses the vertical slider widget, but its stops are a fixed registry
      # (DemographicQuestions::AGE_BANDS), not a scale a creator sizes.
      # Resampling it to RANGE_POINTS would silently drop two of its seven
      # bands — and "16–17" is one of them, which is the boundary the account
      # gate reads. The player sizes the track from labels.size, so a
      # seven-stop slider renders exactly as a five-stop one does.
      next card if card["demographic"]
      c = card.dup
      c["options"] = normalize_range_labels(c["options"], fill: fill)
      # Translations align to options POSITIONALLY, so a resized scale has to
      # resize its translations too — otherwise locale N shows label 4 at
      # stop 5. A translation that comes up short falls back to the primary
      # language for that stop, which is what the player renders anyway.
      if c["i18n"].is_a?(Hash)
        c["i18n"] = c["i18n"].transform_values do |tr|
          next tr unless tr.is_a?(Hash) && tr.key?("options")
          tr.merge("options" => normalize_range_labels(tr["options"], fill: c["options"]))
        end
      end
      c
    end
  end

  # Resize a range card's labels to exactly RANGE_POINTS, keeping the words
  # that are actually there:
  #
  #   5         → every stop stays put; only blanks get named
  #   6 or more → sampled evenly, so both endpoints survive
  #   4         → all four kept, the missing true centre opened up between them
  #   2 or 3    → spread across the scale, endpoints staying endpoints
  #   0         → `fill` (the default agree scale)
  #
  # Whatever the path, the gaps are then named from `fill` so no stop is left
  # blank, and the result is idempotent — re-normalising never shifts a label.
  #
  # A purely numeric scale keeps counting instead of gaining a word, so a
  # Google Forms 1–4 import reads "1 2 3 4 5" and not "1 2 Neutral 3 4".
  # `fill` names the stops this scale can't name itself: the default agree
  # scale for a card's own labels, and the primary-language labels when
  # normalising a translation, so a short translation falls through to the
  # primary word at that stop instead of rendering empty.
  def self.normalize_range_labels(labels, fill: RANGE_DEFAULT_LABELS)
    filler = Array(fill)
    raw    = Array(labels).map { |l| l.to_s.strip }

    # Already the right length: keep every stop exactly where it is and only
    # name the blanks. Re-spreading here would shuffle the whole scale when a
    # creator simply clears one label in the editor.
    return name_blank_stops(raw, filler) if raw.size == RANGE_POINTS

    given = raw.reject(&:blank?)
    return default_range_labels(filler)  if given.empty?
    return name_blank_stops(given, filler) if given.size == RANGE_POINTS

    # Numeric first, whichever direction it needs resizing: sampling a 1–7 run
    # the way words are sampled would print "1 3 4 6 7".
    numeric = resize_numeric_range_labels(given)
    return numeric if numeric

    spread = given.size > RANGE_POINTS ? downsample_range_labels(given) : upsample_range_labels(given)
    name_blank_stops(spread, filler)
  end

  # No stop is left nameless: an unlabelled point renders as a gap on the
  # track, and the editor's autosave would then drop it and shorten the scale.
  def self.name_blank_stops(labels, filler)
    labels.each_with_index.map do |label, i|
      label.presence || filler[i].to_s.strip.presence || RANGE_DEFAULT_LABELS[i]
    end
  end

  # Nothing to preserve: the translation falls back to the primary language,
  # and a card with no labels at all gets the default agree scale.
  def self.default_range_labels(fill)
    Array(fill).first(RANGE_POINTS).presence || RANGE_DEFAULT_LABELS.dup
  end

  # More labels than stops: pick RANGE_POINTS of them at even spacing. Both
  # endpoints are always included, so the scale keeps the range it described.
  def self.downsample_range_labels(given)
    last = given.size - 1
    (0...RANGE_POINTS).map { |i| given[(i * last / (RANGE_POINTS - 1.0)).round] }
  end

  # A consecutive integer run ("1".."4" or "1".."7", as a Google Forms linear
  # scale imports) is re-cut to RANGE_POINTS integers from its own starting
  # point: 1–4 grows to 1–5, 1–7 shrinks to 1–5, and 0–3 keeps its zero and
  # becomes 0–4. Anything else returns nil and takes the word path — including
  # a lone number, which says nothing about the intended run.
  def self.resize_numeric_range_labels(given)
    return nil if given.size < 2
    nums = given.map { |l| Integer(l, exception: false) }
    return nil if nums.any?(&:nil?)
    return nil unless nums.each_cons(2).all? { |a, b| b == a + 1 }
    (nums.first...(nums.first + RANGE_POINTS)).map(&:to_s)
  end

  # Fewer labels than stops: spread what we have so the creator's endpoints
  # stay endpoints. A 4-point scale keeps all four labels and opens up the true
  # centre it was missing (slot 2) — the case this whole rule exists for.
  # Remaining slots come back blank for name_blank_stops to fill.
  RANGE_UPSAMPLE_SLOTS = { 1 => [ 0 ], 2 => [ 0, 4 ], 3 => [ 0, 2, 4 ], 4 => [ 0, 1, 3, 4 ] }.freeze

  def self.upsample_range_labels(given)
    slots = Array.new(RANGE_POINTS)
    RANGE_UPSAMPLE_SLOTS.fetch(given.size).each_with_index { |slot, i| slots[slot] = given[i] }
    slots
  end

  # A single image value (background, card image, or one option_image): an
  # uploaded data-URL (size-capped), an app-rooted asset path, or a Pexels CDN
  # URL — anything else (or blank) returns nil.
  def self.sanitize_image_url(value)
    v = value.to_s.strip
    return nil if v.blank?
    return v if v.match?(ASSET_IMAGE_URL)
    return v if v.match?(ACTIVE_STORAGE_IMAGE_URL)
    return v if v.match?(PEXELS_IMAGE_URL)
    return v if v.match?(DATA_IMAGE_URL) && v.bytesize <= MAX_BACKGROUND_DATA_URL_BYTES
    nil
  end

  def self.sanitize_background_image(value)
    sanitize_image_url(value)
  end

  # One entry of a save response's `warning_details` (SurveysController#update):
  # which card lost which piece of media, and the shape of what was rejected.
  # The `warnings` codes say only that SOMETHING in the deck was dropped, and
  # the editor's one sentence for them — "an image didn't stick" — was read by
  # a creator who had just uploaded a picture as being about that picture,
  # which had saved fine, while the card that actually lost its image (an old
  # oversized inline upload, on another card) went unchecked. This is what
  # lets the pill name the card, and what the controller writes to the log so
  # the next such report can be traced without a reproduction.
  #
  # `index` is the statement slot for an option_images drop — the editor needs
  # it to clear exactly that one picture off the page.
  def self.dropped_media_detail(code, card, value, index: nil)
    detail = { "code" => code, "cid" => card["cid"].to_s, "value" => describe_rejected_media(value) }
    detail["index"] = index if index
    detail
  end

  # A rejected media value as a log line can carry it: never the payload
  # itself — an inline image is megabytes of base64 and the whole point is a
  # line a person can read — just its type and size, or the first characters
  # of a URL.
  def self.describe_rejected_media(value)
    v = value.to_s
    if (m = v.match(%r{\Adata:([^;,]+)}))
      "#{m[1]} data URL, #{v.bytesize} bytes"
    else
      v.strip.first(120)
    end
  end

  # A card's re-crop record: where its image was cut from image_source, as
  # fractions of the source's natural size — x/y the top-left, w/h the
  # extent, all 0..1 with a real area. Fractions rather than pixels so the
  # record survives any resize of the stored source. Anything else is a
  # value we don't understand — nil, and the caller drops the key (the same
  # posture as focal_y: junk must not quietly become 0.0 and crop a corner).
  def self.sanitize_image_crop(value)
    return nil unless value.is_a?(Hash)
    vals = %w[x y w h].map do |k|
      raw = value[k] || value[k.to_sym]
      numeric = raw.is_a?(Numeric) || raw.to_s.strip.match?(/\A-?\d+(?:\.\d+)?\z/)
      numeric ? raw.to_f.clamp(0, 1) : nil
    end
    return nil if vals.any?(&:nil?)
    x, y, w, h = vals
    return nil if w <= 0 || h <= 0
    { "x" => x.round(4), "y" => y.round(4), "w" => w.round(4), "h" => h.round(4) }
  end

  # Which ink a mobile background carries — "light" (white) or "dark". The
  # editor measures the creator's pick and sends the answer (lib/backdrop_ink.js);
  # this is the sanitiser for it, and the same decision for a plain colour, so
  # an imported or seeded deck is not stuck with whatever the default is.
  #
  # 0.38, not 0.5, and the threshold is shared with the JS on purpose: white
  # (L = 1) clears 4.5:1 against a backdrop up to L = 0.183, and the card's dark
  # ink clears it down to L = 0.25, so between those two limits every backdrop
  # fails one ink or the other and the line goes where the failures are least
  # bad. backdrop_ink_parity_test holds both sides to it.
  LIGHT_BACKDROP_THRESHOLD = 0.38
  BACKDROP_INKS = %w[light dark].freeze

  def self.sanitize_backdrop_ink(value)
    v = value.to_s.strip.downcase
    BACKDROP_INKS.include?(v) ? v : nil
  end

  def self.backdrop_ink_for_color(hex)
    return nil unless BrandPalette.valid_hex?(hex.to_s)

    BrandPalette.luminance(hex.to_s) >= LIGHT_BACKDROP_THRESHOLD ? "dark" : "light"
  end

  # One axis of a reposition: a 0-100 percentage, rounded to a whole number
  # because that is all a background-position can usefully carry here. nil for
  # anything that isn't a number, so junk is dropped rather than silently
  # becoming 0 and pinning the frame to an edge.
  def self.sanitize_focal_percent(raw)
    numeric = raw.is_a?(Numeric) || raw.to_s.strip.match?(/\A-?\d+(?:\.\d+)?\z/)
    numeric ? raw.to_f.clamp(0, 100).round : nil
  end

  # How far past cover-fit the media is punched in, 1 (fit) to FOCAL_ZOOM_MAX.
  # Its job is to CREATE the slack a reposition slides: at cover-fit an axis
  # where the picture already matches the frame has nothing hidden to reveal,
  # so dragging it does nothing — which is exactly the "I can't move it
  # vertically" case. Zooming in hides some of both axes, and both then move.
  # Non-destructive like the focal point itself: the stored image is untouched
  # and this can be wound back to 1 for ever. nil at 1 (or for junk), so the
  # caller drops the key and the default applies.
  FOCAL_ZOOM_MAX = 3.0

  def self.sanitize_focal_zoom(raw)
    numeric = raw.is_a?(Numeric) || raw.to_s.strip.match?(/\A-?\d+(?:\.\d+)?\z/)
    return nil unless numeric
    zoom = raw.to_f.clamp(1.0, FOCAL_ZOOM_MAX).round(2)
    zoom > 1.0 ? zoom : nil
  end

  # A tap card's per-statement repositions, aligned slot-for-slot with its
  # (already sanitised) option_images. Each entry is an {"x","y"} pair or nil.
  # A slot with no image, or one whose image didn't survive sanitising, can't
  # have a position: keeping one would be a rule waiting to reposition the NEXT
  # picture dropped into that slot. Trailing nils are trimmed and an array with
  # nothing left in it comes back empty, so a card that has been reset back to
  # centre stores no key at all rather than a row of nulls.
  def self.sanitize_option_focals(value, images)
    focals = Array(value).first(images.length).each_with_index.map do |entry, i|
      next nil if images[i].blank?
      next nil unless entry.is_a?(Hash)
      x = sanitize_focal_percent(entry["x"] || entry[:x])
      y = sanitize_focal_percent(entry["y"] || entry[:y])
      z = sanitize_focal_zoom(entry["z"] || entry[:z])
      next nil if x.nil? && y.nil? && z.nil?
      slot = { "x" => x || 50, "y" => y || 50 }
      slot["z"] = z if z
      # Centred AND at cover-fit is the default this slot would render at
      # anyway — stored, it is a row of numbers that say nothing.
      slot == { "x" => 50, "y" => 50 } ? nil : slot
    end
    focals.pop while focals.any? && focals.last.nil?
    focals
  end

  # The Shuffle direction prompt — the creator's optional free-text steer for
  # what they want out of the Verto's content and imagery ("warm, outdoors,
  # small groups, no offices"). It belongs to one shuffle and is NOT persisted;
  # this just normalises what arrives with the click. Never rendered to a
  # respondent and never sent to Claude; it only widens the words
  # AssetPopulator searches and scores on, so the only handling it needs is a
  # length cap and whitespace collapse. Blank comes back as nil, which is what
  # "no direction" means everywhere downstream.
  MAX_SHUFFLE_DIRECTION = 200

  def self.sanitize_shuffle_direction(value)
    value.to_s.gsub(/\s+/, " ").strip.first(MAX_SHUFFLE_DIRECTION).presence
  end

  # `shuffle_direction` shipped as a column and is no longer written or read:
  # a saved steer is invisible state, and the box now starts empty every time.
  # Ignored rather than dropped in the same change, so the containers still
  # serving during the release don't SELECT a column the migration just
  # removed. The DROP is a follow-up migration, safe once this is live.
  self.ignored_columns += %w[shuffle_direction]

  # Whether a blob filename already ends in an extension ACTIVE_STORAGE_IMAGE_URL
  # accepts. Active Storage serves a blob at /rails/active_storage/…/<filename>,
  # so the name a file was uploaded under decides whether its path survives
  # sanitize_image_url — an image called "logo" or "holiday.jfif" is a perfectly
  # valid PNG/JPEG by content type (which is what the uploaders validate) but
  # yields a path the card sanitiser drops. Uploaders call this to give a blob a
  # name that will pass, rather than re-listing the extensions themselves.
  def self.image_extension?(filename)
    IMAGE_EXTENSIONS.include?(File.extname(filename.to_s).delete_prefix(".").downcase)
  end

  # A card left-panel video URL — only the Pexels video CDN is allowed.
  def self.sanitize_video_url(value)
    v = value.to_s.strip
    v.match?(PEXELS_VIDEO_URL) ? v : nil
  end

  # A card left-panel Lottie animation — only a same-origin stored copy is
  # allowed (CardLottieStore ingests the pasted LottieFiles URL).
  def self.sanitize_lottie_url(value)
    v = value.to_s.strip
    v.match?(ACTIVE_STORAGE_LOTTIE_URL) ? v : nil
  end

  # A photographer-credit link — only a pexels.com URL is allowed (rendered as
  # an href), anything else returns nil so the name shows without a link.
  def self.sanitize_credit_url(value)
    v = value.to_s.strip
    v.match?(PEXELS_CREDIT_URL) ? v : nil
  end

  # Scrub the `image`/`option_images` and the photographer-credit fields on each
  # card before persisting an editor PATCH, so a remote URL can only reach the
  # inline styles if it's a recognised, CSS-safe form and the credit link can
  # only point at Pexels. Other card fields are untouched. When a card has no
  # image, any orphaned credit is dropped.
  #
  # Pass `warnings:` (an array) to have it collect a short code per field that
  # had a real, present value which sanitizing dropped (e.g. an oversized or
  # unsupported upload) — so the caller can tell the editor something didn't
  # stick, instead of the drop being silent.
  # Every card carries a stable opaque id so answer-branching can target it by
  # cid (not array index). Backfill a missing cid AND de-dupe collisions: two
  # cards sharing a cid (from a duplicated/imported/hand-crafted deck) would
  # make a `{card: X}` route resolve to whichever card is last and orphan the
  # other, so any blank-or-already-seen cid is reassigned a fresh unique one
  # (the first occurrence keeps the id, so existing routes to it still resolve).
  #
  # Lifted out of sanitize_cards_images! (which still calls it first, so the
  # behaviour there is unchanged) because two other callers need cids to EXIST
  # before the editor's first save mints them: an import, whose deck is created
  # outside the editor's save path, and the media merge below, which matches the
  # populator's picks to live cards by cid and would match nothing against a
  # deck of blanks.
  def self.ensure_cids!(cards)
    seen = Set.new
    Array(cards).map do |card|
      next card unless card.is_a?(Hash)
      c = card.dup
      cid = c["cid"].to_s.strip
      cid = "c_#{SecureRandom.hex(4)}" while cid.blank? || seen.include?(cid)
      seen << cid
      c["cid"] = cid
      c
    end
  end

  # ── The import's setup window ──────────────────────────────────────────────
  # An imported Verto hands its creator straight to the editor while
  # FinishVertoSetupJob fills in imagery behind them. That is deliberate — they
  # have already waited through the upload and the review screen — but it opens
  # a window in which two writers hold different truths about the same deck.
  #
  # The editor's is the DOM: survey_editor_controller#serialize() rebuilds every
  # card from `data-card-*`, and emits `image` only when `data-card-image` is
  # non-empty. At redirect time it is empty for every card, because the job has
  # not run yet. So the first autosave — one keystroke is enough — used to PATCH
  # a deck with no imagery in it over the deck the job had just populated, and
  # #update replaces `cards` wholesale. background_image survived (it is a
  # column, and serialize() never sends it), which is why the report was "a
  # background but blank cards" rather than "nothing happened".
  #
  # While the flag stands, the client PROVABLY does not know about the pictures
  # yet, so its silence about them is not a decision to remove them. Once
  # setup_pending_since clears, #update behaves exactly as it always has.
  MEDIA_KEYS = %w[
    image video video_poster image_credit image_credit_url
    option_images range_theme subject
  ].freeze

  # The two anchor lines beside an NPS scale's ends — respondent-facing copy,
  # translated per language like text/description (see swap_card_primary,
  # merge_card_translations, SurveyTranslator, LanguageCheckLines).
  NPS_ANCHOR_KEYS = %w[nps_low_label nps_high_label].freeze

  # Long enough that a five-language import finishes inside it, short enough
  # that a job the memory watchdog kills (see VertoBuild#stale?, same reasoning)
  # stops holding the window open. The job clears the flag in an `ensure`; this
  # is the backstop for the case where the job never gets to run its `ensure`.
  SETUP_STALE_AFTER = 10.minutes

  def setup_pending?
    setup_pending_since.present? && setup_pending_since > SETUP_STALE_AFTER.ago
  end

  # Carry the stored imagery onto an incoming deck that doesn't mention it.
  # Matched by cid — never by index, because the creator can insert, delete or
  # reorder cards inside the window, and index-matching would paste the right
  # picture onto the wrong card, which looks intentional and is worse than no
  # picture at all.
  #
  # One direction only: stored media fills an incoming card that has none. A
  # card the creator has since given its own image, video or animation keeps
  # theirs, and nothing else on the card is touched.
  def self.keep_setup_media(stored, incoming)
    by_cid = Array(stored).each_with_object({}) do |card, h|
      next unless card.is_a?(Hash)
      cid = card["cid"].to_s
      h[cid] = card if cid.present?
    end
    return incoming if by_cid.empty?

    Array(incoming).map do |card|
      next card unless card.is_a?(Hash)
      was = by_cid[card["cid"].to_s]
      next card unless was.is_a?(Hash)
      next card if card_has_media?(card)

      c = card.dup
      MEDIA_KEYS.each do |key|
        value = was[key]
        c[key] = value if value.present?
      end
      c
    end
  end

  # Per-card token config, wiped by the same client-silence shape keep_setup_media
  # exists for: the editor renders token controls only while tokenisation is on,
  # so a page loaded before the switch was flipped rebuilds every card with no
  # token keys at all — and cards replace wholesale, so one autosave from that
  # page deleted a deck's amounts for good. The client now says whether it could
  # see the controls (serialize's tokens_authoritative); when it could not, the
  # stored values win, by cid. When it could, absence is meaningful — all-zero
  # amounts serialize as no key — so nothing may be merged back (that would make
  # amounts un-deletable).
  TOKEN_SETTING_KEYS = %w[tokens token_award token_award_mode tokens_enabled].freeze

  def self.keep_token_settings(stored, incoming)
    by_cid = Array(stored).each_with_object({}) do |card, h|
      next unless card.is_a?(Hash)
      cid = card["cid"].to_s
      h[cid] = card if cid.present?
    end
    return incoming if by_cid.empty?

    Array(incoming).map do |card|
      next card unless card.is_a?(Hash)
      was = by_cid[card["cid"].to_s]
      next card unless was.is_a?(Hash)

      c = card.dup
      TOKEN_SETTING_KEYS.each do |key|
        c.delete(key)
        c[key] = was[key] unless was[key].nil?
      end
      c
    end
  end

  # A card's left panel holds a photo OR a video OR an animation. Any of the
  # three means the card has been given its imagery and nothing should overwrite
  # it — the same test AssetPopulator uses to decide what a fill-only run skips.
  def self.card_has_media?(card)
    return false unless card.is_a?(Hash)
    card["image"].present? || card["video"].present? || card["lottie"].present?
  end

  # The intro modal's fields, normalised in place on ONE card. Extracted from
  # sanitize_cards_images! because the locked-deck path (update_card_modal!
  # below) has to bound the same three keys the same way, and a second copy of
  # these rules is a second set of limits to keep in step — the drift would show
  # up as a modal that is 600 characters through one door and unbounded through
  # the other.
  #
  # PRESENCE IS THE FLAG: a card carries a modal iff it has title or body words,
  # so there is one representation of "has a modal" rather than a boolean that
  # can disagree with the copy beside it. A creator who opens the modal editor
  # and types nothing has saved nothing — the same contract the join-block and
  # share-copy placeholders already have.
  #
  # Not gated on card type. A modal explains whatever card it is hung on, and
  # there is no type it would be meaningless for.
  def self.sanitize_card_modal!(card)
    title = card["modal_title"].to_s.strip.first(MAX_MODAL_TITLE)
    body  = card["modal_body"].to_s.strip.first(MAX_MODAL_BODY)
    title.present? ? card["modal_title"] = title : card.delete("modal_title")
    body.present?  ? card["modal_body"]  = body  : card.delete("modal_body")
    # Rich-text layer for the body, the same equivalence contract text_html has:
    # presentation only, and dropped the moment it stops reading as its plain
    # twin (which includes the twin being deleted).
    html = body.present? ? RichTextSanitizer.clean_equivalent(card["modal_body_html"], body) : nil
    html ? card["modal_body_html"] = html : card.delete("modal_body_html")
    # A translation can only translate a modal the primary language HAS. Without
    # this, clearing the modal off a card would leave its Spanish copy behind and
    # the player would render a modal in Spanish only.
    if card["i18n"].is_a?(Hash)
      card["i18n"] = card["i18n"].transform_values do |tr|
        next tr unless tr.is_a?(Hash)
        tr = tr.dup
        tr.delete("modal_title") if title.blank?
        tr.delete("modal_body")  if body.blank?
        tr["modal_title"] = tr["modal_title"].to_s.strip.first(MAX_MODAL_TITLE) if tr.key?("modal_title")
        tr["modal_body"]  = tr["modal_body"].to_s.strip.first(MAX_MODAL_BODY)   if tr.key?("modal_body")
        # Translations are plain by design, exactly like `pages`.
        tr.except("modal_body_html")
      end
    end
    card
  end

  # Write one card's intro modal, and NOTHING else — the narrow door that lets a
  # locked deck gain, reword or lose a modal (SurveysController#update_card_modal).
  #
  # editing_locked? exists because answers are stored against card POSITION, so
  # a deck change re-points every answer already collected. That reasoning does
  # not reach a modal: it is a per-card field, it moves no card, it adds and
  # removes none, and nothing about it is an answer. This method is the proof
  # rather than the claim — it takes a cid and three strings, addresses the card
  # BY CID (never by index, so a deck it half-understands cannot be scrambled),
  # and rebuilds each card as `card.merge(modal fields)`. There is no payload
  # shape it accepts that could reorder, insert, delete or otherwise reshape the
  # deck, which is why it can sit outside the lock while
  # SurveysController#update stays firmly inside it.
  #
  # Returns true when a card matched, false when the cid names nothing.
  def update_card_modal!(cid:, title:, body:, body_html: nil)
    cid = cid.to_s
    return false if cid.blank?

    found = false
    updated = Array(cards).map do |card|
      next card unless card.is_a?(Hash) && card["cid"].to_s == cid
      found = true
      self.class.sanitize_card_modal!(
        card.merge("modal_title" => title, "modal_body" => body, "modal_body_html" => body_html)
      )
    end
    return false unless found

    update!(cards: updated)
    true
  end

  # `structural: false` keeps a deck's existing SHAPE: the two passes at the
  # tail that remove or move a card already in the deck (drop_retired_cards,
  # hoist_consent_gate) are skipped. SurveysController#update passes it for a
  # locked deck saved by an account LiveEditAccess allows past the lock — the
  # editor promised that person that fixing wording in place is safe, and a
  # save that quietly pulled out a retired card or moved the consent gate would
  # re-point every later stored answer behind that promise. The enforce_single_*
  # passes still run: on a deck that was normalised as a draft they can only
  # ever drop a duplicate the editor has JUST added, which puts every card back
  # where its answers already are.
  # `details:` (an array) collects, beside each media code pushed onto
  # `warnings`, WHICH card lost WHAT — see dropped_media_detail. The codes stay
  # as they are: the editor's SAVE_WARNING_KEYS table and JsConstantParityTest
  # are pinned to them, and a code says what kind of sentence to show; a detail
  # says which card to put in it, and what to write in the log.
  def self.sanitize_cards_images!(cards, warnings: nil, structural: true, details: nil)
    Array(ensure_cids!(cards)).map do |card|
      next card unless card.is_a?(Hash)
      c = card.dup
      # Common Question provenance rides in from the editor's autosave payload
      # (the card row carries it as a data attribute so it survives the DOM
      # round-trip). Coerce to a positive integer or drop it: it's client-supplied
      # from here on, and the aggregator matches on it, so junk shouldn't be able
      # to settle in the cards JSON.
      %w[common_question_id common_question_set_id].each do |key|
        next unless c.key?(key)
        id = c[key].to_i
        id.positive? ? c[key] = id : c.delete(key)
      end
      c.delete("logic") unless c["logic"].is_a?(Hash) # drop malformed logic blocks
      # The unconditional flow pointer (any card type) — drop unless it's a valid
      # { "card" => cid } / { "end" => id } target (see LogicGraph.card_next).
      unless c["next"].is_a?(Hash) && (c["next"]["card"].to_s != "" || c["next"]["end"].to_s != "")
        c.delete("next")
      end
      # Optional branch name shown on the flow map (editor-only), stored on the
      # lane's entry card. Bounded plain text; blank ⇒ dropped (falls back to the
      # answer that opens the lane).
      if c.key?("lane_label")
        c["lane_label"] = c["lane_label"].to_s.strip.first(MAX_LANE_LABEL).presence
        c.delete("lane_label") if c["lane_label"].blank?
      end
      # First-class flow membership — an opaque flow id in the same format
      # sanitize_flows mints, or nothing. Whether the id names a REAL flow is
      # cross-checked in reconcile_flows! (it needs the flows list too).
      if c.key?("flow_id")
        fid = c["flow_id"].to_s.strip
        fid.match?(FLOW_ID_FORMAT) ? c["flow_id"] = fid : c.delete("flow_id")
      end
      # Framework provenance. SurveyGenerator#normalize_framework! already
      # allowlists these, but that only runs on generation — this path now
      # receives them from the editor's autosave too, so the same rule has to
      # hold here or a crafted PATCH could put anything in the "Why this card?"
      # panel. Same allowlist-or-drop shape as range_theme below. `outcome` is
      # free text by design, so it is capped rather than checked.
      c.delete("competency") if c.key?("competency") && !Framework.competency?(c["competency"])
      c.delete("condition")  if c.key?("condition")  && !Framework.condition?(c["condition"])
      if c.key?("outcome")
        outcome = c["outcome"].to_s.strip.first(MAX_OUTCOME_LENGTH)
        outcome.present? ? c["outcome"] = outcome : c.delete("outcome")
      end

      # Which opt-in demographic question a card is (heritage/neurodiversity) —
      # only a known key survives, and only on a card that is actually flagged
      # demographic. The flag requirement means a crafted payload can't hang a
      # key on an arbitrary card without also flagging it demographic (which
      # costs it imagery and buys consent gating — no win); the answer sync
      # additionally validates every stored value against the card's own
      # options. Same allowlist-or-drop shape as range_theme below.
      if c.key?("demographic_key")
        key = c["demographic_key"].to_s
        if c["demographic"] && DemographicQuestions::DEMOGRAPHIC_KEYS.include?(key)
          c["demographic_key"] = key
        else
          c.delete("demographic_key")
        end
      end
      # Which country's heritage taxonomy this card was built from — provenance,
      # so the editor can tell a tailored card from the global nine and rebuild
      # it when the Verto's audience country changes. Only a real WorldRegions
      # code survives, and only on the heritage card itself: it says nothing
      # about any other card, and a crafted payload hanging it elsewhere would
      # make the rebuild pick the wrong card. Same allowlist-or-drop shape as
      # demographic_key above.
      if c.key?("heritage_country")
        code = c["heritage_country"].to_s.upcase
        if c["demographic"] && c["demographic_key"].to_s == "heritage" && WorldRegions.valid?(code)
          c["heritage_country"] = code
        else
          c.delete("heritage_country")
        end
      end

      # A location card's search narrowing — places, countries, cities. Kept
      # only on a location card, and each key only while it narrows anything
      # (LocationScope.sanitize_card!).
      LocationScope.sanitize_card!(c)
      # A range card's reaction-animation theme — only a known slug survives, and
      # only on a range card, so the helper always resolves to a real asset
      # folder (NpsHelper owns the theme list).
      if c.key?("range_theme")
        slug = c["range_theme"].to_s
        if c["type"].to_s == "range" && NpsHelper::RANGE_THEMES.include?(slug)
          c["range_theme"] = slug
        else
          c.delete("range_theme")
        end
      end
      # An NPS card's container silhouette — only a vessel we can actually
      # draw survives, and only on an NPS card, so the helper always resolves
      # to a real path (NpsHelper::NPS_VESSELS owns the drawing table). Same
      # allowlist-or-drop shape as range_theme above; dropping it falls back to
      # the Verto-themed pick rather than to nothing.
      if c.key?("nps_shape")
        shape = c["nps_shape"].to_s
        if c["type"].to_s == "nps" && NpsHelper::NPS_VESSELS.key?(shape)
          c["nps_shape"] = shape
        else
          c.delete("nps_shape")
        end
      end
      # "This card is off the classic 0-10 scale." Stored only when a creator
      # turns the classic off, and only as `true` — its absence is not "classic",
      # it is "nobody has said", and NpsHelper#nps_custom_scale? then reads the
      # answer off the labels. That is what lets the switch arrive without a
      # migration: a deck full of 0-10 cards keeps reading as classic and one
      # already carrying an agree scale keeps every label it has.
      # Anything falsy is dropped rather than stored, so there is one
      # representation of "classic" and not two.
      if c.key?("nps_custom_scale")
        if c["type"].to_s == "nps" && c["nps_custom_scale"] == true
          c["nps_custom_scale"] = true
        else
          c.delete("nps_custom_scale")
        end
      end
      # The anchor lines beside an NPS scale's ends ("I have no say at all" /
      # "I am a decision maker"). Only on an NPS card, only with words in them,
      # capped — same allowlist-or-drop shape as the two above, and blank is
      # dropped rather than stored so there is one representation of "none".
      # The per-language copies under i18n get the same cap further down.
      NPS_ANCHOR_KEYS.each do |k|
        next unless c.key?(k)
        words = c[k].to_s.strip.first(NpsHelper::NPS_ANCHOR_MAX)
        if c["type"].to_s == "nps" && words.present?
          c[k] = words
        else
          c.delete(k)
        end
      end
      # Card backdrop — the colour or image behind whatever the panel holds,
      # overriding the Verto-wide --brand-panel for this one card. Meaningful
      # wherever the panel is not already covered edge to edge: behind an
      # animation, and on a card with NO media, where the backdrop IS the design
      # (and, on a phone, is the card's whole top half — see .has-media-bg in
      # the mobile block of application.css). A photo or a video covers the
      # panel itself, so a backdrop is dropped there rather than kept as dead
      # data that would surprise whoever removes the picture later.
      # ApplicationHelper#card_takes_backdrop? states the same rule for
      # rendering; media_picker#_cardTakesBackground for the editor.
      # Same allowlist-or-drop shape as range_theme above.
      if c.key?("media_bg")
        bg  = c["media_bg"].is_a?(Hash) ? c["media_bg"] : {}
        out = {}
        color = bg["color"].to_s
        out["color"] = "#" + color.strip.delete_prefix("#").downcase if BrandPalette.valid_hex?(color)
        if (img = sanitize_image_url(bg["image"])).present?
          out["image"] = img
        end
        # Which ink the card's words take over this backdrop. The editor
        # measures the picture it has in front of it and sends the answer; a
        # plain colour is measured here, so a deck that never went through the
        # picker (an import, a seed, a paste) still gets readable text rather
        # than white on whatever it happens to be. A stored `ink` wins: it was
        # measured against the IMAGE, which is what a respondent sees, and the
        # colour underneath is only what shows before it loads.
        # …and only on the types that READ it. The ink is the colour of words
        # drawn ON the backdrop, which happens on the three full-screen types
        # and nowhere else: a range or Lottie card's backdrop sits behind an
        # animation with the card's text on its own white panel, and a bare
        # card's paints a hero strip with the text below it. Storing an ink for
        # those is storing a decision nothing will ever ask for.
        #
        # Only ever alongside something to read it against, too — an `ink` on
        # its own is a text colour for a backdrop that does not exist, and
        # out.any? below would keep the card a backdrop made of nothing else.
        if out.any? && CardTypes.full_screen_answer?(c["type"])
          if (ink = sanitize_backdrop_ink(bg["ink"])).present?
            out["ink"] = ink
          elsif out["image"].blank? && (ink = backdrop_ink_for_color(out["color"]))
            out["ink"] = ink
          end
        end
        # Reads the card's OWN lottie / image / video values, which at this
        # point have not been through their own sanitisers yet — a card carrying
        # an off-allowlist animation would otherwise have its backdrop kept and
        # the animation dropped, and one carrying an off-allowlist photo would
        # have its backdrop dropped for a picture that is about to go too. Check
        # each the way that sanitiser will.
        animated = c["type"].to_s == "range" || sanitize_lottie_url(c["lottie"]).present?
        bare     = sanitize_image_url(c["image"]).blank? && sanitize_video_url(c["video"]).blank?
        # …and the three types whose answer takes the whole phone screen, which
        # keep a backdrop whatever else they carry. Their picture and their
        # backdrop are different screens' designs, not two layers of one: the
        # phone draws them no hero, so there is nothing for the backdrop to be
        # hidden behind, and refusing to STORE one is what stopped a creator
        # designing the phone view of exactly the cards that are only ever
        # phone. See ApplicationHelper#card_takes_backdrop?.
        full_screen = CardTypes.full_screen_answer?(c["type"])
        if (animated || bare || full_screen) && out.any?
          c["media_bg"] = out
        else
          c.delete("media_bg")
        end
        # The one media branch that used to drop in silence. Every other one
        # reports (grep `warnings << "`), and the editor's own "an image didn't
        # stick" pill and the controller's log line are both driven off these —
        # so a backdrop rejected for its host, or for being a data URL over the
        # cap, left the creator looking at a picture that was already gone.
        if bg["image"].present? && out["image"].blank?
          warnings << "media_bg" if warnings
          details << dropped_media_detail("media_bg", c, bg["image"]) if details
        end
      end

      # Rich-text layer: presentation-only HTML twins of the plain text
      # fields (text_html / description_html / options_html; page html is
      # handled in the PAGED_TYPES block below). Every value passes
      # RichTextSanitizer.clean_equivalent — sanitised to the tag/class
      # allowlist AND required to still read as its plain twin — so grading,
      # aggregation, exports, AI and i18n (all keyed off the plain layer) can
      # never disagree with what respondents saw. Translations stay plain:
      # any *_html inside i18n is stripped outright.
      if (html = RichTextSanitizer.clean_equivalent(c["text_html"], c["text"]))
        c["text_html"] = html
      else
        c.delete("text_html")
      end
      if (html = RichTextSanitizer.clean_equivalent(c["description_html"], c["description"]))
        c["description_html"] = html
      else
        c.delete("description_html")
      end
      if c.key?("options_html")
        opts  = Array(c["options"])
        htmls = Array(c["options_html"]).first(opts.length).each_with_index.map do |h, i|
          RichTextSanitizer.clean_equivalent(h, opts[i])
        end
        htmls += [ nil ] * (opts.length - htmls.length) if htmls.length < opts.length
        htmls.any? ? c["options_html"] = htmls : c.delete("options_html")
      end
      if c["i18n"].is_a?(Hash)
        c["i18n"] = c["i18n"].transform_values do |tr|
          next tr unless tr.is_a?(Hash)
          tr = tr.reject { |k, _| k.to_s.end_with?("_html") }
          # A translated anchor line is held to the primary's cap and rule: no
          # words, no key — the player falls back to the primary for it.
          NPS_ANCHOR_KEYS.each do |k|
            next unless tr.key?(k)
            words = tr[k].to_s.strip.first(NpsHelper::NPS_ANCHOR_MAX)
            words.present? ? tr[k] = words : tr.delete(k)
          end
          tr
        end
      end

      # Per-option visual overrides ({color, icon, emoji} or null, POSITIONAL
      # against `options` — like option_images, DOM order in the editor is the
      # alignment, so there is no splice bookkeeping here). Purely
      # presentational: answers still key off the option's label text. Same
      # allowlist-or-drop shape as range_theme below — hex via BrandPalette,
      # icon ids via OptionIconLibrary, emoji clamped like token icons.
      if c.key?("option_styles")
        if OPTION_STYLE_TYPES.include?(c["type"].to_s)
          limit  = c["type"].to_s == "yes_no" ? 2 : Array(c["options"]).length
          styles = Array(c["option_styles"]).first(limit).map do |entry|
            next nil unless entry.is_a?(Hash)
            out = {}
            color = entry["color"].to_s
            out["color"] = "#" + color.strip.delete_prefix("#").downcase if BrandPalette.valid_hex?(color)
            out["icon"]  = entry["icon"].to_s if OptionIconLibrary.valid_id?(entry["icon"].to_s)
            emoji = entry["emoji"].to_s.strip
            out["emoji"] = emoji.first(MAX_TOKEN_ICON) if emoji.present?
            out.presence
          end
          # Pad so positions keep meaning even when the tail is unstyled.
          styles += [ nil ] * (limit - styles.length) if styles.length < limit
          styles.any? ? c["option_styles"] = styles : c.delete("option_styles")
        else
          c.delete("option_styles")
        end
      end

      # A tap card's RESPONSE SCALE — the 2-6 answers a respondent chooses
      # between on each swipe statement, ordered most-negative first. Same
      # allowlist-or-drop shape as option_styles above, with one difference that
      # matters: `key` is not decoration, it is the value the answer is STORED
      # as (and what `tokens` and `correct` are keyed off), so it is minted when
      # missing and de-duplicated within the card exactly like `cid`, rather
      # than being allowed through as whatever the client sent.
      #
      # Anything short of a whole valid scale is dropped rather than half-kept:
      # TapScales.for_card falls back to the historic 3-point set when the key is
      # absent, which is a working card, whereas a one-button scale is not.
      #
      # Deliberately NOT gated on the card's current type, for the reason
      # option_images isn't either: a creator who builds a six-point scale, tries
      # Range to compare and switches back should find their scale, not the
      # default three. Only tap cards ever read the key, and every field in it is
      # bounded here whatever type it arrives on, so carrying it costs nothing.
      if c.key?("responses")
        seen = Set.new
        list = Array(c["responses"]).first(TapScales::MAX_RESPONSES).filter_map do |entry|
          next unless entry.is_a?(Hash)
          key = entry["key"].to_s.strip.downcase
          key = "r_#{SecureRandom.hex(4)}" while key.blank? || !key.match?(TapScales::KEY_FORMAT) || seen.include?(key)
          seen << key
          out = { "key" => key }
          label = entry["label"].to_s.strip.first(TapScales::MAX_LABEL)
          out["label"] = label if label.present?
          out["glyph"] = entry["glyph"].to_s if TapScales::GLYPHS.include?(entry["glyph"].to_s)
          out["icon"]  = entry["icon"].to_s  if OptionIconLibrary.valid_id?(entry["icon"].to_s)
          emoji = entry["emoji"].to_s.strip
          out["emoji"]  = emoji.first(MAX_TOKEN_ICON) if emoji.present?
          color = entry["color"].to_s
          out["color"]  = "#" + color.strip.delete_prefix("#").downcase if BrandPalette.valid_hex?(color)
          out["strong"] = true if entry["strong"]
          out
        end
        if list.length >= TapScales::MIN_RESPONSES
          c["responses"] = list
        else
          c.delete("responses")
        end
      end
      # Translated response labels align POSITIONALLY, exactly like `options`, so
      # a resized scale has to resize its translations too — otherwise locale N
      # shows response 4's words on response 5. A translation that comes up short
      # falls back to the primary label, which is what the player renders anyway.
      if c["i18n"].is_a?(Hash)
        size = Array(c["responses"]).length
        c["i18n"] = c["i18n"].transform_values do |tr|
          next tr unless tr.is_a?(Hash) && tr.key?("responses")
          next tr.except("responses") if size.zero?
          labels = Array(tr["responses"]).first(size)
                                         .map { |l| l.to_s.strip.first(TapScales::MAX_LABEL) }
          labels += [ "" ] * (size - labels.length) if labels.length < size
          tr.merge("responses" => labels)
        end
      end
      # A range card's slider orientation — "auto" (heuristic decides at
      # render time) or an explicit creator override, and only on a range
      # card. Same allowlist-or-drop shape as range_theme above.
      if c.key?("slider_axis")
        axis = c["slider_axis"].to_s
        if c["type"].to_s == "range" && %w[auto horizontal vertical].include?(axis)
          c["slider_axis"] = axis
        else
          c.delete("slider_axis")
        end
      end
      # Paged text — bounded count/length, and every page gets a stable id
      # (mirrors the cid backfill above) so translations align by id rather than
      # array index, which would silently scramble if a creator reorders pages
      # after translating. Shared by scenario (narrative before a choice) and
      # consent_gate (an information sheet before agreeing), which store pages
      # identically. Dropped entirely on any other type, same as range_theme.
      if PAGED_TYPES.include?(c["type"].to_s)
        c["pages"] = Array(c["pages"]).first(MAX_SCENARIO_PAGES).filter_map do |p|
          next unless p.is_a?(Hash)
          text = p["text"].to_s.strip.first(MAX_SCENARIO_PAGE_LENGTH)
          next if text.blank?
          page = { "id" => p["id"].to_s.strip.presence || "pg_#{SecureRandom.hex(4)}", "text" => text }
          # Rich-text layer for the page, same equivalence contract as
          # text_html below: presentation only, must still read as `text`.
          if (html = RichTextSanitizer.clean_equivalent(p["html"], text))
            page["html"] = html
          end
          page
        end
        if c["i18n"].is_a?(Hash)
          c["i18n"] = c["i18n"].transform_values do |tr|
            next tr unless tr.is_a?(Hash) && tr["pages"].present?
            tr = tr.dup
            tr["pages"] = Array(tr["pages"]).first(MAX_SCENARIO_PAGES).filter_map do |p|
              next unless p.is_a?(Hash) && p["id"].present?
              { "id" => p["id"].to_s, "text" => p["text"].to_s.strip.first(MAX_SCENARIO_PAGE_LENGTH) }
            end
            tr
          end
        end
      else
        c.delete("pages")
      end

      sanitize_card_modal!(c)

      # Per-card free-text cap. Clamped into FREE_TEXT_LIMIT_RANGE rather than
      # rejected, and dropped when it equals the default so a deck only carries
      # the key when a creator actually changed it.
      if c.key?("char_limit")
        limit = c["char_limit"].to_i
        if limit.zero? || limit == DEFAULT_FREE_TEXT_LIMIT
          c.delete("char_limit")
        else
          c["char_limit"] = limit.clamp(FREE_TEXT_LIMIT_RANGE.min, FREE_TEXT_LIMIT_RANGE.max)
        end
      end

      # Per-card ceiling on how many options a respondent may tick. ABSENT means
      # no limit, and storing the absence rather than the number is the
      # load-bearing part: "as many as there are answers" has to stay true when
      # the creator adds a sixth option later. A max at or above the option count
      # therefore isn't a cap at all, and is dropped.
      #
      # Clamping against a SIBLING field is new — every other numeric card field
      # bounds itself against a constant. The consequence is that the key is
      # re-decided on every save, which is exactly what stops a cap of 4
      # outliving the two options that justified it.
      if c.key?("max_choices")
        n = c["max_choices"].to_i
        if MULTI_SELECT_TYPES.include?(c["type"].to_s) &&
           n >= MIN_MAX_CHOICES && n < Array(c["options"]).length
          c["max_choices"] = n
        else
          c.delete("max_choices")
        end
      end

      # Explicit "this question awards no points". Coerced to a real boolean
      # because TokenGrading.awarding? tests for `false` exactly — a "false"
      # string arriving from JSON would otherwise read as truthy and award. Only
      # an explicit false is kept; absent (and true) both mean enabled, so
      # existing decks are untouched.
      if c.key?("tokens_enabled")
        enabled = ActiveModel::Type::Boolean.new.cast(c["tokens_enabled"])
        enabled == false ? c["tokens_enabled"] = false : c.delete("tokens_enabled")
      end

      if c.key?("image")
        original  = c["image"]
        had_image = original.present?
        c["image"] = sanitize_image_url(original)
        if had_image && c["image"].nil?
          warnings << "image" if warnings
          details << dropped_media_detail("image", c, original) if details
        end
      end
      if c.key?("option_images")
        before = Array(c["option_images"])
        after  = before.map { |u| sanitize_image_url(u) }
        c["option_images"] = after
        # Compared slot by slot, NOT array-wide. option_images is positional —
        # index i is statement i — so an empty slot means "this statement has no
        # picture", which is the ordinary state of any tap card where the creator
        # cleared one image or where only some statements were given one. The old
        # test ("something is present" AND "something is nil") read those blanks
        # as drops and fired on every autosave, telling the creator to re-upload
        # an image they had deliberately removed, forever, with nothing wrong.
        dropped = before.each_index.select { |i| before[i].present? && after[i].nil? }
        if dropped.any?
          warnings << "option_images" if warnings
          dropped.each { |i| details << dropped_media_detail("option_images", c, before[i], index: i) } if details
        end
      end

      # A card's left panel holds a photo OR a video OR a Lottie animation.
      # Scrub all three; a poster only makes sense alongside a video.
      if c.key?("video")
        c["video"] = sanitize_video_url(c["video"])
        c.delete("video") if c["video"].blank?
      end
      if c.key?("video_poster")
        c["video_poster"] = sanitize_image_url(c["video_poster"])
        c.delete("video_poster") if c["video"].blank? || c["video_poster"].blank?
      end
      if c.key?("lottie")
        original_lottie = c["lottie"]
        had_lottie = original_lottie.present?
        c["lottie"] = sanitize_lottie_url(original_lottie)
        if c["lottie"].blank?
          c.delete("lottie")
          if had_lottie
            warnings << "lottie" if warnings
            details << dropped_media_detail("lottie", c, original_lottie) if details
          end
        else
          # Mirrors the client's exclusivity: applying an animation clears the
          # photo/video (and with them the credit fields, below). Warn on
          # this same as an outright-rejected image — a card should never
          # reach this branch with both set (the client never sends both,
          # and Shuffle is guarded against it too), so if one does, whatever
          # put it there deserves a visible flag, not a silent drop.
          if c["image"].present?
            warnings << "image" if warnings
            details << dropped_media_detail("image", c, c["image"]) if details
          end
          if c["video"].present?
            warnings << "video" if warnings
            details << dropped_media_detail("video", c, c["video"]) if details
          end
          c.delete("image")
          c.delete("video")
          c.delete("video_poster")
        end
      end

      # A slow, looping push-in/out on the card's own photo or Lottie — never
      # video (its own motion is enough) or range (the reaction set already
      # animates). Checked against image/lottie AFTER both are sanitised
      # above, so a card whose animation just got rejected doesn't keep a
      # flag for motion it no longer has anything to apply to.
      if c.key?("animate_asset")
        animatable = c["type"].to_s != "range" && (c["image"].present? || c["lottie"].present?)
        if animatable && c["animate_asset"] == true
          c["animate_asset"] = true
        else
          c.delete("animate_asset")
        end
      end

      if c.key?("image_credit") || c.key?("image_credit_url")
        if c["image"].present? || c["video"].present?
          c["image_credit"]     = c["image_credit"].to_s.strip.first(MAX_CREDIT_NAME).presence
          c["image_credit_url"] = sanitize_credit_url(c["image_credit_url"])
          c.delete("image_credit_url") if c["image_credit"].blank?
          c.delete("image_credit")     if c["image_credit"].blank?
        else
          c.delete("image_credit")
          c.delete("image_credit_url")
        end
      end

      # The re-crop record: the pre-crop original a card image was cut from
      # (image_source, same allowlist as any image value) and the crop as
      # fractions of it (image_crop) — what lets the editor's "Adjust crop"
      # zoom back OUT of the shipped crop. Editor-only metadata: the player
      # renders `image` and never reads either. A source without the image
      # it explains is dead data; a crop without its source describes
      # nothing — both dropped rather than kept, no warning (losing them
      # degrades a card to remove-and-reupload, it doesn't lose the image).
      if c.key?("image_source") || c.key?("image_crop")
        c["image_source"] = c["image"].present? ? sanitize_image_url(c["image_source"]) : nil
        c.delete("image_source") if c["image_source"].blank?
        crop = c["image_source"].present? ? sanitize_image_crop(c["image_crop"]) : nil
        crop ? c["image_crop"] = crop : c.delete("image_crop")
      end

      # Where the card's media sits inside whatever frame crops it — the mobile
      # header strip, the editor's device frames, and (horizontally) the desktop
      # panel. 0-100 per axis, percentages handed straight to background-position
      # / object-position; 50 (centre) is the default and is stored as nothing.
      # A card image is a 9:16 portrait while the mobile hero is roughly 3:1, so
      # `cover` + centre shows only the middle band of a tall photo and a face at
      # the top of the frame is simply gone — "to drag the image up and down to
      # choose the perfect spot for mobile headers. This would be a huge win"
      # (18 Aug).
      #
      # A stored position rather than a second crop: the original stays intact,
      # so it can be re-adjusted for ever and every other surface still gets the
      # whole picture. That is also what makes it the one reframing that works on
      # media the crop stage cannot touch — a Pexels photo (cross-origin, so the
      # canvas tainting kills the re-encode) or a video (never croppable) — which
      # is why the horizontal axis exists at all: "reposition every image and
      # piece of content, at the moment I can only do it with uploads".
      #
      # Read AFTER image/video/lottie have been scrubbed, so a position can only
      # survive alongside media that itself survived.
      if c.key?("focal_x") || c.key?("focal_y") || c.key?("focal_zoom")
        positioned = c["image"].present? || c["video"].present?
        %w[focal_x focal_y].each do |axis|
          next unless c.key?(axis)
          # `.to_f` alone would turn any junk into 0.0, i.e. silently pin the
          # frame to the edge of the image. A value that isn't a number is a
          # value we don't understand — drop it and use the centre.
          focal = sanitize_focal_percent(c[axis])
          if positioned && focal && focal != 50
            c[axis] = focal
          else
            c.delete(axis)
          end
        end
        # How far past cover-fit it sits. Kept independently of the axes: a
        # creator can punch in without moving off centre, and the zoom is
        # what gives an already-fitting axis something to slide.
        if c.key?("focal_zoom")
          zoom = positioned ? sanitize_focal_zoom(c["focal_zoom"]) : nil
          zoom ? c["focal_zoom"] = zoom : c.delete("focal_zoom")
        end
      end

      # The same reposition, once per tap-card statement. POSITIONAL against
      # option_images (index i is statement i, exactly like the images
      # themselves), each entry either an {"x","y"} pair or nil for "this one
      # sits where it always did". A slot whose image didn't survive above
      # loses its position with it, and an array that ends up saying nothing
      # is dropped rather than stored as a row of nulls.
      if c.key?("option_focals")
        focals = sanitize_option_focals(c["option_focals"], Array(c["option_images"]))
        focals.any? ? c["option_focals"] = focals : c.delete("option_focals")
      end

      # CardSubjectExtractor's photographable-noun-phrase stamp, read by
      # AssetPopulator#card_query to anchor Pexels queries — provenance
      # metadata, not shown to a respondent, so it's simply bounded plain text
      # like lane_label/outcome above rather than tied to the card carrying an
      # image (a subject can be stamped before any image is picked, and
      # outlives a later image being cleared).
      if c.key?("subject")
        c["subject"] = c["subject"].to_s.strip.first(MAX_CARD_SUBJECT).presence
        c.delete("subject") if c["subject"].blank?
      end
      # The respondent-code card's recall opt-in. Coerced to a strict boolean
      # rather than left to ride through like the other card flags, because
      # this one is the switch on an endpoint that hands back a DIFFERENT
      # person's answers — a truthy string arriving from a client is not a
      # creator's decision, and only that card can carry it at all.
      if c.key?("recall")
        c["type"].to_s == "respondent_code" && c["recall"] == true ? c["recall"] = true : c.delete("recall")
      end
      c
    end.then { |list| enforce_single_welcome(list, warnings: warnings) }
       .then { |list| enforce_single_respondent_code(list, warnings: warnings) }
       .then { |list| enforce_single_points_intro(list, warnings: warnings) }
       .then { |list| structural ? drop_retired_cards(list, warnings: warnings) : list }
       .then { |list| structural ? hoist_consent_gate(list, warnings: warnings) : list }
  end

  # At most one points-intro card per deck, same shape and same reasoning as
  # enforce_single_welcome below: the intro is one message, and a second card
  # would say it twice. Dropped with a warning rather than rejected, so a deck
  # that somehow acquired two can still be saved.
  def self.enforce_single_points_intro(list, warnings: nil)
    seen = false
    list.filter_map do |c|
      next c unless c.is_a?(Hash) && c["type"].to_s == "points_intro"
      if seen
        warnings << "duplicate_points_intro" if warnings
        next nil
      end
      seen = true
      c
    end
  end

  # At most one respondent-code card per deck, same shape and same reasoning as
  # enforce_single_welcome above: a second one asks the same person for the same
  # code twice, and apply_respondent_code sets the digest ONCE per response, so
  # the second card's answer would be silently discarded anyway. Dropped with a
  # warning rather than rejected, so a deck that somehow acquired two can still
  # be saved.
  def self.enforce_single_respondent_code(list, warnings: nil)
    seen = false
    list.filter_map do |c|
      next c unless c.is_a?(Hash) && c["type"].to_s == "respondent_code"
      if seen
        warnings << "duplicate_respondent_code" if warnings
        next nil
      end
      seen = true
      c
    end
  end

  # Cards of a retired type never survive a save (see CardTypes.retired?).
  #
  # Safe to drop rather than merely hide, because this runs only on the
  # editor's save path and #update refuses any edit to a Verto that is
  # published or has responses (editing_locked?) — so a deck reaching here has
  # no stored answers for the renumbering to misalign. Live decks keep their
  # copy and the player skips it instead. An account allowed past the lock
  # (LiveEditAccess) saves a live deck through sanitize_cards_images! too, so
  # #update passes `structural: false` for a locked deck and this pass is
  # skipped: the retired card stays exactly where the stored answers expect it.
  #
  # Dropped with a warning rather than a 422, for the same reason
  # enforce_single_welcome drops: decks holding a retired card already exist,
  # and rejecting would turn a historical oddity into an editor that can no
  # longer save.
  def self.drop_retired_cards(list, warnings: nil)
    list.filter_map do |c|
      next c unless c.is_a?(Hash) && CardTypes.retired?(c["type"])
      warnings << "retired_card" if warnings
      nil
    end
  end

  # At most one welcome card per deck. Nothing enforced this: welcome_card was
  # pickable like any other type, so a second could be added — or any card
  # converted into one — and the player then greeted the respondent twice.
  #
  # Duplicates are DROPPED (keeping the first) rather than rejected, and the
  # choice is deliberate: decks with two welcome cards already exist, and a
  # validation error here would 422 their every autosave from now on — turning
  # a historical oddity into an editor that can no longer save. The drop is not
  # silent either: it pushes onto `warnings`, the same channel a rejected image
  # uses, which the editor surfaces as a save warning.
  def self.enforce_single_welcome(list, warnings: nil)
    seen = false
    list.filter_map do |c|
      next c unless c.is_a?(Hash) && c["type"].to_s == "welcome_card"
      if seen
        warnings << "duplicate_welcome" if warnings
        next nil
      end
      seen = true
      c
    end
  end

  # A consent gate must come before any card that captures an answer.
  #
  # It is an ordinary deck card, so a creator could put it at position four —
  # and /progress persists answers on every advance, so by the time the
  # respondent read the sheet and declined, three answers were already stored,
  # counted as a responder, and feeding the public aggregates. Declining is
  # supposed to mean their data is not collected.
  #
  # Non-question cards may still precede it: a welcome card or a points
  # checkpoint captures nothing, so "Hello → consent → questions" is both a
  # nicer flow and still safe. The rule is "before any QUESTION", not "first".
  #
  # Only reached from the editor's save path, and #update refuses any edit to a
  # Verto that is published or already has responses (editing_locked?), so a
  # deck being reordered here can have no stored answers to misalign — which
  # matters, because answers are keyed by card index. An account LiveEditAccess
  # allows past the lock can save a locked deck, so for one #update passes
  # `structural: false` to sanitize_cards_images! and this hoist is skipped —
  # an existing gate stays where the stored answers expect it.
  def self.hoist_consent_gate(list, warnings: nil)
    gate_at = list.index { |c| c.is_a?(Hash) && c["type"].to_s == "consent_gate" }
    return list if gate_at.nil?

    first_question = list.index { |c| c.is_a?(Hash) && CardTypes.question?(c["type"]) }
    return list if first_question.nil? || gate_at < first_question

    gate = list.delete_at(gate_at)
    # The gate is leaving its place in the deck, so any flow membership or
    # branch routing it carried is stale — FlowCompiler chains flow members in
    # deck order, and a hoisted gate still wearing its flow_id would splice the
    # gate into the flow's chain at the front and skip the question the route
    # actually pointed at. Same channel as the image warnings, so the editor
    # can tell the creator the deck was reshaped.
    gate.delete("next")
    gate.delete("flow_id")
    gate.delete("lane_label")
    warnings << "consent_gate_moved" if warnings
    list.insert(first_question, gate)
    list
  end

  # Quiz: the card indices that are graded (carry a correct answer). Empty for a
  # non-quiz Verto, or a quiz whose questions are all still measurement-only.
  def graded_card_indices
    return [] unless quiz?
    QuizGrading.graded_indices(cards)
  end

  def quiz_question_count
    graded_card_indices.size
  end

  # Tokenisation: the card indices that award at least one token. Empty for a
  # non-tokenised Verto, or one whose cards are all still unawarded.
  def token_awarding_indices
    return [] unless tokenisation_enabled?
    TokenGrading.awarding_indices(cards)
  end

  # Which deck position carries the "you'll earn points" intro.
  #
  # The creator's choice is STORED as a cid, so it follows its card through a
  # reorder — but it's RESOLVED to an index, because a deck built outside the
  # editor's save path (the demo seeder, a raw import) can have no cids at all,
  # and the intro still has to appear. Falls back to the welcome card, where it
  # used to be hardcoded, then to the first card.
  # Whether the deck carries a Points Intro card — the intro on a card of its
  # own, superseding the picker below exactly as the respondent_code card
  # supersedes its pre-screen switch.
  def points_intro_card?
    Array(cards).any? { |c| c.is_a?(Hash) && c["type"].to_s == "points_intro" }
  end

  def token_intro_index
    return nil unless tokenisation_enabled?
    # The card renders the intro itself (see _card_component.html.erb), so the
    # inline copy renders nowhere while one is in the deck — and removing the
    # card restores the previous inline placement, token_intro_cid untouched.
    return nil if points_intro_card?

    list = Array(cards)
    return nil if list.empty?

    wanted = token_intro_cid.presence
    if wanted
      found = list.index { |c| c.is_a?(Hash) && c["cid"].to_s == wanted }
      return found if found
    end

    list.index { |c| c.is_a?(Hash) && c["type"].to_s == "welcome_card" } || 0
  end

  # The cid of that card, when it has one — what the editor's picker marks as
  # selected. Nil on a deck whose cards predate cid backfilling; the picker only
  # offers cid-bearing cards, and the default above covers the rest.
  def token_intro_selected_cid
    idx = token_intro_index
    return nil if idx.nil?

    card = Array(cards)[idx]
    card.is_a?(Hash) ? card["cid"].presence : nil
  end

  # Cards a creator can pin the token intro to — anything with a cid.
  def token_intro_choices
    Array(cards).filter_map do |c|
      next unless c.is_a?(Hash) && c["cid"].present?
      [ c["cid"].to_s, c["type"].to_s, c["title"].presence || c["text"].presence ]
    end
  end

  def token_awarding_count
    token_awarding_indices.size
  end

  # This Verto's defined token type ids, e.g. ["gold", "coal"].
  def token_type_ids
    Array(token_types).map { |t| t["id"] }.compact
  end

  MAX_TOKEN_TYPES  = 8
  MAX_TOKEN_NAME   = 40
  MAX_TOKEN_ICON   = 8

  # Coerce creator-submitted token type definitions into a safe, bounded
  # array of {"id", "name", "icon"} before persisting: caps the count, trims
  # name/icon length, drops entries with no name, and assigns a stable id to
  # any entry that doesn't already have one (a fresh row from the editor) —
  # so cards that already reference an id by name change never break.
  def self.sanitize_token_types(value)
    Array(value).filter_map do |entry|
      next unless entry.is_a?(Hash)
      name = entry["name"].to_s.strip.first(MAX_TOKEN_NAME)
      next if name.blank?
      id   = entry["id"].to_s.strip.presence || SecureRandom.hex(4)
      icon = entry["icon"].to_s.strip.first(MAX_TOKEN_ICON).presence || "⭐"
      { "id" => id, "name" => name, "icon" => icon }
    end.first(MAX_TOKEN_TYPES)
  end

  def archive!
    update!(deleted_at: Time.current)
  end

  # ── Publish lifecycle ──────────────────────────────────────────────────────
  # Publishing mints a publish_token; unpublishing stamps unpublished_at and
  # leaves the token alone, so re-publishing restores the same /play link
  # (printed QR codes keep working). A Verto is therefore live only while it has
  # a token AND has not been taken down.
  def published?
    publish_token.present? && unpublished_at.nil?
  end

  # Test Mode: /test/:token plays the Verto — drafts included — without
  # sign-in, records nothing, and stays current while the creator edits.
  # Independent of published?/editing_locked? by design; since no responses
  # are ever written through it, it can never flip the editing lock. The
  # /test/ namespace resolves ONLY by exact test_token, so it never interacts
  # with slug_taken?'s /play/ namespace guard.
  def test_playable?
    test_token.present? && !deleted?
  end

  # Published once, currently taken down.
  def unpublished?
    publish_token.present? && unpublished_at.present?
  end

  # Taken down after collecting responses. Results are kept, but the deck can
  # never be edited again (see editing_locked?), so this is a terminal "closed"
  # state rather than a return to draft.
  def closed?
    unpublished? && responses.exists?
  end

  # Back to a fully editable draft: taken down before anyone answered, so
  # there's nothing for a deck change to misalign.
  def reverted_to_draft?
    unpublished? && !responses.exists?
  end

  # Structural edits are locked while a Verto is live, and STAY locked once it
  # has collected responses even after being taken down: answers are keyed by
  # card index, so adding, removing or reordering cards silently misaligns every
  # later answer already stored. This — not published? — is the real editing
  # boundary, and every write path guards on it.
  #
  # A fact about the VERTO, not about who is asking. The one exception — the
  # accounts LiveEditAccess allows to edit a locked deck knowingly — is applied
  # at the controller boundary (LiveEditing#editing_locked?(survey)), so this
  # predicate keeps answering what it always did and the model's own guards
  # (switch_primary_locale!, the normalisers above that skip a locked deck)
  # don't need to know the override exists.
  def editing_locked?
    published? || responses.exists?
  end

  # Reachable by a respondent at /play/:token (or a partner share link): live,
  # and not archived. The single boundary every public player action guards on.
  def playable?
    published? && !deleted?
  end

  # A results-share token has been minted — distribution state, like
  # test_token/slug, so nothing here touches editing_locked? or published?.
  # The data being shared already exists regardless of whether /play is still
  # collecting more of it.
  def results_share_enabled?
    results_share_token.present?
  end

  # Reachable by anyone at /results/:token: a token exists, hasn't been
  # paused, and the Verto isn't archived. Deliberately NOT gated on
  # published? — a closed Verto's results stay shareable, and the owner
  # controls the whole thing explicitly either way.
  def results_share_live?
    results_share_enabled? && results_share_active? && !deleted?
  end

  # ── Respondent code ────────────────────────────────────────────────────────
  # An optional self-invented code ("your nickname and the day of the month you
  # were born") that links one person's answers across waves of the same Verto
  # without identifying them.
  #
  # Only ever stored as an HMAC. The key is derived per survey, so a digest is
  # comparable only WITHIN this Verto: the same code given to two Vertos yields
  # two unrelated digests, and a creator with database access can neither read a
  # code nor recognise someone across their other Vertos.

  MAX_RESPONDENT_CODE = 60

  # The code can be collected two ways, and the card supersedes the switch —
  # exactly as consent_gate supersedes consent_text (see #consent_required?).
  #
  #   respondent_code_enabled?    the survey-level PRE-SCREEN switch, raw column
  #   respondent_code_card?       a respondent_code card sits in the deck
  #   respondent_code_prescreen?  render the pseudo-card before the deck
  #   respondent_code_active?     a code is being collected AT ALL — which is
  #                               what the player's write path has to ask, and
  #                               asking the column instead meant a deck using
  #                               only the card never recorded a digest.
  #
  # Leaving the column predicate raw keeps the settings form, the migration and
  # every Blazer query working untouched.
  def respondent_code_card
    Array(cards).find { |c| c.is_a?(Hash) && c["type"].to_s == "respondent_code" }
  end

  def respondent_code_card? = respondent_code_card.present?
  def respondent_code_prescreen? = respondent_code_enabled? && !respondent_code_card?
  def respondent_code_active? = respondent_code_enabled? || respondent_code_card?

  # Whether entering the code may fill in ask-once answers this person gave on
  # another device. Off unless the creator turned it on, on the card itself —
  # see PlayerController#recall for what that costs and why it is opt-in.
  def respondent_code_recall?
    respondent_code_card&.dig("recall") == true
  end

  def respondent_code_prompt_text
    respondent_code_prompt.presence || I18n.t("player.respondent_code_prompt_default")
  end

  # nil for anything that isn't a usable code, so a blank or whitespace-only
  # entry is simply "no code" rather than a digest everyone shares.
  def respondent_code_digest(code)
    normalised = self.class.normalize_respondent_code(code)
    return nil if normalised.blank?

    OpenSSL::HMAC.hexdigest("SHA256", respondent_code_key, normalised)
  end

  # The leaderboard identity digest — respondent_code_digest's sibling, same
  # posture: the raw browser-minted key is never stored, and the per-survey
  # key means a digest is comparable only within this Verto, so identities
  # can't be joined across surveys.
  #
  # Still true of DIGESTS, and only of digests. Since respondent accounts
  # (PlayerClaim) there IS one cross-Verto join in the app — but it is opt-in,
  # made by the respondent from their own inbox, and it materialises
  # response_id rather than re-deriving anything from these keys. Nothing here
  # feeds it: see PlayerController#join for why the account writes no digests
  # at all. nil for blank input ("no identity"), and
  # the length bound keeps an abusive payload from becoming HMAC fodder — a
  # legitimate key is a 36-char UUID.
  def player_key_digest(key)
    normalised = key.to_s.strip.first(80)
    return nil if normalised.blank?

    OpenSSL::HMAC.hexdigest("SHA256", player_key_hmac_key, normalised)
  end

  # Case and spacing shouldn't decide whether someone matches themselves — a
  # respondent typing "Sam 14" in wave two after "sam14" in wave one is the same
  # person, and the whole feature is worthless if that misses.
  def self.normalize_respondent_code(code)
    code.to_s.unicode_normalize(:nfkc).downcase.gsub(/\s+/, "").first(MAX_RESPONDENT_CODE)
  end

  # How many respondents gave a code that another response also gave — i.e. came
  # back. Counted in SQL; the digests never leave the database.
  def returning_respondents_count
    responses.where.not(respondent_code_digest: nil)
             .group(:respondent_code_digest)
             .having("COUNT(*) > 1")
             .count.size
  end

  # ── Waves ───────────────────────────────────────────────────────────────────
  # Explicit records the owner opens and closes, not a time window derived from
  # published_at/unpublished_at: those are single columns a re-publish
  # overwrites (#publish keeps the original published_at and nils
  # unpublished_at — no open/close history survives), and responses.completed_at
  # is server-receipt time, not answer time — the offline submit queue can drain
  # after the next wave has already opened, so a timestamp comparison would
  # misfile it. A response is stamped with the CURRENT wave once, at write time
  # (PlayerController#find_or_init_response), and that stamp never moves.
  #
  # Wave 1 stays implicit — no SurveyWave row — until start_next_wave! is first
  # called, at which point every response collected so far (survey_wave_id nil)
  # retroactively becomes wave 1's membership by backfill.

  def waved?
    survey_waves.exists?
  end

  # The wave any new response belongs to right now, or nil while wave 1 is
  # still implicit. At most one wave is ever open at a time — start_next_wave!
  # closes the previous one in the same transaction that opens the next.
  def current_wave
    survey_waves.find_by(closed_at: nil)
  end

  # Closes whatever wave is open and opens a new one, materialising the
  # implicit wave 1 (backfilling every pre-existing response into it) the
  # first time this is ever called. `label` is the owner's optional name for
  # the NEW wave; the one being closed keeps whatever label it already had.
  def start_next_wave!(label: nil)
    transaction do
      if waved?
        close_current_wave!
      else
        wave1 = survey_waves.create!(position: 1, opened_at: published_at || created_at)
        responses.where(survey_wave_id: nil).update_all(survey_wave_id: wave1.id)
        wave1.update!(closed_at: Time.current)
      end
      next_position = survey_waves.maximum(:position).to_i + 1
      survey_waves.create!(position: next_position, label: label.presence, opened_at: Time.current)
    end
  end

  def close_current_wave!
    current_wave&.update!(closed_at: Time.current)
  end

  # How many respondents in `wave` gave a code that also appears in an
  # EARLIER wave — i.e. came back for this run specifically, not merely
  # "answered more than once ever" (returning_respondents_count, whole-Verto).
  # Same discipline: counted in SQL, digests never leave the database.
  def wave_returning_count(wave)
    earlier_ids = survey_waves.where("position < ?", wave.position).pluck(:id)
    return 0 if earlier_ids.empty? # nothing can return before the first wave

    responses.where(survey_wave_id: wave.id)
             .where.not(respondent_code_digest: nil)
             .where(respondent_code_digest: responses.where(survey_wave_id: earlier_ids).select(:respondent_code_digest))
             .count
  end

  # Which identity "No retests" is checked against. The respondent code is the
  # study identity — one person across devices — so it is the ONLY basis on a
  # Verto that collects one; the per-device player key is the fallback for a
  # Verto that does not. Never both: OR-ing them would refuse the second pupil
  # on a shared classroom tablet for the first pupil's run.
  def retest_basis
    return nil unless no_retests?
    respondent_code_active? ? "code" : "device"
  end

  # One completed run per identity per wave. `current_wave` is nil while wave 1
  # is implicit, and new rows are stamped the same way (PlayerController#
  # find_or_init_response), so nil here means IS NULL on both engines and
  # matches exactly the implicit-wave rows; start_next_wave! backfills them
  # into a real wave 1 before it opens the next, which is what re-admits
  # everyone. The row being written is excluded so a replayed submit of the
  # same completed row (offline queue, double tap) stays idempotent. Digests
  # never leave this method.
  def retest_blocked?(resp)
    basis = retest_basis
    return false unless basis

    column = basis == "code" ? :respondent_code_digest : :player_key_digest
    digest = resp.public_send(column)
    # Never `where(column: nil)`: IS NULL would match every digest-less row.
    return false if digest.blank?

    scope = responses.where(status: "completed", survey_wave_id: current_wave&.id, column => digest)
    scope = scope.where.not(id: resp.id) if resp.persisted?
    scope.exists?
  end

  # ── Recently deleted cards ─────────────────────────────────────────────────
  # A bounded ring buffer of cards removed from the deck, so a deletion survives
  # the page reload that in-session undo can't. Not a versioning gem: the need is
  # "give me that card back", not a history of every edit.

  MAX_DELETED_CARDS = 10

  # Cards present in `before` but gone from `after`, newest first, capped.
  # Matched on cid — the stable per-card id — so a reorder is never mistaken for
  # a delete, which comparing by index would do constantly.
  def self.record_deleted_cards(before, after, existing)
    remaining = Array(after).filter_map { |c| c["cid"].to_s.presence if c.is_a?(Hash) }.to_set

    # Anything back in the deck leaves the bin — evaluated on EVERY save, not
    # only ones that also delete something, because a restore is precisely the
    # save that removes nothing.
    kept = Array(existing).reject { |e| e.is_a?(Hash) && remaining.include?(e.dig("card", "cid").to_s) }

    removed = Array(before).select do |c|
      c.is_a?(Hash) && c["cid"].to_s.present? && !remaining.include?(c["cid"].to_s)
    end
    return kept.first(MAX_DELETED_CARDS) if removed.empty?

    entries = removed.map { |card| { "card" => card, "deleted_at" => Time.current.iso8601 } }
    (entries + kept).first(MAX_DELETED_CARDS)
  end

  # The bin, newest first, with anything malformed dropped.
  def recently_deleted_cards
    Array(read_attribute(:deleted_cards)).select do |entry|
      entry.is_a?(Hash) && entry["card"].is_a?(Hash) && entry.dig("card", "cid").present?
    end
  end

  # Pull one card back out by cid. Returns the card hash, or nil if it's gone.
  # Removing it from the bin is the caller's business — restoring is a client-side
  # splice, and the card only truly returns once the deck is saved with it.
  def deleted_card(cid)
    recently_deleted_cards.find { |e| e.dig("card", "cid").to_s == cid.to_s }&.dig("card")
  end

  # ── Free-text limits ───────────────────────────────────────────────────────

  # The free-text cap for the card at `index`.
  def free_text_limit_at(index)
    card = Array(cards)[index.to_i]
    return DEFAULT_FREE_TEXT_LIMIT unless card.is_a?(Hash)

    limit = card["char_limit"].to_i
    limit.positive? ? limit.clamp(FREE_TEXT_LIMIT_RANGE.min, FREE_TEXT_LIMIT_RANGE.max) : DEFAULT_FREE_TEXT_LIMIT
  end

  # Truncate every free-text answer to its card's limit.
  #
  # The client has a maxlength now, but a maxlength is a courtesy: this endpoint
  # is public and takes JSON, so anything relying on the browser to keep the
  # answers column bounded isn't a limit at all. Applies to the answer value and
  # to the "Other" box, which is free text by another name.
  def clamp_free_text(answers)
    return answers unless answers.is_a?(Hash)

    answers.each_with_object({}) do |(key, entry), out|
      unless entry.is_a?(Hash)
        out[key] = entry
        next
      end

      limit = free_text_limit_at(key)
      clamped = entry.dup
      clamped["value"] = entry["value"].first(limit) if entry["value"].is_a?(String)
      clamped["other"] = entry["other"].first(limit) if entry["other"].is_a?(String)
      out[key] = clamped
    end
  end

  # ── Choice limits ──────────────────────────────────────────────────────────

  # The tick ceiling for the card at `index`, or nil where there is none.
  # Re-checked against the card's live options rather than trusted, for the same
  # reason the sanitiser re-decides the key on every save: a deck edited between
  # a cap being set and an answer arriving must not leave a ceiling standing that
  # the card no longer justifies.
  def max_choices_at(index)
    card = Array(cards)[index.to_i]
    return nil unless card.is_a?(Hash) && MULTI_SELECT_TYPES.include?(card["type"].to_s)

    n = card["max_choices"].to_i
    n.between?(MIN_MAX_CHOICES, Array(card["options"]).length - 1) ? n : nil
  end

  # Trim any selection that arrives over its card's ceiling.
  #
  # Same posture as clamp_free_text above, and the same reason: the player
  # refuses the extra tap, but a refusal in the browser is a courtesy and this
  # endpoint is public JSON. Array answers had no length bound of ANY kind
  # before this — clamp_free_text only touches Strings.
  #
  # Keeps the leading N in the order they arrived, which is the DOM order the
  # player's _read produces, so what survives reads as the first N the
  # respondent picked rather than an arbitrary subset.
  def clamp_selection_count(answers)
    return answers unless answers.is_a?(Hash)

    answers.each_with_object({}) do |(key, entry), out|
      max = entry.is_a?(Hash) && entry["value"].is_a?(Array) ? max_choices_at(key) : nil
      out[key] = max ? entry.merge("value" => entry["value"].first(max)) : entry
    end
  end

  # The retired contact card's answer shape: an object of these fields (any
  # subset). Nothing writes this shape any more — it survives because results
  # and the CSV/Excel export still have to READ the details collected while the
  # card was live, and they need to know which fields to lay out in which order.
  CONTACT_FIELDS = %w[name company industry email].freeze

  # Refuse answers to a retired card type. Same posture as clamp_free_text
  # directly above the call site: the player no longer renders these cards at
  # all, but this endpoint is public JSON, so the server owns the contract
  # rather than trusting that nothing will post one — including a respondent
  # whose Service Worker is still serving a player cached from before the
  # retirement.
  #
  # The entry is kept and blanked rather than deleted, so the card still reads
  # as unanswered rather than as never having been in the deck.
  def drop_retired_answers(answers)
    return answers unless answers.is_a?(Hash)

    retired_keys = Array(cards).each_with_index
                               .select { |card, _| card.is_a?(Hash) && CardTypes.retired?(card["type"]) }
                               .map { |_, idx| idx.to_s }
    return answers if retired_keys.empty?

    answers.each_with_object({}) do |(key, entry), out|
      unless retired_keys.include?(key) && entry.is_a?(Hash)
        out[key] = entry
        next
      end

      out[key] = entry.merge("value" => nil)
    end
  end

  # The /play/:token segment to put in front of a respondent. Both the slug and
  # the publish_token resolve the same Verto (PlayerController#load_survey_and_share),
  # but a creator who bothered to set a custom link wants THAT one on the QR code
  # and anywhere else the link is handed out — it's the memorable one, and it
  # survives being read off a printed page. nil until published.
  def public_link_key
    return nil unless published?

    slug.presence || publish_token
  end

  # A same-organisation copy for the dashboard's "Duplicate" action. Always
  # lands in Drafts regardless of the source's status: publish_token,
  # published_at and slug share the /play/:token unique-index namespace, so
  # they're left nil rather than copied, and the results-report/summary
  # columns are generated from a specific run of responses the copy doesn't
  # have. `cards` is round-tripped through JSON so the copy owns its own
  # option/i18n arrays instead of sharing the source's in-memory objects. Card
  # cids are regenerated and every branching route/default rewritten old→new,
  # so the copy's routes point at the COPY's cards, never the original's.
  def duplicate!
    # Cards and flows must be remapped with the SAME cid map: a flow's exit can
    # point at a card, and the copy's exit has to follow the copy's fresh cid.
    dup_cards = JSON.parse(cards.to_json)
    dup_flows = JSON.parse(flows_list.to_json)
    self.class.remap_card_logic!(dup_cards, dup_flows)
    organisation.surveys.create!(
      title:                   self.class.append_copy_suffix(title),
      description:             description,
      # No "(Copy)" on the theme. It is the name a RESPONDENT sees — the player's
      # tab title, the link preview's og:title, the manifest, the mailers — so a
      # suffix here reached everyone the copy was ever shared with, and nothing
      # could take it off again. The marker that tells the creator which tile
      # is the copy is on title above, which the dashboard shows under the theme
      # whenever the two differ.
      theme:                   theme,
      audience_age:            audience_age,
      # Carried with the deck, not left behind: dup_cards copies any tailored
      # Heritage card's heritage_country along with it, so a copy that forgot
      # the setting would claim a country's taxonomy while saying it has none.
      audience_country:        audience_country,
      key_insight:             key_insight,
      cards:                   dup_cards,
      flows:                   dup_flows,
      brand_palette:           read_attribute(:brand_palette),
      background_image:        background_image,
      default_locale:          default_locale,
      locales:                 locales,
      quiz:                    quiz,
      logic:                   logic,
      end_screens:             read_attribute(:end_screens),
      render_mode:             render_mode,
      show_results_comparison: show_results_comparison,
      tokenisation_enabled:    tokenisation_enabled,
      token_types:             token_types,
      # Identical creator content means identical SDG tags — copying is free,
      # re-deriving would spend a Claude call to compute the same answer.
      sdgs:                    read_attribute(:sdgs),
      compare_note:            compare_note,
      # tokens_note and leaderboard_note were missing here until the join
      # prompt was added and the gap became obvious: a duplicated Verto
      # silently dropped both back to the locale default. A follow-up Verto is
      # usually made by duplicating the first, which is exactly when losing a
      # creator's own copy shows.
      tokens_note:             tokens_note,
      leaderboard_note:        leaderboard_note,
      token_result_note:       token_result_note,
      join_prompt_enabled:     join_prompt_enabled,
      # The PROMISE carries: a wave 2 made by duplicating wave 1 is asking the
      # same people about the same decision, so "the council decides in
      # October" is still the right sentence to be showing.
      #
      # The delivered impact does NOT, and neither does the follow-up list.
      # An impact belongs to the run that produced it — copying it would have
      # a brand-new Verto claiming, on day one, to have already changed
      # something — and a copied follow-up list would point the new Verto at
      # whatever the old one pointed at, including possibly itself.
      next_step_headline:      next_step_headline,
      next_step_body:          next_step_body,
      join_title:              join_title,
      join_body:               join_body,
      join_cta:                join_cta,
      thankyou_title:          thankyou_title,
      thankyou_body:           thankyou_body,
      forward_url:             forward_url,
      forward_label:           forward_label,
      share_title:             share_title,
      share_description:       share_description,
      share_message:           share_message,
      # The picked preview picture comes too: the copy carries the same cards,
      # the same backdrop and the same gate image, so the URL still points at a
      # picture the copy itself has — and a wave 2 made by duplicating wave 1
      # would otherwise quietly go back to being chosen for.
      share_image:             share_image,
      consent_text:            consent_text,
      consent_image:           consent_image,
      consent_image_credit:    consent_image_credit,
      consent_image_credit_url: consent_image_credit_url,
      leaderboard_enabled:     leaderboard_enabled,
      leaderboard_retake_policy: leaderboard_retake_policy,
      leaderboard_rank_by:     leaderboard_rank_by,
      # Study-design rules a duplicated instrument must keep.
      no_going_back:           no_going_back,
      no_retests:              no_retests
    ).tap { |copy| copy_card_attachments_to(copy) }
  end

  # Blobs a card's JSON points at — uploaded stills and stored Lottie
  # animations — belong to the survey they were attached to. The cards JSON is
  # copied verbatim above, so without this the copy's media is served entirely
  # out of the ORIGINAL's attachments: the paths resolve, nothing looks wrong,
  # and the copy silently depends on a survey it has no relationship with.
  # Re-attaching the same blobs gives the copy its own claim on them (Active
  # Storage keeps one blob, two attachments), so neither survey can pull the
  # media out from under the other.
  def copy_card_attachments_to(copy)
    referenced = card_images.blobs.select do |blob|
      copy.cards.to_json.include?(blob.filename.to_s)
    end
    copy.card_images.attach(referenced) if referenced.any?
  rescue StandardError => e
    # A copy without its attachments still works today (the paths point at the
    # original's blobs), so this is a hardening step, not a precondition.
    ErrorReporting.report("Survey#copy_card_attachments_to", e, survey_id: id)
  end

  # Give every card a fresh cid and rewrite each branching target (route +
  # default) from the old cid to the new one, so a duplicated deck's routes
  # stay internally consistent. Targets whose old cid isn't in the deck (an
  # unexpected dangling route) are left as-is; the player fails them safe to
  # the linear next card. Pass the deck's flows too and each flow's card exit
  # is rewritten through the same map (flow ids themselves are survey-scoped,
  # so they and the cards' flow_id memberships copy verbatim). Mutates and
  # returns `cards`.
  def self.remap_card_logic!(cards, flows = nil)
    cards  = Array(cards)
    id_map = {}
    used   = Set.new
    cards.each do |card|
      next unless card.is_a?(Hash)
      old   = card["cid"].to_s
      fresh = "c_#{SecureRandom.hex(4)}"
      fresh = "c_#{SecureRandom.hex(4)}" while used.include?(fresh) # guarantee uniqueness
      used << fresh
      id_map[old] = fresh if old.present?
      card["cid"] = fresh
    end
    cards.each do |card|
      next unless card.is_a?(Hash)
      if card["logic"].is_a?(Hash)
        logic = card["logic"]
        Array(logic["routes"]).each { |route| remap_logic_target!(route["to"], id_map) if route.is_a?(Hash) }
        remap_logic_target!(logic["default"], id_map)
      end
      remap_logic_target!(card["next"], id_map) # the unconditional flow pointer
    end
    Array(flows).each { |f| remap_logic_target!(f["exit"], id_map) if f.is_a?(Hash) }
    cards
  end

  def self.remap_logic_target!(target, id_map)
    return unless target.is_a?(Hash) && target["card"].present?
    target["card"] = id_map[target["card"]] if id_map.key?(target["card"])
  end

  def self.append_copy_suffix(value)
    value.present? ? "#{value} (Copy)" : value
  end

  # The compare-results promise shown on the welcome card. Falls back to the
  # default copy when the creator hasn't customised it.
  def compare_note_text
    compare_note.presence || I18n.t("player.compare_promise")
  end

  # The two tokenomics lines on the points intro, per-Verto with the locale
  # default as the fallback — same contract as compare_note above and the
  # thank-you copy below: nil means "say the usual thing".
  #
  # Two limits, not one, and the editor shows both. MAX_NOTE is the storage
  # bound — past it the copy is simply cut. RECOMMENDED_NOTE is where the line
  # stops fitting: the note renders as a single pill on the points intro
  # (player/_token_intro.html.erb), and the shipped default
  # (player.tokens_welcome_note) is 101 characters, so ~120 is the width the
  # design actually holds. A creator with more to say than that is writing a
  # card, not a note, and the editor says so rather than letting them find out
  # on a phone.
  MAX_NOTE         = 200
  RECOMMENDED_NOTE = 120

  def tokens_note_text
    tokens_note.presence || I18n.t("player.tokens_welcome_note")
  end

  def leaderboard_note_text
    leaderboard_note.presence || I18n.t("player.leaderboard_teaser")
  end

  # The sentence above the FINAL tally, and the one note here with no locale
  # default behind it: blank means the end screen says nothing extra, rather
  # than saying a house sentence about points whose meaning only the creator
  # knows. The mid-deck Points Checkpoint answers the same need through its
  # card's own `description` — which SurveyTranslator walks, so it reaches the
  # Verto's other languages — but the final tally is drawn onto the end screen
  # from the submit response and has no card to carry one.
  def token_result_note_text
    token_result_note.presence
  end

  # ── What a respondent is offered after they finish ────────────────────────
  # SurveyLink answers these same three questions, overriding them per link
  # (see SurveyLink#compare_results?). Anything rendering the player asks
  # whichever object it arrived through — `(@survey_link || @survey)` — so the
  # player never has to know whether a share link is in play. They exist as
  # aliases rather than the columns themselves so a link's own nil-means-inherit
  # column reader stays readable for the settings form.
  def compare_results? = show_results_comparison?
  def share_button?    = share_enabled?
  def regions_map?     = regions_enabled?

  # The end-of-Verto ask (join_prompt_enabled). Two limits apiece, same
  # reasoning as MAX_NOTE above: the storage cap is the less useful number,
  # because the block is a card on a phone and the copy stops FITTING well
  # before it stops saving. The shipped defaults are 40 and 118 characters, so
  # those are the widths the design actually holds.
  MAX_JOIN_TITLE         = 60
  RECOMMENDED_JOIN_TITLE = 40
  MAX_JOIN_BODY          = 200
  RECOMMENDED_JOIN_BODY  = 120

  # What the PLAYER renders. The fallback resolves in the respondent's locale,
  # which is the whole point of translating player.join_* — a French respondent
  # reads the French house copy.
  def join_title_text = join_title.presence || I18n.t("player.join_title")
  def join_body_text  = join_body.presence  || I18n.t("player.join_body")
  def join_cta_text   = join_cta.presence   || I18n.t("player.join_cta")

  # What the EDITOR pre-fills its three boxes with, and deliberately not the
  # same thing.
  #
  # The boxes render as `value=` on inputs that autosave `onchange`, so
  # whatever they show is one keystroke away from being SAVED — and a saved
  # join_title is shown to every respondent regardless of the language they
  # answer in. While en.yml was the only file carrying player.join_*, every
  # creator was pre-filled with English and this could not bite. Translating
  # those seven keys is what created the hazard: a creator with a French UI
  # would be handed French house copy, and a stray space in the box would pin
  # French onto an English Verto.
  #
  # So the pre-fill stays English — exactly what the box showed before the
  # backfill. English VARIANTS keep their own spelling (an en-US creator is not
  # shown British copy); everything else falls back to the source. The three
  # strings happen to be identical in en and en-US today, so this is a no-op
  # until one of them grows a spelling EnglishSpellings has an opinion about.
  #
  # Rendering these as `placeholder=` instead would sidestep the whole problem,
  # but it reverses a deliberate earlier choice — the creator edits the real
  # sentence rather than a ghost of it — so it belongs in its own change.
  def join_title_for_editor = join_title.presence || house_join_copy("join_title")
  def join_body_for_editor  = join_body.presence  || house_join_copy("join_body")
  def join_cta_for_editor   = join_cta.presence   || house_join_copy("join_cta")

  def house_join_copy(field)
    locale = SupportedLocales.english?(I18n.locale) ? I18n.locale : I18n.default_locale
    I18n.with_locale(locale) { I18n.t("player.#{field}") }
  end

  # ── What happens next, and what happened ──────────────────────────────────
  #
  # Two halves written months apart (see the migration). The promise is
  # editable for the life of the Verto; the impact is published once, because
  # publishing is what sends the mail.

  MAX_NEXT_STEP_HEADLINE = 80
  RECOMMENDED_NEXT_STEP_HEADLINE = 50
  MAX_NEXT_STEP_BODY = 300
  RECOMMENDED_NEXT_STEP_BODY = 160

  MAX_IMPACT_HEADLINE = 80
  RECOMMENDED_IMPACT_HEADLINE = 50
  MAX_IMPACT_BODY = 600
  RECOMMENDED_IMPACT_BODY = 320
  # Three is a list; more needs ranking, and ranking a respondent's account
  # needs a model of the respondent this app has deliberately never built.
  MAX_IMPACT_CHANGES = 5
  MAX_IMPACT_CHANGE = 140
  MAX_FOLLOW_UPS = 3

  def impact_published? = impact_published_at.present?

  # Whether there is anything to say about what happens next. A Verto with
  # neither a promise nor an impact is the ORDINARY case, and the account says
  # the organisation hasn't said rather than that nothing happened — the app
  # does not know which, and must not imply the harsher reading of a creator
  # who simply hasn't come back.
  def next_step? = next_step_headline.present? || next_step_body.present?

  def impact_changes_list
    Array(impact_changes).filter_map { |line| line.to_s.strip.presence }
  end

  def impact_link? = impact_link_url.present?

  def impact_link_text
    impact_link_label.presence || I18n.t("you.impact_link_default")
  end

  # Enough written to be worth mailing. A headline alone is a promise, not an
  # outcome — refusing to publish an empty impact is what stops a misfire from
  # spending the one send this Verto gets.
  def impact_ready? = impact_headline.present? && impact_body.present?

  # The Vertos this one points at, in the creator's own order, and only ones
  # that are still theirs and still playable. Filtered at read time rather than
  # pruned on write, because a Verto can be unpublished or deleted long after
  # it was chosen and a respondent must never be sent to a dead link.
  def follow_up_surveys
    ids = Array(follow_up_survey_ids).filter_map { |v| Integer(v, exception: false) }
    return Survey.none if ids.empty?

    found = organisation.surveys.kept.where(id: ids).select(&:playable?).index_by(&:id)
    ids.filter_map { |id| found[id] }
  end

  # Reads as a question at the call sites that ask whether to render the block
  # (player/show, the partial, the URL local), matching leaderboard_active? and
  # respondent_code_active? beside it. Nothing else gates it: a draft or an
  # unpublished Verto still renders the markup, and the blank joinUrl value is
  # what keeps it inert there.
  def join_prompt? = join_prompt_enabled?

  # Thank-you screen copy shown after Finish. Both fall back to the default
  # localized copy when the creator hasn't set their own.
  def thankyou_title_text
    thankyou_title.presence || I18n.t("player.thank_you_title")
  end

  # The end screen's message — the creator's words, or nothing.
  #
  # It used to fall back to the "from <account>" byline, which meant the two
  # could never both be shown: a creator who wrote a message lost the byline,
  # and a creator who merely OPENED the thank-you card had the byline saved as
  # their message (the editor prefilled the box with this reader's value, and
  # the card saves on open). The byline is its own line now — see
  # thankyou_from_text — and this is the message alone.
  def thankyou_body_text
    body = thankyou_body.to_s.strip
    # A deck edited while the byline was this fallback has the byline sitting in
    # the column as though it had been typed, in whichever language the
    # creator's editor was in. Read as blank rather than migrated: the row is
    # harmless where it is, and a read answers for the decks a one-off
    # migration would have missed (an import, a duplicate, a restored backup).
    body.present? && thankyou_byline?(body) ? "" : body
  end

  # "from <account>", the byline under the message. Always drawn: it is the
  # attribution for the Verto, not a stand-in for copy the creator didn't write.
  def thankyou_from_text
    I18n.t("player.thank_you_from", org: organisation.name)
  end

  # Is this string the byline itself, in any language we ship? Every locale,
  # not just the current one, because the editor prefilled it in the creator's.
  def thankyou_byline?(text)
    thankyou_byline_texts.include?(text)
  end

  # Memoised: thankyou_body_text is read two or three times per render and this
  # walks every locale we ship.
  def thankyou_byline_texts
    @thankyou_byline_texts ||= I18n.available_locales.filter_map do |locale|
      I18n.t("player.thank_you_from", org: organisation.name, locale: locale, default: nil).presence
    end.to_set
  end

  def forward_url?
    forward_url.present?
  end

  # ── Share copy (what a passed-on /play link says about itself) ─────────────
  # Same contract as the thank-you readers above: the column is what the creator
  # wrote, the reader is what the product says. Blank falls back to the tags the
  # player has always emitted, so a Verto nobody has written share copy for
  # unfurls exactly as it did before these columns existed.
  #
  # The caps are the tightest each field meets in the wild, and they are enforced
  # in SurveysController#update_settings alongside every other creator-written
  # column — LinkedIn truncates a title past 70; og:description is cut around
  # 200 everywhere; a respondent's message rides in an SMS body, so 160.
  # The wizard's own cap on the theme (surveys/new, maxlength 120), applied
  # again where the editor renames it.
  MAX_THEME             = 120
  MAX_SHARE_TITLE       = 70
  MAX_SHARE_DESCRIPTION = 200
  MAX_SHARE_MESSAGE     = 160

  # The internal theme with the product name after it — what og:title has always
  # been. A creator who writes a headline is replacing exactly this.
  def share_title_text
    share_title.presence || "#{theme} · Playverto"
  end

  # description is the creator's editing brief and was never written for a
  # stranger, but it has been public in og:description all along; it stays the
  # fallback so nothing regresses.
  def share_description_text
    share_description.presence || description.presence || theme
  end

  # No fallback on purpose. The other two always have something to say because
  # the tags must be filled; a message written in the respondent's voice is
  # either the creator's or absent, and inventing one would put words in a
  # respondent's mouth.
  def share_message_text
    share_message.presence
  end

  # Whether the creator has set any of the share card — drives the editor's
  # CTA-versus-card state, the same way forward_url? and the thankyou_* columns
  # decide whether the thank-you slot is open.
  #
  # share_image counts. A creator who has only picked the preview picture has
  # still made a decision about how this link presents itself, and leaving the
  # card collapsed behind a "+ Share card" CTA would hide that decision on the
  # next page load with nothing on screen saying it had been made.
  def share_copy?
    share_title.present? || share_description.present? || share_message.present? ||
      share_image.present?
  end

  # The picture a shared /play link unfurls with. NEVER nil: a Verto with no
  # imagery of its own still gets a theme-matched one from the committed
  # library, because "sometimes there's a picture" is not something anybody can
  # rely on when they paste a link into a group chat, and an unfurl with no
  # image is a grey nothing next to one that has one.
  #
  # Relative here; the view absolutises it, because og:image must be an absolute
  # URL and only a request knows the host.
  #
  # A data: background falls THROUGH rather than being used: base64 cannot be an
  # og:image, and promoting one to a blob is a migration this does not need —
  # sanitize_background_image confines data: URLs to that one column anyway, so
  # there is almost always a card image or the library behind it.
  #
  # share_image is the creator's own choice, made in the editor's share card,
  # and it outranks the lot. Blank (or somehow unshareable) falls straight back
  # into the derivation below, which is what the Automatic tile restores — so
  # the override can always be undone without knowing what it replaced.
  def share_image_path
    return share_image if shareable_image?(share_image)

    default_share_image_path
  end

  # The picture this Verto would unfurl with if nobody had chosen one. Public
  # because the editor's Automatic tile has to SHOW it: "let it pick" is only a
  # real option if the creator can see what it picks.
  def default_share_image_path
    [ consent_image, background_image, first_card_image ]
      .find { |candidate| shareable_image?(candidate) } ||
      AssetPopulator.share_image_url_for(self)
  end

  # Alt text for it. The theme is what the picture was chosen to illustrate.
  def share_image_alt
    "#{theme} · Playverto"
  end

  # Fetchable by a crawler on the open internet: a Pexels URL is already
  # absolute and public, and the two same-origin forms become absolute in the
  # view. A data: URL is none of those things.
  #
  # On the class as well as the instance because update_settings has to apply
  # exactly this rule to an incoming share_image before storing it — a picture
  # no crawler can fetch is not a preview image, and storing one would leave the
  # creator looking at a thumbnail that never reaches a single chat app.
  def self.shareable_image?(url)
    return false if url.blank?

    value = url.to_s
    value.match?(PEXELS_IMAGE_URL) ||
      value.match?(ACTIVE_STORAGE_IMAGE_URL) ||
      value.match?(ASSET_IMAGE_URL)
  end

  def shareable_image?(url) = self.class.shareable_image?(url)

  # The first picture the deck itself carries, in card order — the Verto's own
  # imagery beats the library every time.
  def first_card_image
    Array(cards).each do |card|
      next unless card.is_a?(Hash)

      candidate = card["image"].presence ||
                  (card["media_bg"].is_a?(Hash) ? card["media_bg"]["image"].presence : nil)
      return candidate if shareable_image?(candidate)
    end
    nil
  end
  private :shareable_image?, :first_card_image

  # ── End screens (answer-branching) ─────────────────────────────────────────
  # A branch can finish on its own thank-you screen (e.g. a per-hub Stripe link)
  # instead of the shared one. The built-in "default" screen stays backed by the
  # legacy thankyou_* / forward_url columns (so the existing single thank-you is
  # unchanged); extra screens live in the end_screens JSON column.
  MAX_END_SCREENS = 12
  # 120, up from 80. The 80 was silent — no counter in the editor, no
  # validation, just `.first(80)` in update_settings — and it cut a real Verto's
  # end screen mid-sentence at exactly 80 characters ("HALF TIME Your voice is
  # in! You've played your half. Ours starts now. Sign up to"). The title is
  # display type that wraps and balances, and the card is 850px wide, so three
  # short lines of it fit; the editor now says how many are left as well.
  MAX_END_TITLE   = 120
  MAX_END_BODY    = 400
  MAX_END_LABEL   = 40
  DEFAULT_END_ID  = "default"

  def default_end_screen
    {
      "id" => DEFAULT_END_ID,
      "title" => thankyou_title_text,
      "body" => thankyou_body_text,
      "forward_url" => forward_url.presence,
      "forward_label" => forward_label.presence
    }
  end

  def extra_end_screens
    Array(read_attribute(:end_screens)).filter_map do |s|
      next unless s.is_a?(Hash) && s["id"].to_s.present? && s["id"].to_s != DEFAULT_END_ID
      {
        "id" => s["id"].to_s,
        "title" => s["title"].to_s.strip.presence || I18n.t("player.thank_you_title"),
        # No byline fallback: the byline is its own line on the screen now
        # (thankyou_from_text), so a branch screen with no message shows the
        # title and the byline rather than the byline twice.
        "body" => s["body"].to_s.strip,
        "forward_url" => s["forward_url"].presence,
        "forward_label" => s["forward_label"].to_s.strip.presence
      }
    end
  end

  # The full list: the built-in default first, then any extra branch screens.
  def end_screens_list
    [ default_end_screen ] + extra_end_screens
  end

  def end_screen(id)
    end_screens_list.find { |s| s["id"] == id.to_s } || default_end_screen
  end

  def end_screen_ids
    end_screens_list.map { |s| s["id"] }
  end

  # Coerce creator-submitted extra end screens into a safe, bounded array. The
  # "default" id is reserved for the built-in screen, so it's dropped here.
  def self.sanitize_end_screens(value)
    Array(value).filter_map do |entry|
      next unless entry.is_a?(Hash)
      id = entry["id"].to_s.strip.presence || "es_#{SecureRandom.hex(4)}"
      next if id == DEFAULT_END_ID
      title = entry["title"].to_s.strip.first(MAX_END_TITLE)
      body  = entry["body"].to_s.strip.first(MAX_END_BODY)
      fwd   = sanitize_forward_url(entry["forward_url"])
      next if title.blank? && body.blank? && fwd.blank?
      {
        "id" => id,
        "title" => title.presence,
        "body" => body.presence,
        "forward_url" => fwd,
        "forward_label" => entry["forward_label"].to_s.strip.first(MAX_END_LABEL).presence
      }.compact
    end.first(MAX_END_SCREENS)
  end

  # ── Flows (first-class named branches) ────────────────────────────────────
  # A flow is a named, coloured group of cards a routed answer can enter (e.g.
  # UK / UAE / USA regional question sets). Membership rides on each card as
  # `flow_id` (allowlisted in sanitize_cards_images!); this array holds only
  # the authoring metadata. FlowCompiler compiles membership + exit down to the
  # per-card `next` pointers the player already resolves, so play-time
  # semantics don't change. Flows supersede the flow map's older `lane_label`
  # (which remains as a read-only fallback for hand-wired decks).
  MAX_FLOWS      = 12
  MAX_FLOW_NAME  = MAX_LANE_LABEL
  # An opaque `f_`-prefixed token. Server/client mint hex, but any bounded
  # DOM/JSON-safe id is accepted (readable ids like "f_uk" are fine — cids
  # aren't format-constrained either, and the id never renders as copy).
  FLOW_ID_FORMAT = /\Af_[a-z0-9_-]{1,24}\z/i
  # Mirrors the flow map's LANE_PALETTE (logic_map_controller.js) so stored
  # flow colours match what the map already paints for derived lanes.
  FLOW_COLORS = %w[#8B85FF #01EACB #F59E0B #F472B6 #38BDF8 #A3E635].freeze

  def flows_list
    Array(read_attribute(:flows))
  end

  # UN SDG tags, derived by SdgClassifier at import/seed time (see UnSdgs).
  # Always an array; empty means "no goal clearly applies", not "untagged".
  def sdgs
    Array(read_attribute(:sdgs))
  end

  # Coerce creator-submitted flows into a safe, bounded array: opaque `f_` ids
  # (backfilled and de-duped like card cids), bounded plain-text name, a colour
  # from a fixed shape, and a single-key exit target or none. Same
  # allowlist-or-drop posture as sanitize_end_screens above.
  def self.sanitize_flows(value)
    seen = Set.new
    Array(value).each_with_index.filter_map do |entry, i|
      next unless entry.is_a?(Hash)
      id = entry["id"].to_s.strip
      id = nil unless id.match?(FLOW_ID_FORMAT)
      id = "f_#{SecureRandom.hex(4)}" while id.blank? || seen.include?(id)
      seen << id
      name  = entry["name"].to_s.strip.first(MAX_FLOW_NAME).presence || "Flow #{i + 1}"
      color = entry["color"].to_s.match?(/\A#\h{6}\z/) ? entry["color"] : FLOW_COLORS[i % FLOW_COLORS.size]
      out = { "id" => id, "name" => name, "color" => color }
      exit_target = FlowCompiler.valid_exit(entry["exit"])
      out["exit"] = exit_target if exit_target
      out
    end.first(MAX_FLOWS)
  end

  # Cross-field cleanup: a card can only claim membership of a flow that
  # exists. Needs both sides of the pair, so it can't live inside
  # sanitize_cards_images! (cards-only) or sanitize_flows (flows-only).
  # Mutates and returns `cards`.
  def self.reconcile_flows!(cards, flows)
    known = Array(flows).filter_map { |f| f["id"] if f.is_a?(Hash) }.to_set
    Array(cards).each do |c|
      c.delete("flow_id") if c.is_a?(Hash) && c.key?("flow_id") && !known.include?(c["flow_id"])
    end
    cards
  end

  # ── Consent ────────────────────────────────────────────────────────────────
  # Two shapes, one respondent-facing promise. The survey-level gate
  # (consent_text) renders as a bottom BANNER over the first question
  # (player/_consent_banner — it used to be a pseudo-card pinned before the
  # deck); a consent_gate CARD is an ordinary deck card that can span several
  # pages and be reordered. A Verto uses one or the other — never both, or a
  # respondent would be asked to agree twice.

  # The multi-page consent card, if the deck has one.
  def consent_gate_card
    Array(cards).find { |c| c.is_a?(Hash) && c["type"].to_s == "consent_gate" }
  end

  def consent_gate_card?
    consent_gate_card.present?
  end

  # The survey-level gate. False once a consent card is in the deck, so the
  # banner stops rendering rather than stacking a second gate on top of the
  # first — the card wins, being the more specific thing the creator built.
  def consent_required?
    consent_text.present? && !consent_gate_card?
  end

  # Whether this Verto asks a respondent for personal data. DemographicQuestions
  # appends birth month/year, location and gender to every Verto at creation, so
  # in practice this is true almost everywhere — which is exactly why consent
  # being optional was a compliance hole rather than an edge case (P0-6).
  def collects_personal_data?
    Array(cards).any? { |c| c.is_a?(Hash) && c["demographic"] }
  end

  # True when personal data is collected and the creator built no gate of either
  # kind. The player supplies a default gate in that case rather than letting the
  # collection happen ungated.
  #
  # Enforced at the player and not at publish, deliberately: a publish-time
  # requirement would leave every ALREADY-live Verto collecting birth dates and
  # locations with no gate at all, which is the actual exposure. This closes it
  # for those too, at the cost of respondents on a live Verto meeting a consent
  # screen they didn't see yesterday.
  def default_consent_gate?
    collects_personal_data? && consent_text.blank? && !consent_gate_card?
  end

  # Whether the player renders the survey-level consent banner over the first
  # question, from either the creator's own consent_text or the default above.
  def show_consent_gate?
    consent_required? || default_consent_gate?
  end

  # The wording the survey-level gate actually shows.
  def effective_consent_text
    return consent_text if consent_text.present?

    I18n.t("player.consent_default_text") if default_consent_gate?
  end

  # Whether a respondent has to agree before answering, by any route.
  def consent_gated?
    consent_required? || consent_gate_card? || default_consent_gate?
  end

  # What a response records as the text the respondent actually agreed to. For a
  # card gate that's its pages joined in order, so the snapshot stays a faithful
  # record of what was on screen even if the card is edited later. For the
  # default gate it's the default wording, so the audit trail records what the
  # respondent was actually shown rather than a blank.
  def consent_snapshot_text
    card = consent_gate_card
    return effective_consent_text if card.nil?

    Array(card["pages"]).filter_map { |p| p["text"].presence if p.is_a?(Hash) }.join("\n\n").presence
  end

  # How the player presents this Verto. "cards" is the default immersive,
  # animated experience; "form" keeps the same one-question-at-a-time flow but
  # strips the swipe gestures and game-like animation so it reads as a plain
  # questionnaire (see the .forms-mode CSS layer and the player root class).
  RENDER_MODES = %w[cards form].freeze

  def self.normalize_render_mode(value)
    RENDER_MODES.include?(value.to_s) ? value.to_s : "cards"
  end

  # The audience's country as an ISO 3166-1 alpha-2 code, or nil for "not set".
  # Allowlist-or-nil against WorldRegions rather than a CHECK constraint: the
  # value set is 249 rows that already live in Ruby, and "not set" is a normal
  # state rather than an error, so an unknown code degrades to the global
  # heritage taxonomy instead of failing a save.
  def self.normalize_audience_country(value)
    code = value.to_s.strip.upcase.presence
    code if code && WorldRegions.valid?(code)
  end

  # Belt-and-braces behind normalize_audience_country: the column has no CHECK
  # (249 ISO codes is not a readable constraint, and region_country — same
  # registry, same shape — has none either), so the model is where a bad code
  # has to surface. allow_nil because "no country" is a real state, not a gap.
  validates :audience_country, inclusion: { in: WorldRegions::COUNTRIES.keys }, allow_nil: true

  def audience_country_name
    WorldRegions.name_for(audience_country) if audience_country.present?
  end

  def forms_mode?
    render_mode == "form"
  end

  # What a retake does to a player's leaderboard score. A string enum per the
  # render_mode precedent, normalized on write (update_settings) and CHECK-
  # constrained in the database, so an unknown value can't arrive silently.
  #
  #   accumulate — retakes add to the total (the default: the most game-like
  #                reading of "play again", and the least surprising).
  #   no_redo    — the FIRST completed run counts; later runs are stored as
  #                answers but never move the board.
  #   restart    — the latest completed run counts.
  #
  # Scoring only. Whether a retake is allowed at all is `no_retests` (one
  # completed run per person per wave) and whether an answer can be changed
  # mid-run is `no_going_back` — both independent of the board, and the
  # player no longer reads this policy.
  LEADERBOARD_RETAKE_POLICIES = %w[accumulate no_redo restart].freeze

  # The column carries a database CHECK (P2-8), and the coverage rule in
  # enum_constraints_test is that a constrained column also declares its values
  # in the model — a bad value should surface as a validation error, not a raw
  # database exception.
  validates :leaderboard_retake_policy, inclusion: { in: LEADERBOARD_RETAKE_POLICIES }

  # How this Verto's held free text is decided (Moderation::MODES). A DB CHECK
  # backs it, like every other closed set on this table.
  validates :moderation_mode, inclusion: { in: Moderation::MODES }

  # What the board RANKS BY: "all" — one total across every token type, the
  # original board — or one of this Verto's token type ids, when the types are
  # different currencies (CO2 saved, lives) whose sum means nothing. Every row
  # still shows each type's total; this only decides the order. No CHECK
  # constraint, deliberately: the values are creator-defined ids, so the model
  # normalises instead and an unknown or removed id falls back to "all". Locked
  # once live (SETTINGS_LOCKED_IN_USE) for the policy's reason — changing the
  # basis re-ranks standings respondents have already been shown.
  before_validation :coerce_leaderboard_rank_by
  validates :leaderboard_rank_by, presence: true

  def self.normalize_leaderboard_rank_by(value, type_ids)
    value = value.to_s
    Array(type_ids).include?(value) ? value : "all"
  end

  def coerce_leaderboard_rank_by
    self.leaderboard_rank_by = Survey.normalize_leaderboard_rank_by(leaderboard_rank_by, token_type_ids)
  end

  def leaderboard_ranks_by_type? = leaderboard_rank_by != "all"

  # The token type the board ranks by, or nil under "all".
  def leaderboard_rank_type
    Array(token_types).find { |t| t["id"] == leaderboard_rank_by }
  end

  # THE GDPR WALL, scoped to where it bites (owner's call, 2026-08-24): a
  # contact form may sit alongside age, location, gender and heritage, but
  # never the NEURODIVERSITY question — health-adjacent special-category data
  # next to a name and an email is the adjacency nobody here wants to hold.
  # Enforced at the data layer so every path in — the settings toggle, the
  # card autosave, the add-question modal's Demographics tiles, an import —
  # hits the same wall, whichever side moved second. The message is
  # creator-facing: surveys#update relays RecordInvalid text.
  # The join prompt collects an email at the end of the Verto, which is a
  # contact form by any reading — so it sits behind the same wall. Without
  # this, the block would have been a second door into exactly the pairing
  # this validation exists to refuse: a name and an email beside a
  # health-adjacent special-category answer.
  validate :contact_form_excludes_neurodiversity, if: -> { contact_form_enabled? || join_prompt_enabled? }

  def contact_form_excludes_neurodiversity
    return unless neurodiversity_cards?

    collector = contact_form_enabled? ? "collect contact details" : "ask respondents to create an account"
    errors.add(:base, "A Verto can #{collector} or ask the neurodiversity question, never both — " \
                      "remove the neurodiversity question, or turn that off.")
  end

  def neurodiversity_cards?
    Array(cards).any? { |c| DemographicQuestions.key_for(c) == "neurodiversity" }
  end

  def self.normalize_leaderboard_retake_policy(value)
    LEADERBOARD_RETAKE_POLICIES.include?(value.to_s) ? value.to_s : "accumulate"
  end

  # The board only ranks token totals, so without tokenisation there is
  # nothing to rank — leaderboard_enabled alone is inert (the flag survives a
  # pre-live tokenisation switch-off, but nothing renders or records).
  def leaderboard_active?
    tokenisation_enabled? && leaderboard_enabled?
  end

  # Whether the player should mint/record the durable per-device identity
  # (player_key → per-survey digest). The leaderboard needs it for its alias;
  # the contact gate needs it because the digest is the ONLY bridge between a
  # contact row and the pseudonymous responses; ask-once questions need it
  # because "asked once" is a promise made to an identity, and each run's
  # response carries the remembered answer under that identity's digest.
  # No retests on a Verto that collects no respondent code needs it too: the
  # device is then the only identity it can check.
  def player_identity_active?
    leaderboard_active? || contact_form_enabled? || ask_once_cards? || retest_basis == "device"
  end

  # Any question the creator marked "ask once per person" — skipped on repeat
  # plays once the identity has answered it (the player seeds the remembered
  # answer into each new run, so every response row stays complete).
  def ask_once_cards?
    Array(cards).any? { |c| c.is_a?(Hash) && c["ask_once"] }
  end

  # Any card in the deck flagged as a demographic question — the auto-appended
  # birth/location/gender tail and the opt-in heritage/neurodiversity cards
  # all carry "demographic" => true (DemographicQuestions).
  def demographic_cards?
    Array(cards).any? { |c| c.is_a?(Hash) && c["demographic"] }
  end

  def leaderboard_no_redo?
    leaderboard_retake_policy == "no_redo"
  end

  # Coerce a creator-entered website into a safe http(s) URL for the
  # forward-to-website CTA on the thank-you screen. Adds a scheme when missing;
  # returns nil for blank or non-http(s) input so the CTA simply doesn't show.
  def self.sanitize_forward_url(value)
    v = value.to_s.strip
    return nil if v.blank?
    v = "https://#{v}" unless v.match?(%r{\Ahttps?://}i)
    uri = URI.parse(v)
    (uri.is_a?(URI::HTTP) && uri.host.present?) ? v : nil
  rescue URI::InvalidURIError
    nil
  end

  def slug?
    slug.present?
  end

  # Coerce creator input into a URL-safe slug for the optional vanity
  # /play/:slug link — lowercase, non-alphanumeric runs collapsed to a single
  # hyphen, leading/trailing hyphens trimmed, capped so the URL stays
  # reasonable. Blank input (or input with no alphanumerics) returns nil,
  # same "blank clears the setting" convention as consent_text.
  MAX_SLUG_LENGTH = 60
  def self.normalize_slug(value)
    slug = value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
    slug.first(MAX_SLUG_LENGTH).delete_suffix("-").presence
  end

  # True when `value` is already in use anywhere in the /play/:token
  # namespace — a Verto's slug or publish_token, a partner share token, or a
  # share link's slug — so nothing a creator chooses can make
  # PlayerController#load_survey_and_share resolve ambiguously. Each excluding_
  # argument spares the record doing the asking from colliding with itself.
  def self.play_key_taken?(value, excluding_survey_id: nil, excluding_link_id: nil)
    return false if value.blank?
    Survey.where.not(id: excluding_survey_id).exists?(slug: value) ||
      Survey.where.not(id: excluding_survey_id).exists?(publish_token: value) ||
      SurveyShare.exists?(share_token: value) ||
      SurveyLink.where.not(id: excluding_link_id).exists?(slug: value)
  end

  # The Verto's own custom-link form asks the same question about itself.
  def self.slug_taken?(value, excluding_id: nil)
    play_key_taken?(value, excluding_survey_id: excluding_id)
  end

  # A "responder" is anyone who answered at least one question (not just those
  # who submitted). Counted in SQL off the denormalised `answered` flag, so this
  # never loads response rows / answers JSON (the dashboard computes these once
  # as grouped counts; this is the cheap single-survey fallback).
  def responders_count
    responses.where(answered: true).count
  end

  # Of the responders, the percentage who completed (submitted) the Verto.
  # nil when there are no responders yet.
  def completion_rate
    total = responders_count
    return nil if total.zero?
    (responses.where(answered: true, status: "completed").count * 100.0 / total).round
  end

  private

  def enforce_range_scale
    self.cards = self.class.normalize_range_cards!(
      cards, fill: self.class.localized_range_labels(default_locale)
    )
  end

  def hoist_option_label_emoji
    self.cards = self.class.hoist_option_label_emoji!(cards)
  end

  # Move an option label's leading/trailing emoji into that option's icon tile,
  # by promoting it to `option_styles[i]["emoji"]` — the slot every render path
  # (option_tile_icon, choice_templates.js, both repaint paths) already draws
  # inside the tile. Generated decks routinely write "🎯 Pay off debt", which
  # showed the emoji beside the words while the tile keyword-matched a
  # different icon entirely.
  #
  # Doing it here rather than at render time is what keeps it simple: once the
  # emoji IS an option style, nothing downstream needs to know — it renders,
  # serializes and round-trips like any 🎨-picked icon, and a creator can change
  # or clear it the same way.
  #
  # An option label is an ANSWER KEY (`correct`, `tokens` and logic
  # `match.value` all reference it by string), so:
  #   • published Vertos are skipped entirely — their labels are the key for
  #     responses already collected, exactly the reasoning enforce_range_scale
  #     documents above;
  #   • every label-keyed field on the card is rewritten in the same pass;
  #   • an option that already carries an explicit icon or emoji is left ALONE,
  #     label included. That pick wins the tile, so hoisting would mean deleting
  #     an emoji with nowhere to put it — and it makes the transform converge
  #     after one pass instead of nibbling a second emoji off on the next save.
  def self.hoist_option_label_emoji!(list)
    Array(list).map do |card|
      next card unless card.is_a?(Hash) && OPTION_STYLE_TYPES.include?(card["type"].to_s)

      options = Array(card["options"])
      next card if options.empty?

      options = options.dup
      styles  = Array(card["option_styles"]).dup
      html    = Array(card["options_html"]).dup
      renamed = {}

      options.each_with_index do |label, i|
        style = styles[i].is_a?(Hash) ? styles[i] : nil
        next if style && (style["icon"].to_s.present? || style["emoji"].to_s.present?)

        glyphs, text = LabelEmoji.split(label)
        next unless glyphs && text.present? && text != label.to_s

        options[i] = text
        renamed[label.to_s] = text
        styles[i] = (style || {}).merge("emoji" => glyphs.first(MAX_TOKEN_ICON))
        # Keep the rich-text twin in step, or Survey#sanitize's equivalence
        # check drops the whole formatting layer for this option.
        html[i] = html[i].sub(glyphs, "") if html[i].is_a?(String) && html[i].include?(glyphs)
      end

      next card if renamed.empty?

      out = card.merge("options" => options, "option_styles" => styles)
      out["options_html"] = html if card.key?("options_html")
      rename_option_key_references!(out, renamed)
      out
    end
  end

  # The three places a card refers to an option BY ITS LABEL. Missing one would
  # silently unset a quiz answer, strand a branch, or drop a token award.
  def self.rename_option_key_references!(card, renamed)
    case card["correct"]
    when String then card["correct"] = renamed.fetch(card["correct"], card["correct"])
    when Array  then card["correct"] = card["correct"].map { |v| v.is_a?(String) ? renamed.fetch(v, v) : v }
    end

    if card["tokens"].is_a?(Hash)
      card["tokens"] = card["tokens"].transform_keys { |k| renamed.fetch(k.to_s, k) }
    end

    if card["logic"].is_a?(Hash)
      Array(card["logic"]["routes"]).each do |route|
        match = route.is_a?(Hash) ? route["match"] : nil
        next unless match.is_a?(Hash) && match["value"].is_a?(String)
        match["value"] = renamed.fetch(match["value"], match["value"])
      end
    end
    card
  end

  # Replace any inline base64 image about to be written with a stored blob path.
  #
  # Deliberately forgiving: a conversion that fails leaves the data-URL alone,
  # exactly as the upload path and the backfill already do. A fat image beats a
  # broken one, and this must never be the reason a creator's save is refused.
  # Only the attributes actually being written, so an unrelated save never walks
  # a whole deck looking for images.
  def externalize_inline_images
    attributes = []
    attributes << :cards if will_save_change_to_cards?
    attributes += %i[background_image consent_image].select { |a| will_save_change_to_attribute?(a) }
    externalize_images_in(attributes)
  end

  # On create there's no id yet, so a blob can't be attached and the data-URL
  # rides through. Converting straight after means the base64 is in the column
  # for one write rather than indefinitely — the create path is the rare one
  # (a duplicate of a not-yet-converted deck), so paying an extra UPDATE there
  # is the right trade for never having to special-case it elsewhere.
  def externalize_inline_images_after_create
    updates = externalize_images_in(%i[cards background_image consent_image])
    update_columns(updates) if updates.any?
  end

  # Converts in place and returns { attribute => new_value } for whatever moved.
  def externalize_images_in(attributes)
    updates = {}

    if attributes.include?(:cards)
      converted = externalized_cards
      if converted
        self.cards = converted
        updates[:cards] = converted
      end
    end

    (attributes & %i[background_image consent_image]).each do |attribute|
      path = externalized_image_path(read_attribute(attribute))
      next unless path

      write_attribute(attribute, path)
      updates[attribute] = path
    end

    updates
  end

  # The deck with every inline image replaced by a stored path, or nil when
  # there was nothing to convert.
  def externalized_cards
    touched = false

    converted = Array(cards).map do |card|
      next card unless card.is_a?(Hash)

      c = card
      if (path = externalized_image_path(c["image"]))
        c = c.merge("image" => path)
        touched = true
      end

      images = Array(c["option_images"])
      if images.any? { |value| Survey::CardImageStore.data_url?(value) }
        c = c.merge("option_images" => images.map { |value| externalized_image_path(value) || value })
        touched = true
      end

      c
    end

    touched ? converted : nil
  end

  # The stored path for an inline image, or nil when there's nothing to do (it's
  # already a path, blank, or the conversion failed).
  def externalized_image_path(value)
    return nil unless Survey::CardImageStore.data_url?(value)

    # A blob has to belong to a persisted record. On create the row doesn't exist
    # yet, so the data-URL rides through this save and is converted on the next
    # one — or by the backfill task, whichever comes first.
    return nil unless persisted?

    blob = Survey::CardImageStore.attach(self, value)
    return nil unless blob

    Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
  rescue => e
    ErrorReporting.report("Survey#externalize_inline_images", e, survey_id: id)
    nil
  end

  # Per-survey HMAC key, from Rails' own key generator — tied to
  # secret_key_base, so it needs no column of its own and rotating the secret
  # invalidates every digest at once (which is the correct behaviour: they were
  # only ever comparable to each other).
  def respondent_code_key
    Rails.application.key_generator.generate_key("respondent_code/survey/#{id}", 32)
  end

  def player_key_hmac_key
    Rails.application.key_generator.generate_key("player_key/survey/#{id}", 32)
  end
end
