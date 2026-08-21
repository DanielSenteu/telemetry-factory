# Invoice fixtures

SPECIMEN supplier invoices for testing the Materials → Receive flow (upload →
AI extraction → review → confirm). All suppliers are fictional; every document
carries a "SPECIMEN — not a tax document" footer. Regenerate with
`python3 generate.py`.

| File | Tests |
|---|---|
| `polymer-granules.pdf` / `.png` | The happy path: two clean material lines (PP + HDPE by the 25kg bag). PNG version exercises the photo path. |
| `colourant-masterbatch.pdf` / `.png` | Mixed lines: two materials + a transport charge that should be "record only", not stocked. |
| `packaging-hostile.pdf` | The hostile one: four lines, a discount row, comma-formatted amounts, returnable pallets — extraction and review both have to cope. |

Things worth checking when testing:
- Bag/tub quantities: "40 bags @ 4,750" is per-BAG pricing — stocking it as
  grams needs the unit conversion thought through (a known open question, not
  a bug: decide whether materials are stocked in bags or grams).
- The transport line should end up "Record only".
- The alias memory: receive the same supplier twice and the second time the
  lines should map themselves ("remembered" badge).
