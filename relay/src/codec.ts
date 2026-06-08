/** Byte ⇄ wire-format helpers. */

export function toB64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

export function fromB64(text: string): Uint8Array {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/**
 * The exact bytes an author signs for a feed entry: an 8-byte big-endian `seq`
 * followed by the ciphertext. Shared by the relay (to verify) and the client
 * (to sign), so the format has a single source of truth.
 */
export function signedMessage(seq: number, ciphertext: Uint8Array): Uint8Array {
  const message = new Uint8Array(8 + ciphertext.length);
  new DataView(message.buffer).setBigUint64(0, BigInt(seq), false);
  message.set(ciphertext, 8);
  return message;
}
