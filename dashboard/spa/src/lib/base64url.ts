/** Base64url <-> ArrayBuffer conversions for WebAuthn credentials.
 *
 * The WebAuthn API hands challenge/credential ids as ArrayBuffers, while the
 * dashboard API exchanges them as base64url strings. Both directions lived
 * duplicated (byte-identical) in login.tsx and account.tsx; a divergence here
 * would silently corrupt passkey challenges, so there is now exactly one copy.
 */
/** Surfaced to the operator (login setError / account toast). Direction-
 *  specific so the diagnosis points at the right side. */
const B64URL_DECODE_INVALID =
  "invalid base64url value from server (passkey challenge/credential id)"
const B64URL_ENCODE_INVALID =
  "unsupported argument to base64url encode (expected ArrayBuffer or a view over one; got a malformed WebAuthn credential member)"
/** atob() is a FORGIVING decoder (it strips ASCII whitespace), so the alphabet
 *  must be checked explicitly or "ab cd" silently decodes to wrong bytes. */
// `$` alone is not enough: without the `m` flag it still matches before a
// trailing line terminator, and atob() would then strip that whitespace and
// decode the wrong bytes. Reject any whitespace explicitly.
const B64URL_ALPHABET = /^[A-Za-z0-9_-]+={0,2}$/

export function b64urlToBuffer(s: string): ArrayBuffer {
  // The value comes straight from an unvalidated API response; a missing or
  // null field must surface as a domain error, not a raw TypeError.
  if (typeof s !== "string" || /\s/.test(s) || !B64URL_ALPHABET.test(s)) {
    throw new Error(B64URL_DECODE_INVALID)
  }
  // Accept the canonical padded form or the unpadded form, but reject
  // non-canonical padding ("abcd=") — silently re-padding would hide an
  // upstream encoding bug on the one path that must not corrupt challenges.
  const stripped = s.replace(/=+$/, "")
  const suppliedPad = s.length - stripped.length
  const requiredPad = (4 - (stripped.length % 4)) % 4
  if (suppliedPad !== 0 && suppliedPad !== requiredPad) {
    throw new Error(B64URL_DECODE_INVALID)
  }
  const b64 = (stripped + "=".repeat(requiredPad)).replace(/-/g, "+").replace(/_/g, "/")
  let raw: string
  try {
    raw = atob(b64)
  } catch {
    throw new Error(B64URL_DECODE_INVALID)
  }
  const buf = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i++) buf[i] = raw.charCodeAt(i)
  return buf.buffer
}

export function bufferToB64url(buf: ArrayBuffer | ArrayBufferView): string {
  // Symmetric with the decode guard: a partial WebAuthn response (missing
  // attestationObject/signature) must not silently encode to "".
  // Only the shape is guarded: a zero-length buffer is LEGITIMATE in WebAuthn
  // (userHandle is empty for discoverable credentials), so rejecting it would
  // trap a future caller. The decode side's "" rejection is what guards
  // against partial server values.
  let bytes: Uint8Array
  if (ArrayBuffer.isView(buf)) {
    bytes = new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength)
  } else if (buf instanceof ArrayBuffer) {
    bytes = new Uint8Array(buf)
  } else {
    throw new Error(B64URL_ENCODE_INVALID)
  }
  let s = ""
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}
