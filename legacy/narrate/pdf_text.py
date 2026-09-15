"""Extract clean, readable text from a PDF for narration."""
from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass

import pymupdf as fitz


@dataclass
class Document:
    name: str
    path: str
    pages: int
    paragraphs: list[str]

    @property
    def text(self) -> str:
        return "\n\n".join(self.paragraphs)

    @property
    def words(self) -> int:
        return sum(len(p.split()) for p in self.paragraphs)


_WS = re.compile(r"[ \t ]+")
_HYPHEN_BREAK = re.compile(r"(\w)-\n(\w)")
_LINE_BREAK = re.compile(r"(?<![.!?:;])\n(?!\n)")
_PAGE_NUMBER = re.compile(r"^\s*(page\s*)?\d{1,4}(\s*(of|/)\s*\d{1,4})?\s*$", re.I)
_MOSTLY_SYMBOLS = re.compile(r"[A-Za-z]")


def _clean_block(raw: str) -> str:
    raw = raw.replace("\r", "")
    raw = _HYPHEN_BREAK.sub(r"\1\2", raw)          # re-join words split across lines
    raw = _LINE_BREAK.sub(" ", raw)                 # soft line breaks inside a paragraph
    raw = raw.replace("\n", " ")
    raw = _WS.sub(" ", raw).strip()
    # Ligatures and odd glyphs that trip up the phonemizer
    raw = (raw.replace("ﬁ", "fi").replace("ﬂ", "fl").replace("ﬀ", "ff")
              .replace("’", "'").replace("‘", "'").replace("“", '"')
              .replace("”", '"').replace("–", "-").replace("—", " - ")
              .replace("…", "..."))
    return raw


def _is_noise(block: str) -> bool:
    if not block:
        return True
    if _PAGE_NUMBER.match(block):
        return True
    letters = len(_MOSTLY_SYMBOLS.findall(block))
    if letters < max(3, len(block) * 0.4):          # tables, figure axes, math soup
        return True
    return False


def extract(path: str, first_page: int | None = None, last_page: int | None = None) -> Document:
    doc = fitz.open(path)
    total = doc.page_count
    start = max(1, first_page or 1)
    end = min(total, last_page or total)

    per_page: list[list[str]] = []
    for pno in range(start - 1, end):
        page = doc[pno]
        blocks = page.get_text("blocks", sort=True)
        cleaned = [_clean_block(b[4]) for b in blocks if b[6] == 0]  # text blocks only
        per_page.append([c for c in cleaned if not _is_noise(c)])

    # Drop running headers/footers: short lines repeated on many pages.
    if len(per_page) >= 4:
        counts = Counter(b for page in per_page for b in set(page) if len(b) < 120)
        repeated = {b for b, n in counts.items() if n >= max(3, len(per_page) * 0.4)}
        per_page = [[b for b in page if b not in repeated] for page in per_page]

    paragraphs: list[str] = []
    for page in per_page:
        for block in page:
            # Continue a paragraph that was cut by a page break.
            if paragraphs and not paragraphs[-1].rstrip().endswith((".", "!", "?", '"', ":", ")")) \
                    and block and block[0].islower():
                paragraphs[-1] = paragraphs[-1] + " " + block
            else:
                paragraphs.append(block)

    doc.close()
    import os
    return Document(name=os.path.basename(path), path=path, pages=total, paragraphs=paragraphs)
