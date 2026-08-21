#!/usr/bin/env python3
"""Generate SPECIMEN supplier invoices (PDF) for testing the Receive flow.

Fictional Kenyan suppliers, realistic layout/prices/VAT, marked SPECIMEN.
Pure-python PDF writer — no dependencies.
"""

def esc(s):
    return s.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")

class Page:
    def __init__(self):
        self.ops = []
    def text(self, x, y, s, size=10, bold=False, gray=0.0):
        font = "/F2" if bold else "/F1"
        self.ops.append(f"BT {gray:.2f} {gray:.2f} {gray:.2f} rg {font} {size} Tf {x} {y} Td ({esc(s)}) Tj ET")
    def rtext(self, x_right, y, s, size=10, bold=False, gray=0.0):
        # crude right-align: Helvetica avg width ~0.5em
        w = len(s) * size * 0.5
        self.text(x_right - w, y, s, size, bold, gray)
    def line(self, x1, y1, x2, y2, w=0.7, gray=0.75):
        self.ops.append(f"{gray:.2f} {gray:.2f} {gray:.2f} RG {w} w {x1} {y1} m {x2} {y2} l S")
    def stream(self):
        return "\n".join(self.ops)

def build_pdf(page, path):
    content = page.stream().encode("latin-1", "replace")
    objs = []
    objs.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    objs.append(b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    objs.append(b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> >>")
    objs.append(b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"\nendstream")
    objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>")
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + o + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objs)+1}\n0000000000 65535 f \n".encode()
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF".encode()
    with open(path, "wb") as f:
        f.write(bytes(out))
    print("wrote", path)

def invoice(path, supplier, addr, pin, inv_no, date, due, items, note=None, discount=0):
    p = Page()
    y = 790
    p.text(50, y, supplier, 19, bold=True); y -= 16
    for a in addr:
        p.text(50, y, a, 9, gray=0.35); y -= 12
    p.text(50, y, f"PIN: {pin}", 9, gray=0.35)
    p.rtext(545, 790, "INVOICE", 22, bold=True, gray=0.15)
    p.rtext(545, 768, f"No: {inv_no}", 10)
    p.rtext(545, 754, f"Date: {date}", 10)
    p.rtext(545, 740, f"Due: {due}", 10, gray=0.35)
    y = 700
    p.line(50, y, 545, y); y -= 18
    p.text(50, y, "BILL TO", 8, bold=True, gray=0.45); y -= 14
    p.text(50, y, "Alpha Surgicals Supplies Ltd", 11, bold=True); y -= 13
    p.text(50, y, "Baba Dogo Road, Ruaraka, Nairobi", 9, gray=0.35); y -= 12
    p.text(50, y, "PIN: P051234567X", 9, gray=0.35); y -= 24
    # table head
    p.text(50, y, "DESCRIPTION", 8, bold=True, gray=0.45)
    p.rtext(390, y, "QTY", 8, bold=True, gray=0.45)
    p.rtext(460, y, "UNIT PRICE", 8, bold=True, gray=0.45)
    p.rtext(545, y, "AMOUNT", 8, bold=True, gray=0.45)
    y -= 6; p.line(50, y, 545, y); y -= 16
    subtotal = 0
    for desc, qty, unit, price in items:
        amount = qty * price
        subtotal += amount
        p.text(50, y, desc, 10)
        p.rtext(390, y, f"{qty:,.0f} {unit}", 10)
        p.rtext(460, y, f"{price:,.2f}", 10)
        p.rtext(545, y, f"{amount:,.2f}", 10)
        y -= 17
    y -= 4; p.line(300, y, 545, y); y -= 16
    if discount:
        p.rtext(460, y, "Discount", 10, gray=0.35); p.rtext(545, y, f"-{discount:,.2f}", 10); y -= 15
        subtotal -= discount
    vat = round(subtotal * 0.16, 2)
    p.rtext(460, y, "Subtotal", 10, gray=0.35); p.rtext(545, y, f"{subtotal:,.2f}", 10); y -= 15
    p.rtext(460, y, "VAT 16%", 10, gray=0.35); p.rtext(545, y, f"{vat:,.2f}", 10); y -= 6
    p.line(300, y, 545, y); y -= 16
    p.rtext(460, y, "TOTAL KES", 11, bold=True); p.rtext(545, y, f"{subtotal+vat:,.2f}", 12, bold=True)
    y -= 40
    if note:
        p.text(50, y, note, 9, gray=0.35); y -= 14
    p.text(50, y, "Payment: M-Pesa Paybill 000000 / Bank transfer. Goods remain property of seller until paid.", 8, gray=0.45)
    p.text(50, 40, "SPECIMEN - test fixture for software development. Not a tax document.", 8, gray=0.6)
    build_pdf(p, path)

invoice(
    "polymer-granules.pdf",
    "Nairobi Polymer Supplies Ltd",
    ["Enterprise Road, Industrial Area", "P.O. Box 45210-00100, Nairobi", "Tel: 0700 000 111"],
    "P051998877A", "NPS-2026-1188", "2026-08-18", "2026-09-17",
    [
        ("Polypropylene granules PP-H030 (25kg bag)", 40, "bags", 4750.00),
        ("HDPE granules blow grade (25kg bag)", 10, "bags", 5100.00),
    ],
    note="Delivery included. Batch: PP26-0817.",
)
invoice(
    "colourant-masterbatch.pdf",
    "ColourMast East Africa Ltd",
    ["Mombasa Road, Nairobi", "P.O. Box 78001-00200, Nairobi", "Tel: 0722 000 222"],
    "P052112334B", "CM-4471", "2026-08-20", "2026-08-27",
    [
        ("Blue masterbatch MB-2205 (5kg tub)", 6, "tubs", 4200.00),
        ("White masterbatch MB-1010 (5kg tub)", 4, "tubs", 3900.00),
        ("Transport & handling", 1, "trip", 2500.00),
    ],
)
invoice(
    "packaging-hostile.pdf",
    "EastPack Industries Ltd",
    ["Likoni Road, Industrial Area, Nairobi", "P.O. Box 33019-00500, Nairobi"],
    "P052445990C", "EP/08/2026/077", "2026-08-19", "2026-09-02",
    [
        ("Carton boxes 600x400x400 (printed, pk 25)", 12, "pks", 1875.00),
        ("Polythene liner bags 80L (roll of 100)", 8, "rolls", 1450.00),
        ("Strapping tape 12mm (roll)", 24, "rolls", 310.00),
        ("Pallet hire (returnable)", 4, "pcs", 800.00),
    ],
    discount=1500.00,
    note="Discount per August supply agreement. Pallets to be returned within 14 days.",
)
