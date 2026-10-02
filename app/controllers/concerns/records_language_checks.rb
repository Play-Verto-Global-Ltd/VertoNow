# The four things that can happen to a line on the Language check screen —
# approve it, ask for changes, rewrite it, comment on it.
#
# Shared by the owner's screen and the public reviewer link because they are
# genuinely the same actions: the creator reading their own Spanish and the
# Spanish speaker they sent the link to do exactly the same work, and a
# feature where the creator's approval means something different from the
# reviewer's would be a worse feature, not a safer one. What differs is who is
# recorded (`review_actor`) and what they are allowed to reach (`review_scope`),
# and each controller answers those two for itself.
module RecordsLanguageChecks
  extend ActiveSupport::Concern

  # Approve / ask for changes. The digest of the words being ruled on is
  # computed HERE from the deck, never taken from the request: a client that
  # chose its own digest could approve one wording and store the fingerprint of
  # another, and the stale badge — the whole mechanism that stops an approval
  # outliving the text it was given to — would be the thing it defeated.
  def record_language_decision(survey, cid:, locale:, status:)
    return :unknown_line unless review_scope(survey).include?(locale)
    content = line_content(survey, cid, locale)
    return :unknown_line if content.nil?

    actor = review_actor
    row   = LanguageCheck.for_line(survey, cid, locale)

    if status == "pending"
      # Taking a decision back, not making one. The fingerprints and the
      # attribution go with it: a row left carrying "approved by Marta" under a
      # pending status is a record of something that is no longer true, and it
      # would resurface as a stale badge the moment the text next changed.
      row.assign_attributes(status: "pending", content_digest: nil, source_digest: nil,
                            reviewed_at: nil, reviewed_by_name: nil, reviewed_by_user: nil)
    else
      row.assign_attributes(
        status:            status,
        content_digest:    LanguageCheckLines.digest(content),
        source_digest:     source_digest_for(survey, cid, locale),
        reviewed_at:       Time.current,
        reviewed_by_name:  actor[:name],
        reviewed_by_user:  actor[:user],
        language_check_link: actor[:link]
      )
    end
    row.save!
    :ok
  end

  # Rewrite one line. The edit lands in the deck itself (Survey#
  # apply_language_edit!) — there is no pending-suggestion state — so the
  # reviewer's fix is what the next respondent reads.
  #
  # A line edited by its own reviewer is NOT auto-approved. Writing better
  # Spanish and vouching for it are two acts, and collapsing them would mean
  # nobody ever reads the new text; the row is left where it is and the screen
  # shows it as edited-since-approved if it had a tick.
  def record_language_edit(survey, cid:, locale:, fields:)
    return :unknown_line unless review_scope(survey).include?(locale)
    return :forbidden unless review_may_edit?
    return :unknown_line if line_content(survey, cid, locale).nil?

    changed = survey.apply_language_edit!(cid: cid, locale: locale, fields: fields)
    return :unchanged unless changed

    actor = review_actor
    row   = LanguageCheck.for_line(survey, cid, locale)
    row.assign_attributes(
      edited_at:      Time.current,
      edited_by_name: actor[:name],
      # The revision this edit landed at, so SurveysController#update knows
      # which lines an older editor tab has not seen. Read back from the model,
      # which has just incremented it.
      edit_revision:  survey.translations_revision,
      language_check_link: row.language_check_link || actor[:link]
    )
    # Somebody rewriting the Spanish did it reading today's English, so the
    # line is current again — unless what they left has no Spanish in it at
    # all, which is not a translation of anything.
    if locale.to_s != survey.default_locale
      content = line_content(survey, cid, locale)
      row.translated_from_digest = source_digest_for(survey, cid, locale) unless
        content.nil? || LanguageCheckLines.untranslated?(content)
    end
    row.save!
    :ok
  end

  # What a card MEANS, in its author's words — sent to the translator with the
  # card and shown on every line of it. Kept on the primary line's row: the
  # note is about the original, and there is exactly one of those per card.
  # Blank clears it.
  def record_translator_note(survey, cid:, body:)
    return :unknown_line if line_content(survey, cid, survey.default_locale).nil?

    row = LanguageCheck.for_line(survey, cid, survey.default_locale)
    row.translator_note = body.to_s.strip.gsub(/\r\n?/, "\n").first(LanguageCheck::MAX_TRANSLATOR_NOTE).presence
    return :unchanged if row.new_record? && row.translator_note.nil?
    row.save!
    :ok
  end

  def record_language_note(survey, cid:, locale:, body:)
    return :unknown_line unless review_scope(survey).include?(locale)
    return :unknown_line if line_content(survey, cid, locale).nil?

    body = body.to_s.strip.first(LanguageCheckNote::MAX_BODY)
    return :unchanged if body.blank?

    actor = review_actor
    survey.language_check_notes.create!(
      cid: cid.to_s, locale: locale.to_s, body: body,
      author_name: actor[:name], author_user: actor[:user],
      language_check_link: actor[:link]
    )
    :ok
  end

  private

  # The words on one line right now, or nil when the request names a card or a
  # language this Verto does not have — a stale tab, or a crafted parameter.
  # Either way the answer is the same and says nothing about which it was.
  def line_content(survey, cid, locale)
    card = Array(survey.cards).find { |c| c.is_a?(Hash) && c["cid"].to_s == cid.to_s }
    return nil if card.nil?

    canonical = LanguageCheckLines.canonical_content(card)
    return nil if canonical.values.all?(&:blank?)

    locale.to_s == survey.default_locale ?
      canonical :
      LanguageCheckLines.translated_content(card, locale, canonical)
  end

  # The fingerprint of the primary language this line is a translation OF.
  # Nil for the primary line itself, which has no source above it.
  def source_digest_for(survey, cid, locale)
    return nil if locale.to_s == survey.default_locale
    canonical = line_content(survey, cid, survey.default_locale)
    canonical && LanguageCheckLines.digest(canonical)
  end

  # A typed name, bounded and stripped of anything that is not a name. Nobody
  # holding a review link has an account, so this is a courtesy label rather
  # than an identity, and it is treated as such: never trusted, never used to
  # authorise anything, and rendered as plain text.
  def sanitize_reviewer_name(value)
    value.to_s.strip.gsub(/[[:cntrl:]]/, "").first(LanguageCheck::MAX_NAME).presence
  end
end
