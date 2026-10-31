"""Save-time checks for outreach templates pasted in the CRM.

COPY of nikkk07/FlightBridge-AI flightbridge/outreach/templates.py validate() and the BANNED_CLAIMS list in
flightbridge/compliance/content.py. Keep in sync. This check only gives the editor instant feedback; the
FlightBridge content gate re-checks the exact email at send time and is authoritative.
"""
import re

ALLOWED_VARS = {"school_name", "city", "country"}
VAR_RE = re.compile(r"\{\{\s*([a-zA-Z_]+)\s*\}\}")
FOOTER_MARKERS = re.compile(r"(unsubscribe|^\s*--\s*$|\bRef:\s*FB-)", re.I | re.M)
BANNED_CLAIMS = [
    (r"\b\d[\d,]*\s*\+?\s*(pilots|students|candidates|graduates)\b", "unverified_volume_claim"),
    (r"100\s*%\s*placement", "unverified_placement_claim"),
    (r"\bplacement (guarantee|assured|assistance)\b", "unverified_placement_claim"),
    (r"\bguarantee(d)?\b.*\b(job|placement|licen[cs]e|pass)\b", "guarantee_claim"),
    (r"\bour (flying school|aircraft|fleet)\b", "operates_aircraft_claim"),
    (r"\bDGCA[- ]approved\b", "unverified_regulatory_claim"),
    (r"\b(approved|certified|registered) (FTO|flying training organi[sz]ation|ATO)\b", "unverified_regulatory_claim"),
    (r"\bsince 2011\b", "contradicted_founding_year"),
    (r"\b(airline partners?|partner airlines?)\b", "unverified_partner_claim"),
    (r"\b(india'?s )?(most trusted|best|no\.? ?1|#1|premier|leading)\b", "superlative_claim"),
    (r"flystar|flying star", "other_brand"),
]
KINDS = ("initial", "followup_1", "followup_2", "followup_3")


def validate(subject: str, body: str) -> dict:
    errors, warnings = [], []
    subject, body = (subject or "").strip(), (body or "").strip()
    if not subject or len(subject) > 150:
        errors.append("subject must be 1-150 characters")
    if len(body) < 20:
        errors.append("body is too short")
    if re.match(r"^\s*(re|fw|fwd)\s*:", subject, re.I):
        errors.append("subject must not start with Re:/Fwd: (it would look like a reply)")
    for name in sorted({m.group(1) for m in VAR_RE.finditer(subject + body)} - ALLOWED_VARS):
        errors.append(f"unknown placeholder {{{{{name}}}}} (allowed: {', '.join('{{%s}}' % v for v in sorted(ALLOWED_VARS))})")
    stripped = VAR_RE.sub("X", subject + "\n" + body)
    if re.search(r"\{\{|\}\}|\[\[|\]\]|PLACEHOLDER|\bTODO\b|lorem ipsum|<insert", stripped, re.I):
        errors.append("contains an unresolved placeholder or TODO")
    hits = sorted({tag for pat, tag in BANNED_CLAIMS if re.search(pat, stripped, re.I)})
    if hits:
        errors.append("contains claims that are not approved: " + ", ".join(hits))
    if FOOTER_MARKERS.search(body):
        warnings.append("do not add an unsubscribe line, signature divider or Ref: — the system appends the legal footer")
    return {"ok": not errors, "errors": errors, "warnings": warnings,
            "placeholders": sorted({m.group(1) for m in VAR_RE.finditer(subject + body)} & ALLOWED_VARS)}
