"""Extract clean, readable text from a PDF for narration.

`extract` returns the text page by page (so the app can narrate any set of pages without coming
back here) plus an outline — the PDF's own bookmarks when it has them, otherwise headings found by
looking at font sizes and "Chapter N"-style lines — so whole chapters can be picked by name.
"""
from __future__ import annotations

import os
import re
from collections import Counter
from dataclasses import dataclass, field
from typing import Callable

import pymupdf as fitz


@dataclass
class Section:
    title: str
    level: int      # 1 = top level
    first: int      # 1-based page numbers, inclusive
    last: int


@dataclass
class Document:
    name: str
    path: str
    pages: int
    page_blocks: list[list[str]]                # cleaned text blocks per page, in reading order
    outline: list[Section] = field(default_factory=list)
    outline_source: str = "none"                # "bookmarks" | "headings" | "none"

    @property
    def paragraphs(self) -> list[str]:
        return join_paragraphs(self.page_blocks)


_WS = re.compile(r"[ \t ]+")
_HYPHEN_BREAK = re.compile(r"(\w)-\n(\w)")
_LINE_BREAK = re.compile(r"(?<![.!?:;])\n(?!\n)")
_PAGE_NUMBER = re.compile(r"^\s*(page\s*)?\d{1,4}(\s*(of|/)\s*\d{1,4})?\s*$", re.I)
_MOSTLY_SYMBOLS = re.compile(r"[A-Za-z]")
_SENTENCE_END = (".", "!", "?", '"', ":", ")")


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


def join_paragraphs(page_blocks: list[list[str]]) -> list[str]:
    """Blocks of consecutive pages → paragraphs, re-joining paragraphs cut by a page break."""
    paragraphs: list[str] = []
    for page in page_blocks:
        for block in page:
            if paragraphs and not paragraphs[-1].rstrip().endswith(_SENTENCE_END) and block and block[0].islower():
                paragraphs[-1] = paragraphs[-1] + " " + block
            else:
                paragraphs.append(block)
    return paragraphs


# ------------------------------------------------------------------ outline

_CHAPTER_LINE = re.compile(
    r"^(chapter|part|book|section|lecture|unit|appendix|prologue|epilogue|preface|introduction|"
    r"conclusion|foreword|afterword|acknowledg\w*|bibliography|index|notes|glossary)\b"
    r"|^(\d{1,2}|[ivxlc]{1,6})[.:)]?\s+[A-Z]", re.I)


def _bookmark_outline(doc: fitz.Document) -> list[Section]:
    toc = [(lvl, str(title).strip(), page) for lvl, title, page in doc.get_toc(simple=True)
           if isinstance(page, int) and page >= 1 and str(title).strip()]
    if not toc:
        return []
    # Keep it usable: deep TOCs (sub-sub-sections) collapse to the top two levels.
    depth = 2 if len(toc) > 60 else 3
    toc = [t for t in toc if t[0] <= depth]
    return _close_sections(toc, doc.page_count)


def _close_sections(entries: list[tuple[int, str, int]], page_count: int) -> list[Section]:
    """Each entry runs until the next entry at its level or above (or the end of the document)."""
    entries = sorted(entries, key=lambda e: e[2])      # stable: a parent stays ahead of a child on the same page
    out: list[Section] = []
    for i, (lvl, title, page) in enumerate(entries):
        last = page_count
        for lvl2, _, page2 in entries[i + 1:]:
            if lvl2 <= lvl:
                last = max(page, page2 - 1) if page2 > page else page
                break
        out.append(Section(title=title[:120], level=max(1, lvl), first=min(page, page_count), last=min(last, page_count)))
    return out


def _heading_outline(doc: fitz.Document, progress: Callable[[str], None] | None = None) -> list[Section]:
    """No bookmarks: find headings by font size. The body size is whatever most characters are set
    in; a heading is a short line noticeably larger than that (or a "Chapter N" line at any size)."""
    size_chars: Counter = Counter()
    lines: list[tuple[int, float, bool, str]] = []     # (page, size, bold, text)
    limit = min(doc.page_count, 1500)
    for pno in range(limit):
        if progress and pno % 50 == 0:
            progress(f"Looking for chapters… page {pno + 1} of {limit}")
        try:
            d = doc[pno].get_text("dict", flags=fitz.TEXT_PRESERVE_LIGATURES | fitz.TEXT_PRESERVE_WHITESPACE)
        except Exception:  # noqa: BLE001
            continue
        for block in d.get("blocks", []):
            for line in block.get("lines", []):
                spans = [s for s in line.get("spans", []) if s.get("text", "").strip()]
                if not spans:
                    continue
                text = _WS.sub(" ", "".join(s["text"] for s in spans)).strip()
                size = max(s["size"] for s in spans)
                bold = any("bold" in s.get("font", "").lower() or s.get("flags", 0) & 16 for s in spans)
                size_chars[round(size)] += len(text)
                if 2 <= len(text) <= 100:
                    lines.append((pno + 1, size, bold, text))
    if not size_chars:
        return []
    body = size_chars.most_common(1)[0][0]
    big = body * 1.25
    cands: list[tuple[int, str, float]] = []
    for page, size, bold, text in lines:
        letters = len(_MOSTLY_SYMBOLS.findall(text))
        if letters < 3 or _PAGE_NUMBER.match(text):
            continue
        if size >= big or (_CHAPTER_LINE.match(text) and (bold or size > body) and len(text) <= 60):
            cands.append((page, text, size))
    if not cands:
        return []
    # A running header repeated on many pages is not a chapter.
    freq = Counter(t.lower() for _, t, _ in cands)
    cands = [c for c in cands if freq[c[1].lower()] < 3]
    # Too many? Keep the largest sizes until it looks like a table of contents rather than a list of every subhead.
    sizes = sorted({round(s, 1) for _, _, s in cands}, reverse=True)
    while len(cands) > max(12, limit // 3) and len(sizes) > 1:
        sizes.pop()
        cands = [c for c in cands if round(c[2], 1) in sizes]
    # One heading per page at most: the first (largest) on that page.
    by_page: dict[int, tuple[str, float]] = {}
    for page, text, size in cands:
        cur = by_page.get(page)
        if cur is None or size > cur[1] + 0.5:
            by_page[page] = (text, size)
    entries = [(1, text, page) for page, (text, _) in sorted(by_page.items())]
    if len(entries) < 2:
        return []
    return _close_sections(entries[:300], doc.page_count)


# ------------------------------------------------------------------ extraction

def extract(path: str, first_page: int | None = None, last_page: int | None = None,
            progress: Callable[[str], None] | None = None, with_outline: bool = True) -> Document:
    doc = fitz.open(path)
    total = doc.page_count
    start = max(1, first_page or 1)
    end = min(total, last_page or total)

    per_page: list[list[str]] = []
    for pno in range(start - 1, end):
        if progress and (pno - start + 1) % 25 == 0:
            progress(f"Reading page {pno + 1} of {end}…")
        page = doc[pno]
        blocks = page.get_text("blocks", sort=True)
        cleaned = [_clean_block(b[4]) for b in blocks if b[6] == 0]  # text blocks only
        per_page.append([c for c in cleaned if not _is_noise(c)])

    # Drop running headers/footers: short lines repeated on many pages.
    if len(per_page) >= 4:
        counts = Counter(b for page in per_page for b in set(page) if len(b) < 120)
        repeated = {b for b, n in counts.items() if n >= max(3, len(per_page) * 0.4)}
        per_page = [[b for b in page if b not in repeated] for page in per_page]

    outline: list[Section] = []
    source = "none"
    if with_outline:
        outline = _bookmark_outline(doc)
        source = "bookmarks" if outline else "none"
        if not outline and total >= 4:
            outline = _heading_outline(doc, progress)
            source = "headings" if outline else "none"
    doc.close()
    # Pages outside a requested range are simply empty, so page numbers stay 1:1 with the file.
    page_blocks = [[] for _ in range(start - 1)] + per_page + [[] for _ in range(end, total)]
    return Document(name=os.path.basename(path), path=path, pages=total, page_blocks=page_blocks,
                    outline=outline, outline_source=source)
