source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3"
# The original asset pipeline for Rails [https://github.com/rails/sprockets-rails]
gem "sprockets-rails"
# SQLite for development/test; PostgreSQL in production
gem "sqlite3", ">= 1.4", group: [ :development, :test ]
gem "pg", "~> 1.5",      group: :production
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Bounds how long a request may hold a Puma thread. Required as
# `rack/timeout/base` rather than the default entry point: the latter also
# loads a railtie that inserts the middleware automatically at a 15s default,
# which would kill generation, import, the exports and every stream on
# contact. config/initializers/rack_timeout.rb inserts it deliberately, with
# per-tier bounds.
gem "rack-timeout", "~> 0.7.0", require: "rack/timeout/base"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"
# Redis client for Rails.cache on Render Key Value (Valkey) when REDIS_URL is
# set — the load test showed the 0.1-CPU Postgres saturated by Solid Cache and
# rate-limit counter writes long before the web tier worked hard. Action Cable
# and Solid Queue stay on the database.
gem "redis", "~> 5.4"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# Background jobs on the existing database (no Redis). Every Claude call used to
# run inline on a Puma request thread: with one worker and three threads, a few
# slow calls exhausted the pool and the whole app 502'd — including pages that
# never touch Claude. See AnthropicHelpers and PRODUCTION_READINESS_PLAN P0-3.
# Runs inside Puma (config/puma.rb) rather than as a separate service, because
# Render disks mount to exactly one service and Active Storage lives on ours.
gem "solid_queue", "~> 1.1"

# Action Cable over the existing database, so live results need no Redis. The
# production adapter pointed at a Redis that was never provisioned and the redis
# gem was commented out (P1-1) — latent until the first broadcast, which this is.
gem "solid_cable", "~> 3.0"

# Rails.cache on the existing database. Production had no cache_store set, so it
# fell back to a per-process memory store, which is not a throttle: the
# rate-limit counters in SessionsController, PasswordsController,
# RegistrationsController and PlayerController were counted per Puma process and
# wiped by every deploy and every memory-watchdog restart. Those counters and
# NominatimClient's geocode cache are the only Rails.cache users in the app —
# TranslationCache and the results-report markdown are database columns and were
# never affected (P0-5).
gem "solid_cache", "~> 1.0"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Anthropic Claude SDK
gem "anthropic", "~> 1.40"
gem "csv"
gem "rubyzip", "~> 3.6", require: "zip" # bulk brand-asset import (extract a zip of images)

# Scannable QR for a published Verto's share panel. Pure Ruby (no native
# extension, nothing to install in the Docker image) and renders SVG markup
# directly, so the QR goes inline into the page rather than as a data-URL
# <img> — one less thing fighting the CSP. Its chunky_png dependency (also
# pure Ruby) drives the PNG download for tools that won't place an SVG.
gem "rqrcode", "~> 3.0"

# Active Storage image analysis + variants (brand-library thumbnails). The
# Docker image ships the libvips system lib (prod); ruby-vips is loaded LAZILY
# by Active Storage only when it actually processes an image, so `require:
# false` keeps boot working in dev/CI where libvips isn't installed (thumbnails
# are only ever generated in production).
gem "image_processing", "~> 1.2"
gem "ruby-vips", require: false

# Active Storage → an S3-compatible object store (Cloudflare R2, EU jurisdiction,
# or S3 eu-central-1) so uploads are shared by every web instance AND the
# worker — the "disk unpin" that lets the web tier run more than one box. The
# `bucket` service in config/storage.yml is env-driven and inert until
# STORAGE_BUCKET is set; Active Storage requires this gem itself the first time
# that service is instantiated, so `require: false` keeps boot unchanged.
# Cutover runbook: docs/OBJECT_STORAGE_CUTOVER.md.
gem "aws-sdk-s3", require: false

# AI results report → PDF download + Google Doc
gem "kramdown"               # Markdown → HTML for the report body
gem "wicked_pdf"             # HTML → PDF for the downloadable report
gem "wkhtmltopdf-binary"     # bundles the wkhtmltopdf binary (no system install)

# Google Sheets export (per-user OAuth)
gem "googleauth"             # Signet OAuth2: authorize URL, code exchange, token refresh
gem "google-apis-sheets_v4"  # create spreadsheet + write values (Drive API not needed)
gem "google-apis-drive_v3"   # create the AI report as a Google Doc in the user's Drive

# Results export as .xlsx alongside the streamed CSV — pure Ruby, no native
# binary. rubyzip above is what a test unzips the generated workbook with.
gem "caxlsx"

# Internal BI: read-only SQL dashboards over the app DB for VertoNow staff.
# Mounted at /blazer, gated to a staff-email allowlist (see config/routes.rb
# and app/lib/blazer_access.rb). Runs against Postgres in prod.
gem "blazer", "~> 3.4"

# Error tracking (EU/Frankfurt data region — respondent PII stays in the EU;
# see config/initializers/sentry.rb). No-ops without SENTRY_DSN, so it's safe
# to load in every environment, including dev/test.
gem "sentry-ruby"
gem "sentry-rails"

# Social sign-in with Google. Activates only when GOOGLE_CLIENT_ID/SECRET are
# present in the environment — see .env.example.
gem "omniauth", "~> 2.1"
gem "omniauth-rails_csrf_protection" # request phase must be a CSRF-protected POST
gem "omniauth-google-oauth2"

# Load .env in development
gem "dotenv-rails", groups: [ :development, :test ]

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Browser tests (P2-5). Cuprite drives Chrome over CDP rather than through
  # chromedriver, which is what makes one configuration work both on the
  # GitHub runner (google-chrome on PATH) and in a container that only has a
  # Playwright-managed binary. Kept out of `bin/rails test` — system tests run
  # as their own CI step, so a browser hiccup can't take the unit suite down.
  gem "capybara", require: false
  gem "cuprite",  require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end
