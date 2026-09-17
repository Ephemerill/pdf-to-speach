import Foundation
import WebKit

/// Pulls the readable article out of a loaded web page — the body text without the menus, ads,
/// share bars, comments and endnotes — the way Safari's Reader does. The heuristics are a compact
/// take on Readability: paragraph-like blocks vote for their ancestors, the best-scoring container
/// wins, and it is then walked in order with page furniture skipped.
enum Article {
    struct Result {
        var title: String
        var byline: String
        var paragraphs: [String]
        var words: Int

        /// What the narrator reads: the title (and author) first, then the body.
        var spokenParagraphs: [String] {
            var lead = title.trimmingCharacters(in: .whitespaces)
            if lead.isEmpty { return paragraphs }
            if !byline.isEmpty { lead += ", by \(byline)" }
            if !lead.hasSuffix(".") && !lead.hasSuffix("!") && !lead.hasSuffix("?") { lead += "." }
            return [lead] + paragraphs
        }
    }

    /// Below this the page is probably a login wall, a bot check, a viewer of page scans or a
    /// listing — not something worth narrating as-is.
    static let minimumWords = 120

    /// Run the extractor in the page. Nil when nothing paragraph-like was found at all.
    @MainActor
    static func extract(_ web: WKWebView) async throws -> Result? {
        guard let r = try await Capture.eval(web, script, timeout: 30) as? [String: Any] else { return nil }
        let paras = (r["paragraphs"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !paras.isEmpty else { return nil }
        return Result(title: Capture.cleanTitle(r["title"] as? String ?? "Article"),
                      byline: r["byline"] as? String ?? "",
                      paragraphs: paras,
                      words: (r["words"] as? NSNumber)?.intValue ?? Capture.wordCount(paras))
    }

    // An expression evaluating to { title, byline, paragraphs, headings, words, url } or null.
    static let script = #"""
(() => {
  // Readability-style article extraction: score text blocks, pick the densest container, then walk
  // it emitting paragraphs while skipping navigation, ads, share bars, comments and the like.
  const UNLIKELY = /-ad-|_ad_|^ad-|-ad$|advert|adsense|banner|breadcrumb|combx|comment|community|cookie|disqus|extra|footer|gdpr|header|legends|menu|modal|navbar|newsletter|outbrain|pager|pagination|popup|promo|related|recommend|remark|replies|rss|share|sharing|shoutbox|sidebar|skyscraper|social|sponsor|subscribe|supplemental|taboola|toolbar|trending|widget|yom-remote|sr-only|visually-hidden|screen-reader|footnote|endnote|citation|references|bibliography|hatnote|disambig|infobox|navbox|catlinks|mw-editsection|noprint/i;
  const MAYBE = /and|article|body|column|content|main|shadow|post|entry|story|prose|text/i;
  const POSITIVE = /article|body|content|entry|hentry|h-entry|main|page|pagination|post|text|blog|story|prose/i;
  const NEGATIVE = /-ad-|hidden|^hid$| hid$| hid |^hid |banner|combx|comment|com-|contact|foot|footer|footnote|gdpr|masthead|media|meta|modal|outbrain|promo|related|scroll|share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags|tool|widget/i;
  const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'SVG', 'IFRAME', 'NAV', 'ASIDE', 'FOOTER', 'FORM', 'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'FIGURE', 'FIGCAPTION', 'VIDEO', 'AUDIO', 'CANVAS', 'OBJECT', 'EMBED', 'MENU', 'DIALOG', 'IMG', 'PICTURE', 'MATH', 'SUP']);
  const BLOCKS = new Set(['P', 'DIV', 'SECTION', 'ARTICLE', 'MAIN', 'UL', 'OL', 'LI', 'TABLE', 'TBODY', 'THEAD', 'TR', 'TD', 'TH', 'BLOCKQUOTE', 'PRE', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'HEADER', 'FOOTER', 'ASIDE', 'NAV', 'FIGURE', 'DL', 'DD', 'DT', 'DETAILS', 'SUMMARY', 'HR', 'BODY']);
  const BLOCK_SEL = [...BLOCKS].join(',');
  const JUNK = /^(advertisement|sponsored( content)?|share( this)?( article| story| post)?|read more|related( articles| stories| posts| content)?|comments?( \(\d+\))?|subscribe( now)?|sign ?(up|in)|log ?in|photo|image|credit|tags?|more from .*|follow us.*|(click|tap) here.*|loading.*|skip to (main )?content|menu|search|close|print( this)?|email|copy link|table of contents|contents|in this article|see also|references|external links|leave a comment|reply|previous|next|back to top|cookie.*|accept.*|listen( to this article)?|\d+ min(ute)? read|\d+ (shares|comments|views)|\d+ (seconds?|minutes?|hours?|days?|weeks?) ago|(published|updated|posted)( on)?:? .*)$/i;
  const CITATION = /\b(ibid|op\.\s*cit|loc\.\s*cit|pp?\.\s*\d|cf\.|eds?\.|vol\.|no\.\s*\d|\(\d{4}\)|\d{4}\)|university press|press,|journal|doi:|https?:\/\/|retrieved|accessed)/i;
  // Once the article proper is over, sections like these only ever hold lists, links and notes.
  const TERMINAL = /^(see also|references?|external links|further reading|notes|footnotes|endnotes|bibliography|sources|citations|works cited|related( articles| posts| stories| content| reading)?|comments|discussion|more from .*|recommended( for you)?|you may also like|read next|share this.*|about the author|tags|trending( now)?|most popular|newsletter|subscribe.*)$/i;
  const JUNK_HEADING = /related|comments|share|more from|recommended|subscribe|newsletter|tags|popular|trending|sponsored|advertis|you may also|also read|further reading|most read|latest|sign up|footnotes|notes|about the author|author bio/i;

  // Superscript note markers and screen-reader-only text would leak into innerText; hide them while we read.
  for (const sup of document.querySelectorAll('sup, a[role="doc-noteref"], .footnote-ref, .footnote-reference, .reference, .citation-ref'))
    if (/^\[?[\d*†‡§¶a-z]{1,4}\]?$/i.test((sup.textContent || '').trim())) sup.setAttribute('data-narrate-hide', '');
  const style = document.createElement('style');
  style.textContent = '[data-narrate-hide], [class~="sr-only"], [class~="visually-hidden"], [class~="screen-reader-text"], [class~="screen-reader-only"] { display: none !important }';
  document.head.appendChild(style);
  try {
  const hint = el => ((el.className && typeof el.className === 'string' ? el.className : '') + ' ' + (el.id || '')).trim();
  const text = el => (el.innerText || '').replace(/\u00a0/g, ' ').trim();
  const words = s => s.split(/\s+/).filter(Boolean).length;
  const linkDensity = el => { const t = text(el).length; if (!t) return 0; let l = 0; for (const a of el.querySelectorAll('a')) l += text(a).length; return l / t; };
  const unlikelyCache = new WeakMap();
  const unlikely = el => {   // is this element (or an ancestor) obviously page furniture?
    if (!el || el === document.body || el === document.documentElement) return false;
    if (unlikelyCache.has(el)) return unlikelyCache.get(el);
    const h = hint(el), tag = el.tagName;
    let bad = tag === 'NAV' || tag === 'ASIDE' || tag === 'FOOTER' || SKIP.has(tag) || (UNLIKELY.test(h) && !MAYBE.test(h)) || el.getAttribute('role') === 'navigation' || el.getAttribute('role') === 'complementary';
    bad = bad || unlikely(el.parentElement);
    unlikelyCache.set(el, bad);
    return bad;
  };
  const classWeight = el => { const h = hint(el); let w = 0; if (NEGATIVE.test(h)) w -= 25; if (POSITIVE.test(h)) w += 25; return w; };
  const initScore = el => {
    switch (el.tagName) {
      case 'DIV': case 'ARTICLE': case 'MAIN': case 'SECTION': return 5;
      case 'PRE': case 'TD': case 'BLOCKQUOTE': return 3;
      case 'ADDRESS': case 'OL': case 'UL': case 'DL': case 'DD': case 'DT': case 'LI': case 'FORM': return -3;
      case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': case 'TH': return -5;
      default: return 0;
    }
  };

  // 1. Score: every paragraph-like block votes for its parent and grandparent.
  const scores = new Map();
  const bump = (el, s) => { if (!el || el === document.documentElement) return; if (!scores.has(el)) scores.set(el, initScore(el) + classWeight(el)); scores.set(el, scores.get(el) + s); };
  for (const p of document.querySelectorAll('p, pre, td, blockquote, li, div, dd')) {
    if (p.tagName === 'DIV' && p.querySelector(BLOCK_SEL)) continue;   // only leaf divs count as paragraphs
    if (unlikely(p)) continue;
    const t = text(p);
    if (t.length < 25) continue;
    const s = 1 + (t.split(',').length - 1) + Math.min(Math.floor(t.length / 100), 3);
    // Sites like the BBC wrap every paragraph in several layout divs, so the vote has to travel
    // a few levels up (decaying) before it reaches the container the paragraphs actually share.
    let anc = p.parentElement;
    for (let level = 0; anc && anc !== document.body && level < 5; level++, anc = anc.parentElement)
      bump(anc, s / (level === 0 ? 1 : level === 1 ? 2 : level * 3));
  }
  let top = null, topScore = -1;
  for (const [el, s] of scores) {
    const final = s * (1 - linkDensity(el));
    scores.set(el, final);
    if (final > topScore) { top = el; topScore = final; }
  }
  if (!top) return null;
  // A container split into several sibling blocks: climb while the parent holds most of the score.
  let parent = top.parentElement, last = topScore;
  while (parent && parent !== document.body) {
    const ps = scores.get(parent) || 0;
    if (ps < last / 3) break;
    if (ps > last) { top = parent; topScore = ps; }
    last = ps;
    parent = parent.parentElement;
  }

  // 2. Collect the candidate plus siblings that look like continuation of the article.
  const threshold = Math.max(10, topScore * 0.2);
  const roots = [];
  for (const sib of (top.parentElement || top).children) {
    if (sib === top) { roots.push(sib); continue; }
    if (unlikely(sib)) continue;
    let ok = false;
    const s = (scores.get(sib) || 0) + (hint(sib) && hint(top) && hint(sib) === hint(top) ? topScore * 0.2 : 0);
    if (s >= threshold) ok = true;
    else if (sib.tagName === 'P') { const t = text(sib), ld = linkDensity(sib); ok = (t.length > 80 && ld < 0.25) || (t.length <= 80 && ld === 0 && /\.( |$)/.test(t)); }
    if (ok) roots.push(sib);
  }
  if (!roots.length) roots.push(top);

  // 3. Title and byline.
  const clean = s => (s || '').replace(/\s+/g, ' ').trim();
  const meta = n => { const m = document.querySelector(`meta[property="${n}"], meta[name="${n}"]`); return m ? clean(m.content) : ''; };
  let title = meta('og:title') || meta('twitter:title');
  const h1 = top.querySelector('h1') || document.querySelector('h1');
  if (!title || (h1 && clean(text(h1)) && title.includes(clean(text(h1))))) title = clean(h1 ? text(h1) : '') || title;
  if (!title) title = clean(document.title);
  let byline = meta('author') || meta('article:author') || meta('dc.creator') || '';
  if (!byline) { const b = document.querySelector('[rel~="author"], .byline, .author-name, .author, [itemprop="author"]'); if (b) byline = clean(text(b)); }
  byline = byline.replace(/^by\s+/i, '');
  if (byline.length > 80 || /^https?:/.test(byline)) byline = '';

  // 4. Emit paragraphs in reading order.
  const out = [];
  let total = 0, stopped = false;
  const push = (raw, heading) => {
    for (const piece of raw.split(/\n\s*\n/)) {
      if (stopped) return;
      const t = clean(piece);
      if (!t) continue;
      const w = words(t);
      if (heading && TERMINAL.test(t) && total >= 300) { stopped = true; return; }
      if (heading) { if (w < 1 || JUNK_HEADING.test(t) || w > 30) continue; }
      else if (w < 3 && !/[.!?]$/.test(t)) continue;
      if (JUNK.test(t)) continue;
      if (/[›»>|]/.test(t) && w <= 12 && !/[.!?]$/.test(t)) continue;   // breadcrumbs
      if (out.length && out[out.length - 1].text === t) continue;
      out.push({ text: t, heading: !!heading });
      total += w;
    }
  };
  const inlineText = el => (SKIP.has(el.tagName) ? '' : text(el));
  const walk = el => {
    if (el.nodeType !== 1) return;
    const tag = el.tagName;
    if (SKIP.has(tag) || tag === 'HR') return;
    if (el !== top && !roots.includes(el) && unlikely(el)) return;
    if (el.hidden || getComputedStyle(el).display === 'none') return;
    if (tag === 'OL' || tag === 'UL') {   // endnotes / bibliographies: a list that is mostly citations
      const items = [...el.children].filter(c => c.tagName === 'LI');
      if (items.length >= 3 && items.filter(li => CITATION.test(text(li))).length >= 0.6 * items.length) return;
    }
    const heading = /^H[1-6]$/.test(tag);
    if (heading || tag === 'P' || tag === 'PRE' || tag === 'LI' || tag === 'DD' || tag === 'DT' || !el.querySelector(BLOCK_SEL)) {
      // Leaf block. Lists inside an <li> are walked instead so nested items keep their order.
      if (tag === 'LI' && el.querySelector('ul, ol, p')) { walkChildren(el); return; }
      const t = text(el);
      if (!t) return;
      if (!heading && linkDensity(el) > 0.5 && t.length < 200) return;   // link lists, share rows, "read next"
      if (heading && (el.closest('a') || linkDensity(el) > 0.5)) return;  // a linked heading is a teaser for another page
      push(t, heading);
      return;
    }
    walkChildren(el);
  };
  const walkChildren = el => {
    let run = '';
    const flush = () => { if (run.trim()) push(run); run = ''; };
    for (const c of el.childNodes) {
      if (c.nodeType === 3) run += c.textContent;
      else if (c.nodeType !== 1) continue;
      else if (c.tagName === 'BR') run += '\n';
      else if (!BLOCKS.has(c.tagName) && !c.querySelector(BLOCK_SEL)) run += (getComputedStyle(c).display === 'none' ? '' : inlineText(c)) + ' ';   // inline run: text <em>and</em> links
      else { flush(); walk(c); }
    }
    flush();
  };
  for (const r of roots) walk(r);

  // Drop a leading heading that just repeats the title, then any trailing junk-ish headings.
  if (out.length && out[0].heading && (title.includes(out[0].text) || out[0].text.includes(title))) out.shift();
  // Dates, bylines and section labels sit above the first real paragraph as short unpunctuated lines.
  const firstBody = out.findIndex(p => !p.heading && words(p.text) >= 15);
  if (firstBody > 0) for (let i = firstBody - 1; i >= 0; i--) if (!out[i].heading && words(out[i].text) < 8 && !/[.!?"”]$/.test(out[i].text)) out.splice(i, 1);
  while (out.length && out[out.length - 1].heading) out.pop();
  total = out.reduce((n, p) => n + words(p.text), 0);
  return { title, byline, paragraphs: out.map(p => p.text), headings: out.map(p => p.heading), words: total, url: location.href };
  } finally {
    style.remove();
    for (const e of document.querySelectorAll('[data-narrate-hide]')) e.removeAttribute('data-narrate-hide');
  }
})()
"""#
}
