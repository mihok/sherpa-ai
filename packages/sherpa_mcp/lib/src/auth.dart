/// The seam between this client and Sherpa's OAuth implementation.
///
/// sherpa_mcp never stores or refreshes credentials. The integrator adapts
/// sherpa_auth (OAuth 2.1, RFC 9728 discovery, RFC 8707 `resource`,
/// issuer-keyed credentials) to [McpAuthHook]; this package only attaches
/// whatever headers it returns to every HTTP request (the token MUST be on
/// every request and never in the query string) and hands 401/403
/// challenges back.
library;

/// What to do after a 401/403.
enum AuthRetry {
  /// The hook obtained a new credential (refresh, step-up): resend once.
  retry,

  /// Interactive authorization is needed: the call fails with
  /// `McpAuthRequiredException(needsUserConsent: true)` and the app shows
  /// its consent UI, then reconnects.
  needsUserConsent,

  /// Give up: the call fails with `McpAuthRequiredException`.
  fail,
}

/// Supplies credentials for one MCP server (keyed by its canonical URL).
abstract interface class McpAuthHook {
  /// Headers for a request to [serverUrl], typically
  /// `{'authorization': 'Bearer …'}`. Called before every request, so it
  /// should be cheap (cache tokens; refresh ahead of expiry).
  Future<Map<String, String>> headersFor(Uri serverUrl);

  /// Called on HTTP 401 or 403 with the response headers (lower-case
  /// names; `www-authenticate` carries `resource_metadata` and, for
  /// step-up, `error="insufficient_scope"` and `scope`).
  Future<AuthRetry> onAuthChallenge(Uri serverUrl, int status, Map<String, String> responseHeaders);
}
