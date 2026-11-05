// Live check of an SMTP/IMAP mailbox (HIOX India cPanel mail): IMAP LOGIN on 993 and SMTP AUTH on 465, both over TLS.
// Nothing is sent and the password is never logged. (Supabase Edge Functions may not open ports 25 and 587.)
const enc = new TextEncoder();
const dec = new TextDecoder();

async function open(host: string, port: number) {
  const conn = await Deno.connectTls({ hostname: host, port });
  let buf = "";
  const chunk = new Uint8Array(8192);
  const until = async (re: RegExp, ms = 15000): Promise<string> => {
    const end = Date.now() + ms;
    while (!re.test(buf)) {
      const left = end - Date.now();
      if (left <= 0) throw new Error("Timeout");
      let timer: number | undefined;
      const n = await Promise.race([conn.read(chunk),
        new Promise<never>((_, no) => { timer = setTimeout(() => no(new Error("Timeout")), left); })])
        .finally(() => clearTimeout(timer));
      if (n === null) throw new Error("ConnectionClosed");
      buf += dec.decode(chunk.subarray(0, n));
    }
    const out = buf;
    buf = "";
    return out;
  };
  return { until, write: (s: string) => conn.write(enc.encode(s)), close: () => { try { conn.close(); } catch { /* closed */ } } };
}

const quote = (s: string) => `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
const b64 = (s: string) => { let b = ""; for (const x of enc.encode(s)) b += String.fromCharCode(x); return btoa(b); };
const kind = (e: unknown) => ((e as Error)?.name === "TimeoutError" || /Timeout/.test(String(e)) ? "Timeout" : "ConnectionError");

export async function checkMailbox(host: string, user: string, password: string): Promise<[boolean, string]> {
  let c;
  try { c = await open(host, 993); } catch (e) { return [false, `Could not reach ${host}:993 (${kind(e)}). Check the server name.`]; }
  try {
    await c.until(/\r\n/);
    await c.write(`a1 LOGIN ${quote(user)} ${quote(password)}\r\n`);
    const r = await c.until(/^a1 (OK|NO|BAD)[^\r\n]*\r\n/m);
    if (!/^a1 OK/m.test(r)) return [false, "The mail server refused the address or password."];
    await c.write("a2 LOGOUT\r\n");
  } catch (e) {
    return [false, `The mail server did not answer (${kind(e)}). Try again.`];
  } finally { c.close(); }
  let s;
  try { s = await open(host, 465); } catch (e) {
    return [true, `Connected for reading replies. Sending could not be checked from here (${kind(e)}); the Mac Mini sends.`];
  }
  try {
    await s.until(/^220 [^\r\n]*\r\n/m);
    await s.write("EHLO crm.weoneaviation.in\r\n");
    await s.until(/^250 [^\r\n]*\r\n/m);
    await s.write(`AUTH PLAIN ${b64(`\0${user}\0${password}`)}\r\n`);
    const r = await s.until(/^\d{3} [^\r\n]*\r\n/m);
    await s.write("QUIT\r\n");
    if (!/^235 /m.test(r)) return [false, "Replies can be read, but the server refused the login for sending (SMTP)."];
  } catch (e) {
    return [true, `Connected for reading replies. Sending could not be checked (${kind(e)}).`];
  } finally { s.close(); }
  return [true, `Connected: ${user} can send and read replies.`];
}
