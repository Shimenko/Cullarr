import { Controller } from "@hotwired/stimulus"
import { prefersReducedMotion } from "controllers/support/motion_preferences"

// Connects to data-controller="row-expand"
export default class extends Controller {
  static targets = ["content", "toggle"]

  static values = {
    expanded: { type: Boolean, default: false }
  }

  connect() {
    this.reducedMotion = prefersReducedMotion()
    this.syncState()
  }

  toggle(event) {
    if (event.type === "keydown" && !this.supportedKey(event)) {
      return
    }

    if (event.type === "keydown") {
      event.preventDefault()
    }

    this.expandedValue = !this.expandedValue
    this.syncState()
    this.dispatch("toggled", { detail: { expanded: this.expandedValue } })
  }

  expand() {
    this.expandedValue = true
    this.syncState()
  }

  collapse() {
    this.expandedValue = false
    this.syncState()
  }

  syncState() {
    const expanded = this.expandedValue

    this.element.dataset.rowExpandState = expanded ? "expanded" : "collapsed"
    this.element.dataset.rowExpandReducedMotion = this.reducedMotion ? "true" : "false"

    if (this.hasContentTarget) {
      this.contentTarget.hidden = !expanded
      this.contentTarget.setAttribute("aria-hidden", String(!expanded))
    }

    if (this.hasToggleTarget) {
      this.toggleTargets.forEach((target) => {
        target.setAttribute("aria-expanded", String(expanded))
      })
      return
    }

    this.element.setAttribute("aria-expanded", String(expanded))
  }

  supportedKey(event) {
    return event.key === "Enter" || event.key === " " || event.code === "Space"
  }
}
