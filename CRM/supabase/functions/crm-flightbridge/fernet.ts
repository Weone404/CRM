// Fernet tokens, compatible with Python's cryptography.fernet and flightbridge/secrets.py:
// key = urlsafe_b64(sha256("flightbridge-secrets-v1|" + FB_SECRETS_KEY)); first 16 bytes sign (HMAC-SHA256),
// last 16 bytes encrypt (AES-128-CBC, PKCS7). Token = 0x80 | timestamp(8, big-endian) | IV(16) | ciphertext | HMAC(32).
const te = new TextEncoder();
const td = new TextDecoder();

async function keys(master: string) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", te.encode("flightbridge-secrets-v1|" + master)));
  const sign = await crypto.subtle.importKey("raw", d.slice(0, 16), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
  const enc = await crypto.subtle.importKey("raw", d.slice(16, 32), { name: "AES-CBC" }, false, ["encrypt", "decrypt"]);
  return { sign, enc };
}

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_");          // keeps "=" padding, like Python
}

function unb64url(s: string): Uint8Array {
  const t = s.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(t + "=".repeat((4 - (t.length % 4)) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export async function fernetEncrypt(master: string, plaintext: string): Promise<string> {
  const k = await keys(master);
  const iv = crypto.getRandomValues(new Uint8Array(16));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-CBC", iv }, k.enc, te.encode(plaintext)));
  const head = new Uint8Array(1 + 8 + 16 + ct.length);
  head[0] = 0x80;
  new DataView(head.buffer).setBigUint64(1, BigInt(Math.floor(Date.now() / 1000)));
  head.set(iv, 9);
  head.set(ct, 25);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", k.sign, head));
  const out = new Uint8Array(head.length + 32);
  out.set(head);
  out.set(mac, head.length);
  return b64url(out);
}

// Returns null when the token can't be read (wrong FB_SECRETS_KEY, or damaged).
export async function fernetDecrypt(master: string, token: string): Promise<string | null> {
  try {
    const k = await keys(master);
    const raw = unb64url(token);
    if (raw.length < 1 + 8 + 16 + 16 + 32 || raw[0] !== 0x80) return null;
    const body = raw.slice(0, raw.length - 32);
    const ok = await crypto.subtle.verify("HMAC", k.sign, raw.slice(raw.length - 32), body);
    if (!ok) return null;
    const pt = await crypto.subtle.decrypt({ name: "AES-CBC", iv: body.slice(9, 25) }, k.enc, body.slice(25));
    return td.decode(pt);
  } catch {
    return null;
  }
}

export function last4(value: string): string {
  const v = value.trim();
  return v.length >= 8 ? v.slice(-4) : "•".repeat(v.length);
}
