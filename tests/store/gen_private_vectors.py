"""Generate <private> parity vectors from the Python reference (~/reference_filters.py).
Inputs are synthetic. Output: src/store/testdata/private_vectors.json (strip / line / refuse per input)."""
import json, os, sys
sys.path.insert(0, os.path.expanduser("~"))
os.environ["ZIGMEM_PRIVATE_TAGS"] = "1"
import reference_filters as F

inputs = [
    "plain text", "", "a <private>x</private> b", "x < PRIVATE >y</ private > z", "keep <private>forever",
    "<private>a</private> mid <private>b</private>", "<private>a<private>b</private>c</private>",
    "a </private> b", "<privatex>no</privatex>", "<pri vate>no</pri vate>", "<private\n>multi\nline</private\t>",
    "< private >nbsp</private>", "< private>emspace</private>", "<PrIvAtE>mixed</pRiVaTe> tail",
    "<İPRIVATE>dotted</private>", "<prıvate>dotless</private>", "<prİvate>dotted-I</private>",
    "<\x1fprivate>unitsep</private>", "<\x85private>nel</private>", "a<private>b</private>c<private>d",
    "<private></private>", "<<private>>x</private>>", "été <private>café</private> — ok",
    "<private>one</private><private>two", "text with < and > but no tag", "<private >sp</private >",
    "< / private>", "<private>x< /private>y", "<private>x</ private\n>y", "emoji \U0001F600 <private>\U0001F600</private>",
]
lines = [json.dumps({"c": s}) for s in inputs] + [json.dumps({"c": "a <private>leak"}), "{\"a\": 1}",
         json.dumps({"m": "go <private>pin 4455\nand \"q\"</private> thanks"})]
out = []
for s in inputs:
    out.append({"in": s, "strip": F.strip_private(s), "refuse": bool(F.has_private(s)) if hasattr(F, "has_private") else None})
for l in lines:
    out.append({"line": l, "out": F.private_line(l)})
json.dump({"mark": F.PRIVATE_MARK, "cases": out}, open(sys.argv[1], "w"), ensure_ascii=False, indent=0)
print(len(out), "vectors")
