import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="integration-kind-tuners"
export default class extends Controller {
  static targets = ["kindField", "group"]

  connect() {
    this.sync()
  }

  kindChanged() {
    this.sync()
  }

  sync() {
    const selectedKind = this.selectedKind()

    this.groupTargets.forEach((group) => {
      const active = selectedKind === group.dataset.kind
      group.hidden = !active
      group.classList.toggle("hidden", !active)
      group.querySelectorAll("input, select, textarea").forEach((element) => {
        element.disabled = !active
      })
    })
  }

  selectedKind() {
    if (!this.hasKindFieldTarget) {
      return null
    }

    const select = this.kindFieldTarget.querySelector("select")
    return select ? select.value : null
  }
}
