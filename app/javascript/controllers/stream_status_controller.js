import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="stream-status"
export default class extends Controller {
  static targets = ["syncStatus", "deletionStatus"]

  connect() {
    this.boundHandleStreamEvent = this.handleStreamEvent.bind(this)
    window.addEventListener("cullarr:stream-event", this.boundHandleStreamEvent)
  }

  disconnect() {
    window.removeEventListener("cullarr:stream-event", this.boundHandleStreamEvent)
  }

  handleStreamEvent(event) {
    const payload = event.detail || {}
    const eventName = String(payload.event || "")

    if (eventName === "sync_run.updated" && this.hasSyncStatusTarget) {
      const phaseLabel = payload.phaseLabel || payload.phase || "starting"
      const phaseSummary = payload.progress?.totalPhases
        ? `${payload.progress.completedPhases}/${payload.progress.totalPhases} phases`
        : "progress unavailable"
      const percent = Number(payload.progress?.percentComplete || 0).toFixed(1)
      this.syncStatusTarget.textContent = `Live sync update: run #${payload.id} is ${payload.status} at ${percent}% (${phaseSummary}, ${phaseLabel}).`
      return
    }

    if ((eventName === "deletion_run.updated" || eventName === "deletion_action.updated") && this.hasDeletionStatusTarget) {
      if (eventName === "deletion_run.updated") {
        this.deletionStatusTarget.textContent = `Live deletion run update: run #${payload.id} is ${payload.status}.`
        return
      }

      this.deletionStatusTarget.textContent = `Live deletion action update: action #${payload.id} is ${payload.status}.`
    }
  }
}
