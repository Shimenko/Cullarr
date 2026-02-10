import { Controller } from "@hotwired/stimulus"
import {
  mapApiError,
  mapDeleteUnlockResponse,
  mapDeletionPlanResponse,
  mapDeletionRunCreateResponse
} from "controllers/support/api_v1_mappers"

// Connects to data-controller="candidates-workflow"
export default class extends Controller {
  static targets = [
    "candidateCheckbox",
    "versionCheckbox",
    "plexUserCheckbox",
    "unlockPassword",
    "unlockStatus",
    "planButton",
    "planSummary",
    "planWarnings",
    "planBlockers",
    "planSideEffects",
    "planTargetCount",
    "planTotalBytes",
    "planStatus",
    "confirmButton"
  ]

  static values = {
    scope: String,
    unlockUrl: String,
    planUrl: String,
    createUrl: String,
    runPathTemplate: String
  }

  connect() {
    this.unlockToken = null
    this.unlockExpiresAt = null
    this.plannedMediaFileIds = []
    this.currentPlan = null
    this.element.dataset.workflowReady = "true"
    this.refreshControlState()
  }

  selectionChanged() {
    this.clearPlan()
    this.refreshControlState()
  }

  async unlockDeleteMode(event) {
    event.preventDefault()
    this.renderStatus(this.unlockStatusTarget, "Unlocking delete mode...")

    const password = this.unlockPasswordTarget.value.trim()
    if (password.length === 0) {
      this.renderStatus(this.unlockStatusTarget, "Password is required to unlock delete mode.")
      return
    }

    try {
      const response = await this.jsonRequest(this.unlockUrlValue, {
        method: "POST",
        body: JSON.stringify({ password })
      })

      const payload = await response.json()
      if (!response.ok) {
        const error = mapApiError(payload, "Delete mode unlock failed.")
        this.renderStatus(this.unlockStatusTarget, `${error.message} (${error.code})`)
        this.unlockToken = null
        this.unlockExpiresAt = null
        this.refreshControlState()
        return
      }

      const unlock = mapDeleteUnlockResponse(payload)
      if (!unlock.token) {
        this.renderStatus(this.unlockStatusTarget, "Unlock response is missing token data.")
        this.unlockToken = null
        this.unlockExpiresAt = null
        this.refreshControlState()
        return
      }

      this.unlockToken = unlock.token
      this.unlockExpiresAt = unlock.expiresAt
      const expiresLabel = unlock.expiresAt ? new Date(unlock.expiresAt).toLocaleString() : "unknown"
      this.renderStatus(this.unlockStatusTarget, `Delete mode unlocked until ${expiresLabel}.`)
      this.refreshControlState()
    } catch (_error) {
      this.renderStatus(this.unlockStatusTarget, "Delete mode unlock request failed.")
      this.unlockToken = null
      this.unlockExpiresAt = null
      this.refreshControlState()
    }
  }

  async reviewPlan(event) {
    event.preventDefault()
    const selection = this.buildSelectionPayload()

    if (!selection.valid) {
      this.renderStatus(this.planStatusTarget, selection.errorMessage)
      this.refreshControlState()
      return
    }

    if (!this.unlockToken) {
      this.renderStatus(this.planStatusTarget, "Unlock delete mode before requesting a plan.")
      this.refreshControlState()
      return
    }

    const requestPayload = {
      unlock_token: this.unlockToken,
      scope: this.scopeValue,
      selection: selection.selection,
      version_selection: selection.versionSelection,
      plex_user_ids: this.selectedPlexUserIds()
    }

    this.renderStatus(this.planStatusTarget, "Planning deletion run...")

    try {
      const response = await this.jsonRequest(this.planUrlValue, {
        method: "POST",
        body: JSON.stringify(requestPayload)
      })
      const payload = await response.json()

      if (!response.ok) {
        const error = mapApiError(payload, "Deletion plan request failed.")
        this.renderStatus(this.planStatusTarget, `${error.message} (${error.code})`)
        this.clearPlan()
        this.refreshControlState()
        return
      }

      const plan = mapDeletionPlanResponse(payload)
      this.currentPlan = plan
      this.plannedMediaFileIds = plan.plannedMediaFileIds
      this.renderPlan(plan)
      this.renderStatus(this.planStatusTarget, `Plan ready for ${plan.targetCount} target(s).`)
      this.refreshControlState()
    } catch (_error) {
      this.renderStatus(this.planStatusTarget, "Deletion plan request failed.")
      this.clearPlan()
      this.refreshControlState()
    }
  }

  async executeDeletionRun(event) {
    event.preventDefault()
    if (!this.currentPlan || this.plannedMediaFileIds.length === 0) {
      this.renderStatus(this.planStatusTarget, "Review a valid plan before confirming deletion.")
      this.resetHoldButton()
      return
    }

    const requestPayload = {
      unlock_token: this.unlockToken,
      scope: this.scopeValue,
      planned_media_file_ids: this.plannedMediaFileIds,
      plex_user_ids: this.selectedPlexUserIds()
    }

    this.renderStatus(this.planStatusTarget, "Submitting deletion run...")

    try {
      const response = await this.jsonRequest(this.createUrlValue, {
        method: "POST",
        body: JSON.stringify(requestPayload)
      })
      const payload = await response.json()

      if (!response.ok) {
        const error = mapApiError(payload, "Deletion run request failed.")
        this.renderStatus(this.planStatusTarget, `${error.message} (${error.code})`)
        this.resetHoldButton()
        return
      }

      const run = mapDeletionRunCreateResponse(payload)
      this.renderStatus(this.planStatusTarget, `Deletion run #${run.id} queued.`)
      window.location.assign(this.runPathTemplateValue.replace("__RUN_ID__", String(run.id)))
    } catch (_error) {
      this.renderStatus(this.planStatusTarget, "Deletion run request failed.")
      this.resetHoldButton()
    }
  }

  clearPlan() {
    this.currentPlan = null
    this.plannedMediaFileIds = []
    this.planSummaryTarget.hidden = true
    this.planWarningsTarget.innerHTML = ""
    this.planBlockersTarget.innerHTML = ""
    this.planSideEffectsTarget.innerHTML = ""
    this.planTargetCountTarget.textContent = "0"
    this.planTotalBytesTarget.textContent = "0"
  }

  refreshControlState() {
    const selection = this.buildSelectionPayload()
    const hasUnlock = Boolean(this.unlockToken)

    this.planButtonTarget.disabled = !(hasUnlock && selection.valid)
    this.confirmButtonTarget.disabled = !(hasUnlock && this.currentPlan && this.plannedMediaFileIds.length > 0)
  }

  renderPlan(plan) {
    this.planSummaryTarget.hidden = false
    this.planTargetCountTarget.textContent = String(plan.targetCount)
    this.planTotalBytesTarget.textContent = String(plan.totalReclaimableBytes)

    this.planWarningsTarget.innerHTML = ""
    plan.warnings.forEach((warning) => {
      const item = document.createElement("li")
      item.textContent = warning
      this.planWarningsTarget.appendChild(item)
    })

    this.planBlockersTarget.innerHTML = ""
    plan.blockers.forEach((blocker) => {
      const item = document.createElement("li")
      const mediaFileId = blocker.media_file_id || "unknown"
      const flags = Array.isArray(blocker.blocker_flags) ? blocker.blocker_flags.join(", ") : "unknown"
      item.textContent = `media_file_id=${mediaFileId} blocked by ${flags}`
      this.planBlockersTarget.appendChild(item)
    })

    this.planSideEffectsTarget.innerHTML = ""
    const sideEffects = this.buildSideEffects(plan.actionContext)
    sideEffects.forEach((sideEffect) => {
      const item = document.createElement("li")
      item.textContent = sideEffect
      this.planSideEffectsTarget.appendChild(item)
    })
  }

  renderStatus(target, message) {
    target.textContent = message
  }

  selectedCandidateCheckboxes() {
    return this.candidateCheckboxTargets.filter((checkbox) => checkbox.checked && !checkbox.disabled)
  }

  selectedPlexUserIds() {
    return this.plexUserCheckboxTargets.filter((checkbox) => checkbox.checked).map((checkbox) => Number(checkbox.value)).filter((value) => Number.isFinite(value))
  }

  buildSelectionPayload() {
    const selectedCandidates = this.selectedCandidateCheckboxes()
    if (selectedCandidates.length === 0) {
      return { valid: false, errorMessage: "Select at least one eligible candidate before planning." }
    }

    const selectionIds = selectedCandidates
      .map((checkbox) => Number(checkbox.dataset.selectionId))
      .filter((value) => Number.isFinite(value))
    const selectionKey = this.selectionKeyForScope(this.scopeValue)
    if (!selectionKey || selectionIds.length === 0) {
      return { valid: false, errorMessage: "Candidate selection payload is invalid for the current scope." }
    }

    const versionSelection = {}
    for (const checkbox of selectedCandidates) {
      const requiredGroups = this.parseRequiredGroups(checkbox.dataset.requiredGroups)
      for (const groupKey of requiredGroups) {
        const checkedVersionIds = this.versionCheckboxTargets
          .filter((versionCheckbox) => versionCheckbox.dataset.groupKey === groupKey && versionCheckbox.checked)
          .map((versionCheckbox) => Number(versionCheckbox.value))
          .filter((value) => Number.isFinite(value))

        if (checkedVersionIds.length === 0) {
          return {
            valid: false,
            errorMessage: `Explicit version selection is required for ${groupKey}.`
          }
        }

        versionSelection[groupKey] = checkedVersionIds
      }
    }

    return {
      valid: true,
      selection: { [selectionKey]: selectionIds },
      versionSelection: versionSelection
    }
  }

  selectionKeyForScope(scope) {
    switch (scope) {
      case "movie":
        return "movie_ids"
      case "tv_episode":
        return "episode_ids"
      case "tv_season":
        return "season_ids"
      case "tv_show":
        return "series_ids"
      default:
        return null
    }
  }

  parseRequiredGroups(rawGroups) {
    if (!rawGroups) {
      return []
    }

    return rawGroups.split(",").map((entry) => entry.trim()).filter((entry) => entry.length > 0)
  }

  async jsonRequest(url, options) {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
    const headers = {
      Accept: "application/json",
      "Content-Type": "application/json"
    }

    if (csrfToken) {
      headers["X-CSRF-Token"] = csrfToken
    }

    return fetch(url, {
      credentials: "same-origin",
      ...options,
      headers: {
        ...headers,
        ...(options.headers || {})
      }
    })
  }

  resetHoldButton() {
    const holdController = this.application.getControllerForElementAndIdentifier(this.confirmButtonTarget, "hold-to-confirm")
    if (holdController && typeof holdController.reset === "function") {
      holdController.reset()
    }
  }

  buildSideEffects(actionContext) {
    const effects = []

    Object.entries(actionContext || {}).forEach(([mediaFileId, context]) => {
      if (context.should_unmonitor) {
        effects.push(`media_file_id=${mediaFileId}: unmonitor ${context.unmonitor_kind} ${context.unmonitor_target_id}`)
      }

      if (context.should_tag) {
        effects.push(`media_file_id=${mediaFileId}: apply tag to ${context.tag_kind} ${context.tag_target_id}`)
      }
    })

    if (effects.length === 0) {
      return ["No unmonitor/tag side effects for selected targets."]
    }

    return effects
  }
}
