import consumer from "channels/consumer"
import {
  mapDeletionActionStreamEvent,
  mapDeletionRunStreamEvent,
  mapSyncRunStreamEvent
} from "controllers/support/api_v1_mappers"

consumer.subscriptions.create("RunsChannel", {
  connected() {
  },

  disconnected() {
  },

  received(data) {
    const eventType = String(data?.event || "")
    let mappedEvent = null

    if (eventType === "sync_run.updated") {
      mappedEvent = mapSyncRunStreamEvent(data)
    } else if (eventType === "deletion_run.updated") {
      mappedEvent = mapDeletionRunStreamEvent(data)
    } else if (eventType === "deletion_action.updated") {
      mappedEvent = mapDeletionActionStreamEvent(data)
    }

    if (!mappedEvent) {
      return
    }

    window.dispatchEvent(new CustomEvent("cullarr:stream-event", { detail: mappedEvent }))
  }
})
