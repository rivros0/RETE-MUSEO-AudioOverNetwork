#!/usr/bin/env python3
"""Regenerate the standalone installer after editing studio.py or studio.html."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
path=root/'setup_roc_museum.sh'
text=path.read_text()
for marker,name in (('PY_STUDIO','studio.py'),('HTML_STUDIO','studio.html')):
    opening="<<'"+marker+"'\n"
    start=text.index(opening)+len(opening)
    end=text.index('\n'+marker+'\n',start)
    text=text[:start]+(root/name).read_text().rstrip('\n')+text[end:]
path.write_text(text)
