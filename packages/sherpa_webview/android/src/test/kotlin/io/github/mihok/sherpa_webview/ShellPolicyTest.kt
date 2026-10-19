package io.github.mihok.sherpa_webview

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShellPolicyTest {
  private val connect =
    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; " +
      "font-src 'none'; media-src 'none'; connect-src https://api.allowed.example wss://ws.allowed.example; " +
      "frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; " +
      "form-action 'none'; manifest-src 'none'"

  @Test
  fun acceptsBuilderPolicies() {
    assertTrue(ShellPolicy.isValidCsp(ShellPolicy.DEFAULT_CSP))
    assertTrue(ShellPolicy.isValidCsp(connect))
  }

  @Test
  fun rejectsPoliciesThatCouldEscapeTheAttributeOrWidenAccess() {
    for (bad in listOf(
      "",
      "connect-src *",
      "default-src *; frame-src 'none'; connect-src *",
      ShellPolicy.DEFAULT_CSP + "\"><script>alert(1)</script>",
      ShellPolicy.DEFAULT_CSP.replace("frame-src 'none'", "frame-src *"),
      ShellPolicy.DEFAULT_CSP.replace("; connect-src 'none'", ""),
      ShellPolicy.DEFAULT_CSP.uppercase(),
      ShellPolicy.DEFAULT_CSP + "; report-uri https://x.example/?a=b&c=d",
      ShellPolicy.DEFAULT_CSP + "\n",
    )) {
      assertFalse(bad, ShellPolicy.isValidCsp(bad))
    }
  }

  @Test
  fun renderSubstitutesOrFallsBack() {
    val template = "<meta http-equiv=\"Content-Security-Policy\" content=\"__SHERPA_CSP__\">"
    assertEquals(
      "<meta http-equiv=\"Content-Security-Policy\" content=\"$connect\">",
      ShellPolicy.renderShell(template, connect),
    )
    assertEquals(
      "<meta http-equiv=\"Content-Security-Policy\" content=\"${ShellPolicy.DEFAULT_CSP}\">",
      ShellPolicy.renderShell(template, "connect-src *\">"),
    )
    assertNull(ShellPolicy.renderShell("<p>no placeholder</p>", connect))
  }

  @Test
  fun bridgeMessagesOnlyFromTheShellMainFrame() {
    val max = 1024L
    assertTrue(ShellPolicy.acceptBridgeMessage(true, "https", "mcp-view.sherpa.invalid", -1, 10, max))
    assertTrue(ShellPolicy.acceptBridgeMessage(true, "https", "mcp-view.sherpa.invalid", 443, 10, max))
    assertFalse(ShellPolicy.acceptBridgeMessage(false, "https", "mcp-view.sherpa.invalid", -1, 10, max))
    assertFalse(ShellPolicy.acceptBridgeMessage(true, "http", "mcp-view.sherpa.invalid", -1, 10, max))
    assertFalse(ShellPolicy.acceptBridgeMessage(true, "https", "evil.example", -1, 10, max))
    assertFalse(ShellPolicy.acceptBridgeMessage(true, "https", "mcp-view.sherpa.invalid", 8443, 10, max))
    assertFalse(ShellPolicy.acceptBridgeMessage(true, null, null, -1, 10, max), "opaque origin")
    assertFalse(ShellPolicy.acceptBridgeMessage(true, "https", "mcp-view.sherpa.invalid", -1, 1025, max))
    assertFalse(
      ShellPolicy.acceptBridgeMessage(true, "https", "mcp-view.sherpa.invalid", -1, ShellPolicy.HARD_MAX_MESSAGE_CHARS + 1, Long.MAX_VALUE),
    )
  }

  @Test
  fun subframeNavigation() {
    assertTrue(ShellPolicy.isAllowedSubframeUrl("about:srcdoc"))
    assertTrue(ShellPolicy.isAllowedSubframeUrl("about:blank"))
    assertFalse(ShellPolicy.isAllowedSubframeUrl("https://evil.example/"))
    assertFalse(ShellPolicy.isAllowedSubframeUrl("https://mcp-view.sherpa.invalid/"))
    assertFalse(ShellPolicy.isAllowedSubframeUrl("javascript:alert(1)"))
  }

  @Test
  fun allowlistMatchesLikeCsp() {
    val a = ShellPolicy.OriginAllowlist(
      listOf("https://api.allowed.example", "wss://ws.allowed.example", "https://*.wild.example", "https://port.example:8443", "junk", "http://x.example"),
    )
    assertFalse(a.isEmpty)
    assertTrue(a.allows("https://api.allowed.example/data.json"))
    assertTrue(a.allows("https://API.allowed.example:443/x"))
    assertTrue(a.allows("wss://api.allowed.example/socket"), "https source matches wss")
    assertTrue(a.allows("wss://ws.allowed.example/socket"))
    assertFalse(a.allows("https://ws.allowed.example/x"), "wss source does not match https")
    assertTrue(a.allows("https://img.wild.example/a.png"))
    assertTrue(a.allows("https://a.b.wild.example/a.png"))
    assertFalse(a.allows("https://wild.example/a.png"), "wildcard excludes the apex")
    assertFalse(a.allows("https://evilwild.example/a.png"))
    assertTrue(a.allows("https://port.example:8443/"))
    assertFalse(a.allows("https://port.example/"))
    assertFalse(a.allows("https://api.allowed.example:444/"))
    assertFalse(a.allows("http://api.allowed.example/"))
    assertFalse(a.allows("http://x.example/"), "http entries are dropped")
    assertFalse(a.allows("https://user@api.allowed.example/"))
    assertFalse(a.allows("https://evil.example/"))
    assertFalse(a.allows("https://mcp-view.sherpa.invalid/favicon.ico"))
    assertFalse(a.allows("file:///etc/hosts"))
    assertFalse(a.allows("content://x/y"))
    assertFalse(a.allows("intent://x#Intent;end"))
    assertFalse(a.allows("not a url"))
    assertTrue(a.allows("data:image/png;base64,AAAA"), "local schemes are not network")
    assertTrue(a.allows("blob:null/1234"))
    assertTrue(a.allows("about:srcdoc"))
    val none = ShellPolicy.OriginAllowlist(emptyList())
    assertTrue(none.isEmpty)
    assertFalse(none.allows("https://api.allowed.example/"))
  }

  @Test
  fun profileNames() {
    assertEquals("sherpa_mcp_0123456789abcdef01234567", ShellPolicy.profileName("0123456789abcdef01234567"))
    assertNull(ShellPolicy.profileName(""))
    assertNull(ShellPolicy.profileName("../x"))
    assertNull(ShellPolicy.profileName("ABCDEF0123"))
  }

  private fun assertTrue(condition: Boolean, message: String) = assertTrue(message, condition)

  private fun assertFalse(condition: Boolean, message: String) = assertFalse(message, condition)
}
