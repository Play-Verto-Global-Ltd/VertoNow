require "digest"

# Turns a Verto's deck into the rows the Language check screen reviews: one
# LINE per (card, language), carrying the words a speaker of that language
# actually reads.
#
# The screen's whole proposition is that a reviewer sees one question's wording
# in every language at once — primary first, then the secondaries — so the unit
# of review is the line, not the card and not the field. A reviewer who can
# read Spanish approves the Spanish line; they have no opinion about the French
# one and are never asked for it.
#
# Where the words live is not uniform, which is the reason this exists rather
# than each view digging into the card hash itself:
#
#   * the PRIMARY language's words are the card's canonical fields
#     (card["text"], card["options"], …) — there is no i18n entry for it
#   * every SECONDARY language's words are card["i18n"][locale], and any field
#     missing there falls back to the canonical text, because that is exactly
#     what the player renders for it (see Survey.merge_card_translations and
#     the player's own fallback). A line showing blanks where the player shows
#     English would have the reviewer approve something nobody will ever see.
#
# FIELDS is the contract, and it is the same list SurveyTranslator writes and
# Survey.swap_card_primary moves: text, description, options, pages,
# explanation, the NPS anchor lines, responses. A field translated anywhere in the app but missing
# here is a line a reviewer is never shown and therefore never checks — so the
# list is asserted against the translator's own tool schema in the tests rather
# than left to drift.
module LanguageCheckLines
  module_function

  # Card types that carry no respondent-facing wording of their own worth
  # reviewing in isolation. contact_form and respondent_code render chrome the
  # PLATFORM translates (config/locales), not deck text, and a welcome card's
  # title is the Verto's own title, reviewed once at the top of the screen.
  SKIPPED_TYPES = %w[].freeze

  # Ordered so the screen reads the way a card does: the intro modal a
  # respondent meets FIRST, then the question, its sub-text, the answers, then
  # the extras only some types carry.
  SCALAR_FIELDS = %w[modal_title modal_body text description explanation nps_low_label nps_high_label].freeze
  LIST_FIELDS   = %w[options responses].freeze
  PAGE_FIELD    = "pages".freeze
  FIELDS        = (SCALAR_FIELDS + LIST_FIELDS + [ PAGE_FIELD ]).freeze

  # [{ cid:, index:, type:, primary_text:, lines: [{ locale:, primary:, content: {...} }] }]
  # in deck order, one entry per card that has any reviewable words at all.
  def for(survey)
    locales = survey.verto_locales
    primary = survey.default_locale

    Array(survey.cards).each_with_index.filter_map do |card, index|
      next unless card.is_a?(Hash)
      next if SKIPPED_TYPES.include?(card["type"].to_s)

      canonical = canonical_content(card)
      next if canonical.values.all?(&:blank?)

      {
        cid:     card["cid"].to_s,
        index:   index,
        type:    card["type"].to_s,
        lines:   locales.map do |locale|
          {
            locale:  locale,
            primary: locale == primary,
            content: locale == primary ? canonical : translated_content(card, locale, canonical)
          }
        end
      }
    end
  end

  # The canonical (primary-language) words on a card, normalised to the shape
  # every line uses. Blank fields are kept as empty values rather than dropped
  # so a translated line can be compared field-for-field against it.
  def canonical_content(card)
    # The scalars are read OFF SCALAR_FIELDS rather than listed again. They
    # were listed, and the list went stale the first time the constant grew:
    # a field in SCALAR_FIELDS but not here has no canonical value, so
    # translated_content can never fall back to it and the reviewer is shown a
    # blank where the player shows the primary wording.
    SCALAR_FIELDS.index_with { |field| card[field].to_s }.merge(
      "options"     => Array(card["options"]).map(&:to_s),
      "responses"   => Array(card["responses"]).filter_map { |r| r["label"].to_s if r.is_a?(Hash) },
      "pages"       => Array(card["pages"]).filter_map do |p|
        { "id" => p["id"].to_s, "text" => p["text"].to_s } if p.is_a?(Hash) && p["id"].present?
      end
    )
  end

  # One secondary language's words, with the player's own fallback applied:
  # anything this language has not been given reads in the primary language,
  # here and in the player alike.
  #
  # `fallback` (per field) is returned alongside so the screen can mark a line
  # as untranslated rather than quietly showing English under a Spanish flag —
  # the single most misleading thing this page could do.
  def translated_content(card, locale, canonical)
    entry = card.dig("i18n", locale.to_s)
    entry = {} unless entry.is_a?(Hash)

    content = {}
    fell_back = []

    SCALAR_FIELDS.each do |field|
      value = entry[field].to_s
      if value.blank? && canonical[field].present?
        content[field] = canonical[field]
        fell_back << field
      else
        content[field] = value
      end
    end

    LIST_FIELDS.each do |field|
      source = canonical[field]
      given  = Array(entry[field]).map(&:to_s)
      # Positional, and only as long as the canonical list — the alignment
      # invariant SurveyTranslator guarantees and stored answers depend on.
      # A slot with nothing in it reads in the primary language.
      content[field] = source.each_with_index.map do |canon, i|
        translated = given[i].to_s
        if translated.blank?
          fell_back << field
          canon
        else
          translated
        end
      end
    end

    by_id = Array(entry[PAGE_FIELD]).each_with_object({}) do |p, h|
      h[p["id"].to_s] = p["text"].to_s if p.is_a?(Hash)
    end
    content[PAGE_FIELD] = canonical[PAGE_FIELD].map do |page|
      text = by_id[page["id"]].to_s
      if text.blank?
        fell_back << PAGE_FIELD
        page
      else
        { "id" => page["id"], "text" => text }
      end
    end

    content.merge("untranslated" => fell_back.uniq)
  end

  # A stable hash of the words on one line. This is what an approval is
  # actually an approval OF: store it when someone approves, compare it when
  # the screen renders, and a line whose wording has moved since reads
  # "Approved, then edited" instead of carrying a tick it no longer earned.
  #
  # `untranslated` is excluded deliberately — it is a derived annotation about
  # where the words came from, not the words themselves, and including it would
  # lapse every approval on a line the moment an unrelated field was filled in.
  # The NPS captions are left out when blank, and ONLY them. Every card of
  # every type carries a key for every SCALAR_FIELD (canonical_content builds
  # them off the list), so adding two to that list gave every line in the
  # product two empty strings and moved its hash — and every approval anyone
  # had ever given would have read "Approved, then edited" on a line whose
  # words had not changed.
  #
  # Narrow on purpose, and measured: dropping EVERY blank looks tidier and does
  # the same damage, because a card with no sub-text or no quiz explanation has
  # always hashed those as "" and would move too. Rejecting just the new keys
  # reproduces the pre-captions hash byte for byte (they were appended to
  # SCALAR_FIELDS, so the remaining key order is unchanged), which is what
  # keeps existing approvals standing. A caption a creator has actually written
  # is a word on the line and belongs in the hash, so it stays in.
  def digest(content)
    canonical = content.except("untranslated")
                       .reject { |k, v| Survey::NPS_ANCHOR_KEYS.include?(k) && v.blank? }
    Digest::SHA256.hexdigest(canonical.to_json)
  end

  # The provenance to record after a translation pass wrote these cards:
  # [[cid, locale, digest of the original], ...] for every line in `locales`
  # that now has words of its own. See LanguageCheck.record_translated!.
  def translated_pairs(cards, locales)
    Array(cards).flat_map do |card|
      next [] unless card.is_a?(Hash) && card["cid"].present?
      canonical = canonical_content(card)
      next [] if canonical.values.all?(&:blank?)

      source = digest(canonical)
      Array(locales).filter_map do |locale|
        next if untranslated?(translated_content(card, locale, canonical))
        [ card["cid"].to_s, locale.to_s, source ]
      end
    end
  end

  # The same, for an editor autosave: only the translations whose WORDS this
  # save changed. Somebody who rewrote the German in the editor did it reading
  # today's English, so that line is current again; a German line merely sent
  # back as it was keeps whatever provenance it had, which is how a rewritten
  # English question leaves its translations behind.
  #
  # Both sides are read against the NEW original, so a slot the editor filled
  # with the primary label (it does that for an untranslated option) compares
  # equal to the fallback it replaced rather than counting as a translation.
  def changed_translation_pairs(existing, incoming, primary)
    by_cid = Array(existing).each_with_object({}) do |c, h|
      h[c["cid"].to_s] = c if c.is_a?(Hash) && c["cid"].present?
    end

    Array(incoming).flat_map do |card|
      next [] unless card.is_a?(Hash) && card["cid"].present? && card["i18n"].is_a?(Hash)
      canonical = canonical_content(card)
      next [] if canonical.values.all?(&:blank?)

      stored = by_cid[card["cid"].to_s]
      source = digest(canonical)
      (card["i18n"].keys.map(&:to_s) - [ primary.to_s ]).filter_map do |locale|
        now = translated_content(card, locale, canonical)
        next if untranslated?(now)
        next if stored && digest(translated_content(stored, locale, canonical)) == digest(now)
        [ card["cid"].to_s, locale, source ]
      end
    end
  end

  # { locale => [cid, ...] } for every translated line whose original has been
  # rewritten since it was translated (LanguageCheck#outdated_for?). A line
  # with no words of its own is left out — it is untranslated, which the
  # screen already says, not out of date. `include_edited: false` also leaves
  # out lines a reviewer rewrote on the Language check screen: that is what a
  # bulk Re-translate must not overwrite.
  def outdated(cards_rows, checks, include_edited: true)
    out = Hash.new { |h, k| h[k] = [] }
    cards_rows.each do |card|
      source = card[:lines].find { |l| l[:primary] }
      next unless source
      source_digest = digest(source[:content])
      card[:lines].each do |line|
        next if line[:primary] || untranslated?(line[:content])
        row = checks[[ card[:cid], line[:locale] ]]
        next unless row&.outdated_for?(source_digest)
        next if !include_edited && row.edited_at.present?
        out[line[:locale]] << card[:cid]
      end
    end
    out
  end

  # True when this line has no words of its own at all — every field fell back
  # to the primary language. Shown as "Not translated" rather than as text a
  # reviewer might take for a translation.
  def untranslated?(content)
    Array(content["untranslated"]).sort == present_fields(content).sort
  end

  # The fields this line actually has something in, so the view renders three
  # rows for a card with three fields rather than six with half of them blank.
  def present_fields(content)
    FIELDS.select { |f| content[f].present? }
  end

  # How far each language has got, for the sidebar: { locale => { total:,
  # translated: } } over the same rows the board draws.
  #
  # Counted from the DECK rather than from a job record, because the deck is
  # what a reviewer will actually read. A language whose translation job failed,
  # was discarded, or half-finished shows here as what it is — partly done —
  # instead of as "translated" on the strength of a job that reported success.
  def coverage(cards_rows, locales, primary)
    locales.index_with do |locale|
      rows = cards_rows.filter_map { |c| c[:lines].find { |l| l[:locale] == locale } }
      translated = rows.count { |line| line[:primary] || !untranslated?(line[:content]) }
      { total: rows.size, translated: translated, primary: locale == primary }
    end
  end

  # Where every language stands, in the one shape both the rail and the status
  # endpoint report. They used to work this out separately and could therefore
  # disagree — the rail deciding whether to poll from run rows, the endpoint
  # answering the poll from the same rows, and neither of them looking at the
  # deck. Coverage is the deck, which is the thing a reviewer actually reads.
  def poll_state(coverage, runs, locales, primary)
    locales.map do |locale|
      cov  = coverage[locale] || { total: 0, translated: 0 }
      done = cov[:total].to_i.positive? && cov[:translated] == cov[:total]
      run   = runs[locale]&.display_status
      # A run that finished is not a deck that is translated: an editor tab
      # opened before the language was added used to autosave its lines away
      # afterwards, and the rail went on reading "Translated" off the run while
      # every card showed the original wording. The deck has the last word:
      # "incomplete" shows the count and a Try again, and — like "failed" —
      # is not worth polling for, because nothing is on its way.
      run   = "incomplete" if run == "done"
      # Work in flight outranks coverage: re-translating out-of-date lines
      # happens to a language that is already fully covered, and reading
      # "Translated" there would leave the page with nothing to wait for and
      # the new words arriving behind a screen that never reloads.
      state = if locale == primary then "primary"
      elsif %w[queued running].include?(run) then run
      elsif done            then "done"
      else run || "none"
      end
      { locale: locale, state: state, translated: cov[:translated].to_i, total: cov[:total].to_i }
    end
  end

  # Is anything still expected to land? Deliberately counts a language with NO
  # run row at all ("none") as outstanding. Most translation paths never write
  # one — VertoGeneration.translate_survey! and translate_cards! cover creation,
  # import, generating a card, optimising one and adding a question — and those
  # are exactly the cases that used to leave a creator staring at "Not
  # translated yet" until they thought to reload. A recorded failure is the one
  # thing that stops the asking: it has a Try again button of its own.
  def outstanding?(rows)
    rows.any? { |r| r[:total].positive? && !%w[primary done failed incomplete].include?(r[:state]) }
  end

  # What has to change before the page is worth reloading. States only: a count
  # ticking up is repainted in place, and reloading on it would throw away
  # whatever the creator was in the middle of doing on the board.
  def poll_signature(rows)
    rows.map { |r| "#{r[:locale]}:#{r[:state]}" }.join(",")
  end
end
