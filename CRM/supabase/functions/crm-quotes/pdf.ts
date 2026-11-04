// Builds the course quote PDF (same content and layout as the old Render template).
// pdf-lib is passed in so this file runs unchanged in Deno and in Node tests.
// Text uses the PDF's built-in Helvetica (nothing to embed); the rupee sign, which Helvetica lacks,
// is drawn from the DejaVu Sans glyph outline (DejaVu fonts licence: free to use and redistribute).

export type Quote = {
  quote_id: string; date: string; lead_name: string; course_name: string;
  base_fee: number; discount_percent: number; discount_amount: number; discounted_base: number;
  line_items: { description: string; amount: number }[]; total: number;
  installment_count: number; installments: { number: number; amount: number; due: string }[];
};

const RUPEE = {
  regular: { w: 1303, d: "M106 -1370 161 -1493H1199L1144 -1370H790Q869 -1292 890 -1163H1199L1144 -1040H898Q893 -914 832 -829Q767 -736 642 -700Q707 -678 768 -606Q827 -538 892 -408L1097 0H880L689 -383Q614 -534 546 -582Q476 -631 356 -631H136V-797H390Q536 -797 610 -864Q678 -926 684 -1040H106L161 -1163H673Q655 -1230 610 -1282Q536 -1370 390 -1370Z" },
  bold: { w: 1425, d: "M103 -1298 191 -1493H1325L1239 -1298H923Q955 -1242 967 -1168H1325L1239 -973H962Q945 -896 902 -838Q830 -743 686 -698Q765 -680 828 -616Q891 -552 954 -424L1163 0H753L571 -371Q516 -483 459.5 -524.0Q403 -565 309 -565H159V-831H362Q483 -831 536 -898Q562 -931 575 -973H103L191 -1168H572Q559 -1205 536 -1234Q483 -1298 362 -1298Z" },
};
const money = (n: number) => "₹" + Math.round(n).toLocaleString("en-US");
// Helvetica covers Latin-1 (plus the bullet); anything else in a name prints as "?".
const safe = (s: string) => s.replace(/[^\x20-\x7E\xA0-\xFF•₹]/g, "?");
const pct = (n: number) => (Number.isInteger(n) ? n.toFixed(1) : String(n)); // Python prints 10.0 / 7.5

// deno-lint-ignore no-explicit-any
export async function buildQuotePdf(q: Quote, lib: { PDFDocument: any; rgb: any; StandardFonts: any }): Promise<Uint8Array> {
  const { PDFDocument, rgb, StandardFonts } = lib;
  const doc = await PDFDocument.create();
  const reg = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);
  doc.setTitle(`Quote - ${q.lead_name}`);
  doc.setAuthor("We One Aviation");

  const BLUE = rgb(0.118, 0.251, 0.686), INK = rgb(0.2, 0.2, 0.2), GREY = rgb(0.4, 0.4, 0.4);
  const LIGHT = rgb(0.6, 0.6, 0.6), PALE = rgb(0.941, 0.976, 1), BOX = rgb(0.976, 0.976, 0.976);
  const BORDER = rgb(0.867, 0.867, 0.867), GREEN = rgb(0, 0.5, 0);
  const W = 595.28, H = 841.89, M = 40, CW = W - 2 * M;
  let page = doc.addPage([W, H]);
  let y = H - M;

  const ensure = (need: number) => { if (y - need < M) { page = doc.addPage([W, H]); y = H - M; } };
  // Text that may contain "₹": Helvetica for the letters, the glyph outline for the rupee sign.
  const glyph = (font: any) => (font === bold ? RUPEE.bold : RUPEE.regular);
  const width = (s: string, size: number, font = reg) =>
    safe(s).split("₹").reduce((w, part, i) => w + (i ? glyph(font).w * size / 2048 : 0) + font.widthOfTextAtSize(part, size), 0);
  const text = (s: string, x: number, yy: number, size: number, font = reg, color = INK) => {
    let cx = x;
    safe(s).split("₹").forEach((part, i) => {
      if (i) {
        page.drawSvgPath(glyph(font).d, { x: cx, y: yy, scale: size / 2048, color, borderWidth: 0 });
        cx += glyph(font).w * size / 2048;
      }
      if (part) { page.drawText(part, { x: cx, y: yy, size, font, color }); cx += font.widthOfTextAtSize(part, size); }
    });
  };
  const right = (s: string, xr: number, yy: number, size: number, font = reg, color = INK) =>
    text(s, xr - width(s, size, font), yy, size, font, color);
  const center = (s: string, yy: number, size: number, font = reg, color = INK) =>
    text(s, M + (CW - width(s, size, font)) / 2, yy, size, font, color);
  const wrap = (s: string, size: number, font: any, max: number): string[] => {
    const out: string[] = []; let line = "";
    for (const w of s.split(/\s+/)) {
      const t = line ? `${line} ${w}` : w;
      if (width(t, size, font) > max && line) { out.push(line); line = w; } else line = t;
    }
    if (line) out.push(line);
    return out;
  };

  // Header
  center("We One Aviation", y - 24, 24, bold, BLUE); y -= 38;
  center("DGCA Ground School", y - 10, 11, reg, GREY); y -= 18;
  center("[Logo placeholder - add institute logo here]", y - 9, 9, reg, LIGHT); y -= 22;
  page.drawRectangle({ x: M, y, width: CW, height: 2.5, color: BLUE }); y -= 18;

  // Date / quote id / prepared for
  page.drawRectangle({ x: M, y: y - 52, width: CW, height: 52, color: BOX });
  page.drawRectangle({ x: M, y: y - 52, width: 3.5, height: 52, color: BLUE });
  text("Date: ", M + 14, y - 20, 10.5, bold); text(q.date, M + 14 + width("Date: ", 10.5, bold), y - 20, 10.5);
  const qid = `Quote ID: ${q.quote_id}`;
  right(qid, M + CW - 14, y - 20, 10.5, bold);
  text("Prepared for: ", M + 14, y - 40, 10.5, bold);
  text(q.lead_name, M + 14 + width("Prepared for: ", 10.5, bold), y - 40, 10.5);
  y -= 70;

  // Course title
  for (const l of wrap(`${q.course_name} Training Program`, 17, bold, CW)) { text(l, M, y - 17, 17, bold, BLUE); y -= 23; }
  page.drawRectangle({ x: M, y: y - 2, width: CW, height: 1.5, color: BLUE }); y -= 28;

  // Table helper
  const ROW = 20;
  const table = (cols: { w: number; align: "l" | "r" }[], head: string[], rows: { cells: string[]; bold?: boolean; fill?: any; color?: any; big?: boolean }[]) => {
    const draw = (cells: string[], opts: { header?: boolean; bold?: boolean; fill?: any; color?: any; big?: boolean }) => {
      ensure(ROW);
      const size = opts.big ? 11.5 : 10;
      if (opts.header) page.drawRectangle({ x: M, y: y - ROW, width: CW, height: ROW, color: BLUE });
      else if (opts.fill) page.drawRectangle({ x: M, y: y - ROW, width: CW, height: ROW, color: opts.fill });
      let x = M;
      cols.forEach((c, i) => {
        page.drawRectangle({ x, y: y - ROW, width: c.w, height: ROW, borderColor: BORDER, borderWidth: 0.75 });
        const font = opts.header || opts.bold ? bold : reg;
        const color = opts.header ? rgb(1, 1, 1) : (opts.color ?? INK);
        const s = cells[i] ?? "";
        if (c.align === "r") right(s, x + c.w - 9, y - ROW + 6, size, font, color);
        else text(s, x + 9, y - ROW + 6, size, font, color);
        x += c.w;
      });
      y -= ROW;
    };
    draw(head, { header: true });
    for (const r of rows) draw(r.cells, r);
  };

  // Fee breakdown
  ensure(60); text("Fee Breakdown", M, y - 13, 13, bold); y -= 26;
  const feeRows: { cells: string[]; bold?: boolean; fill?: any; color?: any; big?: boolean }[] = [
    { cells: [`${q.course_name} (Base Fee)`, money(q.base_fee)] },
  ];
  if (q.discount_percent > 0) {
    feeRows.push({ cells: [`Discount (${pct(q.discount_percent)}%)`, `-${money(q.discount_amount)}`], color: GREEN });
    feeRows.push({ cells: ["Subtotal after discount", money(q.discounted_base)], bold: true });
  }
  for (const it of q.line_items) feeRows.push({ cells: [it.description, money(it.amount)] });
  feeRows.push({ cells: ["Total Program Fee", money(q.total)], bold: true, fill: PALE, big: true });
  table([{ w: CW * 0.7, align: "l" }, { w: CW * 0.3, align: "r" }], ["Item", "Amount"], feeRows);
  y -= 22;

  // Payment schedule
  ensure(60); text(`Payment Schedule (${q.installment_count} installments)`, M, y - 13, 13, bold); y -= 26;
  table([{ w: CW * 0.34, align: "l" }, { w: CW * 0.26, align: "r" }, { w: CW * 0.4, align: "l" }], ["Payment", "Amount", "Due"],
    q.installments.map((i) => ({ cells: [`Installment ${i.number}`, money(i.amount), i.due] })));
  y -= 22;

  // What's included
  const inc = ["Complete DGCA syllabus coverage", "Study materials and mock tests", "Experienced instructors", "Exam preparation guidance"];
  const boxH = 32 + inc.length * 15;
  ensure(boxH + 10);
  page.drawRectangle({ x: M, y: y - boxH, width: CW, height: boxH, color: PALE });
  page.drawRectangle({ x: M, y: y - boxH, width: 3.5, height: boxH, color: BLUE });
  text("What's Included", M + 14, y - 22, 12.5, bold, BLUE);
  inc.forEach((s, i) => text(`•  ${s}`, M + 22, y - 40 - i * 15, 10));
  y -= boxH + 24;

  // Footer notes
  const notes: [string, string][] = [
    ["Note: ", "This quote is valid for 30 days from the date of issue. Fees are subject to change as per DGCA regulations."],
    ["", "PLACEHOLDER fees shown - Admin must update with actual amounts before sending."],
    ["", "For queries, contact us at info@weoneaviation.com"],
  ];
  ensure(70);
  page.drawRectangle({ x: M, y, width: CW, height: 1.5, color: BORDER }); y -= 18;
  for (const [label, body] of notes) {
    const isBold = label !== "" || body.startsWith("PLACEHOLDER");
    const lines = wrap(label + body, 8.5, reg, CW);
    for (const l of lines) {
      ensure(14);
      if (label && l.startsWith(label)) {
        text(label, M, y - 9, 8.5, bold, GREY);
        text(l.slice(label.length), M + width(label, 8.5, bold), y - 9, 8.5, reg, GREY);
      } else text(l, M, y - 9, 8.5, isBold && !label ? bold : reg, GREY);
      y -= 13;
    }
    y -= 4;
  }
  return await doc.save();
}
