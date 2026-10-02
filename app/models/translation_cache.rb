require "digest"

# Lookup table for SurveyTranslator. Avoids re-billing Claude when the same
# source card content is translated to the same target locale again — e.g.
# a small edit elsewhere triggers a full-survey re-translate, or two Vertos
# happen to share an identical question.
#
# Cache key: SHA256 of the canonical source content + source locale + target.
# Cache value: the translated card-shape hash { "text", "description", "options" }.
class TranslationCache < ApplicationRecord
  self.table_name = "translation_cache"

  validates :source_hash, :source_locale, :target_locale, presence: true

  # Stable hash of the fields SurveyTranslator actually translates. Same
  # source string + same options array (case- and whitespace-sensitive) →
  # same hash → cache hit.
  #
  # Every translated field must be in here. When `pages`/`explanation` were
  # added to the translator, omitting them would have kept serving pre-existing
  # cache entries that predate those fields — the new translations would appear
  # to do nothing on exactly the Vertos that already had translations, which is
  # the hardest version of this bug to spot. Including them changes the hash for
  # cards that carry them, so those miss once and re-translate; ordinary cards
  # keep hashing identically and their cache stays warm.
  def self.source_hash_for(card)
    canonical = {
      "text"        => card["text"].to_s,
      "description" => card["description"].to_s,
      "options"     => Array(card["options"]).map(&:to_s)
    }
    pages = Array(card["pages"]).filter_map do |p|
      { "id" => p["id"].to_s, "text" => p["text"].to_s } if p.is_a?(Hash) && p["id"].present?
    end
    canonical["pages"]       = pages if pages.any?
    canonical["explanation"] = card["explanation"].to_s if card["explanation"].present?
    # The intro modal's words, for exactly the reason above: a card that gains
    # a modal must miss the cache, or its already-translated Verto would keep
    # serving the entry that predates it and the modal would stay English in
    # every other language with nothing to show why.
    canonical["modal_title"] = card["modal_title"].to_s if card["modal_title"].present?
    canonical["modal_body"]  = card["modal_body"].to_s  if card["modal_body"].present?
    # The NPS scale's end captions, for the same reason. They are the words
    # that say what 0 and 10 MEAN, so a card that gains them and misses this
    # hash would keep serving the entry that predates them — and the captions
    # would stay in the source language in every other language, which is
    # exactly the field where that is least survivable.
    Survey::NPS_ANCHOR_KEYS.each { |k| canonical[k] = card[k].to_s if card[k].present? }
    # A tap card's own answer labels, for the same reason again — and only when
    # it has any, so every other card hashes exactly as it did.
    labels = SurveyTranslator.response_labels(card)
    canonical["responses"] = labels if labels.any?(&:present?)

    Digest::SHA256.hexdigest(canonical.to_json)
  end

  # Returns an aligned array: [<translation Hash or nil>, ...] for the given
  # cards/source_locale/target_locale. nil entries are cache misses.
  def self.lookup_many(cards, source_locale:, target_locale:)
    hashes = cards.map { |c| source_hash_for(c) }
    by_hash = where(source_hash: hashes,
                    source_locale: source_locale.to_s,
                    target_locale: target_locale.to_s).index_by(&:source_hash)
    hashes.map { |h| by_hash[h]&.translation }
  end

  # Writes one entry (upsert) given a card + the SurveyTranslator output for
  # that card. No-op if the translation looks empty/malformed.
  def self.write(card, source_locale:, target_locale:, translation:)
    return unless translation.is_a?(Hash) && translation["text"].is_a?(String) && !translation["text"].empty?
    upsert(
      {
        source_hash:   source_hash_for(card),
        source_locale: source_locale.to_s,
        target_locale: target_locale.to_s,
        translation:   translation,
        created_at:    Time.current,
        updated_at:    Time.current
      },
      unique_by: :idx_translation_cache_lookup
    )
  end
end
