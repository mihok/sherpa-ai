/// Outcome of the RFC 9207 authorization-response issuer check.
enum IssCheck {
  /// Proceed to `error` / `code` handling.
  ok,

  /// `iss` present and not identical to the recorded issuer.
  mismatch,

  /// The AS advertises `iss` but the response has none.
  missing,
}

/// The four-row table of A26 L196-213 / RFC 9207 §2.4, with simple string
/// comparison: no case folding, default-port elision, trailing-slash or
/// percent-encoding normalisation. [iss] is the form-decoded parameter
/// value.
///
/// | advertised | `iss` present | result |
/// |---|---|---|
/// | true  | yes | compare |
/// | true  | no  | [IssCheck.missing] |
/// | false | yes | compare (MCP local policy; RFC 9207 only says SHOULD discard) |
/// | false | no  | [IssCheck.ok] |
IssCheck checkAuthorizationResponseIssuer({
  required String? iss,
  required String expectedIssuer,
  required bool issParameterSupported,
}) {
  if (iss == null) return issParameterSupported ? IssCheck.missing : IssCheck.ok;
  return iss == expectedIssuer ? IssCheck.ok : IssCheck.mismatch;
}
