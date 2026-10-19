import Foundation

/// Policy decisions of the native layer (mirrors ShellPolicy.kt). Native
/// code is a checked pipe: every protocol decision is Dart.
enum ShellPolicy {
  /// The shell's virtual origin. `.invalid` is reserved and never resolves.
  static let shellScheme = "https"
  static let shellHost = "mcp-view.sherpa.invalid"
  static let shellOrigin = "https://mcp-view.sherpa.invalid"
  static let shellBaseURL = "https://mcp-view.sherpa.invalid/"

  /// Script message handler name, registered ONLY in the private bridge world.
  static let handlerName = "sherpaHost"
  static let bridgeWorldName = "sherpa-mcp-bridge"

  static let cspPlaceholder = "__SHERPA_CSP__"

  /// The no-network policy (identical to Dart's `McpAppCsp.build()`).
  static let defaultCSP =
    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; "
    + "font-src 'none'; media-src 'none'; connect-src 'none'; frame-src 'none'; child-src 'none'; "
    + "worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; manifest-src 'none'"

  /// Hard cap on one shell string, whatever the config says.
  static let hardMaxMessageChars = 4 * 1024 * 1024 + 4096

  private static let cspAllowed = Set("abcdefghijklmnopqrstuvwxyz0123456789 :;'*./-".unicodeScalars)

  /// Only the characters Dart's builder emits (nothing that could close the
  /// meta attribute), the no-default prefix, explicit connect-src and
  /// `frame-src 'none'`.
  static func isValidCSP(_ csp: String) -> Bool {
    guard !csp.isEmpty, csp.utf16.count <= 16384 else { return false }
    guard csp.unicodeScalars.allSatisfy({ cspAllowed.contains($0) }) else { return false }
    return csp.hasPrefix("default-src 'none'; ") && csp.contains("; frame-src 'none';")
      && csp.contains("; connect-src ")
  }

  /// The shell with `csp` (or the default) substituted; nil when the
  /// template has no placeholder (fail closed: nothing is loaded).
  static func renderShell(_ template: String, csp: String) -> String? {
    guard let range = template.range(of: cspPlaceholder) else { return nil }
    return template.replacingCharacters(in: range, with: isValidCSP(csp) ? csp : defaultCSP)
  }

  /// `WKSecurityOrigin` check for bridge messages (port 0 = default).
  static func isShellOrigin(scheme: String, host: String, port: Int) -> Bool {
    scheme.lowercased() == shellScheme && host.lowercased() == shellHost && (port == 0 || port == 443)
  }

  static func acceptBridgeMessage(isMainFrame: Bool, scheme: String, host: String, port: Int, length: Int, maxChars: Int64) -> Bool {
    isMainFrame && isShellOrigin(scheme: scheme, host: host, port: port)
      && Int64(length) <= min(maxChars, Int64(hardMaxMessageChars))
  }

  /// Sub-frame navigations allowed: the View's srcdoc document only.
  static func isAllowedSubframeURL(_ url: String) -> Bool { url == "about:srcdoc" || url == "about:blank" }

  static func clip(_ s: String, max: Int = 200) -> String { s.count <= max ? s : String(s.prefix(max)) + "…" }

  // MARK: Content rules

  private struct Origin {
    let scheme: String
    let host: String
    let port: Int?
    let wildcard: Bool
  }

  private static func parseOrigin(_ raw: String) -> Origin? {
    let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
    let scheme: String
    if s.hasPrefix("https://") { scheme = "https" } else if s.hasPrefix("wss://") { scheme = "wss" } else { return nil }
    var rest = String(s.dropFirst(scheme.count + 3))
    var wildcard = false
    if rest.hasPrefix("*.") {
      wildcard = true
      rest = String(rest.dropFirst(2))
    }
    var port: Int?
    if let colon = rest.lastIndex(of: ":") {
      guard let p = Int(rest[rest.index(after: colon)...]), (1...65535).contains(p) else { return nil }
      port = p
      rest = String(rest[..<colon])
    }
    let labels = rest.split(separator: ".", omittingEmptySubsequences: false)
    let labelChars = Set("abcdefghijklmnopqrstuvwxyz0123456789-".unicodeScalars)
    guard labels.count >= 2,
      labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.unicodeScalars.allSatisfy { labelChars.contains($0) } })
    else { return nil }
    return Origin(scheme: scheme, host: rest, port: port, wildcard: wildcard)
  }

  /// Escapes a host for a WebKit content-rule `url-filter` regex.
  private static func escape(_ host: String) -> String { host.replacingOccurrences(of: ".", with: "\\.") }

  /// The `WKContentRuleList` JSON: block every load, then re-allow local
  /// schemes, the shell document itself and each consented origin (an
  /// `https` origin also allows `wss`, like CSP). With no consent, every
  /// network load is blocked even if the CSP were bypassed.
  static func contentRules(allowedOrigins: [String]) -> String {
    var rules: [[String: Any]] = [
      ["trigger": ["url-filter": ".*"], "action": ["type": "block"]]
    ]
    func allow(_ filter: String) {
      rules.append(["trigger": ["url-filter": filter], "action": ["type": "ignore-previous-rules"]])
    }
    allow("^about:")
    allow("^data:")
    allow("^blob:")
    allow("^https://" + escape(shellHost) + "/$")
    for raw in allowedOrigins {
      guard let o = parseOrigin(raw) else { continue }
      let hostPattern = o.wildcard ? "([a-z0-9-]+\\.)+" + escape(o.host) : escape(o.host)
      let portPattern = o.port.map { $0 == 443 ? "(:443)?" : ":\($0)" } ?? "(:443)?"
      for scheme in o.scheme == "https" ? ["https", "wss"] : ["wss"] {
        allow("^" + scheme + "://" + hostPattern + portPattern + "/")
      }
    }
    let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  /// A stable identifier per rule set (FNV-1a 64), so compiled lists are
  /// reused from the store.
  static func ruleListIdentifier(_ rules: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in rules.utf8 {
      hash ^= UInt64(b)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return "sherpa-mcp-" + String(hash, radix: 16)
  }

  // MARK: Scripts

  /// Runs in the PRIVATE bridge world of the MAIN frame only: relays the
  /// shell's self-posted `{__sherpaOut}` strings to the message handler,
  /// which page-world scripts (the shell and every View frame) cannot see.
  static let bridgeRelayScript = """
    (function () {
      var ORIGIN = 'https://mcp-view.sherpa.invalid';
      if (window.top !== window || location.origin !== ORIGIN) return;
      window.addEventListener('message', function (e) {
        if (e.source !== window || e.origin !== ORIGIN) return;
        var d = e.data;
        if (!d || typeof d.__sherpaOut !== 'string') return;
        window.webkit.messageHandlers.sherpaHost.postMessage(d.__sherpaOut);
      });
    })();
    """

  /// Best effort in every frame (WebRTC is not covered by CSP); exposes nothing.
  static let neuterWebRTC = """
    (function(){try{['RTCPeerConnection','webkitRTCPeerConnection','RTCDataChannel','RTCIceTransport',\
    'RTCSctpTransport','RTCRtpSender','RTCRtpReceiver','RTCRtpTransceiver'].forEach(function(k){\
    try{Object.defineProperty(window,k,{value:undefined,writable:false,configurable:false});}catch(e){}});}catch(e){}})();
    """
}
