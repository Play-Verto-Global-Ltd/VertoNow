# The automated checks a Verto passes through before a human decides on it.
#
# These do not approve anything. They exist so the reviewer opens a pre-flagged
# row rather than auditing a Verto from scratch — sample size, answer options that
# look like they collect personal data, free-text volume, and how much the Verto
# overlaps what the corpus already holds are all computable, and computing them is
# what makes a three-minute review possible.
#
# Every check returns the same shape so the queue can render them without knowing
# what any of them mean:
#
#   { key:, status: :pass | :warn | :fail, label: }
#
# A :fail is a reason to decline and the label is written to be shown to the
# creator verbatim. A :warn is something to look at, not a blocker.
module CorpusChecks
  module_function

  # Answer options that look like they collect a person rather than an opinion.
  # A Verto asking "What is the name of your school?" as a free-text card is the
  # real example from the supplied data — the answers are institution names, and
  # in a small cohort an institution name plus an age band is an identification.
  PII_OPTION_HINTS = %w[
    name surname firstname lastname email e-mail phone mobile telephone
    address postcode zip school university college employer company
    nombre apellido correo teléfono telefono dirección direccion escuela colegio
  ].freeze

  Check = Struct.new(:key, :status, :label, keyword_init: true) do
    def fail? = status == :fail
    def to_h  = { "key" => key.to_s, "status" => status.to_s, "label" => label }
  end

  # Run every check for one Verto. `entry` may be unsaved. `answered_count` is
  # CorpusIndexer.countable_responses — the population the index will actually
  # be built over. Checking a different one (completion used to be the gate
  # here) failed Vertos for a sample the corpus does not use.
  def run(survey, answered_count:)
    cards = Array(survey.cards)

    [
      sample_size(answered_count),
      pii_options(cards),
      free_text(cards),
      contact_forms(cards),
      question_count(cards),
      integrity(survey)
    ].compact
  end

  def sample_size(answered_count)
    if answered_count >= CorpusEntry.min_sample_size
      Check.new(key: :sample_size, status: :pass,
                label: "Sample size · #{answered_count} responses with answers")
    else
      Check.new(key: :sample_size, status: :fail,
                label: "Fewer than #{CorpusEntry.min_sample_size} responses with answers " \
                       "(#{answered_count}). Re-offer once the Verto has more.")
    end
  end

  # Free-text cards whose wording asks for something identifying. Flagged rather
  # than failed: the reviewer decides, because "What is the name of your school?"
  # and "What would you name your community project?" both match on `name`.
  def pii_options(cards)
    suspects = cards.select do |card|
      next false unless CardTypes.question?(card["type"].to_s)

      haystack = [ card["text"], card["description"], Array(card["options"]).join(" ") ]
                 .join(" ").downcase
      PII_OPTION_HINTS.any? { |hint| haystack.include?(hint) }
    end

    if suspects.empty?
      Check.new(key: :pii_options, status: :pass, label: "No personal-data wording in questions")
    else
      Check.new(key: :pii_options, status: :warn,
                label: "#{suspects.size} question#{"s" if suspects.size != 1} may collect " \
                       "identifying detail — read before approving")
    end
  end

  # How many quotes this Verto would contribute. Not a pass/fail — it is the
  # reviewer's workload, and the queue shows it so nobody approves 400 verbatim
  # quotes without noticing they exist.
  def free_text(cards)
    count = cards.count { |card| card["type"].to_s == "open_ended" }
    return Check.new(key: :free_text, status: :pass, label: "No open-text questions") if count.zero?

    Check.new(key: :free_text, status: :warn,
              label: "#{count} open-text question#{"s" if count != 1} — quotes need a read")
  end

  # Contact forms collect a name and an email on purpose. They are never indexed,
  # and their presence is worth stating so nobody assumes they were.
  def contact_forms(cards)
    count = cards.count { |card| card["type"].to_s == "contact_form" }
    return Check.new(key: :contact_forms, status: :pass, label: "No contact forms") if count.zero?

    Check.new(key: :contact_forms, status: :warn,
              label: "#{count} contact form#{"s" if count != 1} — excluded from the corpus")
  end

  def question_count(cards)
    citable = cards.count { |card| CorpusIndexer.indexable?(card["type"].to_s) }

    if citable.positive?
      Check.new(key: :question_count, status: :pass, label: "#{citable} citable questions")
    else
      Check.new(key: :question_count, status: :fail,
                label: "No questions in this Verto can be cited — nothing to add to Ask Verto.")
    end
  end

  # The Commons' 70% rule (ResponseIntegrity.commons_eligible?): at least that
  # share of a Verto's scored responses High or Medium. No check at all while
  # scores are in shadow mode — a reviewer must not be shown, or a creator
  # declined over, a number nobody has tuned yet.
  def integrity(survey)
    return nil unless ResponseIntegrity.visible?

    standing = ResponseIntegrity.commons_standing(survey)
    needed   = (ResponseIntegrity::COMMONS_MIN_RELIABLE_SHARE * 100).round
    if standing[:share].nil?
      Check.new(key: :integrity, status: :pass,
                label: "Integrity · no scored responses (collected before scoring began, or imported)")
    elsif ResponseIntegrity.commons_eligible?(survey, standing)
      Check.new(key: :integrity, status: :pass,
                label: "Integrity · #{(standing[:share] * 100).round}% of #{standing[:scored]} scored responses High or Medium")
    else
      Check.new(key: :integrity, status: :fail,
                label: "Only #{(standing[:share] * 100).floor}% of #{standing[:scored]} scored responses are High or Medium; " \
                       "the Data Commons needs #{needed}%. Low and unverified responses were given too quickly or " \
                       "carelessly to rely on.")
    end
  end

  # Whether the automated checks alone are enough to decline. A reviewer can still
  # decline a Verto that passes everything.
  def blocking(checks)
    checks.select(&:fail?)
  end
end
