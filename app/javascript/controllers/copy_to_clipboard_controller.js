import { Controller } from "@hotwired/stimulus"
import { prefersReducedMotion } from "controllers/support/motion_preferences"

// Connects to data-controller="copy-to-clipboard"
export default class extends Controller {
  static targets = ["source", "feedback"]

  static values = {
    errorMessage: { type: String, default: "Copy unavailable in this browser." },
    resetDelay: { type: Number, default: 1800 },
    successMessage: { type: String, default: "Copied to clipboard." },
    text: String
  }

  connect() {
    this.feedbackResetTimeoutId = null
    this.reducedMotion = prefersReducedMotion()
  }

  disconnect() {
    this.clearFeedbackResetTimer()
  }

  async copy(event) {
    event.preventDefault()
    const text = this.resolveText(event)

    if (!text) {
      return
    }

    try {
      await this.writeToClipboard(text)
      this.showFeedback(this.successMessageValue, "success")
      this.dispatch("success", { detail: { text } })
    } catch (error) {
      this.showFeedback(this.errorMessageValue, "error")
      this.dispatch("error", { detail: { message: error.message } })
    }
  }

  resolveText(event) {
    if (event?.params?.text) {
      return event.params.text
    }

    if (this.textValue) {
      return this.textValue
    }

    if (!this.hasSourceTarget) {
      return ""
    }

    if (this.sourceTarget.matches("input, textarea")) {
      return this.sourceTarget.value
    }

    return this.sourceTarget.textContent.trim()
  }

  async writeToClipboard(text) {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text)
      return
    }

    const input = document.createElement("textarea")
    input.value = text
    input.setAttribute("readonly", "readonly")
    input.style.position = "absolute"
    input.style.left = "-9999px"
    document.body.appendChild(input)
    input.select()

    const copied = document.execCommand("copy")
    document.body.removeChild(input)

    if (!copied) {
      throw new Error("copy_failed")
    }
  }

  showFeedback(message, state) {
    if (!this.hasFeedbackTarget) {
      return
    }

    this.feedbackTarget.hidden = false
    this.feedbackTarget.textContent = message
    this.feedbackTarget.dataset.copyState = state

    if (!this.reducedMotion) {
      this.feedbackTarget.classList.add("ui-copy-feedback-pulse")
    }

    this.clearFeedbackResetTimer()
    this.feedbackResetTimeoutId = window.setTimeout(() => {
      this.feedbackTarget.classList.remove("ui-copy-feedback-pulse")
    }, this.resetDelayValue)
  }

  clearFeedbackResetTimer() {
    if (this.feedbackResetTimeoutId === null) {
      return
    }

    window.clearTimeout(this.feedbackResetTimeoutId)
    this.feedbackResetTimeoutId = null
  }
}
