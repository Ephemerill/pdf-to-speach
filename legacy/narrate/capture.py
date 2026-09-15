"""Read text out of a live web page in the built-in browser window.

Strategy, in order:
  1. Page-scan images (JSTOR-style viewers): fetch each page image → OCR with column-aware ordering.
  2. Article DOM text, when the page has a real text body.
  3. Scroll the page and screenshot the viewport step by step → OCR (works on anything visible).
OCR runs on macOS's built-in Vision framework, so nothing extra is downloaded.
"""
from __future__ import annotations

import base64
import json
import os
import re
import statistics
import threading
import time
from dataclasses import dataclass
from typing import Callable

import AppKit
import Foundation
import Vision
import WebKit
from PyObjCTools import AppHelper

Progress = Callable[[str, float], None]
DEBUG = bool(os.environ.get("NARRATE_DEBUG"))


def _log(*a):
    if DEBUG:
        print("[capture]", *a, flush=True)


# ------------------------------------------------------------------ webview helpers

def _native(window):
    from webview.platforms.cocoa import BrowserView
    return BrowserView.instances[window.uid].webview  # the WKWebView


def eval_js(window, script: str, timeout: float = 120, is_async: bool = False):
    """Run JS in the page via WebKit directly, with a hard timeout. `script` is an expression;
    with is_async it may evaluate to a promise, which is awaited. Results come back as JSON."""
    wk = _native(window)
    box: dict = {}
    done = threading.Event()

    def handler(result, error):
        box["r"], box["e"] = result, error
        done.set()

    def go():
        if is_async:
            body = f"return JSON.stringify(await ({script}));"
            wk.callAsyncJavaScript_arguments_inFrame_inContentWorld_completionHandler_(
                body, {}, None, WebKit.WKContentWorld.pageWorld(), handler)
        else:
            wk.evaluateJavaScript_completionHandler_(f"JSON.stringify({script})", handler)

    AppHelper.callAfter(go)
    if not done.wait(timeout):
        raise TimeoutError("the page did not respond")
    if box.get("e") is not None:
        raise RuntimeError(f"page script error: {box['e'].localizedDescription()}")
    return json.loads(box["r"]) if box.get("r") is not None else None


def snapshot_png(window) -> bytes:
    """Screenshot the visible viewport of the window's WKWebView (retina resolution)."""
    wk = _native(window)
    box: dict = {}
    done = threading.Event()

    def go():
        cfg = WebKit.WKSnapshotConfiguration.alloc().init()
        cfg.setAfterScreenUpdates_(True)

        def handler(image, error):
            if image is not None:
                rep = AppKit.NSBitmapImageRep.alloc().initWithData_(image.TIFFRepresentation())
                box["png"] = bytes(rep.representationUsingType_properties_(AppKit.NSBitmapImageFileTypePNG, None))
            else:
                box["err"] = str(error)
            done.set()

        wk.takeSnapshotWithConfiguration_completionHandler_(cfg, handler)

    AppHelper.callAfter(go)
    if not done.wait(20) or "png" not in box:
        raise RuntimeError(box.get("err", "snapshot failed"))
    return box["png"]


# ------------------------------------------------------------------ OCR

@dataclass
class Line:
    text: str
    x0: float
    x1: float
    y: float      # top, 0 at top of image
    h: float


_FOOTNOTE_MARK = re.compile(r"(?<=[\w.,;:!?\"')\]])[®°†‡§¶]+")
_HYPHENS = str.maketrans({"\u2010": "-", "\u2011": "-", "\u00ad": "-", "\u2012": "-"})


def _clean_ocr_text(text: str) -> str:
    text = text.translate(_HYPHENS).strip()
    text = _FOOTNOTE_MARK.sub("", text)                 # superscript footnote marks read as symbols
    text = re.sub(r"(?<=[a-z])\s?['’]\s(?=[a-z])", "'", text)  # apostrophes split by spacing
    return text.strip()


def _recognize(handler, roi=None) -> list[Line]:
    req = Vision.VNRecognizeTextRequest.alloc().init()
    req.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
    req.setUsesLanguageCorrection_(True)
    if roi is not None:
        req.setRegionOfInterest_(roi)
    ok, err = handler.performRequests_error_([req], None)
    if not ok:
        raise RuntimeError(f"OCR failed: {err}")
    lines: list[Line] = []
    for obs in req.results() or []:
        cands = obs.topCandidates_(1)
        if not cands:
            continue
        text = _clean_ocr_text(cands[0].string())
        if not text:
            continue
        b = obs.boundingBox()  # normalised, origin bottom-left (relative to the ROI when one is set)
        x, y, w, h = b.origin.x, b.origin.y, b.size.width, b.size.height
        if roi is not None:
            x = roi.origin.x + x * roi.size.width
            w = w * roi.size.width
            y = roi.origin.y + y * roi.size.height
            h = h * roi.size.height
        lines.append(Line(text, x, x + w, 1 - (y + h), h))
    return lines


def ocr(image_bytes: bytes) -> list[Line]:
    data = Foundation.NSData.dataWithBytes_length_(image_bytes, len(image_bytes))
    handler = Vision.VNImageRequestHandler.alloc().initWithData_options_(data, None)
    lines = _recognize(handler)
    if len(lines) < 6:
        return lines
    # Drop caps make Vision merge two lines into one garbled observation. Re-read the text
    # to the right of the big initial and keep the initial letter itself.
    med_h = statistics.median(l.h for l in lines)
    img = AppKit.NSImage.alloc().initWithData_(data)
    aspect = img.size().width / img.size().height if img and img.size().height else 0.7
    fixed: list[Line] = []
    for l in lines:
        if l.h > 1.6 * med_h and (l.x1 - l.x0) > 0.25 and l.y > 0.05:
            cap_w = l.h / aspect * 0.95                      # a drop cap is roughly square in pixels
            roi = Foundation.NSMakeRect(l.x0 + cap_w, 1 - (l.y + l.h), max(0.05, l.x1 - l.x0 - cap_w), l.h)
            sub = sorted(_recognize(handler, roi), key=lambda x: x.y)
            if len(sub) >= 2:
                initial = l.text[:1] if l.text[:1].isalpha() else ""
                sub[0] = Line(initial + sub[0].text, l.x0, sub[0].x1, sub[0].y, sub[0].h)
                fixed.extend(sub)
                continue
        fixed.append(l)
    return _dedupe_fragments(fixed)


def _dedupe_fragments(lines: list[Line]) -> list[Line]:
    """Vision sometimes emits a fragment of a line as a second observation; drop such duplicates."""
    keep: list[Line] = []
    norm = lambda t: re.sub(r"\W+", "", t.lower())
    for l in sorted(lines, key=lambda x: -(x.x1 - x.x0)):
        dup = False
        for k in keep:
            overlap = min(l.y + l.h, k.y + k.h) - max(l.y, k.y)
            if overlap > 0.5 * min(l.h, k.h) and l.x0 < k.x1 and k.x0 < l.x1 and norm(l.text) and norm(l.text) in norm(k.text):
                dup = True
                break
        if not dup:
            keep.append(l)
    return sorted(keep, key=lambda x: x.y)


def _strip_footnotes(lines: list[Line]) -> list[Line]:
    """Footnotes sit at the foot of the page in smaller type with tighter line pitch; drop that block."""
    if len(lines) < 8:
        return lines
    pitches = [b.y - a.y for a, b in zip(lines, lines[1:]) if 0 < b.y - a.y < 0.05]
    if not pitches:
        return lines
    med_pitch = statistics.median(pitches)
    # Walk up from the bottom while the block's average pitch stays tight (single pitches jitter).
    i = len(lines) - 1
    block_start = None
    while i > 0 and lines[i].y > 0.5:
        pitch = lines[i].y - lines[i - 1].y
        avg = (lines[-1].y - lines[i - 1].y) / (len(lines) - i)
        if 0 < pitch < 1.05 * med_pitch and avg < 0.88 * med_pitch:
            block_start = i - 1
            i -= 1
        else:
            break
    if block_start is None or len(lines) - block_start < 3:
        return lines
    first = lines[block_start].text.lstrip()
    if re.match(r"^(\d{1,2}|[*†‡§¶])\s*\S", first):
        return lines[:block_start]
    return lines


def lines_to_paragraphs(lines: list[Line]) -> list[str]:
    """Reconstruct reading order: detect 2-column layouts, split paragraphs on vertical gaps."""
    if not lines:
        return []
    lines = sorted(lines, key=lambda l: l.y)
    med_h = statistics.median(l.h for l in lines)

    def is_furniture(l: Line) -> bool:
        words = l.text.split()
        short = len(words) <= 8
        caps = sum(c.isupper() for c in l.text) >= 0.6 * max(1, sum(c.isalpha() for c in l.text))
        digits = any(c.isdigit() for c in l.text)
        if l.y < 0.1 and short and (caps or digits):
            return True                         # running header / page number
        if l.y > 0.88 and short and (digits or caps) and len(words) <= 4:
            return True                         # page number / journal footer
        return False

    if len(lines) >= 6:
        lines = [l for l in lines if not is_furniture(l)] or lines
        lines = _strip_footnotes(lines)
    left = [l for l in lines if l.x1 < 0.55 and l.x0 < 0.45]
    right = [l for l in lines if l.x0 > 0.45]
    two_col = len(left) >= 4 and len(right) >= 4 and \
        min(len(left), len(right)) >= 0.25 * len(lines)

    ordered: list[Line] = []
    if two_col:
        # Full-width lines (titles, footers) act as section breaks; within a section read L then R.
        section_l: list[Line] = []
        section_r: list[Line] = []

        def flush():
            ordered.extend(section_l); ordered.extend(section_r)
            section_l.clear(); section_r.clear()

        for l in lines:
            spanning = l.x0 < 0.4 and l.x1 > 0.6
            if spanning:
                flush(); ordered.append(l)
            elif (l.x0 + l.x1) / 2 < 0.5:
                section_l.append(l)
            else:
                section_r.append(l)
        flush()
    else:
        ordered = lines

    paras: list[str] = []
    buf: list[str] = []
    prev: Line | None = None
    for l in ordered:
        gap_break = prev is not None and (l.y - (prev.y + prev.h)) > med_h * 1.1
        col_jump = prev is not None and l.y < prev.y - med_h  # jumped back up = new column/section
        indent = prev is not None and abs(l.x0 - prev.x0) > 0.03 and l.x0 > prev.x0 and prev.x1 < 0.9 * l.x1 + 0.1
        if buf and (gap_break or col_jump or (indent and prev.text.rstrip().endswith((".", "?", "!", '"')))):
            paras.append(" ".join(buf)); buf = []
        if buf and buf[-1].endswith("-") and l.text[:1].islower():
            buf[-1] = buf[-1][:-1] + l.text
        else:
            buf.append(l.text)
        prev = l
    if buf:
        paras.append(" ".join(buf))

    cleaned = []
    for p in paras:
        p = re.sub(r"\s+", " ", p).strip()
        letters = sum(c.isalpha() for c in p)
        if letters >= 3 and letters >= 0.4 * len(p):
            cleaned.append(p)
    return cleaned


# ------------------------------------------------------------------ page strategies

# An expression (so it can be composed with the comma operator) that installs shared helpers once.
_JS_HELPERS = """
(window.__narrate = window.__narrate || (() => {
  const bigPages = () => [...document.querySelectorAll('img, canvas')].filter(e => {
    const w = e.naturalWidth || e.width, h = e.naturalHeight || e.height;
    return w >= 500 && h > w * 1.05 && e.getBoundingClientRect().width > 200;
  });
  const scrollsY = e => e === document.scrollingElement || /(auto|scroll)/.test(getComputedStyle(e).overflowY);
  const scrollerOf = el => { for (let e = el.parentElement; e; e = e.parentElement) if (scrollsY(e) && e.scrollHeight > e.clientHeight + 40) return e; return document.scrollingElement; };
  const rendered = c => {   // a pdf.js canvas is blank until the page has been painted
    if (c.tagName !== 'CANVAS') return true;
    try { const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data; let first = d[0] + d[1] + d[2] + d[3];
      for (let i = 4; i < d.length; i += 4 * 997) if (d[i] + d[i + 1] + d[i + 2] + d[i + 3] !== first) return true; return false; }
    catch (_) { return true; }
  };
  return { bigPages, scrollerOf, rendered, imgs: new Map() };
})())
"""

_JS_SCROLLER = "(" + _JS_HELPERS + """, (() => {
  const N = window.__narrate, pages = N.bigPages();
  let best;
  if (pages.length) best = N.scrollerOf(pages[0]);
  else {
    best = document.scrollingElement;
    for (const e of document.querySelectorAll('div, main, section, article'))
      if (/(auto|scroll)/.test(getComputedStyle(e).overflowY) && e.clientHeight > 200 && e.scrollHeight > Math.max(best.scrollHeight, e.clientHeight + 40)) best = e;
  }
  N.scroller = best;
  return { h: best.scrollHeight, ch: best.clientHeight, pages: pages.length };
})())
"""

_JS_SCROLL_TO = "(() => { window.__narrate.scroller.scrollTo(0, %d); return window.__narrate.scroller.scrollTop; })()"

_JS_COLLECT_IMAGES = "(" + _JS_HELPERS + """, (() => {
  const N = window.__narrate;
  for (const e of N.bigPages()) {
    const pageEl = e.closest('[data-page-number], [data-page], .page');
    const num = pageEl && (pageEl.dataset.pageNumber || pageEl.dataset.page || pageEl.dataset.pageIndex);
    const top = e.getBoundingClientRect().top + (N.scroller ? N.scroller.scrollTop : 0);
    const key = e.tagName === 'IMG' ? (e.currentSrc || e.src) : ('canvas:' + (num != null ? num : Math.round(top / 8)));
    const px = (e.naturalWidth || e.width) * (e.naturalHeight || e.height);
    const prev = N.imgs.get(key);
    if (prev && prev.px >= px) continue;          // keep the sharpest render we have seen (pdf.js paints low-res first)
    if (!N.rendered(e)) continue;
    let data = null;
    if (e.tagName === 'CANVAS') { try { data = e.toDataURL('image/png'); } catch (_) {} }
    N.imgs.set(key, { key, data, px, sort: num != null ? +num : top });
  }
  return N.imgs.size;
})())
"""

_JS_FETCH_IMAGES = """
(async () => {
  const out = [];
  for (const v of [...window.__narrate.imgs.values()].sort((a, b) => a.sort - b.sort)) {
    if (v.data) { out.push(v.data); continue; }
    try {
      const r = await fetch(v.key, { credentials: 'include' });
      const b = await r.blob();
      out.push(await new Promise(res => { const fr = new FileReader(); fr.onload = () => res(fr.result); fr.readAsDataURL(b); }));
    } catch (e) {
      // cross-origin without CORS: draw via an <img> into a canvas if allowed
      try {
        const img = await new Promise((res, rej) => { const i = new Image(); i.crossOrigin = 'anonymous'; i.onload = () => res(i); i.onerror = rej; i.src = v.key; });
        const c = document.createElement('canvas'); c.width = img.naturalWidth; c.height = img.naturalHeight;
        c.getContext('2d').drawImage(img, 0, 0); out.push(c.toDataURL('image/png'));
      } catch (_) { out.push(null); }
    }
  }
  return out;
})()
"""

_JS_DOM_TEXT = """
(() => {
  const sels = ['article', 'main', '[role=main]', '#content', '.content', '#main', 'body'];
  for (const s of sels) {
    const el = document.querySelector(s);
    if (!el) continue;
    const t = el.innerText || '';
    if (t.split(/\\s+/).length >= 200) return { title: document.title, text: t, sel: s };
  }
  return { title: document.title, text: document.body ? document.body.innerText : '', sel: 'body' };
})()
"""


def _text_to_paragraphs(text: str) -> list[str]:
    paras = []
    for block in re.split(r"\n\s*\n", text):
        block = re.sub(r"\s+", " ", block).strip()
        words = block.split()
        if len(words) >= 6 or (words and block.endswith((".", "!", "?"))):
            paras.append(block)
    return paras


def clean_title(title: str) -> str:
    """'What Is It Like to Be a Bat? | JSTOR' -> 'What Is It Like to Be a Bat?'"""
    parts = re.split(r"\s+[|—–·:-]\s+", title.strip())
    return parts[0] if parts and len(parts[0]) >= 8 else title.strip()


def capture(window, progress: Progress) -> tuple[str, list[str], str]:
    """Returns (title, paragraphs, method)."""
    _log("start")
    title = clean_title(eval_js(window, "document.title") or "Web page")
    _log("title", title)
    dims = eval_js(window, _JS_SCROLLER)
    _log("dims", dims)
    h, ch = int(dims["h"]), int(dims["ch"])
    has_pages = dims.get("pages", 0) > 0
    step = max(200, int(ch * (0.6 if has_pages else 0.85)))
    positions = list(range(0, max(1, h - ch + 1), step)) + [max(0, h - ch)]
    positions = sorted(set(positions))

    # Pass 1: scroll through everything (triggers lazy loading), collect page images and viewport shots.
    shots: list[tuple[int, bytes]] = []
    for i, y in enumerate(positions):
        eval_js(window, _JS_SCROLL_TO % y)
        time.sleep(0.9 if (i == 0 or has_pages) else 0.45)   # lazy viewers need time to paint
        n = eval_js(window, _JS_COLLECT_IMAGES)
        if not has_pages:
            shots.append((y, snapshot_png(window)))
        _log("step", i, y, "pages", n)
        progress(f"Scanning page… {i + 1}/{len(positions)}", 0.3 * (i + 1) / len(positions))
    if has_pages:
        eval_js(window, _JS_SCROLL_TO % 0)
        time.sleep(1.2)
        eval_js(window, _JS_COLLECT_IMAGES)
    n_imgs = int(eval_js(window, "window.__narrate.imgs.size"))
    if n_imgs and not has_pages:          # pages appeared during the scroll (lazy viewer): rescan them
        eval_js(window, _JS_SCROLLER)
    _log("images", n_imgs)

    # Strategy 1: page images.
    if n_imgs >= 1:
        images = [d for d in (eval_js(window, _JS_FETCH_IMAGES, timeout=300, is_async=True) or []) if d]
        if images:
            paras: list[str] = []
            for i, data_url in enumerate(images):
                raw = base64.b64decode(data_url.split(",", 1)[1])
                paras += lines_to_paragraphs(ocr(raw))
                progress(f"Reading page scans… {i + 1}/{len(images)}", 0.3 + 0.7 * (i + 1) / len(images))
            if sum(len(p.split()) for p in paras) >= 80:
                return title, _merge_page_breaks(paras), "page images"

    # Strategy 2: DOM text.
    dom = eval_js(window, _JS_DOM_TEXT) or {}
    dom_paras = _text_to_paragraphs(dom.get("text", ""))
    if sum(len(p.split()) for p in dom_paras) >= 200:
        progress("Reading article text…", 1.0)
        return clean_title(dom.get("title") or title), dom_paras, "article text"

    # Strategy 3: OCR the viewport screenshots, de-duplicating the overlap between frames.
    if not shots:
        for i, y in enumerate(positions):
            eval_js(window, _JS_SCROLL_TO % y)
            time.sleep(0.5)
            shots.append((y, snapshot_png(window)))
    paras = []
    seen: set[str] = set()
    for i, (_, png) in enumerate(shots):
        lines = ocr(png)
        # drop lines touching the frame edge (they may be cut); overlap guarantees they appear intact elsewhere
        lines = [l for l in lines if l.y > 0.01 and (l.y + l.h) < 0.99]
        fresh = []
        for l in lines:
            key = re.sub(r"\W+", "", l.text.lower())
            if key and key not in seen:
                seen.add(key); fresh.append(l)
        paras += lines_to_paragraphs(fresh)
        progress(f"Reading screen… {i + 1}/{len(shots)}", 0.3 + 0.7 * (i + 1) / len(shots))
    return title, _merge_page_breaks(paras), "screen OCR"


def _merge_page_breaks(paras: list[str]) -> list[str]:
    """Join a paragraph that was cut at a page/frame boundary with its continuation."""
    out: list[str] = []
    for p in paras:
        if out and not out[-1].rstrip().endswith((".", "!", "?", '"', ":", ")")) and p[:1].islower():
            out[-1] = out[-1] + " " + p
        else:
            out.append(p)
    return out
