// The card types whose ANSWER takes the whole phone screen — the JS mirror of
// CardTypes::FULL_SCREEN_ANSWER_TYPES (app/lib/card_types.rb).
//
// A tap matrix's stack cannot shrink, an NPS scale cannot either, and a
// prioritise list's rows are drag targets, so one below the fold cannot even be
// scrolled to. The phone therefore draws all three no hero strip at all.
//
// Which makes them exactly the cards that take NO HEADER BACKDROP (card.media_bg):
// there is no header for one to be behind. Every type takes a MOBILE
// BACKGROUND (card.mobile_bg) — behind the question and answers — and on these
// three that is the whole card. The editor decides whether to offer the header
// control from this list, and the server decides whether to store what it sets
// from the Ruby one — so they have to agree, and
// test/lib/js_constant_parity_test.rb asserts they do.
export const FULL_SCREEN_ANSWER_TYPES = [ "tap_card", "nps", "prioritise" ]

export function isFullScreenAnswer(type) {
  return FULL_SCREEN_ANSWER_TYPES.includes(type || "")
}
