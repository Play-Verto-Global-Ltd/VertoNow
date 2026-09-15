// Renders index.html to one shareable PDF — a page per board, each sized to
// the board it carries.
//
//   node make_pdf.mjs && python3 merge_pdf.py     # -> respondent-verification-mockups.pdf
//
// Chromium print-to-PDF rather than stitching shots/*.png: the page is HTML,
// CSS and inline SVG throughout, so every label, note and spec line stays real
// vector text — sharp at any zoom, selectable and searchable — where an
// image-per-page PDF would bake it all into pixels at one fixed resolution.
//
// Why a page per board rather than one uniform sheet: the boards run from
// ~360px (the dashboard tile) to ~2600px (the spec). Any single height
// either leaves most sheets two-thirds empty or forces the tall ones to be
// scaled down or split — and Chromium splits them badly, painting a panel's
// background past the sheet edge and through the footer. Fitting the sheet to
// the board costs nothing and means nothing has to be shrunk to survive.
//
// Chromium takes one page size per print call, hence a part per board; the
// widths all match, so only the heights differ. merge_pdf.py stitches them.
import { createRequire } from "node:module"
import { fileURLToPath } from "node:url"
import path from "node:path"
import fs from "node:fs"

const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_DIR || "/opt/node22/lib/node_modules/playwright")

const here = path.dirname(fileURLToPath(import.meta.url))
const tmp  = process.env.PDF_PARTS_DIR || path.join(here, ".pdf-parts")
fs.rmSync(tmp, { recursive: true, force: true })
fs.mkdirSync(tmp, { recursive: true })

const WIDTH = 1150   // sets the reading size of the type; see @media print
// Room under the last line and for the footer, plus a proportional allowance.
// The notes are a multi-column box and CSS balances columns against the height
// of the fragmentainer they land in, so a board measured in the DOM grows by a
// few percent once the sheet is cut to that measurement. page.pdf() fragments
// against the CSS page box rather than the viewport, so no amount of
// re-measuring in the page sees it; the slack is what keeps the last line off
// the edge. Overflow here is not cosmetic — it prints through the footer.
const PAD   = 30
const SLACK = 0.07
// A sheet fitted to its board is right until the board is very tall: the seven
// unfurls come to ~3000px, and a page nearly three times taller than it is wide
// is awkward to read and to scroll. Past this the board is split over however
// many sheets it needs, divided evenly — taking the cap for each would leave
// the last one two-thirds empty. Splitting is clean because the tiles, notes
// and table rows all carry break-inside: avoid.
// 2700 rather than the siblings' 2000: this deck's spec is eleven items plus
// a costing table, and at 2000 the sheet was the binding constraint rather
// than the split — it packed into three and spilled the last 900 characters
// onto a fourth. 2700 against a 1150px sheet is 1:2.3, still inside what the
// paragraph above is guarding against.
const CAP   = 2700

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || "/opt/pw-browsers/chromium" })
const page = await browser.newPage({ viewport: { width: WIDTH, height: 1200 } })
await page.goto("file://" + path.join(here, "index.html"))
await page.evaluate(() => document.fonts.ready)
await page.emulateMedia({ media: "print" })
await page.waitForTimeout(250)

const sections = await page.evaluate(() =>
  ["__cover__", ...[...document.querySelectorAll("section.board, section.spec")].map(el => el.id)]
)

await page.addStyleTag({ content: `
  body.pdf-isolate header.hero, body.pdf-isolate nav.toc,
  body.pdf-isolate main.wrap > *:not(.pdf-show) { display: none !important; }
  body.pdf-isolate .pdf-show { break-before: auto !important; }
  body.pdf-cover main.wrap > *:not(section.intro) { display: none !important; }
  body.pdf-cover section.intro { break-after: auto !important; }
` })

const parts = []
for (const [i, id] of sections.entries()) {
  const height = await page.evaluate((sid) => {
    document.body.classList.remove("pdf-isolate", "pdf-cover")
    document.querySelectorAll(".pdf-show").forEach(el => el.classList.remove("pdf-show"))
    if (sid === "__cover__") {
      document.body.classList.add("pdf-cover")
      return ["header.hero", "nav.toc", "section.intro"]
        .reduce((sum, s) => sum + (document.querySelector(s)?.getBoundingClientRect().height || 0), 0)
    }
    document.body.classList.add("pdf-isolate")
    const el = document.getElementById(sid)
    el.classList.add("pdf-show")
    return el.getBoundingClientRect().height
  }, id)

  const target = Math.ceil(height * (1 + SLACK)) + PAD
  const sheets = Math.max(1, Math.ceil(target / CAP))
  // 1.30 rather than the siblings' 1.18: board A is a flow strip whose notes
  // column re-balances at print width, and at 1.18 it spilled a third, nearly
  // empty sheet. Raise this if a board ever gains one again.
  // Dividing the raw height evenly is not enough once a board actually splits:
  // tiles and note blocks carry break-inside: avoid, so each sheet wastes
  // whatever is left below the last whole one, and the remainder spills to an
  // extra, nearly empty page. The extra headroom absorbs that.
  const sheet  = sheets === 1 ? target : Math.min(CAP, Math.ceil(target * 1.30 / sheets))

  const file = path.join(tmp, `${String(i).padStart(2, "0")}-${id.replace(/\W+/g, "-")}.pdf`)
  await page.pdf({
    path: file,
    width: `${WIDTH}px`,
    height: `${sheet}px`,
    printBackground: true,
    margin: { top: "0px", bottom: "0px", left: "0px", right: "0px" },
  })
  parts.push(file)
  console.log(`  ${id.padEnd(12)} ${Math.ceil(height)}px -> ${sheets} sheet(s) of ${sheet}px`)
}

await browser.close()
console.log(`${parts.length} parts -> run: python3 merge_pdf.py`)
