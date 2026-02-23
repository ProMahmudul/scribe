let Hooks = {}

// Only emit debug logs in development builds.
// esbuild replaces process.env.NODE_ENV at bundle time; guard in case it doesn't.
const __DEV__ =
  typeof process !== "undefined" && process.env.NODE_ENV !== "production"

Hooks.Clipboard = {
  mounted() {
    this.el.addEventListener("click", () => this._handleClick())
  },

  _handleClick() {
    const text = this._resolveText()
    if (__DEV__) {
      console.debug("[Clipboard] copying", text?.length ?? 0, "chars")
    }
    if (!text) return
    this._copy(text)
  },

  // Prefer the live textarea value inside the same form (captures user edits).
  // Fall back to the data-clipboard-text attribute rendered onto the button.
  _resolveText() {
    const form = this.el.closest("form")
    if (form) {
      const ta = form.querySelector("textarea")
      if (ta) return ta.value
    }
    return this.el.dataset.clipboardText || ""
  },

  _copy(text) {
    // navigator.clipboard requires a secure context (HTTPS or localhost).
    if (window.isSecureContext && navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(text)
        .then(() => this._onCopied())
        .catch((err) => {
          if (__DEV__) {
            console.warn("[Clipboard] navigator.clipboard rejected, using fallback:", err)
          }
          this._execCommandFallback(text)
        })
    } else {
      if (__DEV__) {
        console.debug(
          "[Clipboard] navigator.clipboard unavailable (insecure context?), using execCommand fallback"
        )
      }
      this._execCommandFallback(text)
    }
  },

  // document.execCommand("copy") is deprecated but remains the only reliable
  // option in non-HTTPS environments and older browsers.
  _execCommandFallback(text) {
    const ta = document.createElement("textarea")
    ta.value = text
    // Place off-screen so the temporary element does not cause layout shift or
    // a visible flash.
    Object.assign(ta.style, {
      position: "fixed",
      top: "-9999px",
      left: "-9999px",
      width: "1px",
      height: "1px",
      opacity: "0",
      pointerEvents: "none",
    })
    document.body.appendChild(ta)
    ta.focus()
    ta.select()
    let ok = false
    try {
      ok = document.execCommand("copy")
    } catch (err) {
      if (__DEV__) {
        console.warn("[Clipboard] execCommand('copy') threw:", err)
      }
    }
    document.body.removeChild(ta)
    if (ok) this._onCopied()
  },

  _onCopied() {
    // Route the event to the owning LiveComponent so it can switch the button
    // label to "Copied!" and back.  pushEventTo(this.el, ...) uses the
    // data-phx-component attribute that Phoenix sets on each live_component
    // root element, so no phx-target is required.
    this.pushEventTo(this.el, "copied-to-clipboard", {})
    setTimeout(() => this.pushEventTo(this.el, "reset-copied", {}), 2000)
  },
}

export default Hooks
