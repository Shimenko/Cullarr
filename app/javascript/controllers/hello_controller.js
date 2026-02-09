import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  /** @type {HTMLElement} */
  element

  connect() {
    this.element.textContent = "Hello World!"
  }
}
