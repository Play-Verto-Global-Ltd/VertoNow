import { Controller } from "@hotwired/stimulus"

// Device preview toggle for the editor. Swaps a device-* class on the cards
// feed so the split-cards reframe to phone / tablet width (CSS in
// application.css). The cards stay the same editable DOM, so clicking a card
// to change its type, deleting, and adding all keep working at any size.
export default class extends Controller {
  static targets = ["feed", "btn"]

  set(e) {
    const device = e.currentTarget.dataset.device || "desktop"
    this.feedTarget.classList.remove("device-desktop", "device-tablet", "device-mobile")
    this.feedTarget.classList.add(`device-${device}`)
    this.btnTargets.forEach(b => {
      const active = b.dataset.device === device
      b.classList.toggle("is-active", active)
      b.setAttribute("aria-pressed", active)
    })
  }

  // The media dock's proxies (surveys/_card_media_dock). A dock button names
  // the panel pill it stands in for (data-proxy, a selector scoped to this
  // card's wrap) and this clicks it — so the handler that runs is the pill's
  // own, with the pill as its currentTarget and the same closest(".survey-
  // card-wrap") it has always resolved. The pill is display:none in the frame,
  // and a synthetic click does not care. A pill the picker has hidden with
  // [hidden] (Reposition on a card with no media) is not clicked: its proxy
  // is hidden too, but a stale click must not open a stage for a picture
  // that is not there.
  proxy(e) {
    const btn  = e.currentTarget
    const wrap = btn.closest(".survey-card-wrap")
    const real = wrap?.querySelector(btn.dataset.proxy)
    if (!real || real.hidden) return
    real.click()
  }
}
