import { Controller } from "@hotwired/stimulus"
import { createRunsSubscription } from "channels/runs_channel"

const CONNECTION_CHECK_INTERVAL_MS = 1_000
const DISCONNECTED_GRACE_MS = 10_000
const FALLBACK_POLL_START_MS = 5_000
const FALLBACK_POLL_MAX_MS = 30_000

// Connects to data-controller="stream-status"
export default class extends Controller {
  static targets = ["syncStatus", "deletionStatus"]

  connect() {
    this.connectionState = "connecting"
    this.disconnectedAt = null
    this.nextPollAt = null
    this.currentPollIntervalMs = FALLBACK_POLL_START_MS
    this.refreshInFlight = false
    this.pollTimer = window.setInterval(() => this.pollForSnapshotRefresh(), CONNECTION_CHECK_INTERVAL_MS)
    this.subscription = createRunsSubscription(
      (payload) => this.handleStreamEvent(payload),
      {
        connected: () => this.handleStreamConnected(),
        disconnected: () => this.handleStreamDisconnected(),
        rejected: () => this.handleStreamRejected()
      }
    )
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

  handleStreamConnected() {
    const recoveredFromDisconnect = this.connectionState === "disconnected" || this.connectionState === "rejected"
    this.connectionState = "connected"
    this.disconnectedAt = null
    this.nextPollAt = null
    this.currentPollIntervalMs = FALLBACK_POLL_START_MS

    if (!recoveredFromDisconnect) {
      return
    }

    const connectedAt = new Date().toLocaleTimeString()
    this.setStatusMessage(`Realtime stream reconnected at ${connectedAt}.`)
    void this.refreshSnapshotsAfterReconnect()
  }

  handleStreamDisconnected() {
    if (this.connectionState === "disconnected") {
      return
    }

    this.connectionState = "disconnected"
    this.disconnectedAt = Date.now()
    this.nextPollAt = this.disconnectedAt + DISCONNECTED_GRACE_MS
    this.currentPollIntervalMs = FALLBACK_POLL_START_MS
    this.setStatusMessage("Realtime stream disconnected; retrying websocket before polling fallback.")
  }

  handleStreamRejected() {
    if (this.connectionState === "rejected") {
      return
    }

    this.connectionState = "rejected"
    this.disconnectedAt = Date.now()
    this.nextPollAt = this.disconnectedAt + DISCONNECTED_GRACE_MS
    this.currentPollIntervalMs = FALLBACK_POLL_START_MS
    this.setStatusMessage("Realtime stream subscription rejected; retrying websocket before polling fallback.")
  }

  handleStreamEvent(payload) {
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

    if (!this.shouldUsePollingFallback()) {
      return
    }

    if (this.nextPollAt && Date.now() < this.nextPollAt) {
      return
    }

    this.scheduleNextPollingAttempt()
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

      if (this.shouldUsePollingFallback()) {
        const refreshedAt = new Date().toLocaleTimeString()
        this.setStatusMessage(`Realtime stream unavailable; snapshot refreshed via polling at ${refreshedAt}.`)
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

  shouldUsePollingFallback() {
    return this.connectionState === "disconnected" || this.connectionState === "rejected"
  }

  scheduleNextPollingAttempt() {
    this.nextPollAt = Date.now() + this.currentPollIntervalMs
    this.currentPollIntervalMs = Math.min(this.currentPollIntervalMs * 2, FALLBACK_POLL_MAX_MS)
  }

  setStatusMessage(message) {
    if (this.hasSyncStatusTarget) {
      this.syncStatusTarget.textContent = message
    }
    if (this.hasDeletionStatusTarget) {
      this.deletionStatusTarget.textContent = message
    }
  }

  async refreshSnapshotsAfterReconnect() {
    if (document.hidden || this.refreshInFlight) {
      return
    }

    this.refreshInFlight = true
    try {
      let refreshed = false
      if (this.hasRunsSnapshot()) {
        refreshed = await this.refreshRunsSnapshotsFromPolling()
      }

      if (!refreshed && this.hasDeletionRunSnapshot()) {
        await this.refreshDeletionRunSnapshotFromPolling()
      }
    } catch (_error) {
      // Keep reconnect recovery best-effort to avoid UI interruptions.
    } finally {
      this.refreshInFlight = false
    }
  }
}
