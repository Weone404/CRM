// Minimal SMTP client for Edge Functions: implicit TLS (port 465), AUTH LOGIN, one message per connection.
// Supabase blocks ports 25 and 587, so only SSL ports are used. No external packages.

export interface SmtpConfig { host: string; port: number; username: string; password: string; fromName?: string | null }
export interface Mail { to: string[]; subject: string; text: string; html: string }

const enc = new TextEncoder();
const dec = new TextDecoder();
const b64 = (s: string) => {
  const bytes = enc.encode(s);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
};
const wrap76 = (s: string) => s.replace(/.{1,76}/g, "$&\r\n");
const noCrLf = (s: string) => s.replace(/[\r\n]+/g, " ").trim();
const encWord = (s: string) => /^[\x20-\x7e]*$/.test(s) ? s : `=?UTF-8?B?${b64(s)}?=`;

export function buildMessage(cfg: SmtpConfig, mail: Mail, now = new Date(), id = crypto.randomUUID()): string {
  const from = cfg.username;
  const domain = from.split("@")[1] || "localhost";
  const name = noCrLf(cfg.fromName ?? "").replace(/["<>]/g, "");
  const boundary = `b_${id.replace(/-/g, "")}`;
  const lines = [
    `From: ${name ? `"${encWord(name)}" ` : ""}<${from}>`,
    `To: ${mail.to.join(", ")}`,
    `Subject: ${encWord(noCrLf(mail.subject))}`,
    `Date: ${now.toUTCString().replace("GMT", "+0000")}`,
    `Message-ID: <${id}@${domain}>`,
    "MIME-Version: 1.0",
    `Content-Type: multipart/alternative; boundary="${boundary}"`,
    "",
    `--${boundary}`,
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    wrap76(b64(mail.text)),
    `--${boundary}`,
    "Content-Type: text/html; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    wrap76(b64(mail.html)),
    `--${boundary}--`,
    "",
  ];
  return lines.join("\r\n");
}

type Conn = { read(p: Uint8Array): Promise<number | null>; write(p: Uint8Array): Promise<number>; close(): void };

class Session {
  private buf = "";
  constructor(private conn: Conn) {}
  async reply(): Promise<{ code: number; text: string }> {
    const chunk = new Uint8Array(4096);
    for (;;) {
      const lines = this.buf.split("\r\n");
      // A complete reply ends with a line "NNN text" (space, not dash) followed by CRLF.
      for (let i = 0; i < lines.length - 1; i++) {
        if (/^\d{3} /.test(lines[i]) || /^\d{3}$/.test(lines[i])) {
          const text = lines.slice(0, i + 1).join("\n");
          this.buf = lines.slice(i + 1).join("\r\n");
          return { code: Number(lines[i].slice(0, 3)), text };
        }
      }
      const n = await this.conn.read(chunk);
      if (n === null) throw new Error("Mail server closed the connection");
      this.buf += dec.decode(chunk.subarray(0, n));
    }
  }
  async cmd(line: string, expect: number[], hide = false): Promise<string> {
    await this.conn.write(enc.encode(line + "\r\n"));
    const r = await this.reply();
    if (!expect.includes(r.code)) throw new Error(`Mail server said ${r.code} to ${hide ? "login" : line.split(" ")[0]}: ${r.text.slice(0, 160)}`);
    return r.text;
  }
}

export async function smtpSend(cfg: SmtpConfig, mail: Mail,
  connect: (host: string, port: number) => Promise<Conn> = (hostname, port) => Deno.connectTls({ hostname, port }),
  timeoutMs = 20000): Promise<void> {
  if (!mail.to.length) throw new Error("No recipients");
  let conn: Conn | null = null, timedOut = false;
  const timer = setTimeout(() => { timedOut = true; try { conn?.close(); } catch { /* closed */ } }, timeoutMs);
  try {
    conn = await connect(cfg.host, cfg.port);
    const s = new Session(conn);
    const hello = await s.reply();
    if (hello.code !== 220) throw new Error(`Mail server greeting: ${hello.text.slice(0, 160)}`);
    await s.cmd(`EHLO crm.weoneaviation.in`, [250]);
    await s.cmd("AUTH LOGIN", [334]);
    await s.cmd(b64(cfg.username), [334], true);
    await s.cmd(b64(cfg.password), [235], true).catch((e) => {
      throw new Error(/535|authentication/i.test(e.message) ? "Wrong email or password (the mail server refused the login)" : e.message);
    });
    await s.cmd(`MAIL FROM:<${cfg.username}>`, [250]);
    for (const r of mail.to) await s.cmd(`RCPT TO:<${r}>`, [250, 251]);
    await s.cmd("DATA", [354]);
    const body = buildMessage(cfg, mail).replace(/\r\n\./g, "\r\n..");   // dot-stuffing
    await s.cmd(body + "\r\n.", [250]);
    await s.cmd("QUIT", [221]).catch(() => {});
  } catch (e) {
    const m = e instanceof Error ? e.message : String(e);
    if (timedOut) throw new Error(`Mail server ${cfg.host}:${cfg.port} did not answer within ${Math.round(timeoutMs / 1000)} seconds`);
    if (!/said|Wrong|greeting|No recipients/.test(m)) {
      throw new Error(`Could not reach ${cfg.host}:${cfg.port} (${m})`);
    }
    throw e;
  } finally {
    clearTimeout(timer);
    try { conn?.close(); } catch { /* already closed */ }
  }
}
