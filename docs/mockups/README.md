# Mockups

Design documents, not code. Each directory is one self-contained `index.html` —
artboards with numbered callouts, keyed to a numbered spec at the foot of the
same page, so the pictures and their technical implications stay together. All
of them work from `file://`: fonts are base64-embedded, artwork is inline SVG,
and nothing is fetched.

| Deck | What it covers | Built? |
|---|---|---|
| [`responder-share/`](responder-share/) | A respondent passing a Verto on to friends and family — the end-screen share card, the link as it unfurls in WhatsApp, Messages and the feeds, the generated 1200×630 image, and where the creator writes the narrative headline. | No — except §4 (the `robots.txt` change), which shipped |
| [`responder-accounts/`](responder-accounts/) | A respondent taking an **account** at the end of a Verto — the Vertos they played, their answers against everyone, a token wallet, the impact the Verto had, follow-ups, and the emails. | No |
| [`respondent-verification/`](respondent-verification/) | The account once it exists — proving the address it was created with, and the extra tap on the Google door. Unlike the two above it draws **what is actually shipped**, so its boards are a record of the current flows as well as a proposal. | No — but it documents three live bugs, and §6's relabel is a two-line fix |

All three share a fiction (Haverley Town Council, "Car-free High Street", 1,284
responses) and cross-reference each other's specs, so they read as one story —
read `responder-share/` first. `respondent-verification/` is the only one
assembled by a script (`build.py`, from `parts/`) rather than hand-written, and it
splices its fonts and stylesheet out of `responder-accounts/index.html` so the
three stay visually identical.

The written-out plan that grew from the third deck — the whole respondent mail
lifecycle, and the three live bugs it turned up — is
[`../RESPONDENT_LIFECYCLE_PLAN.md`](../RESPONDENT_LIFECYCLE_PLAN.md).

Each deck carries its own README with the board list, how to re-shoot the PNGs,
and how to rebuild its PDF.
