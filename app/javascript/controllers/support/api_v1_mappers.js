const REQUIRED_ERROR_KEYS = ["code", "message"]

function ensureObject(payload) {
  return payload && typeof payload === "object" ? payload : {}
}

function ensureArray(value) {
  return Array.isArray(value) ? value : []
}

export function mapApiError(payload, fallbackMessage = "Request failed.") {
  const envelope = ensureObject(payload)
  const error = ensureObject(envelope.error)
  const hasRequiredKeys = REQUIRED_ERROR_KEYS.every((key) => Object.prototype.hasOwnProperty.call(error, key))

  if (!hasRequiredKeys) {
    return { code: "internal_error", message: fallbackMessage, details: {}, correlationId: null }
  }

  return {
    code: String(error.code),
    message: String(error.message),
    details: ensureObject(error.details),
    correlationId: error.correlation_id || null
  }
}

export function mapDeleteUnlockResponse(payload) {
  const envelope = ensureObject(payload)
  const unlock = ensureObject(envelope.unlock)

  return {
    token: String(unlock.token || ""),
    expiresAt: unlock.expires_at || null
  }
}

export function mapDeletionPlanResponse(payload) {
  const envelope = ensureObject(payload)
  const plan = ensureObject(envelope.plan)

  return {
    targetCount: Number(plan.target_count || 0),
    totalReclaimableBytes: Number(plan.total_reclaimable_bytes || 0),
    warnings: ensureArray(plan.warnings).map((entry) => String(entry)),
    blockers: ensureArray(plan.blockers),
    plannedMediaFileIds: ensureArray(plan.planned_media_file_ids).map((entry) => Number(entry)).filter((entry) => Number.isFinite(entry)),
    actionContext: ensureObject(plan.action_context)
  }
}

export function mapDeletionRunCreateResponse(payload) {
  const envelope = ensureObject(payload)
  const run = ensureObject(envelope.deletion_run)

  return {
    id: Number(run.id),
    status: String(run.status || "queued")
  }
}

export function mapSyncRunStreamEvent(payload) {
  const event = ensureObject(payload)
  const progress = ensureObject(event.progress)

  return {
    event: String(event.event || ""),
    id: Number(event.id || 0),
    status: String(event.status || ""),
    trigger: String(event.trigger || ""),
    phase: event.phase || null,
    phaseLabel: event.phase_label || null,
    progress: {
      percentComplete: Number(progress.percent_complete || 0),
      completedPhases: Number(progress.completed_phases || 0),
      totalPhases: Number(progress.total_phases || 0)
    },
    queuedNext: Boolean(event.queued_next),
    errorCode: event.error_code || null,
    correlationId: event.correlation_id || null
  }
}

export function mapDeletionRunStreamEvent(payload) {
  const event = ensureObject(payload)

  return {
    event: String(event.event || ""),
    id: Number(event.id || 0),
    status: String(event.status || ""),
    summary: ensureObject(event.summary),
    correlationId: event.correlation_id || null
  }
}

export function mapDeletionActionStreamEvent(payload) {
  const event = ensureObject(payload)

  return {
    event: String(event.event || ""),
    id: Number(event.id || 0),
    deletionRunId: Number(event.deletion_run_id || 0),
    mediaFileId: Number(event.media_file_id || 0),
    status: String(event.status || ""),
    errorCode: event.error_code || null,
    correlationId: event.correlation_id || null
  }
}
