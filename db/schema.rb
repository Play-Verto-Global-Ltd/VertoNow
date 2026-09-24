# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_24_120000) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ask_messages", force: :cascade do |t|
    t.integer "ask_thread_id", null: false
    t.json "citations", default: [], null: false
    t.datetime "created_at", null: false
    t.string "role", null: false
    t.text "text", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["ask_thread_id", "created_at"], name: "index_ask_messages_on_ask_thread_id_and_created_at"
    t.index ["ask_thread_id"], name: "index_ask_messages_on_ask_thread_id"
    t.check_constraint "role IN ('user', 'assistant')", name: "chk_ask_messages_role"
  end

  create_table "ask_threads", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "organisation_id", null: false
    t.json "scope", default: {}, null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["organisation_id", "updated_at"], name: "index_ask_threads_on_organisation_id_and_updated_at"
    t.index ["organisation_id"], name: "index_ask_threads_on_organisation_id"
    t.index ["user_id"], name: "index_ask_threads_on_user_id"
  end

  create_table "blazer_audits", force: :cascade do |t|
    t.datetime "created_at"
    t.string "data_source"
    t.integer "query_id"
    t.text "statement"
    t.integer "user_id"
    t.index ["query_id"], name: "index_blazer_audits_on_query_id"
    t.index ["user_id"], name: "index_blazer_audits_on_user_id"
  end

  create_table "blazer_checks", force: :cascade do |t|
    t.string "check_type"
    t.datetime "created_at", null: false
    t.integer "creator_id"
    t.text "emails"
    t.datetime "last_run_at"
    t.text "message"
    t.integer "query_id"
    t.string "schedule"
    t.text "slack_channels"
    t.string "state"
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_blazer_checks_on_creator_id"
    t.index ["query_id"], name: "index_blazer_checks_on_query_id"
  end

  create_table "blazer_dashboard_queries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "dashboard_id"
    t.integer "position"
    t.integer "query_id"
    t.datetime "updated_at", null: false
    t.index ["dashboard_id"], name: "index_blazer_dashboard_queries_on_dashboard_id"
    t.index ["query_id"], name: "index_blazer_dashboard_queries_on_query_id"
  end

  create_table "blazer_dashboards", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "creator_id"
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_blazer_dashboards_on_creator_id"
  end

  create_table "blazer_queries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "creator_id"
    t.string "data_source"
    t.text "description"
    t.string "name"
    t.text "statement"
    t.string "status"
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_blazer_queries_on_creator_id"
  end

  create_table "common_question_sets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "default_locale", default: "en", null: false
    t.datetime "deleted_at"
    t.text "key_insight"
    t.string "name", null: false
    t.integer "organisation_id", null: false
    t.string "theme"
    t.datetime "updated_at", null: false
    t.index ["deleted_at"], name: "index_common_question_sets_on_deleted_at"
    t.index ["organisation_id"], name: "index_common_question_sets_on_organisation_id"
  end

  create_table "common_questions", force: :cascade do |t|
    t.boolean "allow_other", default: false, null: false
    t.string "card_type", null: false
    t.integer "common_question_set_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.json "options"
    t.integer "position", null: false
    t.text "text", null: false
    t.datetime "updated_at", null: false
    t.index ["common_question_set_id", "position"], name: "index_common_questions_on_common_question_set_id_and_position"
    t.index ["common_question_set_id"], name: "index_common_questions_on_common_question_set_id"
  end

  create_table "contact_details", force: :cascade do |t|
    t.string "company"
    t.datetime "created_at", null: false
    t.string "email"
    t.string "industry"
    t.string "key_digest", null: false
    t.string "name"
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["survey_id", "key_digest"], name: "index_contact_details_on_survey_id_and_key_digest", unique: true
    t.index ["survey_id"], name: "index_contact_details_on_survey_id"
  end

  create_table "corpus_entries", force: :cascade do |t|
    t.json "check_results", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "indexed_at"
    t.json "offered_scope", default: {}, null: false
    t.datetime "opted_in_at"
    t.integer "opted_in_by_id"
    t.integer "organisation_id", null: false
    t.integer "response_count", default: 0, null: false
    t.text "review_note"
    t.string "review_status", default: "pending", null: false
    t.datetime "reviewed_at"
    t.string "reviewed_by_email"
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.datetime "withdrawn_at"
    t.index ["opted_in_by_id"], name: "index_corpus_entries_on_opted_in_by_id"
    t.index ["organisation_id"], name: "index_corpus_entries_on_organisation_id"
    t.index ["review_status", "opted_in_at"], name: "index_corpus_entries_on_review_status_and_opted_in_at"
    t.index ["review_status"], name: "index_corpus_entries_on_review_status"
    t.index ["survey_id"], name: "index_corpus_entries_on_survey_id", unique: true
    t.check_constraint "review_status IN ('pending', 'approved', 'declined')", name: "chk_corpus_entries_review_status"
  end

  create_table "corpus_questions", force: :cascade do |t|
    t.string "card_type", null: false
    t.string "cid"
    t.integer "corpus_entry_id", null: false
    t.datetime "created_at", null: false
    t.json "distribution", default: {}, null: false
    t.json "options", default: [], null: false
    t.integer "position"
    t.text "question_text", null: false
    t.integer "response_count", default: 0, null: false
    t.json "segments", default: {}, null: false
    t.string "theme"
    t.datetime "updated_at", null: false
    t.index ["card_type"], name: "index_corpus_questions_on_card_type"
    t.index ["corpus_entry_id", "position"], name: "index_corpus_questions_on_corpus_entry_id_and_position"
    t.index ["corpus_entry_id"], name: "index_corpus_questions_on_corpus_entry_id"
  end

  create_table "corpus_quotes", force: :cascade do |t|
    t.boolean "approved", default: true, null: false
    t.text "body", null: false
    t.integer "corpus_question_id", null: false
    t.datetime "created_at", null: false
    t.string "theme"
    t.datetime "updated_at", null: false
    t.index ["corpus_question_id", "approved"], name: "index_corpus_quotes_on_corpus_question_id_and_approved"
    t.index ["corpus_question_id"], name: "index_corpus_quotes_on_corpus_question_id"
  end

  create_table "email_automation_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.integer "email_automation_id", null: false
    t.integer "email_automation_step_id"
    t.string "error"
    t.string "idempotency_key", null: false
    t.string "name"
    t.datetime "scheduled_at"
    t.datetime "sent_at"
    t.string "status", default: "queued", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["email_automation_id"], name: "index_email_automation_runs_on_email_automation_id"
    t.index ["email_automation_step_id"], name: "index_email_automation_runs_on_email_automation_step_id"
    t.index ["idempotency_key"], name: "index_email_automation_runs_on_idempotency_key", unique: true
    t.index ["status", "scheduled_at"], name: "index_email_automation_runs_on_status_and_scheduled_at"
    t.index ["token"], name: "index_email_automation_runs_on_token", unique: true
    t.check_constraint "status IN ('queued','sending','sent','failed','skipped','suppressed','simulated')", name: "chk_email_automation_runs_status"
  end

  create_table "email_automation_steps", force: :cascade do |t|
    t.text "compiled_html"
    t.text "compiled_text"
    t.datetime "created_at", null: false
    t.integer "delay_minutes", default: 1440, null: false
    t.json "design"
    t.integer "email_automation_id", null: false
    t.integer "position", default: 1, null: false
    t.string "preheader", default: "", null: false
    t.json "send_days"
    t.integer "send_hour"
    t.string "subject", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["email_automation_id"], name: "index_email_automation_steps_on_email_automation_id"
    t.check_constraint "delay_minutes >= 0", name: "chk_email_automation_steps_delay"
    t.check_constraint "send_hour IS NULL OR (send_hour >= 0 AND send_hour <= 23)", name: "chk_email_automation_steps_hour"
  end

  create_table "email_automations", force: :cascade do |t|
    t.text "compiled_html"
    t.text "compiled_text"
    t.json "conditions"
    t.datetime "created_at", null: false
    t.integer "created_by_id"
    t.integer "delay_minutes", default: 0, null: false
    t.json "design"
    t.boolean "enabled", default: false, null: false
    t.string "from_name"
    t.string "name", default: "Untitled automation", null: false
    t.json "params"
    t.string "preheader", default: "", null: false
    t.string "reply_to"
    t.json "send_days"
    t.integer "send_hour"
    t.string "subject", default: "", null: false
    t.string "trigger_type", default: "user_signed_up", null: false
    t.datetime "updated_at", null: false
    t.index ["enabled"], name: "index_email_automations_on_enabled"
    t.check_constraint "delay_minutes >= 0", name: "chk_email_automations_delay"
    t.check_constraint "send_hour IS NULL OR (send_hour >= 0 AND send_hour <= 23)", name: "chk_email_automations_hour"
    t.check_constraint "trigger_type IN ('user_signed_up','user_inactive','first_verto_published','first_response_received')", name: "chk_email_automations_trigger"
  end

  create_table "email_campaign_links", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "email_campaign_id", null: false
    t.text "url", null: false
    t.index ["email_campaign_id"], name: "index_email_campaign_links_on_email_campaign_id"
  end

  create_table "email_campaign_recipients", force: :cascade do |t|
    t.integer "click_count", default: 0, null: false
    t.datetime "complained_at"
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.string "email", null: false
    t.integer "email_campaign_id", null: false
    t.integer "email_list_contact_id"
    t.string "error"
    t.datetime "first_clicked_at"
    t.datetime "first_opened_at"
    t.datetime "last_clicked_at"
    t.datetime "last_opened_at"
    t.string "name"
    t.integer "open_count", default: 0, null: false
    t.datetime "sent_at"
    t.string "status", default: "queued", null: false
    t.integer "subject_variant", default: 0, null: false
    t.string "token", null: false
    t.datetime "unsubscribed_at"
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["email_campaign_id", "email"], name: "index_email_campaign_recipients_on_email_campaign_id_and_email", unique: true
    t.index ["email_campaign_id", "status"], name: "idx_on_email_campaign_id_status_90909c2255"
    t.index ["token"], name: "index_email_campaign_recipients_on_token", unique: true
    t.check_constraint "status IN ('queued','sending','sent','delivered','simulated','bounced','failed','skipped')", name: "chk_email_campaign_recipients_status"
  end

  create_table "email_campaigns", force: :cascade do |t|
    t.json "audience"
    t.text "compiled_html"
    t.text "compiled_text"
    t.datetime "created_at", null: false
    t.integer "created_by_id"
    t.json "design"
    t.string "from_name"
    t.date "newsletter_week"
    t.string "preheader", default: "", null: false
    t.integer "recipient_count", default: 0, null: false
    t.string "reply_to"
    t.datetime "scheduled_for"
    t.json "scheduled_snapshot"
    t.datetime "sent_at"
    t.string "status", default: "draft", null: false
    t.string "subject", default: "", null: false
    t.json "subject_variants"
    t.string "title", default: "Untitled campaign", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_email_campaigns_on_created_at"
    t.index ["created_by_id"], name: "index_email_campaigns_on_created_by_id"
    t.index ["newsletter_week"], name: "index_email_campaigns_on_newsletter_week", unique: true
    t.index ["scheduled_for"], name: "index_email_campaigns_on_scheduled_for"
    t.index ["status"], name: "index_email_campaigns_on_status"
    t.check_constraint "status IN ('draft','scheduled','sending','sent','failed','cancelled')", name: "chk_email_campaigns_status"
  end

  create_table "email_events", force: :cascade do |t|
    t.integer "email_automation_run_id"
    t.integer "email_campaign_id"
    t.integer "email_campaign_recipient_id"
    t.string "kind", null: false
    t.json "meta"
    t.datetime "occurred_at", null: false
    t.text "url"
    t.index ["email_automation_run_id"], name: "index_email_events_on_email_automation_run_id"
    t.index ["email_campaign_id", "kind"], name: "index_email_events_on_email_campaign_id_and_kind"
    t.index ["occurred_at"], name: "index_email_events_on_occurred_at"
    t.check_constraint "kind IN ('queued','sent','delivered','open','click','bounce','complaint','unsubscribe','failed','simulated','skipped')", name: "chk_email_events_kind"
  end

  create_table "email_list_contacts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.integer "email_list_id", null: false
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["email_list_id", "email"], name: "index_email_list_contacts_on_email_list_id_and_email", unique: true
  end

  create_table "email_lists", force: :cascade do |t|
    t.integer "contacts_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "created_by_id"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_email_lists_on_created_at"
  end

  create_table "email_suppressions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "reason", null: false
    t.integer "source_campaign_id"
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["email"], name: "index_email_suppressions_on_email", unique: true
    t.check_constraint "reason IN ('unsubscribe','hard_bounce','complaint','manual')", name: "chk_email_suppressions_reason"
  end

  create_table "flow_generations", force: :cascade do |t|
    t.json "cards", default: [], null: false
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "flow_name"
    t.json "payload", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["status"], name: "index_flow_generations_on_status"
    t.index ["survey_id", "created_at"], name: "index_flow_generations_on_survey_id_and_created_at"
    t.index ["survey_id"], name: "index_flow_generations_on_survey_id"
    t.index ["user_id"], name: "index_flow_generations_on_user_id"
    t.check_constraint "status IN ('pending', 'running', 'succeeded', 'failed')", name: "chk_flow_generations_status"
  end

  create_table "funder_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "funder_id", null: false
    t.integer "organisation_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["funder_id", "organisation_id"], name: "index_funder_memberships_on_funder_id_and_organisation_id", unique: true
    t.index ["funder_id"], name: "index_funder_memberships_on_funder_id"
    t.index ["organisation_id"], name: "index_funder_memberships_on_organisation_id"
    t.check_constraint "status IN ('active', 'suspended')", name: "chk_funder_memberships_status"
  end

  create_table "funders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "organisation_id", null: false
    t.integer "seat_count", default: 0, null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id", "name"], name: "index_funders_on_organisation_id_and_name", unique: true
    t.index ["organisation_id"], name: "index_funders_on_organisation_id"
    t.check_constraint "status IN ('active', 'revoked')", name: "chk_funders_status"
  end

  create_table "held_texts", force: :cascade do |t|
    t.boolean "auto", default: false, null: false
    t.integer "card_index", null: false
    t.string "category"
    t.float "certainty"
    t.datetime "created_at", null: false
    t.datetime "decided_at"
    t.string "decided_by_email"
    t.text "decision_note"
    t.string "last_screen_error"
    t.integer "organisation_id", null: false
    t.datetime "purge_after"
    t.string "question"
    t.integer "response_id", null: false
    t.integer "screen_attempts", default: 0, null: false
    t.datetime "screened_at"
    t.json "scrub_hits", default: {}, null: false
    t.string "slot", null: false
    t.string "status", default: "pending", null: false
    t.integer "survey_id", null: false
    t.text "text"
    t.string "text_digest", null: false
    t.datetime "updated_at", null: false
    t.text "verdict_note"
    t.index ["organisation_id", "status"], name: "index_held_texts_on_organisation_id_and_status"
    t.index ["organisation_id"], name: "index_held_texts_on_organisation_id"
    t.index ["response_id", "card_index", "slot", "text_digest"], name: "index_held_texts_on_response_slot_digest", unique: true
    t.index ["response_id"], name: "index_held_texts_on_response_id"
    t.index ["status", "updated_at"], name: "index_held_texts_on_status_and_updated_at"
    t.index ["survey_id", "status"], name: "index_held_texts_on_survey_id_and_status"
    t.index ["survey_id", "text_digest"], name: "index_held_texts_on_survey_id_and_text_digest"
    t.index ["survey_id"], name: "index_held_texts_on_survey_id"
    t.check_constraint "slot IN ('value', 'other')", name: "chk_held_texts_slot"
    t.check_constraint "status IN ('pending', 'screening', 'review', 'released', 'removed', 'safeguarding', 'superseded')", name: "chk_held_texts_status"
  end

  create_table "identities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.string "name"
    t.string "provider", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["provider", "uid"], name: "index_identities_on_provider_and_uid", unique: true
    t.index ["user_id"], name: "index_identities_on_user_id"
  end

  create_table "image_review_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "note"
    t.integer "organisation_id", null: false
    t.text "reason_given"
    t.datetime "reviewed_at"
    t.string "reviewed_by_email"
    t.string "status", default: "pending", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["organisation_id"], name: "index_image_review_requests_on_organisation_id"
    t.index ["status", "created_at"], name: "index_image_review_requests_on_status_and_created_at"
    t.index ["survey_id", "status"], name: "index_image_review_requests_on_survey_id_and_status"
    t.index ["survey_id"], name: "index_image_review_requests_on_survey_id"
    t.index ["user_id"], name: "index_image_review_requests_on_user_id"
    t.check_constraint "status IN ('pending', 'approved', 'rejected')", name: "chk_image_review_requests_status"
  end

  create_table "invites", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email_address"
    t.datetime "expires_at", null: false
    t.integer "funder_id"
    t.integer "invited_by_id", null: false
    t.string "kind", default: "member", null: false
    t.integer "organisation_id", null: false
    t.integer "partnership_id"
    t.string "role", default: "member", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["funder_id"], name: "index_invites_on_funder_id"
    t.index ["invited_by_id"], name: "index_invites_on_invited_by_id"
    t.index ["kind"], name: "index_invites_on_kind"
    t.index ["organisation_id"], name: "index_invites_on_organisation_id"
    t.index ["partnership_id"], name: "index_invites_on_partnership_id"
    t.index ["token"], name: "index_invites_on_token", unique: true
    t.check_constraint "kind IN ('member', 'partner', 'licensee')", name: "chk_invites_kind"
  end

  create_table "language_check_links", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.boolean "can_edit", default: true, null: false
    t.datetime "created_at", null: false
    t.integer "created_by_user_id"
    t.datetime "last_seen_at"
    t.json "locales", default: [], null: false
    t.string "name"
    t.integer "survey_id", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_language_check_links_on_created_by_user_id"
    t.index ["survey_id"], name: "index_language_check_links_on_survey_id"
    t.index ["token"], name: "index_language_check_links_on_token", unique: true
  end

  create_table "language_check_notes", force: :cascade do |t|
    t.string "author_name"
    t.integer "author_user_id"
    t.text "body", null: false
    t.string "cid", null: false
    t.datetime "created_at", null: false
    t.integer "language_check_link_id"
    t.string "locale", null: false
    t.datetime "resolved_at"
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["author_user_id"], name: "index_language_check_notes_on_author_user_id"
    t.index ["language_check_link_id"], name: "index_language_check_notes_on_language_check_link_id"
    t.index ["survey_id", "cid", "locale"], name: "index_language_check_notes_on_survey_card_locale"
    t.index ["survey_id"], name: "index_language_check_notes_on_survey_id"
  end

  create_table "language_checks", force: :cascade do |t|
    t.string "cid", null: false
    t.string "content_digest"
    t.datetime "created_at", null: false
    t.integer "edit_revision", default: 0, null: false
    t.datetime "edited_at"
    t.string "edited_by_name"
    t.integer "language_check_link_id"
    t.string "locale", null: false
    t.datetime "reviewed_at"
    t.string "reviewed_by_name"
    t.integer "reviewed_by_user_id"
    t.string "source_digest"
    t.string "status", default: "pending", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["language_check_link_id"], name: "index_language_checks_on_language_check_link_id"
    t.index ["reviewed_by_user_id"], name: "index_language_checks_on_reviewed_by_user_id"
    t.index ["survey_id", "cid", "locale"], name: "index_language_checks_on_survey_card_locale", unique: true
    t.index ["survey_id", "edit_revision"], name: "index_language_checks_on_survey_edit_revision"
    t.index ["survey_id"], name: "index_language_checks_on_survey_id"
    t.check_constraint "status IN ('pending', 'approved', 'changes_requested')", name: "chk_language_checks_status"
  end

  create_table "leaderboard_standings", force: :cascade do |t|
    t.datetime "achieved_at"
    t.datetime "created_at", null: false
    t.string "key_digest", null: false
    t.integer "survey_id", null: false
    t.integer "total", default: 0, null: false
    t.json "totals", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["survey_id", "key_digest"], name: "index_leaderboard_standings_on_survey_id_and_key_digest", unique: true
    t.index ["survey_id", "total"], name: "index_leaderboard_standings_on_survey_id_and_total"
  end

  create_table "memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "organisation_id", null: false
    t.string "role", default: "member", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["organisation_id"], name: "index_memberships_on_organisation_id"
    t.index ["user_id", "organisation_id"], name: "index_memberships_on_user_id_and_organisation_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
    t.check_constraint "role IN ('viewer', 'member', 'admin')", name: "chk_memberships_role"
  end

  create_table "organisations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "default_brand_palette"
    t.boolean "funder_enabled", default: false, null: false
    t.boolean "internal", default: false, null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.boolean "verto_creation_enabled", default: true, null: false
    t.index ["slug"], name: "index_organisations_on_slug", unique: true
  end

  create_table "partnership_common_question_sets", force: :cascade do |t|
    t.integer "common_question_set_id", null: false
    t.datetime "created_at", null: false
    t.integer "partnership_id", null: false
    t.datetime "updated_at", null: false
    t.index ["partnership_id", "common_question_set_id"], name: "idx_partnership_cq_sets_unique", unique: true
    t.index ["partnership_id"], name: "index_partnership_common_question_sets_on_partnership_id"
  end

  create_table "partnership_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "organisation_id", null: false
    t.integer "partnership_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_partnership_memberships_on_organisation_id"
    t.index ["partnership_id", "organisation_id"], name: "idx_on_partnership_id_organisation_id_292249422a", unique: true
    t.index ["partnership_id"], name: "index_partnership_memberships_on_partnership_id"
    t.check_constraint "status IN ('active', 'pending', 'revoked')", name: "chk_partnership_memberships_status"
  end

  create_table "partnership_vertos", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "partnership_id", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["partnership_id", "survey_id"], name: "index_partnership_vertos_on_partnership_id_and_survey_id", unique: true
    t.index ["partnership_id"], name: "index_partnership_vertos_on_partnership_id"
    t.index ["survey_id"], name: "index_partnership_vertos_on_survey_id"
  end

  create_table "partnerships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "organisation_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id", "name"], name: "index_partnerships_on_organisation_id_and_name", unique: true
    t.index ["organisation_id"], name: "index_partnerships_on_organisation_id"
    t.check_constraint "status IN ('active', 'pending', 'revoked')", name: "chk_partnerships_status"
  end

  create_table "player_aliases", force: :cascade do |t|
    t.string "anon_name", null: false
    t.datetime "created_at", null: false
    t.string "key_digest", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["survey_id", "anon_name"], name: "index_player_aliases_on_survey_id_and_anon_name", unique: true
    t.index ["survey_id", "key_digest"], name: "index_player_aliases_on_survey_id_and_key_digest", unique: true
    t.index ["survey_id"], name: "index_player_aliases_on_survey_id"
  end

  create_table "player_claims", force: :cascade do |t|
    t.datetime "claimed_at", null: false
    t.datetime "created_at", null: false
    t.integer "player_id", null: false
    t.integer "response_id", null: false
    t.string "source", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["player_id", "response_id"], name: "index_player_claims_on_player_id_and_response_id", unique: true
    t.index ["player_id"], name: "index_player_claims_on_player_id"
    t.index ["response_id"], name: "index_player_claims_on_response_id"
    t.index ["survey_id", "claimed_at"], name: "index_player_claims_on_survey_id_and_claimed_at"
    t.index ["survey_id"], name: "index_player_claims_on_survey_id"
    t.check_constraint "source IN ('signup', 'signed_in_play', 'device_key')", name: "chk_player_claims_source"
  end

  create_table "player_email_preferences", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "organisation_id", null: false
    t.integer "player_id", null: false
    t.datetime "unsubscribed_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_player_email_preferences_on_organisation_id"
    t.index ["player_id", "organisation_id"], name: "index_player_email_prefs_on_player_and_org", unique: true
    t.index ["player_id"], name: "index_player_email_preferences_on_player_id"
  end

  create_table "player_identities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.string "name"
    t.integer "player_id", null: false
    t.string "provider", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.index ["player_id"], name: "index_player_identities_on_player_id"
    t.index ["provider", "uid"], name: "index_player_identities_on_provider_and_uid", unique: true
  end

  create_table "player_notifications", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.integer "organisation_id", null: false
    t.integer "player_id", null: false
    t.datetime "sent_at"
    t.integer "survey_id", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_player_notifications_on_organisation_id"
    t.index ["player_id", "survey_id", "kind"], name: "index_player_notifications_on_player_survey_kind", unique: true
    t.index ["player_id"], name: "index_player_notifications_on_player_id"
    t.index ["survey_id"], name: "index_player_notifications_on_survey_id"
    t.index ["token"], name: "index_player_notifications_on_token", unique: true
    t.check_constraint "kind IN ('impact', 'follow_up')", name: "chk_player_notifications_kind"
  end

  create_table "player_oauth_handoffs", force: :cascade do |t|
    t.json "claim_payload", default: [], null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "locale"
    t.integer "survey_id"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_player_oauth_handoffs_on_expires_at"
    t.index ["survey_id"], name: "index_player_oauth_handoffs_on_survey_id"
    t.index ["token_digest"], name: "index_player_oauth_handoffs_on_token_digest", unique: true
  end

  create_table "player_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.integer "player_id", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["player_id"], name: "index_player_sessions_on_player_id"
  end

  create_table "player_sign_in_links", force: :cascade do |t|
    t.json "claim_payload", default: [], null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "origin", default: "email", null: false
    t.integer "player_id", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_player_sign_in_links_on_expires_at"
    t.index ["player_id"], name: "index_player_sign_in_links_on_player_id"
    t.index ["token_digest"], name: "index_player_sign_in_links_on_token_digest", unique: true
  end

  create_table "players", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.datetime "email_verified_at"
    t.string "name"
    t.string "password_digest"
    t.string "preferred_locale"
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_players_on_email_address", unique: true
  end

  create_table "portfolio_common_question_sets", force: :cascade do |t|
    t.integer "common_question_set_id", null: false
    t.datetime "created_at", null: false
    t.integer "portfolio_id", null: false
    t.datetime "updated_at", null: false
    t.index ["common_question_set_id"], name: "index_portfolio_common_question_sets_on_common_question_set_id"
    t.index ["portfolio_id", "common_question_set_id"], name: "idx_portfolio_cq_sets_unique", unique: true
    t.index ["portfolio_id"], name: "index_portfolio_common_question_sets_on_portfolio_id"
  end

  create_table "portfolio_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "funder_membership_id", null: false
    t.integer "portfolio_id", null: false
    t.datetime "updated_at", null: false
    t.index ["funder_membership_id"], name: "index_portfolio_memberships_on_funder_membership_id"
    t.index ["portfolio_id", "funder_membership_id"], name: "idx_portfolio_memberships_unique", unique: true
    t.index ["portfolio_id"], name: "index_portfolio_memberships_on_portfolio_id"
  end

  create_table "portfolios", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.integer "funder_id", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["deleted_at"], name: "index_portfolios_on_deleted_at"
    t.index ["funder_id", "name"], name: "index_portfolios_on_funder_id_and_name", unique: true
    t.index ["funder_id"], name: "index_portfolios_on_funder_id"
  end

  create_table "report_renders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "kind", default: "report", null: false
    t.string "status", default: "pending", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["status", "created_at"], name: "index_report_renders_on_status_and_created_at"
    t.index ["survey_id"], name: "index_report_renders_on_survey_id"
    t.index ["user_id"], name: "index_report_renders_on_user_id"
    t.check_constraint "kind IN ('report', 'infographic')", name: "chk_report_renders_kind"
    t.check_constraint "status IN ('pending', 'running', 'succeeded', 'failed')", name: "chk_report_renders_status"
  end

  create_table "respondent_aliases", force: :cascade do |t|
    t.string "anon_name", null: false
    t.string "code_digest", null: false
    t.datetime "created_at", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["survey_id", "anon_name"], name: "index_respondent_aliases_on_survey_id_and_anon_name", unique: true
    t.index ["survey_id", "code_digest"], name: "index_respondent_aliases_on_survey_id_and_code_digest", unique: true
    t.index ["survey_id"], name: "index_respondent_aliases_on_survey_id"
  end

  create_table "responses", force: :cascade do |t|
    t.boolean "answered", default: false, null: false
    t.json "answers", default: {}, null: false
    t.string "collection_mode"
    t.datetime "completed_at"
    t.datetime "consent_agreed_at"
    t.datetime "consent_declined_at"
    t.text "consent_text_snapshot"
    t.datetime "created_at", null: false
    t.string "demographic_age_band"
    t.integer "demographic_birth_year"
    t.string "demographic_gender"
    t.string "demographic_heritage"
    t.string "demographic_neurodiversity"
    t.string "device_kind"
    t.string "locale"
    t.string "player_key_digest"
    t.integer "quiz_max"
    t.string "region_country"
    t.string "region_label"
    t.string "region_postcode"
    t.string "respondent_code_digest"
    t.integer "score"
    t.string "session_token", null: false
    t.datetime "started_at"
    t.string "status", default: "completed", null: false
    t.integer "survey_id", null: false
    t.integer "survey_link_id"
    t.integer "survey_share_id"
    t.integer "survey_wave_id"
    t.json "token_totals", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["session_token"], name: "index_responses_on_session_token", unique: true
    t.index ["survey_id", "answered", "created_at"], name: "index_responses_on_survey_answered_created_at"
    t.index ["survey_id", "answered", "status"], name: "index_responses_on_survey_answered_status"
    t.index ["survey_id", "collection_mode"], name: "index_responses_on_survey_and_collection_mode"
    t.index ["survey_id", "demographic_age_band"], name: "index_responses_on_survey_id_and_demographic_age_band"
    t.index ["survey_id", "demographic_birth_year"], name: "index_responses_on_survey_id_and_demographic_birth_year"
    t.index ["survey_id", "demographic_gender"], name: "index_responses_on_survey_id_and_demographic_gender"
    t.index ["survey_id", "demographic_heritage"], name: "index_responses_on_survey_id_and_demographic_heritage"
    t.index ["survey_id", "demographic_neurodiversity"], name: "index_responses_on_survey_id_and_demographic_neurodiversity"
    t.index ["survey_id", "player_key_digest"], name: "index_responses_on_survey_and_player_key"
    t.index ["survey_id", "region_country"], name: "index_responses_on_survey_and_region_country"
    t.index ["survey_id", "respondent_code_digest"], name: "index_responses_on_survey_and_respondent_code"
    t.index ["survey_id", "survey_wave_id"], name: "index_responses_on_survey_id_and_survey_wave_id"
    t.index ["survey_link_id"], name: "index_responses_on_survey_link_id"
    t.index ["survey_share_id"], name: "index_responses_on_survey_share_id"
    t.check_constraint "status IN ('started', 'completed')", name: "chk_responses_status"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", limit: 1024, null: false
    t.integer "channel_hash", limit: 8, null: false
    t.datetime "created_at", null: false
    t.binary "payload", limit: 536870912, null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", limit: 4, null: false
    t.datetime "created_at", null: false
    t.binary "key", limit: 1024, null: false
    t.integer "key_hash", limit: 8, null: false
    t.binary "value", limit: 536870912, null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "survey_links", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.boolean "regions_enabled"
    t.boolean "share_enabled"
    t.boolean "show_results_comparison"
    t.string "slug", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_survey_links_on_slug", unique: true
    t.index ["survey_id", "created_at"], name: "index_survey_links_on_survey_id_and_created_at"
    t.index ["survey_id"], name: "index_survey_links_on_survey_id"
  end

  create_table "survey_shares", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "partner_organisation_id", null: false
    t.integer "partnership_verto_id", null: false
    t.string "share_token", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["partner_organisation_id"], name: "index_survey_shares_on_partner_organisation_id"
    t.index ["partnership_verto_id", "partner_organisation_id"], name: "index_survey_shares_on_pv_and_partner", unique: true
    t.index ["partnership_verto_id"], name: "index_survey_shares_on_partnership_verto_id"
    t.index ["share_token"], name: "index_survey_shares_on_share_token", unique: true
    t.index ["survey_id"], name: "index_survey_shares_on_survey_id"
  end

  create_table "survey_translations", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.string "last_error"
    t.string "locale", null: false
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["survey_id", "locale"], name: "index_survey_translations_on_survey_and_locale", unique: true
    t.index ["survey_id"], name: "index_survey_translations_on_survey_id"
    t.check_constraint "status IN ('queued', 'running', 'done', 'failed')", name: "chk_survey_translations_status"
  end

  create_table "survey_waves", force: :cascade do |t|
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.string "label"
    t.datetime "opened_at", null: false
    t.integer "position", null: false
    t.integer "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["survey_id", "position"], name: "index_survey_waves_on_survey_id_and_position", unique: true
    t.index ["survey_id"], name: "index_survey_waves_on_survey_id"
  end

  create_table "surveys", force: :cascade do |t|
    t.string "audience_age"
    t.string "audience_country"
    t.boolean "auto_detect_language", default: true, null: false
    t.text "background_image"
    t.boolean "brand_answer_tint", default: false, null: false
    t.string "brand_font"
    t.string "brand_font_heading"
    t.json "brand_palette"
    t.boolean "capture_postcode", default: false, null: false
    t.json "cards"
    t.boolean "chrome_follows_verto_language", default: true, null: false
    t.string "compare_note"
    t.text "consent_image"
    t.string "consent_image_credit"
    t.string "consent_image_credit_url"
    t.text "consent_text"
    t.boolean "contact_form_enabled", default: false, null: false
    t.datetime "created_at", null: false
    t.string "default_locale", default: "en", null: false
    t.datetime "deleted_at"
    t.json "deleted_cards", default: [], null: false
    t.text "description"
    t.json "end_screens", default: [], null: false
    t.json "flows", default: [], null: false
    t.json "follow_up_survey_ids", default: [], null: false
    t.string "forward_label"
    t.string "forward_url"
    t.text "impact_body"
    t.json "impact_changes", default: [], null: false
    t.string "impact_headline"
    t.string "impact_link_label"
    t.string "impact_link_url"
    t.datetime "impact_published_at"
    t.string "join_body"
    t.string "join_cta"
    t.boolean "join_prompt_enabled", default: false, null: false
    t.string "join_title"
    t.text "key_insight"
    t.boolean "leaderboard_enabled", default: false, null: false
    t.string "leaderboard_note"
    t.string "leaderboard_rank_by", default: "all", null: false
    t.datetime "leaderboard_refreshed_at"
    t.string "leaderboard_retake_policy", default: "accumulate", null: false
    t.json "locales"
    t.boolean "logic", default: false, null: false
    t.string "moderation_mode", default: "assisted", null: false
    t.text "next_step_body"
    t.string "next_step_headline"
    t.boolean "no_going_back", default: false, null: false
    t.boolean "no_retests", default: false, null: false
    t.integer "organisation_id", null: false
    t.string "publish_token"
    t.datetime "published_at"
    t.boolean "quiz", default: false, null: false
    t.boolean "regions_enabled", default: true, null: false
    t.string "render_mode", default: "cards", null: false
    t.boolean "respondent_code_enabled", default: false, null: false
    t.string "respondent_code_prompt"
    t.json "results_insights"
    t.text "results_report"
    t.text "results_report_brief"
    t.datetime "results_report_edited_at"
    t.integer "results_report_response_count"
    t.boolean "results_share_active", default: true, null: false
    t.string "results_share_token"
    t.text "results_summary"
    t.integer "results_summary_response_count"
    t.json "sdgs", default: [], null: false
    t.datetime "setup_pending_since"
    t.text "share_description"
    t.boolean "share_enabled", default: true, null: false
    t.text "share_image"
    t.text "share_message"
    t.string "share_title"
    t.boolean "show_results_comparison", default: false, null: false
    t.string "shuffle_direction"
    t.string "slug"
    t.string "test_token"
    t.text "thankyou_body"
    t.string "thankyou_title"
    t.string "theme"
    t.string "title"
    t.boolean "token_amounts_shown", default: false, null: false
    t.boolean "token_back_nav_enabled", default: false, null: false
    t.boolean "token_hud_enabled", default: true, null: false
    t.string "token_intro_cid"
    t.string "token_result_note"
    t.boolean "token_reveal_enabled", default: false, null: false
    t.json "token_types", default: [], null: false
    t.boolean "tokenisation_enabled", default: false, null: false
    t.string "tokens_note"
    t.integer "translations_revision", default: 0, null: false
    t.datetime "unpublished_at"
    t.datetime "updated_at", null: false
    t.index ["deleted_at"], name: "index_surveys_on_deleted_at"
    t.index ["organisation_id"], name: "index_surveys_on_organisation_id"
    t.index ["publish_token"], name: "index_surveys_on_publish_token", unique: true
    t.index ["results_share_token"], name: "index_surveys_on_results_share_token", unique: true
    t.index ["slug"], name: "index_surveys_on_slug", unique: true
    t.index ["test_token"], name: "index_surveys_on_test_token", unique: true
    t.check_constraint "leaderboard_retake_policy IN ('accumulate', 'no_redo', 'restart')", name: "chk_surveys_leaderboard_retake_policy"
    t.check_constraint "moderation_mode IN ('assisted', 'review_all')", name: "chk_surveys_moderation_mode"
  end

  create_table "translation_cache", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "source_hash", null: false
    t.string "source_locale", null: false
    t.string "target_locale", null: false
    t.json "translation", null: false
    t.datetime "updated_at", null: false
    t.index ["source_hash", "source_locale", "target_locale"], name: "idx_translation_cache_lookup", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.datetime "email_verified_at"
    t.text "google_access_token"
    t.datetime "google_connected_at"
    t.string "google_email"
    t.text "google_refresh_token"
    t.datetime "google_token_expires_at"
    t.string "name", default: "", null: false
    t.string "password_digest", null: false
    t.boolean "password_pending", default: false, null: false
    t.string "preferred_locale"
    t.datetime "terms_accepted_at"
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "verto_builds", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "kind", default: "generate", null: false
    t.integer "organisation_id", null: false
    t.json "payload", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.integer "survey_id"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["organisation_id", "created_at"], name: "index_verto_builds_on_organisation_id_and_created_at"
    t.index ["organisation_id"], name: "index_verto_builds_on_organisation_id"
    t.index ["status"], name: "index_verto_builds_on_status"
    t.index ["survey_id"], name: "index_verto_builds_on_survey_id"
    t.index ["user_id"], name: "index_verto_builds_on_user_id"
    t.check_constraint "kind IN ('generate', 'import_manual', 'import_google_form', 'import_pdf')", name: "chk_verto_builds_kind"
    t.check_constraint "status IN ('pending', 'running', 'succeeded', 'failed')", name: "chk_verto_builds_status"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "ask_messages", "ask_threads"
  add_foreign_key "ask_threads", "organisations"
  add_foreign_key "ask_threads", "users"
  add_foreign_key "common_question_sets", "organisations"
  add_foreign_key "common_questions", "common_question_sets"
  add_foreign_key "contact_details", "surveys"
  add_foreign_key "corpus_entries", "organisations"
  add_foreign_key "corpus_entries", "surveys"
  add_foreign_key "corpus_entries", "users", column: "opted_in_by_id"
  add_foreign_key "corpus_questions", "corpus_entries"
  add_foreign_key "corpus_quotes", "corpus_questions"
  add_foreign_key "flow_generations", "surveys"
  add_foreign_key "flow_generations", "users"
  add_foreign_key "funder_memberships", "funders"
  add_foreign_key "funder_memberships", "organisations"
  add_foreign_key "funders", "organisations"
  add_foreign_key "held_texts", "organisations"
  add_foreign_key "held_texts", "responses"
  add_foreign_key "held_texts", "surveys"
  add_foreign_key "identities", "users"
  add_foreign_key "image_review_requests", "organisations", on_delete: :cascade
  add_foreign_key "image_review_requests", "surveys", on_delete: :cascade
  add_foreign_key "image_review_requests", "users", on_delete: :cascade
  add_foreign_key "invites", "funders"
  add_foreign_key "invites", "organisations"
  add_foreign_key "invites", "partnerships"
  add_foreign_key "invites", "users", column: "invited_by_id"
  add_foreign_key "language_check_links", "surveys"
  add_foreign_key "language_check_links", "users", column: "created_by_user_id"
  add_foreign_key "language_check_notes", "language_check_links"
  add_foreign_key "language_check_notes", "surveys"
  add_foreign_key "language_check_notes", "users", column: "author_user_id"
  add_foreign_key "language_checks", "language_check_links"
  add_foreign_key "language_checks", "surveys"
  add_foreign_key "language_checks", "users", column: "reviewed_by_user_id"
  add_foreign_key "leaderboard_standings", "surveys"
  add_foreign_key "memberships", "organisations"
  add_foreign_key "memberships", "users"
  add_foreign_key "partnership_common_question_sets", "common_question_sets"
  add_foreign_key "partnership_common_question_sets", "partnerships"
  add_foreign_key "partnership_memberships", "organisations"
  add_foreign_key "partnership_memberships", "partnerships"
  add_foreign_key "partnership_vertos", "partnerships"
  add_foreign_key "partnership_vertos", "surveys"
  add_foreign_key "partnerships", "organisations"
  add_foreign_key "player_aliases", "surveys"
  add_foreign_key "player_claims", "players"
  add_foreign_key "player_claims", "responses"
  add_foreign_key "player_claims", "surveys"
  add_foreign_key "player_email_preferences", "organisations"
  add_foreign_key "player_email_preferences", "players"
  add_foreign_key "player_identities", "players"
  add_foreign_key "player_notifications", "organisations"
  add_foreign_key "player_notifications", "players"
  add_foreign_key "player_notifications", "surveys"
  add_foreign_key "player_oauth_handoffs", "surveys", on_delete: :nullify
  add_foreign_key "player_sessions", "players"
  add_foreign_key "player_sign_in_links", "players"
  add_foreign_key "portfolio_common_question_sets", "common_question_sets"
  add_foreign_key "portfolio_common_question_sets", "portfolios"
  add_foreign_key "portfolio_memberships", "funder_memberships"
  add_foreign_key "portfolio_memberships", "portfolios"
  add_foreign_key "portfolios", "funders"
  add_foreign_key "report_renders", "surveys"
  add_foreign_key "report_renders", "users"
  add_foreign_key "respondent_aliases", "surveys"
  add_foreign_key "responses", "survey_links"
  add_foreign_key "responses", "survey_shares"
  add_foreign_key "responses", "survey_waves"
  add_foreign_key "responses", "surveys"
  add_foreign_key "sessions", "users"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "survey_links", "surveys"
  add_foreign_key "survey_shares", "organisations", column: "partner_organisation_id"
  add_foreign_key "survey_shares", "partnership_vertos"
  add_foreign_key "survey_shares", "surveys"
  add_foreign_key "survey_translations", "surveys"
  add_foreign_key "survey_waves", "surveys"
  add_foreign_key "surveys", "organisations"
  add_foreign_key "verto_builds", "organisations"
  add_foreign_key "verto_builds", "surveys"
  add_foreign_key "verto_builds", "users"
end
