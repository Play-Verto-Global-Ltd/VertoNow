#!/usr/bin/env python3
"""Stitch the per-board PDFs from make_pdf.mjs into one numbered document.

Run `node make_pdf.mjs` first; this merges .pdf-parts/*.pdf in filename order
and stamps a footer on every page. It is a separate step because Chromium takes
only one page size per print call, and these sheets are deliberately different
heights — see the header of make_pdf.mjs.

    python3 merge_pdf.py            # -> respondent-verification-mockups.pdf
"""
import pathlib
import sys

import pymupdf

HERE = pathlib.Path(__file__).parent
PARTS = HERE / ".pdf-parts"
OUT = HERE / "respondent-verification-mockups.pdf"

FOOT_LEFT = "Playverto \u00b7 Proving the address, and the tap that need not be there"
INK = (0.478, 0.498, 0.580)   # --ink3 #7A7F94, the page's own muted grey


def main() -> int:
    parts = sorted(PARTS.glob("*.pdf"))
    if not parts:
        print(f"no parts in {PARTS}/ - run `node make_pdf.mjs` first", file=sys.stderr)
        return 1

    doc = pymupdf.open()
    for part in parts:
        with pymupdf.open(part) as src:
            doc.insert_pdf(src)

    total = doc.page_count
    for i, page in enumerate(doc, start=1):
        y = page.rect.height - 15
        page.insert_text((30, y), FOOT_LEFT, fontname="helv", fontsize=8, color=INK)
        label = f"{i} / {total}"
        w = pymupdf.get_text_length(label, fontname="helv", fontsize=8)
        page.insert_text((page.rect.width - 30 - w, y), label, fontname="helv", fontsize=8, color=INK)

    doc.set_metadata({
        "title": "The Vertos you played - respondent account mockups",
        "subject": "Playverto: an account at the end of a Verto - results, tokens, impact, follow-ups",
        "keywords": "Playverto, Verto, accounts, mockups, wallet, impact, email",
    })
    doc.save(OUT, garbage=4, deflate=True)
    doc.close()
    print(f"{OUT.name} - {total} pages, {OUT.stat().st_size / 1024:.0f} KB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
