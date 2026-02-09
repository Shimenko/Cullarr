import { Controller } from "@hotwired/stimulus"
import { prefersReducedMotion } from "controllers/support/motion_preferences"

// Connects to data-controller="hold-to-confirm"
export default class extends Controller {
  static targets = ["label", "progress"]

  static values = {
    confirmedText: { type: String, default: "Confirmed" },
    duration: { type: Number, default: 800 },
    submitOnConfirm: { type: Boolean, default: false },
    idleText: String
  }

  connect() {
    this.animationFrameId = null
    this.completionTimeoutId = null
    this.holding = false
    this.confirmed = false
    this.startedAt = 0
    this.reducedMotion = prefersReducedMotion()
    this.idleLabelText = this.idleTextValue || this.currentLabelText()
    this.reset()
  }

  disconnect() {
    this.clearTimers()
  }

  start(event) {
    if (this.confirmed || this.holding) {
      return
    }

    if (event.type === "keydown" && !this.supportedKey(event)) {
      return
    }

    if (event.type === "pointerdown" && event.button !== 0) {
      return
    }

    if (event.type === "keydown") {
      event.preventDefault()
    }

    this.holding = true
    this.startedAt = performance.now()
    this.element.dataset.holdToConfirmState = "holding"
    this.updateProgress(0)

    if (this.reducedMotion) {
      this.completionTimeoutId = window.setTimeout(() => this.complete(), this.durationValue)
      return
    }

    const step = (timestamp) => {
      if (!this.holding || this.confirmed) {
        return
      }

      const elapsed = timestamp - this.startedAt
      const percent = Math.min(100, (elapsed / this.durationValue) * 100)
      this.updateProgress(percent)

      if (percent >= 100) {
        this.complete()
        return
      }

      this.animationFrameId = window.requestAnimationFrame(step)
    }

    this.animationFrameId = window.requestAnimationFrame(step)
  }

  cancel(event) {
    if (!this.holding || this.confirmed) {
      return
    }

    if (event && event.type === "keyup" && !this.supportedKey(event)) {
      return
    }

    if (event && event.type === "pointerup" && event.button !== 0) {
      return
    }

    this.holding = false
    this.clearTimers()
    this.updateProgress(0)
    this.setLabel(this.idleLabelText)
    this.element.dataset.holdToConfirmState = "idle"
    this.dispatch("canceled")
  }

  reset() {
    this.clearTimers()
    this.holding = false
    this.confirmed = false
    this.updateProgress(0)
    this.setLabel(this.idleLabelText)
    this.element.dataset.holdToConfirmState = "idle"
  }

  complete() {
    if (this.confirmed) {
      return
    }

    this.clearTimers()
    this.holding = false
    this.confirmed = true
    this.updateProgress(100)
    this.setLabel(this.confirmedTextValue)
    this.element.dataset.holdToConfirmState = "confirmed"
    this.dispatch("confirmed")

    if (this.submitOnConfirmValue) {
      this.submitClosestForm()
    }
  }

  currentLabelText() {
    if (this.hasLabelTarget) {
      return this.labelTarget.textContent.trim()
    }

    return this.element.textContent.trim()
  }

  setLabel(value) {
    if (!this.hasLabelTarget) {
      return
    }

    this.labelTarget.textContent = value
  }

  updateProgress(percent) {
    const roundedPercent = Math.max(0, Math.min(100, percent))
    this.element.setAttribute("aria-valuenow", String(Math.round(roundedPercent)))

    if (!this.hasProgressTarget) {
      return
    }

    this.progressTarget.style.width = `${roundedPercent}%`
  }

  submitClosestForm() {
    const form = this.element.form || this.element.closest("form")
    if (!form) {
      return
    }

    if (typeof form.requestSubmit === "function") {
      form.requestSubmit()
      return
    }

    form.submit()
  }

  supportedKey(event) {
    return event.key === "Enter" || event.key === " " || event.code === "Space"
  }

  clearTimers() {
    if (this.animationFrameId !== null) {
      window.cancelAnimationFrame(this.animationFrameId)
      this.animationFrameId = null
    }

    if (this.completionTimeoutId !== null) {
      window.clearTimeout(this.completionTimeoutId)
      this.completionTimeoutId = null
    }
  }
}
