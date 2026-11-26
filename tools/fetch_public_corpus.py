"""Fetch a public labelled corpus and turn it into an `archiviste --eval` folder (not committed).

N-Mehdi/french-invoices-synth (Hugging Face, Apache-2.0): synthetic French invoices as images,
with the seller, the date and the total TTC. Its test split (100 invoices) by default.

    uv run --with pyarrow --with huggingface_hub python tools/fetch_public_corpus.py [split] [dest]
    archiviste --eval corpus/public/french-invoices-synth
"""
import io, json, os, re, sys

import pyarrow.parquet as pq
from huggingface_hub import snapshot_download

REPO = "N-Mehdi/french-invoices-synth"
split = sys.argv[1] if len(sys.argv) > 1 else "test"
dest = sys.argv[2] if len(sys.argv) > 2 else "corpus/public/french-invoices-synth"

root = snapshot_download(REPO, repo_type="dataset", allow_patterns=[f"data/{split}*", f"*/{split}*"])
files = sorted(os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs if f.endswith(".parquet") and split in f)
if not files:
    sys.exit(f"Aucun fichier parquet « {split} » dans {root}")
os.makedirs(dest, exist_ok=True)


def iso(date):
    """'15/03/2025', '2025-03-15', '15-03-2025' → '2025-03-15'; None if unreadable."""
    date = str(date or "").strip()
    if m := re.fullmatch(r"(\d{4})-(\d{2})-(\d{2}).*", date):
        return "-".join(m.groups())
    if m := re.fullmatch(r"(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})", date):
        d, mo, y = m.groups()
        return f"{y}-{int(mo):02d}-{int(d):02d}"
    return None


def amount(value):
    try:
        return f"{float(str(value).replace(' ', '').replace(',', '.')):.2f} EUR"
    except ValueError:
        return None


documents = []
for path in files:
    table = pq.read_table(path).to_pylist()
    for i, row in enumerate(table):
        truth = row.get("ground_truth")
        truth = json.loads(truth) if isinstance(truth, str) else (truth or {})
        truth = truth.get("gt_parse", truth)
        image = row.get("image")
        data = image.get("bytes") if isinstance(image, dict) else image
        if not data:
            continue
        name = f"{split}-{len(documents) + 1:03d}.png"
        with open(os.path.join(dest, name), "wb") as f:
            f.write(data)
        doc = {"file": name, "type": "Facture"}
        seller = truth.get("seller") or {}
        if isinstance(seller, dict) and seller.get("name"):
            doc["issuer"] = seller["name"]
        if d := iso(truth.get("date") or truth.get("invoice_date")):
            doc["date"] = d
        if a := amount(truth.get("total_ttc")):
            doc["amount"] = a
        items = [it.get("description", "") for it in truth.get("items") or [] if isinstance(it, dict)]
        words = [w for w in re.findall(r"[^\W\d_]{5,}", items[0] if items else "")][:2]
        if words:
            doc["detail"] = [w.lower() for w in words]
        documents.append(doc)

with open(os.path.join(dest, "corpus.json"), "w", encoding="utf-8") as f:
    json.dump({"source": f"https://huggingface.co/datasets/{REPO} (Apache-2.0)", "documents": documents},
              f, ensure_ascii=False, indent=2)
print(f"✓ {len(documents)} factures dans {dest}")
