import { Controller } from "@hotwired/stimulus"
import { createRunsSubscription } from "channels/runs_channel"

const STREAM_STALE_AFTER_MS = 1_000
const POLL_INTERVAL_MS = 1_000

// Connects to data-controller="stream-status"
export default class extends Controller {
  static targets = ["syncStatus", "deletionStatus"]

  connect() {
    this.lastStreamEventAt = Date.now()
    this.refreshInFlight = false
    this.pollTimer = window.setInterval(() => this.pollForSnapshotRefresh(), POLL_INTERVAL_MS)
    this.subscription = createRunsSubscription((payload) => this.handleStreamEvent(payload))
  }

  disconnect() {
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
    if (this.pollTimer) {
      window.clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  handleStreamEvent(payload) {
    this.lastStreamEventAt = Date.now()

    const eventName = String(payload.event || "")

    if (eventName === "sync_run.updated" && this.hasSyncStatusTarget) {
      const phaseLabel = payload.phaseLabel || payload.phase || "starting"
      const phaseSummary = payload.progress?.totalPhases
        ? `${payload.progress.completedPhases}/${payload.progress.totalPhases} phases`
        : "progress unavailable"
      const percent = Number(payload.progress?.percentComplete || 0).toFixed(1)
      const phasePercent = Number(payload.progress?.currentPhasePercent || 0).toFixed(1)
      this.syncStatusTarget.textContent = `Live sync update: run #${payload.id} is ${payload.status} at ${percent}% overall (${phaseSummary}, ${phaseLabel} ${phasePercent}%).`
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

  async pollForSnapshotRefresh() {
    if (document.hidden || this.refreshInFlight) {
      return
    }

    const streamFresh = (Date.now() - this.lastStreamEventAt) < STREAM_STALE_AFTER_MS
    if (streamFresh) {
      return
    }

    this.refreshInFlight = true
    try {
      let refreshed = false
      if (this.hasRunsSnapshot()) {
        refreshed = await this.refreshRunsSnapshotsFromPolling()
      }

      if (!refreshed && this.hasDeletionRunSnapshot()) {
        refreshed = await this.refreshDeletionRunSnapshotFromPolling()
      }

      if (!refreshed) {
        return
      }

      this.lastStreamEventAt = Date.now()
      const refreshedAt = new Date().toLocaleTimeString()
      if (this.hasSyncStatusTarget) {
        this.syncStatusTarget.textContent = `Stream was stale; snapshot refreshed via polling at ${refreshedAt}.`
      }
      if (this.hasDeletionStatusTarget) {
        this.deletionStatusTarget.textContent = `Stream was stale; snapshot refreshed via polling at ${refreshedAt}.`
      }
    } catch (_error) {
      // Keep the page stable; polling is best-effort fallback.
    } finally {
      this.refreshInFlight = false
    }
  }

  hasRunsSnapshot() {
    return Boolean(document.querySelector("#sync-runs-snapshot") || document.querySelector("#deletion-runs-snapshot"))
  }

  hasDeletionRunSnapshot() {
    return Boolean(document.querySelector("#deletion-run-snapshot"))
  }

  async refreshRunsSnapshotsFromPolling() {
    const response = await fetch("/runs", {
      headers: { Accept: "text/html" },
      credentials: "same-origin"
    })
    if (!response.ok) {
      return false
    }

    const html = await response.text()
    const parsed = new DOMParser().parseFromString(html, "text/html")

    let replaced = false
    replaced = this.replaceSnapshot("#sync-runs-snapshot", parsed) || replaced
    replaced = this.replaceSnapshot("#deletion-runs-snapshot", parsed) || replaced

    return replaced
  }

  async refreshDeletionRunSnapshotFromPolling() {
    const response = await fetch(window.location.pathname, {
      headers: { Accept: "text/html" },
      credentials: "same-origin"
    })
    if (!response.ok) {
      return false
    }

    const html = await response.text()
    const parsed = new DOMParser().parseFromString(html, "text/html")
    return this.replaceSnapshot("#deletion-run-snapshot", parsed)
  }

  replaceSnapshot(selector, parsedDocument) {
    const target = document.querySelector(selector)
    const source = parsedDocument.querySelector(selector)
    if (!target || !source) {
      return false
    }

    target.innerHTML = source.innerHTML
    return true
  }
}
