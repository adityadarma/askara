import Foundation

/// Script that pulls the readable text out of the current page. It runs in WebKit's isolated
/// `.defaultClient` world, so the page's own scripts can't replace its helpers. The result is only a
/// plain dictionary of text and image addresses; `ReaderArticle` validates and limits it before anything
/// is shown.
enum ReaderMode {
    static let extractionScript = """
    (() => {
      try {
        const SKIP = 'nav,aside,footer,form,script,style,noscript,button,select,iframe,svg,canvas,dialog,'
          + '[hidden],[aria-hidden="true"],[role="navigation"],[role="banner"],[role="complementary"],'
          + '[role="contentinfo"],[role="search"]';
        const NOISE = /(^|[\\s_-])(comment|comments|sidebar|footer|nav|navbar|menu|share|sharing|social|promo|advert|ads|related|recommend|newsletter|subscribe|cookie|breadcrumb|toc)($|[\\s_-])/i;
        const text = (el) => (el.textContent || '').replace(/\\s+/g, ' ').trim();
        const visible = (el) => {
          const style = getComputedStyle(el);
          return style.display !== 'none' && style.visibility !== 'hidden';
        };
        const noisy = (el, root) => {
          for (let n = el; n && n !== root; n = n.parentElement) {
            if (n.matches && n.matches(SKIP)) return true;
            const label = (n.id || '') + ' ' + (typeof n.className === 'string' ? n.className : '');
            if (NOISE.test(label)) return true;
          }
          return false;
        };

        // Container: an <article>/<main> with real text, otherwise the block holding the most paragraph text.
        const scores = new Map();
        let longParagraphs = 0;
        for (const p of document.querySelectorAll('p')) {
          const length = text(p).length;
          if (length < 60 || p.closest(SKIP)) continue;
          longParagraphs++;
          const weight = Math.min(length, 400);
          const parent = p.parentElement;
          if (!parent) continue;
          scores.set(parent, (scores.get(parent) || 0) + weight);
          const grand = parent.parentElement;
          if (grand) scores.set(grand, (scores.get(grand) || 0) + weight / 2);
        }
        let best = null, bestScore = 0;
        for (const [el, score] of scores) if (score > bestScore) { best = el; bestScore = score; }
        const semantic = document.querySelector('article, [itemprop="articleBody"], main, [role="main"]');
        const semanticParagraphs = semantic
          ? Array.from(semantic.querySelectorAll('p')).filter((p) => text(p).length >= 60).length : 0;
        const root = (semantic && semanticParagraphs >= 3) ? semantic : (best || semantic || document.body);
        if (!root) return null;

        const blocks = [];
        for (const el of root.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,img')) {
          if (blocks.length >= 3000) break;
          if (noisy(el, root) || !visible(el)) continue;
          const tag = el.tagName.toLowerCase();
          if (tag === 'img') {
            const width = el.naturalWidth || parseInt(el.getAttribute('width') || '0', 10);
            if (width > 0 && width < 120) continue;
            const source = el.currentSrc || el.getAttribute('src') || el.getAttribute('data-src') || '';
            let absolute;
            try { absolute = new URL(source, document.baseURI).href; } catch (_) { continue; }
            blocks.push({ t: 'img', src: absolute, text: el.getAttribute('alt') || '' });
            continue;
          }
          if (tag !== 'pre' && el.closest('pre')) continue;
          if ((tag === 'p' || tag === 'li') && el.parentElement && el.parentElement.closest('blockquote')) continue;
          if (tag === 'p' && el.closest('li')) continue;
          if (tag === 'li' && el.querySelector('li')) continue;
          if (tag === 'blockquote' && el.querySelector('blockquote')) continue;
          if (tag === 'pre') { blocks.push({ t: 'pre', text: el.textContent || '' }); continue; }
          const body = text(el);
          if (!body) continue;
          if (tag === 'p') blocks.push({ t: 'p', text: body });
          else if (tag === 'li') blocks.push({ t: 'li', text: body });
          else if (tag === 'blockquote') blocks.push({ t: 'q', text: body });
          else blocks.push({ t: 'h', level: parseInt(tag.slice(1), 10), text: body });
        }

        const meta = (selector) => {
          const node = document.querySelector(selector);
          return node ? (node.content || node.textContent || '').replace(/\\s+/g, ' ').trim() : '';
        };
        const heading = document.querySelector('h1');
        return {
          title: meta('meta[property="og:title"]') || document.title || (heading ? text(heading) : ''),
          byline: meta('meta[name="author"]') || meta('[rel="author"]') || meta('[itemprop="author"]'),
          siteName: meta('meta[property="og:site_name"]') || location.hostname,
          blocks: blocks,
        };
      } catch (_) {
        return null;
      }
    })();
    """
}
