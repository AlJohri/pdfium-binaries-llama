"""Print the functions that PDFium's public headers declare with FPDF_EXPORT."""

import pathlib
import re
import sys

names = set()
for header in pathlib.Path(sys.argv[1]).glob("*.h"):
    text = re.sub(r"//[^\n]*|/\*.*?\*/", "", header.read_text(), flags=re.S)
    names.update(re.findall(r"\bFPDF_EXPORT\b[^;{}()]*?\bFPDF_CALLCONV\s+(\w+)\s*\(", text))
print("\n".join(sorted(names)))
