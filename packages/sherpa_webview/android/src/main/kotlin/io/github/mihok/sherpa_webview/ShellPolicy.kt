package io.github.mihok.sherpa_webview

import java.net.URI

/**
 * Pure-JVM policy decisions of the native layer (JVM unit-tested; no Android
 * classes). Native code is a checked pipe: every protocol decision is Dart.
 */
object ShellPolicy {
  /** The shell's virtual origin. `.invalid` is reserved and never resolves. */
  const val SHELL_SCHEME = "https"
  const val SHELL_HOST = "mcp-view.sherpa.invalid"
  const val SHELL_ORIGIN = "$SHELL_SCHEME://$SHELL_HOST"
  const val SHELL_BASE_URL = "$SHELL_ORIGIN/"

  /** Name of the injected bridge object (addWebMessageListener). */
  const val BRIDGE_OBJECT = "__sherpaHost"

  const val CSP_PLACEHOLDER = "__SHERPA_CSP__"

  /**
   * The no-network policy (identical to Dart's `McpAppCsp.build()`); used
   * whenever the policy Dart sent fails [isValidCsp].
   */
  const val DEFAULT_CSP =
    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; " +
      "font-src 'none'; media-src 'none'; connect-src 'none'; frame-src 'none'; child-src 'none'; " +
      "worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; manifest-src 'none'"

  private val CSP_CHARS = Regex("^[a-z0-9 :;'*./-]+$")
  private val PROFILE_KEY = Regex("^[0-9a-f]{8,64}$")

  /** Hard cap on one shell string, whatever the config says. */
  const val HARD_MAX_MESSAGE_CHARS = 4 * 1024 * 1024 + 4096

  /**
   * A policy native code accepts: only the characters Dart's builder emits
   * (no quotes that could close the meta attribute, no `<`, `>`, `&`), the
   * no-default prefix, and explicit connect-src / frame-src 'none'.
   */
  fun isValidCsp(csp: String): Boolean =
    csp.length <= 16384 &&
      CSP_CHARS.matches(csp) &&
      csp.startsWith("default-src 'none'; ") &&
      csp.contains("; frame-src 'none';") &&
      csp.contains("; connect-src ")

  /**
   * The shell document with [csp] (or [DEFAULT_CSP]) in its meta tag; null
   * when the template has no placeholder (fail closed: nothing is loaded).
   */
  fun renderShell(template: String, csp: String): String? {
    if (!template.contains(CSP_PLACEHOLDER)) return null
    return template.replaceFirst(CSP_PLACEHOLDER, if (isValidCsp(csp)) csp else DEFAULT_CSP)
  }

  /** The message-listener source check: the shell origin exactly. */
  fun isShellOrigin(scheme: String?, host: String?, port: Int): Boolean =
    scheme.equals(SHELL_SCHEME, ignoreCase = true) && host.equals(SHELL_HOST, ignoreCase = true) && (port == -1 || port == 443)

  /** Accepts a bridge message: main frame, shell origin, string, size. */
  fun acceptBridgeMessage(isMainFrame: Boolean, scheme: String?, host: String?, port: Int, length: Int, maxChars: Long): Boolean =
    isMainFrame && isShellOrigin(scheme, host, port) && length <= minOf(maxChars, HARD_MAX_MESSAGE_CHARS.toLong())

  /** Sub-frame navigations allowed: the View's srcdoc document only. */
  fun isAllowedSubframeUrl(url: String): Boolean = url == "about:srcdoc" || url == "about:blank"

  /** WebView profile name for a per-server key; null for a malformed key. */
  fun profileName(profileKey: String): String? = if (PROFILE_KEY.matches(profileKey)) "sherpa_mcp_$profileKey" else null

  fun clip(s: String, max: Int = 200): String = if (s.length <= max) s else s.substring(0, max) + "…"

  /**
   * Origins a request may reach (Android interception, defence in depth
   * behind the CSP). Entries are `scheme://[*.]host[:port]` as Dart
   * validated them; they are re-validated here and invalid ones dropped.
   */
  class OriginAllowlist(origins: List<String>) {
    private data class Entry(val scheme: String, val host: String, val port: Int, val wildcard: Boolean)

    private val entries: List<Entry> = origins.mapNotNull(::parse)

    val isEmpty: Boolean get() = entries.isEmpty()

    /** True for local schemes and for http(s)/ws(s) URLs of an allowed origin. */
    fun allows(url: String): Boolean {
      val lower = url.lowercase()
      if (lower.startsWith("data:") || lower.startsWith("blob:") || lower.startsWith("about:")) return true
      val uri = try {
        URI(url)
      } catch (_: Exception) {
        return false
      }
      val scheme = uri.scheme?.lowercase() ?: return false
      if (scheme != "https" && scheme != "wss") return false
      if (uri.rawUserInfo != null) return false
      val host = uri.host?.lowercase() ?: return false
      val port = if (uri.port == -1) 443 else uri.port
      return entries.any { e ->
        // CSP: an https source also matches wss (secure upgrade).
        val schemeOk = e.scheme == scheme || (e.scheme == "https" && scheme == "wss")
        val hostOk = if (e.wildcard) host.endsWith("." + e.host) else host == e.host
        schemeOk && hostOk && port == e.port
      }
    }

    private companion object {
      val SHAPE = Regex("^(https|wss)://(\\*\\.)?([a-z0-9-]+(?:\\.[a-z0-9-]+)+)(?::(\\d{1,5}))?$")

      fun parse(raw: String): Entry? {
        val m = SHAPE.matchEntire(raw.trim().lowercase()) ?: return null
        val port = m.groupValues[4].ifEmpty { null }?.toIntOrNull() ?: 443
        if (port !in 1..65535) return null
        return Entry(m.groupValues[1], m.groupValues[3], port, m.groupValues[2].isNotEmpty())
      }
    }
  }
}
