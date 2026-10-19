/// Pure-Dart OAuth 2.1 client for Sherpa.
///
/// - MCP authorization per the 2026-07-28 revision (R02): RFC 9110
///   challenge parsing, RFC 9728 Protected Resource Metadata, RFC 8414 /
///   OIDC discovery with the issuer identity check, pre-registered → CIMD →
///   DCR registration keyed by issuer, PKCE S256 (refused when not
///   advertised), RFC 8707 `resource` on every request, RFC 9207 `iss`
///   validation, step-up on `insufficient_scope`, and single-flight
///   rotating refresh. [McpAuthorizer] is the entry point for the MCP client.
/// - "Sign in with Hugging Face" via [HuggingFaceOAuth] (R08 §8).
///
/// Only the browser hop ([BrowserLauncher]) and secret storage
/// ([SecretAuthStateStore] over `SecretStore`) are provided by the app.
/// All traffic goes through [AuthHttp]: SSRF policy, same-origin
/// redirects only, size and time caps, redacted errors.
library;

export 'src/common/redaction.dart' show AuthLogLevel, AuthLogger, AuthRedact;
export 'src/discovery/authorization_server.dart';
export 'src/discovery/protected_resource.dart';
export 'src/discovery/resource_uri.dart';
export 'src/errors.dart';
export 'src/flow/browser.dart';
export 'src/flow/device_flow.dart';
export 'src/flow/issuer_check.dart';
export 'src/flow/oauth_client.dart';
export 'src/flow/pending.dart';
export 'src/flow/pkce.dart';
export 'src/flow/scopes.dart';
export 'src/flow/tokens.dart';
export 'src/hf/hugging_face.dart';
export 'src/http/auth_http.dart';
export 'src/http/network_policy.dart';
export 'src/mcp/mcp_authorizer.dart';
export 'src/registration/client_registration.dart';
export 'src/registration/registrar.dart';
export 'src/store/auth_state_store.dart';
export 'src/www_authenticate.dart';
