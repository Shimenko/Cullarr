import consumer from "channels/consumer"
import {
  mapDeletionActionStreamEvent,
  mapDeletionRunStreamEvent,
  mapSyncRunStreamEvent
} from "controllers/support/api_v1_mappers"

export function createRunsSubscription(onEvent, callbacks = {}) {
  const onConnected = callbacks.connected
  const onDisconnected = callbacks.disconnected
  const onRejected = callbacks.rejected

  return consumer.subscriptions.create("RunsChannel", {
    connected() {
      if (typeof onConnected === "function") {
        onConnected()
      }
    },

    disconnected() {
      if (typeof onDisconnected === "function") {
        onDisconnected()
      }
    },

    rejected() {
      if (typeof onRejected === "function") {
        onRejected()
      }
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

      if (!mappedEvent || typeof onEvent !== "function") {
        return
      }

      onEvent(mappedEvent)
    }
  })
}
