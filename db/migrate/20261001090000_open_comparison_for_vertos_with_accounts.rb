class OpenComparisonForVertosWithAccounts < ActiveRecord::Migration[8.1]
  # An account is where a respondent comes back to see their answers beside
  # everyone else's, and /you/v/:id draws none of it while
  # surveys.show_results_comparison is false — which it is for every Verto
  # whose creator never found that second switch. Offering accounts now turns
  # the comparison on with it (SurveysController#update_settings), but that is
  # a default for the future: column defaults and toggle-time rules apply to
  # what happens next, and the accounts that already exist are holding Vertos
  # that were switched on before it.
  #
  # So the Vertos accounts already depend on are opened:
  #
  #   · every Verto that has the account ask on (join_prompt_enabled) — the
  #     creator is offering accounts there, and the same rule applies;
  #   · every Verto an account already holds a claim on, even if the ask has
  #     since been turned off — those respondents are signed in to it now.
  #
  # That does overwrite a creator who chose false deliberately. Accepted
  # knowingly, as in ChromeFollowsVertoLanguageByDefault: a stored false cannot
  # be told apart from never having touched an opt-in that shipped off, and the
  # people it affects are respondents who were promised a place to compare.
  # The switch stays, so a creator who wants results closed can close them.
  #
  # Visible beyond the account: the end-of-Verto "compare" button follows the
  # same switch, so those Vertos now offer it to everyone who finishes.
  #
  # updated_at is left alone on purpose. The creator dashboard orders by it, and
  # touching every affected row would reshuffle it; the cached player page is
  # keyed on it too, but a deploy that changes any asset changes
  # PLAYER_PAGE_BUILD, which retires those pages anyway.
  #
  # Idempotent, and not reversible: nothing records which rows were false.
  def up
    execute <<~SQL.squish
      UPDATE surveys
         SET show_results_comparison = #{quoted_true}
       WHERE show_results_comparison = #{quoted_false}
         AND ( join_prompt_enabled = #{quoted_true}
               OR id IN (SELECT DISTINCT survey_id FROM player_claims) )
    SQL
  end

  def down
    # Data only, and the previous values were not kept. Nothing to restore.
  end
end
