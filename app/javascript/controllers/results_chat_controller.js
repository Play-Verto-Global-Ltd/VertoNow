import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"

export default class extends Controller {
  static targets = ["messages", "input", "sendBtn", "panel", "fab"]
  static values  = { url: String, theme: String }

  _messages = []
  _loading  = false
  _greeted  = false

  // The greeting waits for the panel to be opened. It used to be written at
  // connect, which was free when the chat was a permanent column and is not
  // now: a closed panel would announce itself to a screen reader on every
  // results page load, before anyone had asked for it.
  toggle() {
    this.panelTarget.classList.contains("is-open") ? this.close() : this.open()
  }

  open() {
    if (!this._greeted) {
      this._greeted = true
      this._addMessage("assistant", `Hi! I'm Verto. I've analysed the results for "${this.themeValue}". Ask me anything about the responses!`)
    }
    this.panelTarget.classList.add("is-open")
    this.fabTarget.classList.add("is-open")
    this.fabTarget.setAttribute("aria-expanded", "true")
    this.inputTarget.focus()
  }

  close() {
    this.panelTarget.classList.remove("is-open")
    this.fabTarget.classList.remove("is-open")
    this.fabTarget.setAttribute("aria-expanded", "false")
    // Focus goes back to the control that opened it, or it lands on <body>
    // and the next Tab starts from the top of the page.
    this.fabTarget.focus()
  }

  closeOnEsc() {
    if (this.panelTarget.classList.contains("is-open")) this.close()
  }

  send() {
    const text = this.inputTarget.value.trim()
    if (!text || this._loading) return

    this._loading = true
    this.inputTarget.value = ""
    this.sendBtnTarget.disabled = true

    this._addMessage("user", text)
    this._messages.push({ role: "user", content: text })

    const aiDiv  = this._addMessage("assistant", "")
    const bubble = aiDiv.querySelector(".chat-ai-bubble")

    this._stream(bubble)
  }

  keydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.send()
    }
  }

  async _stream(bubble) {
    let aiText = ""
    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const res = await fetch(this.urlValue, {
        method:  "POST",
        headers: {
          "Content-Type": "application/json",
          ...(csrfToken ? { "X-CSRF-Token": csrfToken } : {})
        },
        body:    JSON.stringify({ messages: this._messages })
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)

      const reader = res.body.getReader()
      const dec    = new TextDecoder()

      const pump = async () => {
        const { done, value } = await reader.read()
        if (done) return
        aiText += dec.decode(value, { stream: true })
        bubble.textContent = aiText
        this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
        return pump()
      }
      await pump()
      this._messages.push({ role: "assistant", content: aiText })
    } catch (_) {
      bubble.textContent = t("results.chat_error")
    }

    this._loading = false
    this.sendBtnTarget.disabled = false
    this.inputTarget.focus()
  }

  _addMessage(role, text) {
    const wrap = document.createElement("div")

    if (role === "user") {
      wrap.style.cssText = "display:flex;justify-content:flex-end;margin-bottom:12px;padding:0 4px;"
      wrap.innerHTML = `<div style="max-width:82%;background:#01EACB;color:#fff;padding:10px 14px;border-radius:16px 16px 3px 16px;font-family:'ABeeZee',sans-serif;font-size:13px;line-height:1.55;">${this._esc(text)}</div>`
    } else {
      wrap.style.cssText = "display:flex;align-items:flex-start;gap:8px;margin-bottom:12px;padding:0 4px;"
      wrap.innerHTML = `
        <div style="width:24px;height:24px;flex-shrink:0;margin-top:3px;background:rgba(1,234,203,0.15);border-radius:7px;display:flex;align-items:center;justify-content:center;">
          <span style="font-size:11px;color:#01EACB;line-height:1;">✦</span>
        </div>
        <div class="chat-ai-bubble" style="flex:1;background:rgba(255,255,255,0.06);color:rgba(255,255,255,0.78);padding:10px 14px;border-radius:3px 16px 16px 16px;font-family:'ABeeZee',sans-serif;font-size:13px;line-height:1.6;white-space:pre-wrap;">${this._esc(text)}</div>`
    }

    this.messagesTarget.appendChild(wrap)
    this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
    return wrap
  }

  _esc(text) {
    const d = document.createElement("div")
    d.textContent = text
    return d.innerHTML
  }
}
