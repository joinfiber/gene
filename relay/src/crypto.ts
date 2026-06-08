/**
 * Ed25519 signature verification via WebCrypto — supported natively in workerd,
 * so the relay needs no crypto dependency. This is the relay's *only* crypto:
 * it verifies that a feed entry was signed by the feed's pinned author key. It
 * never holds private keys and never decrypts content.
 */
export async function verifyEd25519(
  publicKey: Uint8Array,
  signature: Uint8Array,
  message: Uint8Array,
): Promise<boolean> {
  // A malformed pinned key or signature must read as "not verified", never throw
  // — otherwise one bad append could 500 or brick a feed. importKey throws on a
  // wrong-length key; verify throws on a wrong-length signature. Catch both.
  try {
    const key = await crypto.subtle.importKey(
      "raw",
      publicKey,
      { name: "Ed25519" },
      false,
      ["verify"],
    );
    return await crypto.subtle.verify({ name: "Ed25519" }, key, signature, message);
  } catch {
    return false;
  }
}
