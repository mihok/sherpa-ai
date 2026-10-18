# 02 — MCP Authorization for a mobile public client (Sherpa)

Researched 2026-10-18 against primary sources: the spec repo on raw.githubusercontent.com, RFC texts from rfc-editor.org, IETF drafts, Apple and Chrome developer docs, npm tarballs and pub.dev archives. Anything I could not verify is marked **UNVERIFIED**. This document builds on `01-mcp-spec.md` (eras, `server/discover`, transport) and owns everything about OAuth.

**Source keys used below**

| Key | Source |
|---|---|
| **A26** | `docs/specification/2026-07-28/basic/authorization/index.mdx` (raw: `https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/docs/specification/2026-07-28/basic/authorization/index.mdx`; rendered: `https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization`) |
| **ASD26** | same dir, `authorization-server-discovery.mdx` |
| **CR26** | same dir, `client-registration.mdx` |
| **SC26** | same dir, `security-considerations.mdx` |
| **SBP26** | `docs/docs/2026-07-28/tutorials/security/security_best_practices.mdx` |
| **CL26** | `docs/specification/2026-07-28/changelog.mdx` |
| **A25-11** | `docs/specification/2025-11-25/basic/authorization.mdx` (a single page, not a directory) |
| **A25-06** | `docs/specification/2025-06-18/basic/authorization.mdx` |
| **A25-03** | `docs/specification/2025-03-26/basic/authorization.mdx` |
| **TS1** | `@modelcontextprotocol/sdk@1.32.1`, `/opt/vendor-src/npm/modelcontextprotocol-sdk-1.32.1/package/dist/esm/client/auth.js` (+ `streamableHttp.js`, `../shared/auth.js`, `../shared/auth-utils.js`, `../shared/transport.js`) |
| **TS2** | `@modelcontextprotocol/client@2.3.1`, `/opt/vendor-src/npm/modelcontextprotocol-client-2.3.1/package/dist/index.mjs`; schemas in `@modelcontextprotocol/core@2.3.1`, `/opt/vendor-src/npm/modelcontextprotocol-core-2.3.1/package/dist/auth-BNDyLTqp.mjs` |
| **MD** | `mcp_dart@2.4.3`, `/opt/vendor-src/pub/mcp_dart-2.4.3/lib/src/client/streamable_https.dart` |
| RFCs | `https://www.rfc-editor.org/rfc/rfcNNNN.txt`; OAuth 2.1 = `https://www.ietf.org/archive/id/draft-ietf-oauth-v2-1-13.txt`; CIMD = `https://www.ietf.org/archive/id/draft-ietf-oauth-client-id-metadata-document-02.txt` (latest is rev 02, 2026-07-06; the MCP spec cites -00) |

The spec repo directory listing is not reachable through the proxy (api.github.com is blocked). I found the 2026-07-28 page layout by probing: `basic/authorization/index.mdx` plus three subpages. The 2025 revisions use a single `basic/authorization.mdx`. The `draft/` auth pages match 2026-07-28 apart from one example redirect URI (`http://[::1]:3000/callback`).

---

## 0. TL;DR for implementers

1. A **401** from any MCP HTTP request (including the first `server/discover` or `initialize`) means "run OAuth". It is **not** an era verdict (see 01 §11).
2. **Discovery chain:**
   - Parse `WWW-Authenticate` and take `resource_metadata`, `scope` and `error`.
   - Fetch the Protected Resource Metadata (PRM): the header URL if present, otherwise `/.well-known/oauth-protected-resource{path}` and then `/.well-known/oauth-protected-resource`.
   - Pick an AS from `authorization_servers`.
   - Fetch AS metadata from `/.well-known/oauth-authorization-server{path}`, then `/.well-known/openid-configuration{path}`, then `{path}/.well-known/openid-configuration`.
   - **Validate `issuer` is identical** to the issuer the URL was built from.
3. **Refuse** if `code_challenge_methods_supported` is absent or lacks `S256`. Both TS SDKs proceed when it is absent, which is a spec violation; Sherpa must not copy that.
4. **Client ID**, in this priority: pre-registered for that issuer → **CIMD** (`client_id` = Sherpa's HTTPS JSON URL) if the AS has `client_id_metadata_document_supported: true` → **DCR** (deprecated in 2026-07-28; send `application_type`) → ask the user.
5. **Authorization request:** authorization code + PKCE S256 + `state` + `resource` (canonical MCP URI, sent always) + scope (challenge `scope` → PRM `scopes_supported` → omit) + optional `offline_access`.
6. **Callback:** check `state`, then the **RFC 9207 `iss` four-row table** with exact string comparison, *before* redeeming the code. On mismatch, never display `error`/`error_description`.
7. **Token request** carries `code_verifier` and the same `resource`. Store tokens keyed by **(issuer, resource, client_id)**. Refresh with `resource`, replace a rotated refresh token atomically, and run only one refresh at a time per grant.
8. **403** with `WWW-Authenticate: Bearer error="insufficient_scope", scope="..."` triggers step-up: re-authorize interactively with the **union** of previously requested, granted and challenged scopes. Retry once; never loop.
9. **Mobile redirect:** claimed HTTPS (iOS Universal Links via `ASWebAuthenticationSession.Callback.https(host:path:)`, iOS ≥ 17.4; Android App Links via Auth Tab/Custom Tabs). Fall back to a reverse-DNS private-use scheme. The MCP spec text, read literally, forbids custom schemes (see §11.2).
10. Implement **all OAuth logic in pure Dart** in `sherpa_core`, behind injected `HttpClient`, `SecretStore`, `BrowserAuthenticator`, `Clock` and `Random`. The only Flutter plugin piece is the browser step (`flutter_web_auth_2` 5.1.0 recommended).

---

## 1. What changed across revisions (client-relevant)

| Topic | 2025-06-18 (A25-06) | 2025-11-25 (A25-11) | 2026-07-28 (A26/ASD26/CR26/SC26) |
|---|---|---|---|
| `WWW-Authenticate` on 401 | Server **MUST** send it with `resource_metadata` | Optional. The server MUST implement header **or** well-known (SEP-985); clients MUST support both and fall back path → root | Same as 2025-11-25 |
| AS metadata discovery | RFC 8414 only ("clients MUST use the OAuth 2.0 Authorization Server Metadata") | RFC 8414 **or** OIDC Discovery; clients MUST try 3 URLs (path issuer) or 2 URLs (no path) in a fixed order (PR #797) | Same order, plus an explicit **MUST validate `issuer` identical to the issuer used to build the URL**, with an attacker example (ASD26 L94) |
| Registration | DCR **SHOULD** | Priority: pre-reg → CIMD (SHOULD, SEP-991) → DCR (MAY) → prompt user | Same priority. **DCR deprecated** (PR #2858; earliest removal ≥ 2027-07-28). **DCR MUST send `application_type`** (SEP-837). Credentials **MUST be keyed by issuer**; re-register on AS change (SEP-2352). CIMD client ids are portable across ASes |
| PKCE | MUST implement | MUST verify support via `code_challenge_methods_supported`; **refuse if absent**; MUST use S256 | Same |
| Scope selection | — | Challenge `scope` → PRM `scopes_supported` → omit (SEP-835) | Same, plus: challenge scopes are "authoritative for the current operation" and SHOULD be combined with previously granted scopes |
| Step-up (403 `insufficient_scope`) | — | Defined; "determine required scopes as in Scope Selection Strategy" | **Union** of previously requested scopes and challenged scopes; servers SHOULD put all required scopes in one challenge; servers MUST honour scope hierarchies (A26 L379-405) |
| `iss` (RFC 9207) | — | — | **New** (SEP-2468). Record the issuer with the PKCE verifier; four-row table; no normalisation; applies to error responses too (A26 L190-213) |
| Refresh tokens | AS MUST rotate for public clients | Same | **New "Refresh Tokens" section** (A26 L299-313): clients SHOULD list `refresh_token` in `grant_types`; MAY add `offline_access` if the AS lists it; MUST NOT assume a refresh token is issued. Not in CL26; TS2 attributes it to SEP-2207 (**UNVERIFIED** attribution) |
| `resource` (RFC 8707) | MUST on authorize and token requests | Same | Same |
| Communication security | AS endpoints HTTPS; **redirect URIs MUST be `localhost` or HTTPS** | Same | Same (SC26 L42-43) |
| Mix-up | — | — | Section added, pointing at the `iss` validation (SC26 L63-65) |
| Extensions | — | ext-auth repo referenced | ext-auth: *Enterprise-Managed Authorization* (Stable), *Client Credentials* (Draft) (`raw.githubusercontent.com/modelcontextprotocol/ext-auth/main/README.md`) |

The legacy 2025-03-26 behaviour (A25-03 L141-175): if AS metadata is missing, use `/authorize`, `/token` and `/register` relative to the MCP server origin, and send the `MCP-Protocol-Version` header on discovery. Both TS SDKs still implement this fallback (§15). Sherpa should treat it as an opt-in compatibility mode (Open question Q7).

---

## 2. Step 1: 401 + `WWW-Authenticate`

Spec rules:
- Servers MUST return 401 for missing, invalid or expired tokens (A26 L289-290).
- They SHOULD include `scope` (A26 L99-103) and MUST include `resource_metadata` if they do not serve the well-known URL (ASD26 L39-47).
- Clients MUST parse `WWW-Authenticate` (ASD26 L49).

Shape (A26 L118-122; RFC 9728 §5.1; RFC 6750 §3):

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
                         scope="files:read"
```

Parameters to read:

| Param | Source | Notes |
|---|---|---|
| `resource_metadata` | RFC 9728 §5.1 | Absolute URL of the PRM. It MAY appear under schemes other than `Bearer`, such as `DPoP` (RFC 9728 §5.1). |
| `scope` | RFC 6750 §3 | Space-delimited and **authoritative for the current operation** (A26 L105-114). It MUST NOT appear more than once (RFC 6750 §3). Values can contain `=`, `&` and `,` inside quotes, e.g. `scope="urn:example:channel=HBO&urn:example:rating=G,PG-13"` (RFC 6750 §3). |
| `error` | RFC 6750 §3.1 | `invalid_request` (400), `invalid_token` (401), `insufficient_scope` (403). It is absent when the request carried no credentials. |
| `error_description`, `error_uri`, `realm` | RFC 6750 §3 | Display-only, untrusted. |

**Parser requirements for Sherpa:**
- Implement an RFC 9110 §11.6.1 challenge-list parser: multiple challenges, `token68` vs auth-params, quoted-string with `\` escapes, case-insensitive scheme and param names. Also handle several `WWW-Authenticate` header lines; Dart `package:http` folds repeated headers into one comma-joined string (**UNVERIFIED**; test it).
- Select the `Bearer` challenge. Also read `resource_metadata`/`scope` from a `DPoP` challenge, as TS2 does (`RECOGNIZED_CHALLENGE_SCHEMES = {bearer, dpop}`, TS2 L886).
- **The TS SDKs' parser is weak, so do not copy it.** It splits on the first space and checks only the *first* challenge's scheme. It then extracts each field with `new RegExp(fieldName + '=(?:"([^"]+)"|([^\\s,]+))')` (TS1 L471-483, TS2 L923-933). That regex has no word boundary and no escape handling, so `error_description="need scope=x"` placed before `scope=` gives a wrong `scope`.
- Treat `resource_metadata` as **untrusted input** that feeds the SSRF policy (§14.3).
- RFC 9728 §5.2: a later 401/403 that carries a `resource_metadata` signals the metadata may have changed. The client SHOULD re-fetch and re-validate it. This is how a server moves to another AS, which triggers re-registration (CR26 L181-191).
- **403 without** `WWW-Authenticate` / `error="insufficient_scope"` is not an auth signal. It can be an invalid `Origin` (2026-07-28 Streamable HTTP, `basic/transports/streamable-http.mdx` L58-61). Surface it as an error.

---

## 3. Protected Resource Metadata (RFC 9728)

### 3.1 URL construction and fallback order

Spec (ASD26 L37-47, A25-11 L91-101):
1. Use `resource_metadata` from the parsed header **when present**.
2. Otherwise build the URLs **in this order**:
   - **Path-aware:** for MCP endpoint `https://example.com/public/mcp`, use `https://example.com/.well-known/oauth-protected-resource/public/mcp`.
   - **Root:** `https://example.com/.well-known/oauth-protected-resource`.
3. If neither works, abort or use pre-configured values (ASD26 sequence diagram L114-127). The diagram notes the path-aware probe is "not applicable if the MCP server is at the root".

RFC 9728 §3.1:
- Remove any terminating `/` after the host.
- Insert `/.well-known/oauth-protected-resource` **between the host and the path and/or query**, so the query is kept after the path.
- Example: resource `https://resource.example.com/resource1` → `GET /.well-known/oauth-protected-resource/resource1`.

Algorithm (matches TS1 L554-599 and TS2 L1009-1043):
```
u = serverUrl (fragment stripped)
path = u.path with one trailing "/" removed ("/" → "")
if header.resource_metadata: candidates = [header URL]          # no fallback in either SDK
else:
  candidates = []
  if path != "": candidates += origin + "/.well-known/oauth-protected-resource" + path + (u.query? "?"+query)
  candidates += origin + "/.well-known/oauth-protected-resource"
try in order; fall back to next on: network-level "no response", HTTP 4xx, 502 (TS2 only; TS1: 4xx only)
5xx (other than 502 in TS2) on the first candidate → TS SDKs stop (do not fall back) and fail
```
Sherpa additions:
- Also fall back when a 200 response is **not JSON**, or fails schema validation. A SPA catch-all can return `index.html` with 200.
- Cap the response size (for example 64 KiB) and time out at about 10 s.
- **Do not** fall back from a header-supplied URL to well-known probing unless the header URL returns 404. The SDKs never fall back from it. Probing is harmless and helps against stale headers (judgement call).

### 3.2 Document shape

From RFC 9728 §2/§3.2 and the TS2 schema (`OAuthProtectedResourceMetadataSchema`, core L1495-1510):
```json
{
  "resource": "https://mcp.example.com/mcp",                    // REQUIRED, https, no fragment
  "authorization_servers": ["https://auth.example.com/tenant1"], // MCP: MUST contain ≥1 (ASD26 L14-15)
  "scopes_supported": ["files:read"],
  "bearer_methods_supported": ["header"],
  "resource_name": "Example Files",
  "resource_documentation": "https://mcp.example.com/docs",
  "jwks_uri": "...", "dpop_bound_access_tokens_required": false   // optional, ignore unless supported
}
```
Unknown members MUST be ignored (RFC 9728 §3.2).

### 3.3 Validation

- **RFC 9728 §3.3 (strict):**
  - The returned `resource` MUST be **identical** to the resource identifier the well-known suffix was inserted into.
  - If the PRM URL came from `WWW-Authenticate`, `resource` MUST be identical to **the URL the client used for the request**.
  - Otherwise the data MUST NOT be used. This defeats impersonation (§7.3).
- **What the SDKs actually do** (TS1/TS2 `selectResourceURL` + `checkResourceAllowed`, TS1 `shared/auth-utils.js`):
  - Accept if `resource` has the **same origin** and its path is a **segment-boundary prefix** of the server URL path. For example, `https://ex.com` and `https://ex.com/mcp` are both accepted for `https://ex.com/mcp`; `/api123` does not match `/api`.
  - Then send the PRM `resource` string **verbatim** as the RFC 8707 `resource` parameter. They do not use the `URL.href`, which would add `/` (TS1 L263-268, TS2 L724-726, issue #1968).
- **Sherpa:**
  - Accept identical matches.
  - Also accept the SDK's same-origin path-prefix rule for interoperability, and log the relaxation.
  - **Reject cross-origin `resource`.**
  - Send the PRM `resource` verbatim.
- PRM `authorization_servers` absent or empty is a spec violation for MCP. The SDKs fall back to "the MCP server origin is the AS" (TS2 L1188). Sherpa should do that only in 2025-03-26 compatibility mode (Q7).
- **Multiple ASes:** the client chooses (RFC 9728 §7.6). Registrations and tokens MUST be kept per AS (ASD26 L27-35). The SDKs always take `authorization_servers[0]` (TS1 L757, TS2 L1184). Sherpa: take the first AS whose metadata validates and passes the PKCE check, and remember the choice per server.

---

## 4. Authorization Server metadata discovery (RFC 8414 + OIDC Discovery)

### 4.1 Mandated order (ASD26 L75-92, identical in A25-11 L135-144)

Issuer **with a path**, e.g. `https://auth.example.com/tenant1`:
1. `https://auth.example.com/.well-known/oauth-authorization-server/tenant1` (RFC 8414 path insertion)
2. `https://auth.example.com/.well-known/openid-configuration/tenant1` (OIDC with path insertion)
3. `https://auth.example.com/tenant1/.well-known/openid-configuration` (OIDC Discovery 1.0 path appending)

Issuer **without a path**:
1. `https://auth.example.com/.well-known/oauth-authorization-server`
2. `https://auth.example.com/.well-known/openid-configuration`

Path handling:
- Strip a single trailing `/` from the issuer path before building the URLs. `https://as/` counts as "no path" (TS1 L639-679, TS2 L1077-1104).
- MD adds a fourth compatibility probe, `{path}/.well-known/oauth-authorization-server` (MD L1030-1065). That probe is not in the spec, so Sherpa should skip it.

The 2025-06-18 servers only promised RFC 8414 (A25-06). Trying the OIDC URLs as well does no harm.

### 4.2 Fallback rules

| Response | TS1 (L696-730) | TS2 (L1132-1158) | Sherpa (recommended) |
|---|---|---|---|
| fetch threw a `TypeError` (CORS, browser only) | continue | continue (browser); **rethrow** on Node | n/a (no CORS on mobile). A network error is a hard error ("offline"), not a fallback |
| 4xx | continue | continue | continue |
| 502 | throw | continue | continue |
| other 5xx | throw | throw | throw (retryable) |
| 200 + schema error | throw | throw | **continue** to the next candidate, and remember the error |
| 200 + `issuer` mismatch | not checked | throw `IssuerMismatchError` (no continue) | do **not use** the document; continue; if nothing validates, fail with the mismatch |
| all exhausted | `undefined` → legacy default endpoints | same | fail ("AS metadata not found"), except in compatibility mode |

Redirects:
- Both SDKs follow redirects **only within the same origin** (http→https same host is allowed), up to 5 hops.
- For POST they follow only 307/308. A cross-origin redirect is returned unfollowed and therefore counts as "not ok" (TS1 `shared/transport.js` `fetchWithinOrigin`/`followWithinOrigin`).
- Sherpa should copy this policy.

Headers on discovery GETs:
- TS1/TS2 send `MCP-Protocol-Version: <LATEST_PROTOCOL_VERSION>` (`2025-11-25` in both) and `Accept: application/json`.
- The header is a 2025-03-26 SHOULD (A25-03 L135-139) and is not required later. Sending it is harmless; Sherpa may send `Accept: application/json` only.
- **Never send `Authorization`/cookies** on metadata fetches.

### 4.3 Validation (ASD26 L94; RFC 8414 §3.3; OIDC Discovery §4.3)

- `issuer` in the document **MUST be identical** to the issuer identifier used to build the URL, otherwise MUST NOT be used.
- Spec example: a document fetched from `https://attacker.example/.well-known/oauth-authorization-server` that contains `"issuer": "https://honest.example"` MUST be rejected.
- TS2 allows exactly one relaxation: an expected `https://as/x/` matches a document `https://as/x` (TS2 L1152-1155). It exists because JS `String(new URL(...))` adds `/`.
- **Sherpa:** compare the **raw string** taken from PRM `authorization_servers[i]` against `metadata.issuer` with code-point equality (RFC 9728 §6, RFC 3986 §6.2.1). Allow only the single trailing-slash tolerance, and log it.
- The validated `metadata.issuer` becomes **the recorded issuer** used for `iss` checks and credential keying.

Other validation:
- **PKCE (SC26 L50-61):**
  - If `code_challenge_methods_supported` is absent → **MUST refuse to proceed**. This holds for both RFC 8414 and OIDC documents; OIDC providers serving MCP MUST include it.
  - MUST use `S256`. Sherpa: refuse unless the list contains `"S256"`.
  - **TS1 L788-791 and TS2 L1210 only throw when the list is *present* and lacks S256, so they proceed when it is absent.** MD refuses correctly (MD L557-560).
- `response_types_supported` must contain `"code"`. It is required by RFC 8414; TS1/TS2 throw otherwise.
- `authorization_endpoint` and `token_endpoint` MUST be `https`. Loopback `http` is allowed only in dev (SC26 L42; OAuth 2.1 §1.5). TS2 enforces this on the token endpoint (`assertSecureTokenEndpoint`, TS2 L534-548: https or `localhost`/`*.localhost`/`127.0.0.1`/`::1`).
- Reject `javascript:`, `data:`, `vbscript:` and `file:` URLs, and anything that is not http(s) (SBP26 "OAuth Authorization URL Validation"; TS `SafeUrlSchema`).
- **OIDC schema strictness trap:** TS2's `OpenIdProviderMetadataSchema` *requires* `jwks_uri`, `subject_types_supported` and `id_token_signing_alg_values_supported` (core L1542-1580), so an OAuth-only server publishing `openid-configuration` fails parsing. Sherpa should parse both kinds with one lenient model and require only the fields OAuth needs.

Fields Sherpa reads:

```json
{
  "issuer": "https://auth.example.com/tenant1",
  "authorization_endpoint": "https://auth.example.com/tenant1/authorize",
  "token_endpoint": "https://auth.example.com/tenant1/token",
  "registration_endpoint": "https://auth.example.com/tenant1/register",
  "revocation_endpoint": "https://auth.example.com/tenant1/revoke",
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code", "refresh_token"],
  "code_challenge_methods_supported": ["S256"],
  "token_endpoint_auth_methods_supported": ["none", "client_secret_basic", "client_secret_post"],
  "scopes_supported": ["files:read", "files:write", "offline_access"],
  "client_id_metadata_document_supported": true,
  "authorization_response_iss_parameter_supported": true
}
```

---

## 5. Client registration

### 5.1 Priority (CR26 L13-18; A25-11 L204-209)

1. **Pre-registered** client info for that server/issuer, if available.
2. **CIMD**, if AS metadata has `client_id_metadata_document_supported` (an OPTIONAL boolean, CIMD-02 §6). Only a literal `true` counts (TS1 L301, TS2 L745).
3. **DCR**, if AS metadata has `registration_endpoint`.
4. **Prompt the user** for client info.

How the SDKs implement this (TS2 L733-767):
- Step 1: `provider.clientInformation({issuer})` is consulted first. A stored DCR result also counts here and short-circuits registration.
- Step 2 needs both the AS flag **and** `provider.clientMetadataUrl`, which must be `https:` with a path other than `/` (`isHttpsUrl`, TS2 L855-863).
- Otherwise they always try DCR. If metadata exists without `registration_endpoint` they throw `Incompatible auth server: does not support dynamic client registration`. If no metadata exists they POST to `{AS}/register`.

### 5.2 Client ID Metadata Documents (CIMD)

**Client rules** (CR26 L36-42; CIMD-02 §3, §4, §4.1):
- `client_id` is an **https URL with a path**. It MUST NOT contain userinfo, `.` or `..` segments, or a fragment, and SHOULD NOT contain a query. It is compared by simple string comparison, so `https://example.com/client` ≠ `https://example.com:443/client`. A path of `/` is NOT RECOMMENDED. Avoid URL shorteners: the AS **MUST NOT follow redirects** when fetching (CIMD-02 §5).
- The document MUST contain at least **`client_id`, `client_name` and `redirect_uris`**, and `client_id` MUST equal the document URL exactly.
- It must be served with `200 OK` and JSON content. All other statuses are errors.
- **No shared secrets:** `token_endpoint_auth_method` MUST NOT be `client_secret_*`; `client_secret` and `client_secret_expires_at` MUST NOT appear; only public keys (`jwks`/`jwks_uri`) are allowed. `private_key_jwt` is a MAY (CR26 L42; CIMD-02 §8.2).
- Keep it small: ASes SHOULD stop reading at about **5 KB** (CIMD-02 §8.7).
- ASes MAY require `redirect_uris` to be **same-origin with the `client_id`** (CIMD-02 §8.1), so host both on one domain.
- ASes SHOULD show the `client_id` hostname on consent (CIMD-02 §8.5), MAY apply domain trust policies (SC26 L103-105), and SHOULD warn on localhost-only redirect URIs (SC26 L93-101).
- **Portable:** no re-registration is needed when the AS changes (CR26 L199-202).

Spec example (CR26 L55-69):
```json
{"client_id":"https://app.example.com/oauth/client-metadata.json","client_name":"Example MCP Client",
 "client_uri":"https://app.example.com","logo_uri":"https://app.example.com/logo.png",
 "redirect_uris":["http://127.0.0.1:3000/callback","http://localhost:3000/callback"],
 "grant_types":["authorization_code"],"response_types":["code"],"token_endpoint_auth_method":"none"}
```

**How a native app "hosts" a CIMD.** The device hosts nothing. The publisher serves one static JSON file per app identity on a domain it controls, and every install shares the same `client_id` constant compiled into the app. Proposed (domain **TBD**, see Q1):

`GET https://sherpa.example/oauth/mcp-client.json` → `200`, `Content-Type: application/json`, `Cache-Control: public, max-age=3600`, no redirects:
```json
{
  "client_id": "https://sherpa.example/oauth/mcp-client.json",
  "client_name": "Sherpa",
  "client_uri": "https://sherpa.example",
  "logo_uri": "https://sherpa.example/oauth/logo.png",
  "policy_uri": "https://sherpa.example/privacy",
  "redirect_uris": ["https://sherpa.example/oauth/callback"],
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "token_endpoint_auth_method": "none"
}
```

Design notes:
- **Two documents:** use `mcp-client.json` with only the claimed-https redirect, and optionally a second `mcp-client-legacy.json` whose redirect is `example.sherpa:/oauth/callback` for devices that cannot use https callbacks (iOS < 17.4; Android App Links not verified). Each is its own `client_id`, so users consent separately.
  - Rationale: an AS that applies the MCP rule "redirect URIs MUST be localhost or HTTPS" may reject a document that contains a custom scheme.
  - A custom-scheme redirect can be claimed by any app (OAuth 2.1 §8.4.3), which weakens what CIMD guarantees.
  - `application_type` is omitted. How ASes interpret it inside a CIMD is **UNVERIFIED**.
- **Do not change URLs.** Changing the `client_id` URL makes Sherpa a new client everywhere (CIMD-02 §8.3). Removing a redirect URI breaks in-flight flows. ASes cache the document per HTTP cache headers (CR26 L49-50; CIMD-02 §5.2), so keep old redirect URIs during migrations.
- **Forks** of an open-source Sherpa cannot reuse this `client_id`: the redirect is bound to the app's signing identity through AASA/assetlinks. Builds need a configurable `client_id` and redirect (Q1).

### 5.3 Pre-registration (CR26 L128-136)

- The client SHOULD support static credentials: either hard-coded per AS, or a UI where the user pastes a `client_id` (and, if needed, a `client_secret`) after registering an OAuth app with that provider.
- Sherpa UI: show the exact redirect URI to register, and store the result in secure storage keyed by **issuer**.
- A secret entered by the user for their own app is acceptable, but Sherpa is still a public client and must never ship secrets.
- If the PRM later points to a different AS, **surface an error** rather than silently using mismatched credentials (CR26 L193-197). TS2 throws `AuthorizationServerMismatchError` in this case (TS2 L735).

### 5.4 Dynamic Client Registration (RFC 7591), deprecated

- **Status:** "Dynamic Client Registration is deprecated. New implementations should use Client ID Metadata Documents" (CR26 L140-145; CL26 Deprecated #4, PR #2858). It stays functional; TS2 marks `registerClient` `@deprecated` (TS2 L1415-1427).
- **`application_type` MUST be sent** (CR26 L160-179). Native apps SHOULD send `"native"`; omitting it means `"web"` under OIDC. The client MUST handle rejections, SHOULD surface a meaningful error, and MAY retry with a different `application_type` or different redirect URIs.
- **OIDC Registration 1.0 constraint**, which conflicts with MCP for mobile:
  - "Native Clients MUST only register redirect_uris using custom URI schemes or loopback URLs using the http scheme". The default is `web` (`https://openid.net/specs/openid-connect-registration-1_0.html` §2).
  - So `native` + a claimed-https redirect is rejected by strict OIDC ASes.
  - TS2's heuristic `deriveApplicationType` returns `native` for loopback or non-http(s) schemes and `web` otherwise (TS2 L562-574).
- **Request** (TS2 `resolveClientMetadata` defaults: `grant_types` = `["authorization_code","refresh_token"]` for interactive clients, `application_type` derived; the resolved `scope` is merged into the body, TS2 L595-602 and L1434-1437):
```http
POST /tenant1/register HTTP/1.1
Host: auth.example.com
Content-Type: application/json
Accept: application/json

{"client_name":"Sherpa","client_uri":"https://sherpa.example","logo_uri":"https://sherpa.example/oauth/logo.png",
 "redirect_uris":["https://sherpa.example/oauth/callback"],"grant_types":["authorization_code","refresh_token"],
 "response_types":["code"],"token_endpoint_auth_method":"none","application_type":"native","scope":"files:read"}
```
- **Response** `201` (RFC 7591 §3.2.1): `client_id` (REQUIRED), optional `client_secret`, `client_id_issued_at`, `client_secret_expires_at` (REQUIRED if a secret is issued; 0 = never), `registration_access_token` and `registration_client_uri` (RFC 7592), plus all registered metadata echoed. The AS MAY substitute values, so use the echoed `redirect_uris` and `token_endpoint_auth_method`.
- **Errors** (`400`, RFC 7591 §3.2.2): `invalid_redirect_uri`, `invalid_client_metadata`, `invalid_software_statement`, `unapproved_software_statement`. TS2 throws `RegistrationRejectedError{status, body, submittedMetadata}` with no automatic retry (TS2 L96-112, L1443-1447). TS1 parses the body into an OAuthError.
- **Sherpa DCR attempt ladder** (judgement; max 3 attempts; the outcome is cached per issuer):
  1. `native` + `[https claimed]`: literal MCP compliance; non-OIDC ASes ignore `application_type`.
  2. On `invalid_redirect_uri`/`invalid_client_metadata`: `web` + `[https claimed]`, matching the TS2 heuristic and OIDC rules.
  3. On another rejection: `native` + `[example.sherpa:/oauth/callback]`, the classic RFC 8252 native client.
- **Persist** `{issuer, client_id, client_secret?, secret_expires_at, registration_access_token?, redirect_uri_used, token_endpoint_auth_method}` in secure storage, **keyed by issuer** (CR26 L183-191).

### 5.5 Client authentication at the token endpoint

TS1 L30-59 and TS2 L471-479 select the method in this order:
1. The DCR-returned `token_endpoint_auth_method`, if it is one of `client_secret_basic|client_secret_post|none` and either supported by the AS or the AS list is empty.
2. Otherwise, if the AS list is empty: `client_secret_basic` when a secret exists, else `none` (RFC 8414 §2 default).
3. Otherwise basic > post (when a secret exists) > `none`.
4. Last resort: post with a secret, `none` without.

Mechanics:
- `none` means sending `client_id` in the form body.
- `client_secret_basic` means `Authorization: Basic base64(client_id:client_secret)`.
- TS uses the raw values. MD form-encodes id and secret before base64, per RFC 6749 §2.3.1 (MD `_basicAuthorizationHeader`). **Use RFC 6749 encoding.**

---

## 6. Authorization request

### 6.1 Pre-flight checks

- AS metadata is validated (§4.3).
- PKCE `S256` is present.
- `authorization_endpoint` is https and not a dangerous scheme.
- `client_id` is resolved.
- The redirect URI is one that was registered for this `client_id`. Each registration has exactly one redirect, so keep the redirect paired with the client.

### 6.2 Record the flow before opening the browser (A26 L192)

- The client **MUST record the `issuer` from validated metadata** together with the PKCE verifier and `state`. Without an authentic issuer the check is meaningless.
- RFC 9700 §4.4.2: store, per authorization request, the issuer the request was sent to. Storing only the AS URL is not sufficient.
- Persist a `PendingAuthorization` record. The app may be killed while the browser is open; Android in particular.

```json
{ "state": "<b64url 32B>", "code_verifier": "<b64url 32B>", "issuer": "https://auth.example.com/tenant1",
  "iss_param_supported": true, "authorization_endpoint": "...", "token_endpoint": "...",
  "client_id": "https://sherpa.example/oauth/mcp-client.json", "redirect_uri": "https://sherpa.example/oauth/callback",
  "resource": "https://mcp.example.com/mcp", "scope": "files:read offline_access", "server_key": "<canonical MCP URL>",
  "created_at": "2026-10-18T12:00:00Z", "purpose": "initial|reauth|step_up" }
```
Expire records after about 10 minutes, and make them one-time use. TS2 implements the same idea through `saveDiscoveryState`/`saveCodeVerifier`, and refuses the callback leg if the recorded issuer is missing or differs (TS2 L716-722).

### 6.3 Parameters

| Param | Value | Source |
|---|---|---|
| `response_type` | `code` | OAuth 2.1 §4.1.1 |
| `client_id` | pre-registered id, DCR id, or CIMD URL | §5 |
| `redirect_uri` | the exact registered string | OAuth 2.1 §2.3.1 (exact match; loopback port excepted) |
| `code_challenge` | `BASE64URL(SHA256(ASCII(code_verifier)))`, no padding | RFC 7636 §4.2 |
| `code_challenge_method` | `S256` | SC26 L53 |
| `state` | ≥128-bit CSPRNG, base64url | SC26 L75-76 (SHOULD); Sherpa also needs it to route the callback |
| `scope` | §6.4 | A26 L124-134 |
| `resource` | canonical MCP URI: the PRM `resource` verbatim, else the canonicalised server URL. **Always sent** | A26 L215-252 |
| `prompt` | `consent` when the scope contains `offline_access` (TS1 L811-816, TS2 L1222; OIDC Core §11) | SDK behaviour |

PKCE details:
- `code_verifier` must be 43-128 characters from `[A-Za-z0-9-._~]` (RFC 7636 §4.1). Generate 32 random bytes and base64url-encode them to get 43 characters.
- Test vector (RFC 7636 App. B, verified locally with SHA-256): verifier `dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk` → challenge `E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM`.

### 6.4 Scope selection (A26 L124-134)

1. Use the `scope` from the 401 challenge if present.
2. Otherwise use **all** PRM `scopes_supported`.
3. Otherwise omit `scope`.

Additional rules:
- The challenge scope MUST NOT be assumed to relate to `scopes_supported` in any particular way (A26 L105-108).
- Optionally append **`offline_access`** if AS `scopes_supported` contains it (A26 L308). TS2 does so only when the client's `grant_types` include `refresh_token` (TS2 L664-669).
- Servers SHOULD NOT put `offline_access` in their challenges or PRM (A26 L311-313).
- TS1/TS2 add a third fallback, `clientMetadata.scope` (TS1 L274, TS2 L666).
- Do not add `openid` unless the server asks. If `openid` is requested and an `id_token` comes back, either validate it fully (with `nonce`) or ignore it. MCP never needs it.

### 6.5 CSRF and nonce

- OAuth 2.1 §2.3.3: clients that confirmed AS PKCE support MAY rely on PKCE for CSRF protection; `nonce` covers OIDC.
- MCP still says clients SHOULD use and verify `state` and discard responses where it is missing or mismatched (SC26 L75-76).
- Sherpa: always send `state`. Send `nonce` only if `openid` is in scope.

### 6.6 Example

Line breaks added for display:

```
https://auth.example.com/tenant1/authorize?response_type=code
 &client_id=https%3A%2F%2Fsherpa.example%2Foauth%2Fmcp-client.json
 &redirect_uri=https%3A%2F%2Fsherpa.example%2Foauth%2Fcallback
 &code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256
 &state=af0ifjsldkj3Xq8...&scope=files%3Aread%20offline_access&prompt=consent
 &resource=https%3A%2F%2Fmcp.example.com%2Fmcp
```

Before opening the browser, show a consent sheet:
- the MCP server origin,
- the **AS host** (RFC 9728 §7.8 phishing guidance; CIMD-02 §8.5),
- the scopes.

Open the URL only through the system auth session (§12). Never use a WebView (RFC 8252 §8.12) and never a shell (SBP26).

---

## 7. Authorization response (callback)

Callback examples:
```
https://sherpa.example/oauth/callback?code=SplxlOBeZQQYbYS6WxSbIA&state=af0ifjsldkj3Xq8...&iss=https%3A%2F%2Fauth.example.com%2Ftenant1
https://sherpa.example/oauth/callback?error=access_denied&state=...&iss=https%3A%2F%2Fauth.example.com%2Ftenant1
```

Processing order:
1. Match the redirect URI, without its query, against the expected redirect.
2. Look up the pending record by `state`. If there is **no record, it is expired or already used → drop it silently** (log only).
3. **`iss` validation** (A26 L196-213; RFC 9207 §2.4), done **before** reading `error` or redeeming `code`.
   - Form-decode `iss`, then compare it with the recorded issuer by **simple string comparison**.
   - **No** scheme/host case folding, default-port elision, trailing-slash or percent-encoding normalisation.

   | `authorization_response_iss_parameter_supported` | `iss` present? | Action |
   |---|---|---|
   | `true` | yes | compare; mismatch → reject |
   | `true` | no | **reject** |
   | `false`/absent | yes | compare; mismatch → reject (local-policy row, A26 L207) |
   | `false`/absent | no | proceed |

   - On mismatch the client **MUST NOT act on or display** `error`, `error_description` or `error_uri` (A26 L213).
   - TS2: `validateAuthorizationResponseIssuer` (L349-356) uses strict `!==`. It is a no-op when there is no expected issuer. `IssuerMismatchError` deliberately does not extend `OAuthError`, so `auth()`'s retry logic cannot swallow it (L44-79). For error-shaped callbacks it validates `iss` first and only then surfaces `error` (L423-449).
   - Expect a future revision to make AS `iss` a MUST (A26 L209).
4. If `error` is present, map it to UI. `access_denied` means the user cancelled; also expect `invalid_scope`, `invalid_target`, `server_error` and `temporarily_unavailable`. Delete the pending record.
5. If `code` is present, delete the pending record (one-time use) and redeem the code at the **recorded** `token_endpoint`. Never re-derive it from fresh discovery.

---

## 8. Token request and response

```http
POST /tenant1/token HTTP/1.1
Host: auth.example.com
Content-Type: application/x-www-form-urlencoded
Accept: application/json

grant_type=authorization_code&code=SplxlOBeZQQYbYS6WxSbIA
&redirect_uri=https%3A%2F%2Fsherpa.example%2Foauth%2Fcallback
&code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk
&client_id=https%3A%2F%2Fsherpa.example%2Foauth%2Fmcp-client.json
&resource=https%3A%2F%2Fmcp.example.com%2Fmcp
```
(TS1 L833-871, TS2 L1240-1289; RFC 8707 §2.2; A26 L220.)

```http
HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: no-store

{"access_token":"eyJhbGciOi...","token_type":"Bearer","expires_in":3600,
 "refresh_token":"tGzv3JOkF0XG5Qx2TlKWIA","scope":"files:read offline_access"}
```

Response handling:
- Accept `token_type` case-insensitively and require `bearer`. Other types, such as `DPoP`, are out of scope until supported; TS2 has DPoP from SEP-1932, which is not in the core spec.
- `expires_in` → compute `expires_at` with a 30-60 s skew.
- If `scope` is absent, the granted scope equals the requested scope (RFC 6749 §5.1). Store both the requested and the granted scope. For step-up decisions TS2 conservatively treats an absent `scope` as empty (TS2 L382-404).
- TS1/TS2 strip unknown members from the stored token (`OAuthTokensSchema.strip()`). Sherpa should ignore `id_token` unless OIDC is used.
- **Token response errors** (RFC 6749 §5.2, plus RFC 8707 §2): `400 {"error":"invalid_grant"|"invalid_client"|"unauthorized_client"|"invalid_request"|"unsupported_grant_type"|"invalid_scope"|"invalid_target", "error_description":"..."}`. `invalid_client` may come back as 401.
- TS2 also handles a 200 body that contains `error` (L1282-1288).
- **Refuse to send a token request to non-https endpoints**, loopback excepted (TS2 `InsecureTokenEndpointError`, L122-132).

---

## 9. Using, refreshing and rotating tokens

**Using tokens:**
- Send `Authorization: Bearer <token>` on **every** HTTP request to the MCP server (A26 L262-279). In 2026-07-28 that covers every POST, including `subscriptions/listen`; in the legacy era it also covers GET SSE and DELETE.
- Never put the token in the query string.
- **Never send a token to anything except the MCP server it was issued for.** Look it up by (canonical resource, issuer) where the issuer is currently in the PRM `authorization_servers` (A26 L292).
- Do not attach it to metadata, AS endpoints, icons (01: fetch icons without credentials), URL-elicitation pages, or cross-origin redirects. Disable auto-redirect for MCP requests and handle redirects manually; whether dart:io carries `Authorization` across redirects is **UNVERIFIED**.

**Refreshing:**
- Refresh proactively before `expires_at`, and reactively on a 401 (any 401 with a refresh token present → try refresh once).

```http
POST /tenant1/token HTTP/1.1
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token&refresh_token=tGzv3JOkF0XG5Qx2TlKWIA
&client_id=https%3A%2F%2Fsherpa.example%2Foauth%2Fmcp-client.json&resource=https%3A%2F%2Fmcp.example.com%2Fmcp
```
- Include `resource`, as TS1 L907-922 and TS2 L1330-1346 do (RFC 8707 §2.2 example L353-365).
- `scope` is optional and MUST NOT exceed the original grant (OAuth 2.1 §4.3.1). Refresh can never widen scope.

**Rotation:**
- For public clients the AS MUST rotate refresh tokens (SC26 L34) or sender-constrain them (OAuth 2.1 §4.3.1).
- If a new refresh token is returned the client MUST discard the old one (OAuth 2.1 §4.3.2). If none is returned, keep the old one (TS1 L921, TS2 L1331).
- **Reuse detection revokes the whole grant.** When an invalidated refresh token is presented, the AS "will revoke the active refresh token as well as the access authorization grant" (OAuth 2.1 §4.3.1). Therefore:
  - **single-flight refresh** per (issuer, client_id, resource), shared by all concurrent requests, background isolates and app extensions;
  - write the new token set to secure storage **before** using it, atomically;
  - treat a crash between the token response and the write as "re-auth may be needed".

**MUST NOT assume a refresh token** is issued (A26 L309).

**Error handling** (what the SDKs do, then Sherpa):

| Condition | TS1 `auth()` L186-203 | TS2 `auth()` L642-660 / refresh L797-821 | Sherpa |
|---|---|---|---|
| `invalid_client` / `unauthorized_client` (any leg) | `invalidateCredentials('all')`, retry once | invalidate `client` + `tokens`, warn, retry once | Drop the DCR registration for this issuer (never drop a pre-registered or CIMD id silently; surface it instead) and the tokens, then re-register once |
| `invalid_grant` | invalidate `tokens`, retry once | same (also `invalid_dpop_proof`) | Drop the tokens; interactive re-auth only on user action or foreground |
| refresh → network error / `server_error` / non-OAuth | swallow, fall through to a **new interactive authorization** | warn, fall through to a new authorization | **Do not open a browser.** Keep the tokens, mark the server "offline", retry with backoff |
| refresh → other OAuth error (`invalid_scope`, `invalid_target`, …) | rethrow | rethrow | rethrow, surface to the user |
| 401 right after a successful auth | throw "Server returned 401 after successful authentication" (TS1 streamableHttp L330-332) | throw `ClientHttpAuthentication` "Server returned 401 after re-authentication" (TS2 L5760) | Circuit breaker: one auth attempt per request; then surface |
| issuer mismatch / insecure token endpoint | n/a | fatal, not retried | fatal |

**Revocation:** on "disconnect server", call `revocation_endpoint` (RFC 7009) if advertised, then wipe local state. This is not required by MCP.

---

## 10. Step-up authorization (403 `insufficient_scope`)

Server response (A26 L332-377):
```http
HTTP/1.1 403 Forbidden
WWW-Authenticate: Bearer error="insufficient_scope", scope="files:write",
                         resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
                         error_description="File write permission required for this operation"
```

Client algorithm (A26 L379-405):
1. Parse the challenge.
2. Compute **required = previously requested scopes ∪ challenged scopes**, plus the scopes the current token was granted.
   - TS2: `computeScopeUnion(this._scope, tokens?.scope, challenge.scope)`, de-duplicated in first-seen order with no hierarchy handling (TS2 L374-381, L5423).
   - 2025-11-25 did not require the union and told servers to include existing scopes themselves (A25-11 L514-524). Clients must therefore work with both styles; the union handles both.
3. Re-authorize **interactively**. A refresh cannot add scopes, so TS2 forces re-authorization when the union is a strict superset of the token's scope (`isStrictScopeSuperset`, L399-404; `forceReauthorization`, L797).
4. Retry the original request **a few times at most**. TS2 default: `maxStepUpRetries = 1` (`DEFAULT_MAX_STEP_UP_RETRIES`, L5281). TS1 stops when the same `WWW-Authenticate` header repeats (streamableHttp L355-357).
5. Track attempts per (server, operation, scope set) (A26 L401-402). Cache recent denials to avoid loops (SBP26 Scope Minimization).

Known bugs and options in the SDKs:
- **TS1 bug:** on 403 it calls `auth()` with the new scope. If a refresh token exists, `auth()` *refreshes* (no `scope` parameter) and returns AUTHORIZED. The retry gets the same 403 and fails (TS1 L351-365 + streamableHttp L350-375). TS1 also *replaces* the scope instead of taking the union.
- **TS2** offers `onInsufficientScope: 'reauthorize' | 'throw'` (default `'reauthorize'`, L5388). `'throw'` raises `InsufficientScopeError{requiredScope, resourceMetadataUrl, errorDescription}` so the host can show its own UI (L133-193).

**Sherpa UX:**
- The agent loop must pause the tool call and show "Additional permissions required: files:write on mcp.example.com (via auth.example.com) [Authorize]". The MCP Inspector does the same (`docs/docs/2026-07-28/tools/inspector/authorization.mdx` "Mid-session re-authorization").
- If declined, return a tool error to the model.
- Clients acting for themselves (`client_credentials`) MAY abort instead (A26 L383-384).

---

## 11. Redirect URIs for a native mobile app

### 11.1 RFC 8252 / OAuth 2.1 options

| Option | Rule | Mobile verdict |
|---|---|---|
| **Claimed https** (Universal Links / App Links) | RFC 8252 §7.2; "native apps SHOULD use them over the other options where possible", because the OS guarantees the destination app | **Primary** |
| **Private-use scheme** | RFC 8252 §7.1: **reverse-DNS of a domain you control**, e.g. `com.example.app:/oauth2redirect/example-provider` (single slash). ASes SHOULD reject schemes without a `.` (§8.4; OAuth 2.1 §2.3.1). OAuth 2.1 §8.4.3: "should only be used if the previously mentioned more secure options are not available", because other apps can register the same scheme | **Fallback** |
| **Loopback** `http://127.0.0.1:{port}/…` / `http://[::1]:{port}/…` | RFC 8252 §7.3; the AS MUST allow any port. Meant for desktop | Not for iOS (no reliable listener while backgrounded). Possible on Android but pointless; skip |
| Embedded WebView | RFC 8252 §8.12: native apps **MUST NOT** use embedded user-agents | Forbidden |

### 11.2 MCP-specific tension (Risk R1)

- SC26 L42-43: "All redirect URIs **MUST** be either `localhost` or use HTTPS". The same text is in A25-06 and A25-11.
- OAuth 2.1 §1.5 says the same about "OAuth protocol URLs", but OAuth 2.1 §8.4.3 still defines private-use schemes for native apps.
- Read literally, MCP forbids custom schemes. MD enforces that literal reading: `_validateOAuthRedirectUri` accepts only https, or http on loopback (MD L1323-1336).
- TS2 explicitly anticipates custom schemes: `deriveApplicationType` returns "native" for them (TS2 L562-574).
- OIDC native clients can **only** register custom schemes or loopback (§5.4).
- **Conclusion:** use **claimed https** wherever possible, which is spec-clean. Keep the custom scheme as a documented, per-AS fallback.

### 11.3 iOS: `ASWebAuthenticationSession`

- `ASWebAuthenticationSession.Callback` is available from **iOS 17.4 / macOS 14.4** (`https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/callback.md`). It has:
  - `.customScheme(String)`, which matches URLs with that scheme;
  - `.https(host:path:)`, where **the host must be a member of a domain associated with the app** (Associated Domains; `…/callback/https(host:path:).md`);
  - `matchesURL(_:)`.
- If the default browser lacks `CallbackURLMatchingIsSupported`, the system uses Safari (`callback.md` "Important").
- Developer-forum reports say https callbacks also need the `webcredentials:` service in Associated Domains, plus a valid `apple-app-site-association` (`https://developer.apple.com/forums/thread/805416`, `https://support.auth0.com/center/s/article/auth0-https-scheme-does-not-work-for-ios-universal-link`). **UNVERIFIED** in Apple docs; configure both `applinks:` and `webcredentials:` anyway.
- Before 17.4 only `init(url:callbackURLScheme:completionHandler:)` exists, so https callbacks are unavailable and a custom scheme is required (`https://developer.apple.com/forums/thread/769749`).
- `prefersEphemeralWebBrowserSession` (iOS 13+) means no shared Safari cookies: no SSO, and no "wants to use … to sign in" alert.
- The session intercepts the callback itself; the custom scheme does not need to be in `CFBundleURLTypes` (**UNVERIFIED**). This also limits custom-scheme hijacking compared with Android.

### 11.4 Android: Auth Tab / Custom Tabs + App Links

- **Auth Tab** (`androidx.browser:browser:1.9.0`, Chrome **137+**) (`https://developer.chrome.com/docs/android/custom-tabs/guide-auth-tab`):
  - `AuthTabIntent.launch(launcher, uri, redirectScheme)` for a custom scheme;
  - `launch(launcher, uri, redirectHost, redirectPath)` for https. "When using https, Digital Asset Link verification is required"; `http` is not allowed.
  - Results: `RESULT_OK`, `RESULT_CANCELED`, `RESULT_VERIFICATION_FAILED`, `RESULT_VERIFICATION_TIMED_OUT`.
  - On unsupported browsers it falls back to a Custom Tab, and the app gets `RESULT_CANCELED` when the tab closes. The redirect must then arrive through an **intent filter**. Check support with `CustomTabsClient.isAuthTabSupported()`.
- **Ephemeral Custom Tabs:** Chrome 136+, `isEphemeralBrowsingSupported` (`https://developer.chrome.com/docs/android/custom-tabs/guide-ephemeral-tab`). `setEphemeralBrowsingEnabled(true)` exists on both builders (flutter_web_auth_2 `TabBuilderWrapper.kt` L12-47).
- **App Links:**
  - `<intent-filter android:autoVerify="true">` with `VIEW`/`DEFAULT`/`BROWSABLE` and `https` + host + path;
  - `https://sherpa.example/.well-known/assetlinks.json` with `delegate_permission/common.handle_all_urls` and the release-signing SHA-256 fingerprints. Play App Signing uses a different key, so list both.
  - Custom scheme: an intent filter with `android:scheme="example.sherpa"`. Other apps can claim it; PKCE limits the damage.
- **`taskAffinity`:** `flutter_web_auth_2` advises `android:taskAffinity=""` on exported activities, including `CallbackActivity` (its README L94). `flutter_appauth` says *removing* it fixes returns (its README L240). Test on the chosen plugin only.

### 11.5 Recommended Sherpa redirect configuration

- **Primary:** `https://sherpa.example/oauth/callback` (Associated Domains `applinks:` + `webcredentials:`; Android `autoVerify`).
  - The callback **web page** loads when the app does not intercept: app not installed, verification failed, or iOS < 17.4.
  - It must contain no third-party scripts, send `Referrer-Policy: no-referrer` and `Cache-Control: no-store`, and only say "Return to Sherpa".
  - It must never log query strings server-side, because the code is in them.
- **Fallback:** `example.sherpa:/oauth/callback` (reverse-DNS of the TBD domain). Use it only with DCR/pre-registration ASes, or through the "legacy" CIMD document.
- Use **one fixed redirect per `client_id`**. Mix-up defence via per-issuer redirect URIs (RFC 9700 §4.4.2.2) cannot work with CIMD, so rely on `iss` plus the recorded per-flow issuer.

---

## 12. Flutter/Dart helpers (pub.dev, checked 2026-10-18)

| Package | Version (date) | Maintainer / score | What it does | Custom scheme | https callback | Ephemeral | Verdict |
|---|---|---|---|---|---|---|---|
| `flutter_web_auth_2` | **5.1.0** (2026-08-12); `6.0.0-alpha.8` (2026-09-08) needed for built-in KGP/AGP 9+ | femtopedia.de; 150/160 points, ~595k downloads/30d | Browser step only: returns the callback URL. iOS: `ASWebAuthenticationSession`, using `Callback.https(host:path:)` / `.customScheme` on iOS ≥ 17.4, else the legacy init (Swift L84-103). Android: **Auth Tab** (`AuthTabIntent`, androidx.browser 1.9.0) with `CustomTabsIntent` fallback (`AuthenticationManagementActivity.kt` L103-135, L164-180) plus a `CallbackActivity` intent filter. iOS min 11.0 (Package.swift), Android minSdk 21 | yes | yes: `callbackUrlScheme:'https'` + **required** `httpsHost`/`httpsPath` options on Android and iOS ≥ 17.4 (`options.dart` L144-160) | `preferEphemeral` (iOS `prefersEphemeralWebBrowserSession`; Android `setEphemeralBrowsingEnabled`; with ephemeral on, Auth Tab is used only on Chrome/Edge ≥ 141, otherwise Custom Tabs) | **Use it** for `BrowserAuthenticator` |
| `flutter_appauth` | **12.1.0** (2026-08-29); `13.0.0-dev.1` | dexterx.dev; 160/160, ~418k/30d | Wraps AppAuth-iOS **2.1.0** and AppAuth-Android **0.11.1**. Does its own discovery (OIDC `issuer + /.well-known/openid-configuration`, or an explicit `serviceConfiguration`), PKCE, state and token exchange natively. `additionalParameters` can carry `resource`. Returns `codeVerifier`, `nonce`, `authorizationAdditionalParameters` | yes (Android `appAuthRedirectScheme` manifest placeholder) | **UNVERIFIED** (no Auth Tab; no `Callback.https`) | `ExternalUserAgent.ephemeralAsWebAuthenticationSession` (iOS) | **Avoid.** Hides the MCP-specific logic (RFC 8414-first discovery order, issuer echo, PKCE refusal, RFC 9207 `iss`, issuer keying, step-up) in native code that cannot be unit-tested in Dart. README warns iOS `Cache.db` can hold the token response (README L261) |
| `oauth2` | **2.0.5** (2025-10-20) | tools.dart.dev; 160/160 | Pure Dart. Auth-code grant with PKCE S256 (`AuthorizationCodeGrant`) and `state` check. **The token request body is fixed** (`_handleAuthorizationCode`, `authorization_code_grant.dart` L295-322), so `resource` cannot be added. No discovery, DCR, CIMD or `iss`. Refresh sends `scope` | n/a | n/a | n/a | **Do not use** (cannot meet the RFC 8707 MUST) |
| `flutter_secure_storage` | **11.2.0** (2026-09-16) | steenbakker.dev; 160/160 | iOS Keychain (`KeychainAccessibility.first_unlock_this_device` etc.). Android: AES-GCM data plus an RSA-OAEP-wrapped key in Android Keystore. EncryptedSharedPreferences backend **removed** in 11.0.0; minSdk 24; optional biometrics | — | — | — | **Use** for `SecretStore` |
| `app_links` | 7.2.2 (2026-10-06) | cow-level.ovh; 160/160 | Generic App Links / Universal Links receiver | — | — | — | Optional; `flutter_web_auth_2` already captures callbacks |

**Decision: implement the OAuth logic in pure Dart.** It goes in `sherpa_core` (it already has `common/clock.dart`) or a sibling pure-Dart package such as `sherpa_mcp`; see Q8. It needs `package:http` and `package:crypto`. The Flutter app provides:
```dart
abstract interface class BrowserAuthenticator {         // Flutter impl: flutter_web_auth_2
  /// Opens [authorizationUrl] in the system auth session; completes with the full callback URL.
  /// Throws AuthCancelled / BrowserUnavailable / RedirectVerificationFailed.
  Future<Uri> authenticate(Uri authorizationUrl, RedirectSpec redirect, {required bool ephemeral});
}
sealed class RedirectSpec { }                            // HttpsRedirect(host, path) | CustomSchemeRedirect(scheme, path)
abstract interface class SecretStore {                   // Flutter impl: flutter_secure_storage
  Future<String?> read(String key); Future<void> write(String key, String value); Future<void> delete(String key);
}
```
Everything else is plain Dart and fully testable with `package:http/testing.dart` `MockClient`, a fake clock and a seeded RNG (production uses `Random.secure()`):
- challenge parsing, PRM/AS discovery, the SSRF policy,
- registration (CIMD/DCR/pre-reg), PKCE/state, URL building,
- callback validation, token client, refresh single-flight, step-up, and issuer-keyed storage schema.

---

## 13. Token and credential storage

- **MUST** store securely (SC26 L30-31; OAuth 2.1 §7.1). Refresh tokens MUST be confidential in storage (A26 L306).
- **Keys:** `mcp.oauth/{issuer}/client` holds the client registration (CR26 L183-191). `mcp.oauth/{issuer}/{client_id}/{resource}/tokens` holds `{access_token, token_type, expires_at, refresh_token?, requested_scope, granted_scope?, issuer, resource}`. Pending flows live in `mcp.oauth/pending/{state}`. Non-secret discovery caches (PRM, AS metadata with fetched-at timestamps) can live in normal app storage.
- **iOS:** Keychain with `first_unlock_this_device`. Background refresh works after the first unlock, and items are not restored to other devices or backups.
- **Android:**
  - `flutter_secure_storage` 11 (Keystore-wrapped AES-GCM).
  - **Disable or exclude Auto Backup** for its prefs. Restored ciphertext cannot be decrypted (`InvalidKeyException`; README L124-136) and backups are an exfiltration path.
- Keep access tokens in memory with a write-through to secure storage. Never put tokens, codes, verifiers or `state` in logs, crash reports or analytics.
- Redact `Authorization`, `code`, `code_verifier`, `refresh_token`, `access_token` and `client_secret` in HTTP logging. JSON-escape attacker-controlled strings in logs, as TS2 does with `JSON.stringify` (L58-62).
- If an NSURLSession-based client is ever used (e.g. `cupertino_http`), use an **ephemeral configuration**: iOS caches responses in `Cache.db` (flutter_appauth README L261). Token responses should carry `Cache-Control: no-store` (RFC 6749 §5.1). The dart:io `HttpClient` has no disk cache.
- When the user removes a server, wipe its tokens, revoke if possible, and keep the issuer's client registration only if other servers use that AS.

---

## 14. Security considerations (client-side checklist)

### 14.1 Audience binding and the token-passthrough ban

- Always send `resource` on authorize, token and refresh requests (SC26 L16-23; A26 L215-252; RFC 9728 §7.4).
- Never reuse a token across servers.
- Servers MUST validate the audience and **MUST NOT pass through** client tokens upstream (SC26 L116-131; SBP26 "Token Passthrough"). For a client this means: never forward a token to another server, and never accept tokens from tool output or servers as credentials.

### 14.2 Confused deputy

- The MUST applies to **MCP proxy servers** that use a static client id with third-party ASes: they must get consent per dynamically registered client (SC26 L107-114; SBP26 "Confused Deputy Problem").
- For Sherpa it matters only if Sherpa ever runs a hosted relay or proxy (Q9).
- Client-side analogue: show consent with the AS host and the MCP server before every interactive authorization, including step-up.

### 14.3 SSRF while fetching metadata from user- or server-supplied URLs (SBP26 "SSRF"; RFC 9728 §7.7)

- **Sources:** `resource_metadata`, `authorization_servers[*]`, every endpoint in AS metadata, and redirect `Location`s.
- **Policy:**
  - https only, except loopback in dev mode.
  - Block private, reserved, loopback and link-local destinations: `10/8`, `172.16/12`, `192.168/16`, `127/8`, `169.254/16`, `::1`, `fc00::/7`, `fe80::/10`. Also block `100.64/10`, `0/8` and IPv4-mapped IPv6.
  - Exception: when the **MCP server URL itself** is in that range (the user explicitly configured a LAN or loopback server), allow same-host endpoints. MD's rule is narrower (MD L1338-1366).
  - Use a vetted IP parser; SBP26 warns about octal, hex and mapped forms.
  - Validate **each redirect hop**, follow same-origin only, and cap at 5.
  - Resolve DNS and check the resolved IP. Pin it through `HttpClient.connectionFactory` (**UNVERIFIED** API fit), otherwise accept the TOCTOU residual risk on mobile.
  - Also enforce timeouts, body-size caps and an `application/json` expectation.
- "MCP clients deployed to a server **MUST**" do this (SBP26). For a phone it is a SHOULD, but home and corporate LANs make it worthwhile.
- **Cross-origin AS hosts are normal** (e.g. `mcp.vendor.com` → `auth.vendor.com` or `login.microsoftonline.com`). Do **not** copy MD's default of rejecting cross-origin OAuth URIs without an app-supplied `OAuthUriValidator` (MD L1338-1366, L254-283). Instead, show the AS host in the consent sheet.

### 14.4 Authorization URL validation (SBP26)

- Allow only `https` (`http` only for loopback in dev). **MUST reject** `javascript:`, `data:`, `file:`, `vbscript:` and anything else (allowlist).
- Never open URLs through a shell.
- `ASWebAuthenticationSession` and Custom Tabs accept only http(s) anyway; still validate first.

### 14.5 Open redirect

- Register exact redirect URIs (SC26 L71-73).
- Verify `state` and discard responses where it is missing or mismatched (SC26 L75-76).
- The https callback page must not redirect anywhere based on query parameters.

### 14.6 Mix-up attacks

- **Mandatory defence:** record the issuer per flow (A26 L192), validate `iss` (§7), and redeem the code only at the token endpoint recorded with that flow (RFC 9700 §4.4.2).
- PKCE alone does not stop mix-up, because the verifier goes to the attacker's token endpoint (SBP26 "Mix-Up Attacks"). The defence depends on honest ASes emitting `iss`.

### 14.7 Localhost or custom-scheme impersonation of a CIMD client

- Anyone can present Sherpa's `client_id` with a redirect they control, unless the AS restricts redirects (SBP26 "Localhost Redirect URI Impersonation"; SC26 L93-101).
- Claimed https redirects plus same-origin `client_id` hosting are the client-side mitigation.

### 14.8 Phishing (RFC 9728 §7.8)

- Display the AS domain and the server domain.
- Use the system browser so password managers and passkeys work. Never use a WebView.

### 14.9 Untrusted strings

- Everything from `WWW-Authenticate`, metadata and callbacks is attacker-controlled. Do not render it as markup or feed it to the LLM unless it has been sanitised.

---

## 15. TS SDK algorithm extraction (reference behaviour)

### 15.1 TS2 `auth(provider, {serverUrl, authorizationCode?, iss?, scope?, resourceMetadataUrl?, forceReauthorization?})`, `authInternal` L670-834

1. `clientMetadata = resolveClientMetadata(provider)` (defaults: `grant_types=['authorization_code','refresh_token']` when interactive; `application_type` derived from the redirect URIs).
2. `cachedState = provider.discoveryState()`. The resource-metadata URL comes from the argument, else from the cache.
3. **Discovery.**
   - If a cached `authorizationServerUrl` exists, reuse the cached AS metadata or re-discover it. Re-fetch the PRM if it is missing, swallowing non-`TypeError` errors.
   - Otherwise call `discoverOAuthServerInfo`:
     - PRM: the header URL, or path-aware then root. **Every PRM failure except `TypeError` is swallowed**; a ZodError from a malformed PRM is swallowed too.
     - AS = `authorization_servers[0]`, otherwise `new URL('/', serverUrl)` (legacy).
     - AS metadata via `buildDiscoveryUrls` with issuer-echo validation.
4. `issuer = metadata?.issuer ?? String(authorizationServerUrl)`. This is the **credential binding key** (SEP-2352). `saveAuthorizationServerUrl(issuer)` is called.
5. **Callback leg** (`authorizationCode` set): `recordedIssuer = cachedState.authorizationServerMetadata.issuer ?? cachedState.authorizationServerUrl`. A mismatch throws `AuthorizationServerMismatchError`; a missing record also throws when the provider supports `saveDiscoveryState`.
6. `saveDiscoveryState(fresh)`.
7. `resource = selectResourceURL(...)`. It is `undefined` when there is no PRM, so **no `resource` is sent then**, which deviates from A26 L252. The PRM string is used verbatim.
8. `scope = determineScope(...)`: challenge, else PRM `scopes_supported`, else `clientMetadata.scope`; plus `offline_access` when the AS lists it and `grant_types` include `refresh_token`.
9. Client info:
   - `provider.clientInformation({issuer})` passes through the issuer-stamp filter, and a mismatch reads as `undefined`.
   - If the provider cannot save → `AuthorizationServerMismatchError`. Unstamped values are stamped and saved.
   - If none: CIMD (AS flag **and** `clientMetadataUrl`), else `registerClient` (DCR).
   - On the callback leg with no client info → `Error('Existing OAuth client information is required when exchanging an authorization code')`.
10. If `authorizationCode` is set (or the flow is non-interactive): `validateAuthorizationResponseIssuer` → `fetchToken` → `saveTokens({...tokens, issuer})` → `'AUTHORIZED'`.
11. Tokens pass the issuer filter. If there is a `refresh_token` and `!forceReauthorization` → refresh. Failures behave as in §9.
12. `startAuthorization(...)`: requires `response_types_supported ∋ 'code'`; checks S256 **only if the list is present**; generates PKCE with `pkce-challenge`; sets `response_type, client_id, code_challenge, code_challenge_method=S256, redirect_uri, state?, scope?, prompt=consent? (offline_access), resource?`. Then `saveCodeVerifier` and `redirectToAuthorization`, returning `'REDIRECT'`.
13. Wrapper `auth()`: `invalid_client`/`unauthorized_client` → invalidate `client` + `tokens`, run once more; `invalid_grant`/`invalid_dpop_proof` → invalidate `tokens`, run once more.

### 15.2 TS2 transport (`StreamableHTTPClientTransport`, L5339-5790)

- **401:** extract params; `_scope = union(_scope, challenge.scope)`; `onUnauthorized` → `auth()`; retry once; a second 401 raises an error.
- **403** with `error === 'insufficient_scope'` → `_stepUpAuthorize`: honours `onInsufficientScope`, enforces `maxStepUpRetries`, takes the union with the token scope, applies the `forceReauthorization` gate, then retries.
- Redirect policy: `'same-origin'` by default (`fetchWithinOrigin`).

### 15.3 TS1 differences (1.32.1)

- No metadata-issuer validation. The comment says "this version does not check that the metadata document echoes the URL it was fetched from" (L258-262).
- No `iss` validation.
- `issuersMatch` normalises by URL parsing (L146-156), whereas TS2 compares strings with the trailing-slash tolerance (L234-236).
- No `application_type`.
- `extractWWWAuthenticateParams` recognises only Bearer.
- AS discovery continues on `<500` only (502 is not special).
- Step-up replaces the scope instead of taking the union, and is broken when a refresh token exists (§10).

### 15.4 Spec gaps in both SDKs (do NOT replicate)

1. They proceed when `code_challenge_methods_supported` is absent.
2. They omit `resource` when there is no PRM.
3. They keep 2025-03-26 default-endpoint fallbacks.
4. `WWW-Authenticate` parsing is regex-based.
5. `state` is never verified by the SDK; it is left to the host.
6. A network failure during refresh falls through to an interactive re-authorization.

---

## 16. End-to-end sequence for Sherpa (first 401 → refreshed token)

Setup: MCP server `https://mcp.example.com/mcp`; AS issuer `https://auth.example.com/tenant1`; Sherpa CIMD `https://sherpa.example/oauth/mcp-client.json`; redirect `https://sherpa.example/oauth/callback`. Transport headers are as in 01.

**S1. Unauthenticated probe** (2026-07-28 era; in the legacy era this is `initialize`):
```http
POST /mcp HTTP/1.1
Host: mcp.example.com
Content-Type: application/json
Accept: application/json, text/event-stream
Mcp-Method: server/discover

{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28", "...": "..."}}}
```
```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp", scope="files:read"
```
→ parse: `resource_metadata` = …/mcp, `scope` = `files:read`. Pass the URL through the SSRF policy.

**S2. PRM.** If the header carried no URL, probe `/.well-known/oauth-protected-resource/mcp`, then `/.well-known/oauth-protected-resource`.
```http
GET /.well-known/oauth-protected-resource/mcp HTTP/1.1
Host: mcp.example.com
Accept: application/json
```
```http
HTTP/1.1 200 OK
Content-Type: application/json

{"resource":"https://mcp.example.com/mcp","authorization_servers":["https://auth.example.com/tenant1"],
 "scopes_supported":["files:read"],"bearer_methods_supported":["header"]}
```
→ `resource` is identical to the request URL ✓. If the AS set changed since the last visit, drop the old AS's DCR credentials and tokens (CR26 L185-191).

**S3. AS metadata** (issuer has a path → 3 candidates):
```http
GET /.well-known/oauth-authorization-server/tenant1 HTTP/1.1
Host: auth.example.com
Accept: application/json
```
`200` with the §4.3 document. Checks: `issuer` ✓ identical; `code_challenge_methods_supported ∋ S256` ✓; `response_types_supported ∋ code` ✓; endpoints https ✓. Record `issuer` and `authorization_response_iss_parameter_supported=true`. On 404, try `/.well-known/openid-configuration/tenant1`, then `/tenant1/.well-known/openid-configuration`.

**S4. Client id.** There is no pre-registered client for this issuer, and `client_id_metadata_document_supported: true` → `client_id = https://sherpa.example/oauth/mcp-client.json`. The AS fetches that document during S6. Without the flag, use DCR (§5.4) and persist the result keyed by issuer. Without DCR, prompt the user (§5.3).

**S5. Scope and PKCE.** `scope = "files:read"` (from the challenge) + `offline_access` (the AS lists it) → `"files:read offline_access"`. Generate `code_verifier`, `code_challenge` and `state`. Persist the `PendingAuthorization` (§6.2). Show the consent sheet (server `mcp.example.com`, sign-in at `auth.example.com`, scopes).

**S6. Browser.** `BrowserAuthenticator.authenticate(<§6.6 URL>, HttpsRedirect('sherpa.example','/oauth/callback'), ephemeral:false)` → the user signs in → the browser returns:
```
https://sherpa.example/oauth/callback?code=SplxlOBeZQQYbYS6WxSbIA&state=af0ifjsldkj3Xq8...&iss=https%3A%2F%2Fauth.example.com%2Ftenant1
```

**S7. Callback validation.** The pending record for `state` exists and has not expired; consume it. `iss` decodes to `https://auth.example.com/tenant1`, which equals the recorded issuer ✓ (row 1). Then take `code`.

**S8. Token exchange** at the **recorded** `token_endpoint` (§8 request) → `200 {access_token, token_type:"Bearer", expires_in:3600, refresh_token, scope}`. Store it under `(issuer, client_id, resource)`.

**S9. Retry S1** with `Authorization: Bearer eyJ…` → `200` → continue era negotiation as in 01.

**S10. Step-up at runtime.** `tools/call` → `403` + `WWW-Authenticate: Bearer error="insufficient_scope", scope="files:write", resource_metadata="…"`. Compute the union: `files:read offline_access files:write`. The token's granted scope lacks `files:write`, so an interactive re-authorization is required: consent sheet → S5-S8 with the union scope → retry `tools/call` once. A second 403 → tool error "permission not granted".

**S11. Expiry and refresh.** On `expires_at - 60s`, or on a 401 with `error="invalid_token"`, start a single-flight refresh:
```http
POST /tenant1/token HTTP/1.1
Host: auth.example.com
Content-Type: application/x-www-form-urlencoded
Accept: application/json

grant_type=refresh_token&refresh_token=tGzv3JOkF0XG5Qx2TlKWIA
&client_id=https%3A%2F%2Fsherpa.example%2Foauth%2Fmcp-client.json&resource=https%3A%2F%2Fmcp.example.com%2Fmcp
```
```http
HTTP/1.1 200 OK
Cache-Control: no-store
Content-Type: application/json

{"access_token":"eyJ...new","token_type":"Bearer","expires_in":3600,"refresh_token":"8xLOxBtZp8...rotated","scope":"files:read offline_access files:write"}
```
→ atomically replace the access token and the **rotated refresh token** in secure storage, then retry the request.

- `400 {"error":"invalid_grant"}` → delete the tokens and mark the server "sign-in required". Run S5-S8 only on user action.
- A network error → keep the tokens, back off, and do not open a browser.

---

## 17. Unit tests to write (pure Dart, `MockClient` + fake clock/RNG)

**WWW-Authenticate parser**
1. A single Bearer challenge with quoted `resource_metadata` and `scope`.
2. Unquoted token values; mixed-case scheme and param names.
3. Several challenges in one header (`DPoP algs="ES256", Bearer resource_metadata="…"`), and several header lines folded with `, `.
4. Quoted-string with `\"` and commas: `scope="a,b c"`.
5. `error_description="need scope=x"` placed before `scope=` gives `scope` from the real param (regression against the SDK regex).
6. A duplicate `scope` param → reject or take the first, and log.
7. `token68` challenges (`Basic`, `Negotiate abc==`) are ignored without crashing.
8. A `DPoP` challenge carrying `resource_metadata` is honoured.
9. An invalid or relative `resource_metadata` URL → treated as absent, then well-known probing.

**PRM discovery**

10. The header URL is used verbatim, and there is no well-known probe when it succeeds.
11. No header, path `/mcp` → `/.well-known/oauth-protected-resource/mcp` → on 404 → `/.well-known/oauth-protected-resource`.
12. A server at root (`https://h/`) → a single root probe.
13. A trailing slash (`/mcp/`) is stripped; the query is preserved after the path (`/.well-known/…/mcp?tenant=1`).
14. 500 on the path probe → error (no fallback); 502 → fallback.
15. 200 with an HTML body → fallback to the next candidate.
16. `resource` identical → ok; same-origin prefix → ok, with a logged relaxation; `/api` vs `/api123` → reject; cross-origin → reject.
17. Empty or missing `authorization_servers` → error (unless compatibility mode is on).
18. A new 401 with a different `resource_metadata` → PRM re-fetch; an AS change triggers credential invalidation.

**AS discovery**

19. A path issuer gives exactly the three URLs, in spec order; a pathless issuer gives two.
20. Issuer `https://as/` (path `/`) is treated as pathless; `https://as/t1/` gives `/.well-known/oauth-authorization-server/t1`.
21. Fallback on 4xx/502; 503 → error.
22. An `issuer` mismatch → that document is not used and the next candidate is tried; if all mismatch → `IssuerMismatch` (ASD26 attacker example).
23. The trailing-slash tolerance is accepted only in the documented direction.
24. `code_challenge_methods_supported` absent → **refuse**; `["plain"]` → refuse; `["S256"]` → ok.
25. `response_types_supported` without `code` → refuse.
26. An `http:` token endpoint (non-loopback) → refuse; `javascript:` authorization endpoint → refuse.
27. OIDC document lacking `jwks_uri` is still accepted if the OAuth fields are present.

**Registration**

28. A pre-registered client for the issuer wins over CIMD and DCR.
29. CIMD is used only when the flag is literally `true` (`"true"` the string → not used).
30. Validation of the CIMD `client_id` constant: https, has a path, no fragment, query or userinfo.
31. DCR body includes `application_type`, `grant_types` including `refresh_token`, `token_endpoint_auth_method:"none"` and the resolved `scope`.
32. The DCR ladder: `invalid_redirect_uri` → the next attempt; maximum 3 attempts; the outcome is cached per issuer.
33. DCR result stored keyed by issuer; another issuer cannot read it.
34. An issuer change with a pre-registered client → surfaced error (no silent use).
35. No CIMD and no `registration_endpoint` → `NeedsUserClientId`.

**Authorization request and callback**

36. The PKCE S256 vector from RFC 7636 App. B; verifier length 43-128 with the allowed characters only.
37. The URL contains every required param; `resource` is the PRM string verbatim (no added `/`); `resource` is present even without a PRM (compatibility mode).
38. Scope selection: challenge > PRM `scopes_supported` > omitted; `offline_access` is appended only when the AS lists it; `prompt=consent` is added with `offline_access`.
39. `state` is unique per flow; an unknown, expired or reused `state` → dropped.
40. The four `iss` rows; exact comparison (case, `:443`, trailing slash and `%2F` differences all mismatch).
41. On an `iss` mismatch with `error=access_denied` → the error text is **not** surfaced.
42. The redirect host or path differs from the pending record → reject.
43. The code is redeemed at the recorded token endpoint even if discovery changed in the meantime.

**Token client**

44. Form encoding; `client_id` for `none`; RFC 6749 form-encoded Basic auth for `client_secret_basic`; method selection matching §5.5.
45. Missing `scope` in the response → granted = requested; `token_type` `bearer` (case-insensitive) accepted, `mac` rejected.
46. Error mapping for `invalid_grant`, `invalid_client` (400 and 401), `invalid_target`, a 200-with-`error` body, and non-JSON 5xx.
47. Refresh sends `resource`; a rotated refresh token replaces the old one; an absent refresh token keeps the old one.
48. **Single-flight:** 10 concurrent 401s → exactly 1 refresh POST.
49. A network error during refresh → no browser launch; tokens kept.
50. `invalid_grant` on refresh → tokens deleted, state "sign-in required".
51. Proactive refresh at `expires_at - skew` via the fake clock.

**Step-up and loops**

52. 403 `insufficient_scope` → union scope; forced interactive re-authorization (no refresh); a single retry.
53. The same 403 after step-up → stop, with a "permission not granted" error.
54. 403 without `WWW-Authenticate` → plain error, no auth flow.
55. 401 → auth → 401 again → circuit breaker, no infinite loop.
56. Step-up declined by the user → tool error; no browser.

**SSRF and redirects**

57. `resource_metadata` pointing at `http://169.254.169.254/…`, `https://10.0.0.1/…`, `https://[::ffff:127.0.0.1]/` or `https://0177.0.0.1/` → blocked.
58. A LAN MCP server (`https://192.168.1.5/mcp`) → its same-host metadata is allowed; a cross-host private IP is blocked.
59. A cross-origin 302 during metadata fetch → not followed; same-origin 301 → followed (≤ 5 hops); POST 302 → not followed.
60. Oversized (>64 KiB) or slow metadata → aborted.
61. A `javascript:` or `data:` authorization endpoint never reaches `BrowserAuthenticator`.

**Storage and binding**

62. A token for server A is never attached to server B (same AS, different `resource`).
63. `Authorization` is never sent to metadata URLs, AS endpoints or icons.
64. Removing a server wipes its tokens and pending flows; a shared-issuer client registration is kept.
65. Logs contain no tokens, codes, verifiers or `state` (snapshot test of the HTTP logger).

---

## 18. Recommendations for Sherpa

1. **Pure-Dart `McpAuth` module** (§12) with interfaces for `BrowserAuthenticator`, `SecretStore`, `http.Client`, `Clock`, `Random` and `UserConsent`. Only the browser step and secure storage are Flutter plugins (`flutter_web_auth_2` 5.1.0, `flutter_secure_storage` 11.2.0). Do not use `flutter_appauth` or `oauth2`.
2. **Apply the 2026-07-28 rules to every server, whatever its era**:
   - `iss` validation, the issuer echo check, issuer-keyed credentials, `application_type` and scope union.
   - All of these are backward compatible with ASes behind 2025-11-25 and 2025-06-18 servers. The one exception is the PKCE-refusal rule (R3).
3. **Register via CIMD first** (after pre-registration). Host `https://<sherpa-domain>/oauth/mcp-client.json` on the **same origin** as a claimed-https redirect. Optionally host a second "legacy" CIMD with a custom-scheme redirect for devices without https callbacks.
4. **Redirects:** `https://<sherpa-domain>/oauth/callback` via Universal Links (iOS ≥ 17.4, `applinks:` + `webcredentials:`) and App Links (Auth Tab or Custom Tabs, `autoVerify`). The fallback is reverse-DNS `<tld>.<name>:/oauth/callback`. Ship a minimal callback web page with no third-party scripts.
5. **Strict discovery:**
   - the spec's URL order;
   - same-origin-only redirects;
   - an SSRF policy that allows LAN servers the user explicitly configured;
   - JSON-only bodies with size and time caps;
   - lenient parsing for unknown members, strict on required fields;
   - **refuse without PKCE S256**.
6. **Always send `resource`**: the PRM value verbatim, else the canonical server URL. Send it on authorize, token and refresh requests.
7. **Persist pending flows** (state → verifier, issuer, endpoints, redirect, resource, scope) with a TTL, so a killed app can complete the callback. Validate `state` before `iss`, and `iss` before the code, error or token handling.
8. **Token lifecycle:**
   - proactive plus reactive refresh, **single-flight**, atomic rotation;
   - never trigger interactive auth on network errors or from the background;
   - `invalid_grant` → "sign-in required" state.
9. **Step-up is user-mediated**: pause the tool call and show the scopes, AS host and server. Use the union scope and a forced re-authorization, with one retry and denial caching.
10. **Consent and transparency UI:** show the server origin, the AS host and the scopes on every interactive authorization. Give each server a "Sign out" action that wipes and revokes.
11. **Optional 2025-03-26 compatibility mode** (default endpoints, AS = MCP origin), off by default (Q7).
12. **Defer DPoP**, `private_key_jwt`/attestation and the ext-auth extensions (Enterprise-Managed, Client Credentials). Design the token model so that `token_type` and per-request proof hooks can be added later.

---

## 19. Risks

- **R1. Custom-scheme redirects vs. MCP's "localhost or HTTPS" MUST.** Some MCP ASes (and MD) reject custom schemes, while OIDC native DCR requires them. Mitigation: claimed https first; a per-issuer fallback ladder; a "legacy" CIMD.
- **R2. iOS < 17.4 has no https callback** in `ASWebAuthenticationSession`, so those users need a custom scheme and lose the R1-clean path. Universal Links callbacks are also reported to be flaky (missing `webcredentials`, AASA CDN caching, simulator differences; Apple forum threads cited in §11.3; **UNVERIFIED** prevalence).
- **R3. The PKCE-refusal MUST can break real servers.** Some older ASes (especially 2025-06-18-era ones, and OIDC providers) omit `code_challenge_methods_supported` but do support PKCE, and both TS SDKs connect to them anyway. Sherpa will look "broken" where Claude/TS-based clients work. Consider an explicit per-server "I accept the risk" override (Q6).
- **R4. Android App Links / Auth Tab verification failures** (`RESULT_VERIFICATION_FAILED`, Play App Signing fingerprint missing from `assetlinks.json`, or browsers without Auth Tab). If the fallback to Custom Tabs lacks a working intent filter, the flow dead-ends at the callback web page.
- **R5. Refresh-token rotation races** (several isolates, background fetch, app extensions) trigger reuse detection, and the AS revokes the entire grant. A cross-process lock is required if any non-main-isolate code refreshes.
- **R6. CIMD domain and identity are long-lived.** Losing the domain lets a third party impersonate Sherpa (CIMD-02 §8.3). Forks and white-label builds need their own `client_id`.
- **R7. SSRF policy vs. LAN servers.** Too strict breaks self-hosted servers; too loose turns the phone into a LAN probe. DNS rebinding cannot be fully prevented without connection pinning.
- **R8. Spec churn.** `iss` is expected to become an AS MUST, DCR can be removed from 2027-07-28 onward, and the CIMD draft is at rev 02 while MCP cites -00. Keep these behind feature flags with versioned tests.
- **R9. Copying SDK shortcuts** (regex challenge parsing, no-PRM → no `resource`, refresh failure → interactive re-auth, step-up via refresh) would replicate known bugs (§15.4).
- **R10. Token leakage through platform caches and backups**: NSURLSession `Cache.db`, Android Auto Backup, crash reporters. Mitigate as in §13.

---

## 20. Open questions for the product owner

- **Q1.** Which **domain** will host Sherpa's CIMD documents, the callback page, `apple-app-site-association` and `assetlinks.json`? Who operates it (uptime, TLS, no redirects)? What is the policy for forks and white-label builds: a configurable `client_id` and redirect at build time?
- **Q2.** **Minimum iOS version.** Is iOS ≥ 17.4 acceptable, so only https callbacks are used? Or must older devices be supported through the custom-scheme fallback and "legacy" CIMD?
- **Q3.** **Ephemeral browser session by default?** Ephemeral is more private and avoids iOS's "wants to sign in" prompt, but loses SSO with the user's existing browser sessions. Should it be per-server?
- **Q4.** Should **interactive OAuth** ever start automatically, for example while an agent run connects to servers? Or only on an explicit user tap? Background runs would then fail fast with "sign-in required".
- **Q5.** **Step-up policy:** always ask, or allow "always approve additional permissions for this server"?
- **Q6.** Allow a **per-server override** to connect to ASes that omit `code_challenge_methods_supported` (non-compliant but common), with a warning? Default: refuse.
- **Q7.** Support **2025-03-26-era auth** (no PRM; AS = MCP origin; `/authorize`, `/token` and `/register` defaults)? Recommendation: behind an advanced toggle, off by default.
- **Q8.** Should the auth module live in `sherpa_core`, which would add `package:http` and `package:crypto` dependencies, or in a separate pure-Dart package such as `sherpa_mcp`?
- **Q9.** Will Sherpa ever operate a **hosted relay or proxy** for MCP? That would make Sherpa itself subject to the confused-deputy MUSTs (SC26 L107-114) and the token-passthrough ban.
- **Q10.** **Biometric gating** for token use, i.e. `flutter_secure_storage` biometric options? This is a trade-off against background refresh.
- **Q11.** Is **DPoP** (sender-constrained tokens; implemented in TS2, not yet in the core spec) or **Enterprise-Managed Authorization** (ext-auth, Stable) in scope for v1?

---

## 21. Verification log (10+ load-bearing claims re-checked against primary sources)

All checks were re-run on 2026-10-18 by grepping the downloaded primary files (spec `.mdx` from raw.githubusercontent.com, RFC/ID `.txt`, vendored tarballs).

| # | Claim | Re-check (source, location) | Result |
|---|---|---|---|
| 1 | AS discovery order for path issuers: OAuth path insertion → OIDC path insertion → OIDC path appending; pathless: OAuth → OIDC | ASD26 L75-92 (identical in A25-11 L135-144) | ✔ confirmed |
| 2 | PRM: use the header URL when present, else path-aware well-known, then root, in that order | ASD26 L39-47; RFC 9728 §3.1 (trailing `/` removal; insertion before path and query) | ✔ confirmed |
| 3 | Registration priority: pre-registered → CIMD (`client_id_metadata_document_supported`) → DCR (`registration_endpoint`) → prompt user | CR26 L13-18 | ✔ confirmed |
| 4 | CIMD minimum fields `client_id`, `client_name`, `redirect_uris`; https with a path; exact match; the AS MUST NOT follow redirects; 5 KB read limit | CR26 L38-41; CIMD-02 §3, §4, §5, §8.7 | ✔ confirmed. Rev 02 is current (datatracker API: rev 02, 2026-07-06) while MCP cites -00; the requirements used here are in both |
| 5 | Refuse if `code_challenge_methods_supported` is absent (both RFC 8414 and OIDC); MUST use S256 | SC26 L50-61 | ✔ confirmed |
| 6 | TS1 and TS2 proceed when `code_challenge_methods_supported` is absent | TS1 `auth.js` L788-791; TS2 `index.mjs` L1210 (`if (metadata.code_challenge_methods_supported && !…includes('S256')) throw`) | ✔ confirmed |
| 7 | RFC 9207 four-row table; exact comparison with no normalisation; error responses must not be displayed on mismatch | A26 L196-213; RFC 9207 §2.4 | ✔ confirmed. Row 3 (iss present, not advertised → compare) is MCP's local-policy choice; RFC 9207 itself says SHOULD *discard* such responses. Wording fixed in §7 |
| 8 | Metadata `issuer` MUST be identical to the issuer used to build the URL (new explicit text in 2026-07-28) | ASD26 L94; RFC 8414 §3.3; absent from A25-11 (the word "identical" does not occur in A25-11 at all) | ✔ confirmed |
| 9 | DCR deprecated in 2026-07-28; DCR MUST send `application_type`; credentials keyed per issuer | CR26 L140-145, L160-163, L183-191; CL26 Minor #8, #9 and Deprecated #4 | ✔ confirmed |
| 10 | Step-up uses the union of previously requested and challenged scopes (new in 2026-07-28; 2025-11-25 referenced the Scope Selection Strategy) | A26 L389-394; A25-11 L551 | ✔ confirmed. CL26 does not list this change; it was found by diffing |
| 11 | "All redirect URIs MUST be either `localhost` or use HTTPS" | SC26 L43; A25-11 L591; A25-06 (Communication Security) | ✔ confirmed |
| 12 | `ASWebAuthenticationSession.Callback` (`.https(host:path:)`, `.customScheme`) is iOS 17.4+; the host must be an associated domain | Apple docs `callback.md` and `https(host:path:).md` (availability metadata "iOS: 17.4.0 -") | ✔ confirmed. The `webcredentials` requirement is **not** in Apple docs; it stays marked UNVERIFIED |
| 13 | `flutter_web_auth_2` 5.1.0 supports https callbacks with `httpsHost`/`httpsPath` and uses Auth Tab on Android | pub archive `ios/.../FlutterWebAuth2Plugin.swift` L84-103; `android/.../AuthenticationManagementActivity.kt` L103-135; `options.dart` L144-160; `android/build.gradle` (`androidx.browser:browser:1.9.0`) | ✔ confirmed. An earlier draft said "iOS 17.4 required" (from the 4.x README); the podspec and Package.swift say iOS 11.0 with runtime `#available` fallbacks. Fixed |
| 14 | The `oauth2` package cannot add `resource` to the token request | `oauth2-2.0.5/lib/src/authorization_code_grant.dart` L295-322 (fixed `body` map; no extra-params hook in the file) | ✔ confirmed |
| 15 | OIDC Registration: `native` ⇒ only custom schemes or loopback; the default is `web` | `openid.net/specs/openid-connect-registration-1_0.html` §2 (`application_type`) | ✔ confirmed |
| 16 | Public-client refresh rotation; reuse revokes the grant; replace the old refresh token | SC26 L33-34; OAuth 2.1 draft-13 §4.3.1-§4.3.2 | ✔ confirmed |

Corrections made during verification:
- §7, row 3: the "local policy" provenance was clarified.
- §12: the iOS minimum for `flutter_web_auth_2` was corrected to 11.0, with https callbacks needing 17.4+.
- §1: refresh-token and step-up changes are marked "not in changelog".
