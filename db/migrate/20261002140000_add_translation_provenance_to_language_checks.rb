# Two things the Language check screen needs to know about a line that the deck
# itself cannot hold, because the editor rebuilds every card from its DOM on
# autosave and would strip any key it does not render.
#
#   translated_from_digest — the primary-language wording (LanguageCheckLines.
#     digest) a translation was made FROM. When the original is rewritten, the
#     line can say it is out of date instead of offering "5 minutos" for review
#     against an English that now says "3 minutes". Null means "we cannot
#     tell" — every translation made before this existed — and shows no badge.
#   translator_note — on the PRIMARY line's row only: the author's word on
#     what the card means ("power" as in motivation), sent to the translator
#     with the card and shown to every reviewer of it.
class AddTranslationProvenanceToLanguageChecks < ActiveRecord::Migration[8.1]
  def change
    add_column :language_checks, :translated_from_digest, :string
    add_column :language_checks, :translator_note, :text
  end
end
