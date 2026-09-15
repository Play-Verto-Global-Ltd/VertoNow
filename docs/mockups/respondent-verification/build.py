#!/usr/bin/env python3
"""Assemble index.html from the fragments in parts/.

The fonts, the base stylesheet and the shared SVG symbols are spliced out of
../responder-accounts/index.html so the three decks stay visually identical and
this one carries no CDN reference either. Run once after editing any .part-*;
index.html is the checked-in deliverable, not this script's output directory.
"""
import pathlib, re, sys

here = pathlib.Path(__file__).parent
sib  = here.parent / "responder-accounts" / "index.html"
src  = sib.read_text().split("\n")

fonts = "\n".join(src[10:14])
css   = "\n".join(src[14:487])
defs  = "\n".join(src[489:661])

# sanity: splice boundaries must still be where we think they are
assert fonts.startswith("<style>") and fonts.rstrip().endswith("</style>"), "font splice moved"
assert css.startswith("<style>")   and css.rstrip().endswith("</style>"),   "css splice moved"
assert defs.lstrip().startswith("<!--") and defs.rstrip().endswith("</svg>"), "defs splice moved"

def part(name):
    p = here / "parts" / name
    if not p.exists():
        sys.exit(f"missing part: {name}")
    return p.read_text()

BUILD = "2026-09-15-a"
body = "\n".join(part(n) for n in [
    "body-1.html", "body-2.html", "body-3.html",
    "body-4.html", "body-5.html",
])

# the extra symbols go just inside the shared <svg> defs block
defs = defs.replace("</svg>", part("defs-extra.html") + "</svg>")

out = f"""<!doctype html>
<!-- respondent-verification mockups · build {BUILD} · view-source and check this line to confirm
     you are looking at the copy you think you are. Assembled by build.py, which
     splices the fonts, stylesheet and shared symbols out of
     ../responder-accounts/index.html — edit the files in parts/, not this one. -->
<html lang="en" data-build="{BUILD}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Proving the address, and the tap that need not be there — Playverto</title>
{fonts}
{css}
{part("extra-css.html")}
</head>
<body>
{defs}
{body}
<footer class="foot"><div class="wrap">Playverto · respondent verification &amp; the Google door · build {BUILD} · internal design document</div></footer>
</body>
</html>
"""
(here / "index.html").write_text(out)
boards = out.count('<section class="board"')
print(f"wrote index.html — {len(out):,} bytes, {boards} boards")
