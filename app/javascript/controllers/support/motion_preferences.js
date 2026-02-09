export function prefersReducedMotion() {
  const hasMatchMedia = typeof window.matchMedia === "function"

  if (!hasMatchMedia) {
    return false
  }

  return window.matchMedia("(prefers-reduced-motion: reduce)").matches
}
