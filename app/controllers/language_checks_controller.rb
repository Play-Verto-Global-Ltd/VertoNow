# The creator's side of the Language check screen: every card's wording in
# every language the Verto has, primary line first, with the same approve /
# edit / comment actions the reviewer link offers.
#
# One screen rather than a panel in the editor, because the job it serves is
# not the job the editor serves. The editor is one card at a time in one
# language; this is one question across three languages, read down the page.
# The editor's locale switcher stays exactly as it was — a creator writing
# Spanish still writes it there — and this is where somebody CHECKS it.
#
# Open to every role, like the Share panel and for the same reason: reading
# the wording and saying whether it is right is what a viewer seat is for.
# Minting a review link is admin-only (LanguageCheckLinksController) — handing
# an account-less stranger the ability to rewrite live copy is an account-level
# decision, the same bar as a partner share.
class LanguageChecksController < ApplicationController
  include RecordsLanguageChecks

  before_action :set_survey

  # GET /surveys/:id/language_check
  def show
    @cards  = LanguageCheckLines.for(@survey)
    @checks = LanguageCheck.index_for(@survey)
    @notes  = LanguageCheckNote.index_for(@survey)
    @links  = @survey.language_check_links.order(created_at: :desc)
    @locales = @survey.verto_locales
    @coverage = LanguageCheckLines.coverage(@cards, @locales, @survey.default_locale)
    @runs = SurveyTranslation.index_for(@survey)
    # What each language's Re-translate button would ask for — the same list
    # #retranslate works out, so the count on the button is the work it does.
    @retranslatable = LanguageCheckLines.outdated(@cards, @checks, include_edited: false)
    # What the sidebar can still offer. Registry order, so the list reads the
    # same here as in the editor's Language settings.
    @addable = SupportedLocales.all.reject { |loc| @locales.include?(loc.code) }
    # Mirrors review_may_edit? below, so the page offers exactly the buttons
    # the endpoint would honour — a viewer seat is shown no Edit control rather
    # than one that bounces.
    @editable = can_edit_vertos?
    @shared = false
  end

  # POST /surveys/:id/language_check/lines
  # One endpoint for all three verbs, because the screen posts one line at a
  # time and the only thing that varies is which field of the row is written.
  def update_line
    outcome =
      case params[:verb].to_s
      when "approve"          then record_language_decision(@survey, **line_params, status: "approved")
      when "request_changes"  then record_language_decision(@survey, **line_params, status: "changes_requested")
      when "reset"            then record_language_decision(@survey, **line_params, status: "pending")
      when "edit"             then record_language_edit(@survey, **line_params, fields: edit_fields)
      when "note"             then record_language_note(@survey, **line_params, body: params[:body])
      # The author's word on what a card means. The creator's call, not a
      # reviewer's — the shared link has no such verb — and a viewer seat reads
      # it like everything else here but does not set it.
      when "translator_note"
        can_edit_vertos? ? record_translator_note(@survey, cid: params[:cid].to_s, body: params[:body]) : :unknown_line
      else :unknown_line
      end

    redirect_to survey_language_check_path(@survey, anchor: "line-#{params[:cid]}-#{params[:locale]}",
                                                    filter: params[:filter].presence),
                alert: (t("language_check.action_failed") if outcome == :unknown_line)
  end

  # POST /surveys/:id/language_check/languages — add languages from the
  # sidebar and set them translating.
  #
  # Adds only. The editor's Language settings is where a language is DROPPED,
  # because dropping one is a decision about the Verto rather than about
  # checking it, and a tick-list that silently deselected on this screen would
  # let a reviewer's sidebar remove a language from a live Verto. See
  # Survey#add_locales!.
  #
  # Same bar as editing the wording: a viewer seat reads and rules, it does not
  # change what the Verto IS, and adding a language spends AI and alters what
  # respondents are offered.
  def add_languages
    return redirect_back_to_screen unless can_edit_vertos?

    added = @survey.add_locales!(params[:locales])
    TranslateLocalesJob.enqueue_for(@survey, added) if added.any?
    redirect_back_to_screen
  end

  # GET /surveys/:id/language_check/status — what the rail polls while a
  # language is being translated.
  #
  # The screen was a plain server render, so a translation finishing behind it
  # changed nothing on the page: the only way to learn a language had landed
  # was to guess when to press reload. Telling somebody "give it a minute, then
  # reload" is a worse version of the spinner that never resolves — it still
  # makes them do the waiting, and it still leaves them unsure whether nothing
  # has happened or nothing is going to.
  #
  # Returns only what the rail needs to decide whether to keep asking, so the
  # poll stays cheap on a page somebody leaves open.
  def status
    runs  = SurveyTranslation.index_for(@survey)
    cards = LanguageCheckLines.for(@survey)
    cover = LanguageCheckLines.coverage(cards, @survey.verto_locales, @survey.default_locale)

    languages = LanguageCheckLines.poll_state(cover, runs, @survey.verto_locales, @survey.default_locale)

    render json: {
      ok: true,
      # The same predicate the rail armed itself with. These were two separate
      # expressions and could answer differently about the same Verto: the rail
      # would decide to watch and this would immediately report nothing doing,
      # which the poll reads as "finished" and answers with a reload — on a page
      # whose state has not changed, for ever.
      working: LanguageCheckLines.outstanding?(languages),
      # What the poll compares against what it was rendered with. A reload is
      # worth it when a language CHANGES state, not merely while one is pending.
      signature: LanguageCheckLines.poll_signature(languages),
      languages: languages
    }
  end

  # POST /surveys/:id/language_check/languages/retry — run one language again
  # after it failed. The rail only offers this on a spent row, so it is the
  # creator saying "yes, try that again" rather than a second silent attempt.
  def retry_language
    locale = params[:locale].to_s
    if can_edit_vertos? && @survey.secondary_locales.include?(locale)
      TranslateLocalesJob.enqueue_for(@survey, [ locale ])
    end
    redirect_back_to_screen
  end

  # POST /surveys/:id/language_check/retranslate — translate lines again from
  # the original as it reads now.
  #
  # With a cid, that one line, whatever has happened to it: the creator is
  # looking at it and has asked. Without one, every out-of-date line in the
  # language EXCEPT those somebody rewrote on this screen — a reviewer's
  # hand-made Spanish is not something a bulk button should quietly replace,
  # and each of those lines keeps its own button for when that is the point.
  #
  # Same bar as adding a language: it spends AI and changes what respondents
  # read, so a viewer seat cannot.
  def retranslate
    locale = params[:locale].to_s
    return redirect_back_to_screen unless can_edit_vertos? && @survey.secondary_locales.include?(locale)

    cards = LanguageCheckLines.for(@survey)
    cids  =
      if params[:cid].present?
        [ params[:cid].to_s ] & cards.map { |c| c[:cid] }
      else
        LanguageCheckLines.outdated(cards, LanguageCheck.index_for(@survey), include_edited: false)[locale]
      end
    TranslateLocalesJob.enqueue_for(@survey, [ locale ], cids: cids) if cids.present?

    if params[:cid].present?
      redirect_to survey_language_check_path(@survey, anchor: "line-#{params[:cid]}-#{locale}",
                                                      filter: params[:filter].presence)
    else
      redirect_back_to_screen
    end
  end

  private

  def redirect_back_to_screen
    redirect_to survey_language_check_path(@survey, filter: params[:filter].presence,
                                                    anchor: "language-check-languages")
  end

  def set_survey
    @survey = Current.organisation.surveys.kept.without_report_text.find(params[:id])
  end

  def line_params
    { cid: params[:cid].to_s, locale: params[:locale].to_s }
  end

  # Only the fields the screen actually renders an input for, and always as a
  # plain hash of scalars/arrays — `permit!` on a nested params hash from a
  # form is how an unexpected key reaches a model write.
  def edit_fields
    raw = params[:fields]
    return {} unless raw.respond_to?(:permit)
    raw.permit(:text, :description, :explanation,
               options: [], responses: [], pages: [ :id, :text ]).to_h
  end

  # Who is acting, for the record on the row. A signed-in creator is a real
  # identity; the name is carried alongside so the screen reads the same
  # whether the line was ruled on here or through a link.
  def review_actor
    { user: Current.user, name: Current.user&.name, link: nil }
  end

  # The creator sees every language their Verto has.
  def review_scope(survey)
    survey.verto_locales
  end

  # A viewer seat reads the wording and rules on it; it does not rewrite the
  # Verto. That is the same line OrganisationScope draws everywhere else
  # (require_verto_editing!), and it has to be drawn here too — this screen is
  # a write path into `cards` like any other, just a narrower one.
  #
  # The live-edit LOCK is a separate question, and deliberately not asked here:
  # what the lock protects is the answer key (canonical option labels), and
  # Survey#apply_language_edit! refuses those itself on a locked deck while
  # still letting a typo in a live question be fixed. See its comment.
  def review_may_edit?
    can_edit_vertos?
  end
end
