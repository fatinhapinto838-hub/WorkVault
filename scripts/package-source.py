#!/usr/bin/env python3
"""Package only source, reports, locked development tool, and signed app."""
from pathlib import Path
import zipfile
root=Path(__file__).resolve().parents[1]
out=root.parent/'WorkVault-1.2.2-source-and-app.zip'
skip={'.git','.build','work','node_modules','__pycache__'}
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
 for p in sorted(root.rglob('*')):
  rel=p.relative_to(root)
  if p.is_file() and not any(part in skip for part in rel.parts) and p.name!='.DS_Store':archive.write(p,str(Path('WorkVault')/rel))
print(out)
