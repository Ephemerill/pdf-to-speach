"""Extract clean, readable text from a PDF for narration.

`extract` returns the text page by page (so the app can narrate any set of pages without coming
back here) plus an outline — the PDF's own bookmarks when it has them, otherwise headings found by
looking at font sizes and "Chapter N"-style lines — so whole chapters can be picked by name.

Every block is also classified — body text, page number, running header/footer, or footnote — and
footnote reference marks (the little raised "12" after a word) are found inside body lines, so the
app can offer both a clean reading (the default) and a literal one without coming back here.
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
    page_blocks: list[list[str]]                # body text blocks per page, in reading order (notes, page numbers,
                                                #   running heads and note marks skipped)
    page_blocks_all: list[list[str]] = field(default_factory=list)   # everything, read literally
    outline: list[Section] = field(default_factory=list)
    outline_source: str = "none"                # "bookmarks" | "headings" | "none"
    scanned_pages: list[int] = field(default_factory=list)   # 1-based pages that are pictures with no text layer

    @property
    def paragraphs(self) -> list[str]:
        return join_paragraphs(self.page_blocks)


_WS = re.compile(r"[ \t ]+")
_HYPHEN_BREAK = re.compile(r"(\w)-\n(\w)")
_LINE_BREAK = re.compile(r"(?<![.!?:;])\n(?!\n)")
_PAGE_NUMBER = re.compile(r"^\s*[-–—(\[]?\s*(page\s*|p\.\s*)?\d{1,4}(\s*(of|/)\s*\d{1,4})?\s*[-–—)\]]?\s*$", re.I)
# Front-matter page numbers (only trusted in the top/bottom margin: "mix" is a word too).
_ROMAN_PAGE = re.compile(r"^\s*[-–—(\[]?\s*(?=[ivxlc]+\b)c{0,3}(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})\s*[-–—)\]]?\s*$")
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


# ------------------------------------------------------------------ page anatomy
#
# Reading a scholarly PDF aloud literally means hearing "142 Journal of River Studies" at every page
# turn, "traders twelve" in the middle of sentences and the footnotes read as if they were the text.
# So every block is classified from its position, size and neighbours:
#
#   page number   a lone number (or "Page 3 of 9", "– 12 –", "xii") — roman numerals only in the margins
#   header        a running head/foot: short, in the top/bottom margin, repeated across pages once its
#                 digits are ignored ("142 JOURNAL…", "Downloaded from … on 12 Oct"), or rotated margin text
#   footnote      the run of smaller-than-body blocks at the foot of the page that starts with a note
#                 mark ("12 See…", "* Equal contribution", a raised "3"), or anything under the short
#                 rule LaTeX/Word draw above notes. Once a document's note size is known, unmarked runs
#                 of that size at the foot (a note continued from the previous page) count too.
#
# Inside body lines, note marks are small raised digits/symbols right after a word or punctuation
# ("traders¹²,"); they're dropped from the clean text. A raised digit after a digit or a lone letter is
# a power (10⁹, n²) and stays.

_NOTE_MARK = re.compile(r"^\s*(\d{1,3}|[*∗†‡§¶#]{1,3})\s*$")
_NOTE_START = re.compile(r"^\s*(\d{1,3}|[*∗†‡§¶]{1,3}|\(\d{1,3}\)|\[\d{1,3}\])[.)]?\s*\S")
_NUMBERED_HEAD = re.compile(r"^\s*\d{1,4}\s|\s\d{1,4}\s*$")
_MARGIN = 0.09          # top/bottom fraction of the page where running heads and page numbers live


@dataclass
class _Block:
    text: str           # clean: note marks removed
    full: str           # literal
    size: float         # dominant font size
    top: float
    bottom: float
    rotated: bool
    marked: bool        # starts with a note mark (typed or raised)
    kind: str = "body"


def _span_join(parts: list[tuple[str, tuple]]) -> str:
    """Spans of one line → text, adding the space PDFs often leave implicit (a gap between glyph runs)."""
    out = ""
    prev_x1 = None
    for text, bbox in parts:
        if out and prev_x1 is not None and bbox[0] - prev_x1 > 1.5 and not out.endswith(" ") and not text.startswith(" "):
            out += " "
        out += text
        prev_x1 = bbox[2]
    return out


def _read_blocks(page: fitz.Page) -> list[_Block]:
    d = page.get_text("dict", sort=True, flags=fitz.TEXT_PRESERVE_LIGATURES | fitz.TEXT_PRESERVE_WHITESPACE)
    blocks: list[_Block] = []
    for b in d.get("blocks", []):
        if b.get("type") != 0:
            continue
        full_lines, clean_lines = [], []
        size_chars: Counter = Counter()
        rotated = 0
        marked = False
        for li, line in enumerate(b.get("lines", [])):
            spans = [s for s in line.get("spans", []) if s.get("text")]
            if not spans:
                continue
            if abs(line.get("dir", (1, 0))[1]) > 0.1:
                rotated += 1
            weights: Counter = Counter()
            for s in spans:
                weights[round(s["size"] * 2) / 2] += len(s["text"].strip())
            main = weights.most_common(1)[0][0] if weights else spans[0]["size"]
            baseline = max((s["origin"][1] for s in spans if abs(s["size"] - main) < 0.6), default=spans[0]["origin"][1])
            full, clean = [], []
            for si, s in enumerate(spans):
                t = s["text"]
                full.append((t, s["bbox"]))
                raised = (s.get("flags", 0) & 1) or (s["size"] <= main * 0.82 and s["origin"][1] < baseline - main * 0.12)
                is_mark = bool(raised and _NOTE_MARK.match(t))
                if is_mark:
                    if li == 0 and si == 0:
                        marked = True                      # a note that opens with a raised number
                    prev = "".join(x for x, _ in clean).rstrip()
                    # After a word or punctuation it's a note mark; after a digit or a one-letter
                    # variable it's a power (10⁹, n²) and stays.
                    last = prev.split()[-1] if prev else ""
                    after_word = bool(last) and (last[-1] in ".,;:!?)\"'’”]" or (last[-1].isalpha() and len(last) >= 2))
                    if after_word or not prev:
                        continue                           # drop it from the clean text
                clean.append((t, s["bbox"]))
                size_chars[round(s["size"] * 2) / 2] += len(t.strip())
            full_lines.append(_span_join(full))
            clean_lines.append(_span_join(clean))
        if not full_lines:
            continue
        full = _clean_block("\n".join(full_lines))
        clean = _clean_block("\n".join(clean_lines))
        if not full:
            continue
        size = size_chars.most_common(1)[0][0] if size_chars else 0.0
        x0, y0, x1, y1 = b["bbox"]
        blocks.append(_Block(text=clean, full=full, size=size, top=y0, bottom=y1,
                             rotated=rotated == len(full_lines), marked=marked or bool(_NOTE_START.match(full))))
    return blocks


def _note_rule(page: fitz.Page) -> float | None:
    """The y of the short horizontal rule above footnotes, if the page has one."""
    w, h = page.rect.width, page.rect.height
    best = None
    try:
        drawings = page.get_drawings()
    except Exception:  # noqa: BLE001
        return None
    for dr in drawings:
        r = dr.get("rect")
        if r is None or r.height > 1.5 or not (25 <= r.width <= w * 0.45):
            continue
        if not (h * 0.4 <= r.y0 <= h * (1 - _MARGIN * 0.5)) or r.x0 > w * 0.45:
            continue
        if best is None or r.y0 > best:   # the lowest one: tables and figures sit higher up
            best = r.y0
    return best


def _classify(pages: list[list[_Block]], rules: list[float | None], heights: list[float]) -> None:
    """Fill in each block's kind (see the comment at the top of this section)."""
    sizes: Counter = Counter()
    for page in pages:
        for b in page:
            sizes[b.size] += len(b.full)
    if not sizes:
        return
    body = sizes.most_common(1)[0][0]
    small = body * 0.92

    # Running heads: digits ignored, repeated in the margins of many pages.
    def key(t: str) -> str:
        return re.sub(r"\d+", "#", t.lower()).strip()
    n = len(pages)
    margin_counts: Counter = Counter()
    exact_counts: Counter = Counter()
    for page, h in zip(pages, heights):
        seen, seen_exact = set(), set()
        for b in page:
            if len(b.full) < 150 and (b.bottom < h * _MARGIN * 1.4 or b.top > h * (1 - _MARGIN * 1.4)):
                seen.add(key(b.full))
            if len(b.full) < 120:
                seen_exact.add(b.full)
        margin_counts.update(seen); exact_counts.update(seen_exact)
    repeat = max(3, n * 0.2)

    for page, h in zip(pages, heights):
        for b in page:
            in_margin = b.bottom < h * _MARGIN * 1.4 or b.top > h * (1 - _MARGIN * 1.4)
            if _PAGE_NUMBER.match(b.full) or (in_margin and _ROMAN_PAGE.match(b.full)):
                b.kind = "page_number"
            elif b.rotated and len(b.full) < 200:
                b.kind = "header"                      # sideways margin stamps ("arXiv:… 2 Aug 2023")
            elif in_margin and len(b.full) < 150 and n >= 3 and margin_counts[key(b.full)] >= repeat:
                b.kind = "header"
            elif in_margin and len(b.full) < 100 and margin_counts[key(b.full)] >= 2 and _NUMBERED_HEAD.search(b.full):
                b.kind = "header"                      # "142 JOURNAL…" on even pages, "…TRADE 143" on odd ones
            elif n >= 4 and len(b.full) < 120 and exact_counts[b.full] >= max(3, n * 0.4):
                b.kind = "header"

    def foot_run(page: list[_Block]) -> list[_Block]:
        """Body blocks at the bottom of the page with nothing body-sized below them."""
        run: list[_Block] = []
        for b in sorted((b for b in page if b.kind == "body"), key=lambda b: b.top, reverse=True):
            if b.size <= small:
                run.append(b)
            else:
                break
        return run[::-1]

    note_sizes: Counter = Counter()
    for page, rule, h in zip(pages, rules, heights):
        if rule is not None:
            below = [b for b in page if b.kind == "body" and b.top >= rule - 2 and b.size <= body * 1.02]
            if below:
                for b in below:
                    b.kind = "footnote"; note_sizes[b.size] += 1
                continue
        run = [b for b in foot_run(page) if b.top > h * 0.45]
        # The run counts as notes from its first marked block down.
        for i, b in enumerate(run):
            if b.marked:
                for c in run[i:]:
                    c.kind = "footnote"; note_sizes[c.size] += 1
                break
    # Second pass: unmarked runs set in the document's note size (a note carried over from the page before).
    if note_sizes:
        note = note_sizes.most_common(1)[0][0]
        for page, h in zip(pages, heights):
            for b in foot_run(page):
                if b.top > h * 0.45 and abs(b.size - note) <= 0.5:
                    b.kind = "footnote"


# ------------------------------------------------------------------ extraction

def extract(path: str, first_page: int | None = None, last_page: int | None = None,
            progress: Callable[[str], None] | None = None, with_outline: bool = True) -> Document:
    doc = fitz.open(path)
    total = doc.page_count
    start = max(1, first_page or 1)
    end = min(total, last_page or total)

    pages: list[list[_Block]] = []
    rules: list[float | None] = []
    heights: list[float] = []
    scanned: list[int] = []
    for pno in range(start - 1, end):
        if progress and (pno - start + 1) % 25 == 0:
            progress(f"Reading page {pno + 1} of {end}…")
        page = doc[pno]
        try:
            blocks = _read_blocks(page)
        except Exception:  # noqa: BLE001 — a malformed page shouldn't sink the whole book
            blocks = []
        if not blocks:
            try:
                if page.get_images():
                    scanned.append(pno + 1)
            except Exception:  # noqa: BLE001
                pass
        pages.append(blocks)
        rules.append(_note_rule(page) if blocks else None)
        heights.append(page.rect.height)
    _classify(pages, rules, heights)

    # Tables, figure axes and math soup are never worth reading; page numbers fail that test but are
    # kept in the literal reading.
    def keep(b: _Block, text: str) -> bool:
        return bool(text) and (b.kind == "page_number" or not _is_noise(text))
    clean_pages = [[b.text for b in page if b.kind == "body" and keep(b, b.text)] for page in pages]
    full_pages = [[b.full for b in page if keep(b, b.full)] for page in pages]

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
    pad_before, pad_after = [[] for _ in range(start - 1)], [[] for _ in range(end, total)]
    return Document(name=os.path.basename(path), path=path, pages=total,
                    page_blocks=pad_before + clean_pages + pad_after,
                    page_blocks_all=[[] for _ in range(start - 1)] + full_pages + [[] for _ in range(end, total)],
                    outline=outline, outline_source=source, scanned_pages=scanned)
