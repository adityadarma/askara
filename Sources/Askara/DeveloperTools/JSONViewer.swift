import WebKit

/// Shows JSON responses as a collapsible tree with Raw and Copy, like Firefox's JSON viewer.
///
/// Runs in its own content world: the page can't reach it, and it keeps working on sites where
/// JavaScript is blocked. Values are inserted with `textContent` only, never as HTML, so a
/// response can't inject markup or script.
enum JSONViewer {
    /// Larger documents stay plain text: building the tree would freeze the page.
    static let maxBytes = 8 * 1024 * 1024

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
    }

    static let source = #"""
    (() => {
      const type = (document.contentType || "").toLowerCase();
      if (!(type === "application/json" || type === "text/json" || /\+json$/.test(type))) return;
      const body = document.body;
      if (!body || body.children.length !== 1 || body.firstElementChild.tagName !== "PRE") return;
      const raw = body.firstElementChild.textContent;
      if (raw.length > \#(maxBytes)) return;
      let data;
      try { data = JSON.parse(raw); } catch (e) { return; }

      const el = (tag, cls, text) => {
        const node = document.createElement(tag);
        if (cls) node.className = cls;
        if (text !== undefined) node.textContent = text;
        return node;
      };
      const isContainer = v => v !== null && typeof v === "object";
      const scalar = v => {
        if (v === null) return el("span", "askj-null", "null");
        if (typeof v === "string") return el("span", "askj-string", JSON.stringify(v));
        if (typeof v === "number") return el("span", "askj-number", String(v));
        if (typeof v === "boolean") return el("span", "askj-bool", String(v));
        return el("span", "", String(v));
      };
      const render = (value, key, depth) => {
        const row = el("div", "askj-row");
        const label = () => {
          if (key === undefined) return;
          row.append(el("span", "askj-key", typeof key === "number" ? String(key) : JSON.stringify(key)), el("span", "askj-punct", ": "));
        };
        if (!isContainer(value)) { label(); row.append(scalar(value)); return row; }
        const isArray = Array.isArray(value);
        const entries = isArray ? value.map((v, i) => [i, v]) : Object.entries(value);
        const details = el("details");
        details.open = depth < 3;
        const summary = el("summary");
        const keep = row;
        details.append(summary);
        if (key !== undefined) {
          summary.append(el("span", "askj-key", typeof key === "number" ? String(key) : JSON.stringify(key)), el("span", "askj-punct", ": "));
        }
        summary.append(el("span", "askj-punct", isArray ? "[" : "{"),
                       el("span", "askj-count", isArray ? `${entries.length} items` : `${entries.length} keys`),
                       el("span", "askj-punct", isArray ? "]" : "}"));
        const children = el("div", "askj-children");
        for (const [k, v] of entries) children.append(render(v, k, depth + 1));
        details.append(children);
        keep.append(details);
        return keep;
      };

      const pretty = JSON.stringify(data, null, 2);
      const style = el("style", "", `
        :root { color-scheme: light dark; }
        body { margin: 0; font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; }
        .askj-bar { position: sticky; top: 0; display: flex; gap: 6px; padding: 6px 10px; background: Canvas;
                    border-bottom: 1px solid color-mix(in srgb, CanvasText 15%, transparent); font-family: -apple-system, sans-serif; }
        .askj-bar button { font: 12px -apple-system, sans-serif; padding: 2px 10px; }
        .askj-bar button[aria-pressed="true"] { font-weight: 600; }
        .askj-view { padding: 8px 12px; }
        .askj-children { padding-left: 18px; border-left: 1px solid color-mix(in srgb, CanvasText 12%, transparent); margin-left: 4px; }
        .askj-row { line-height: 1.6; white-space: pre-wrap; word-break: break-word; }
        summary { cursor: default; list-style-position: outside; }
        .askj-key { color: #881391; } .askj-string { color: #1a1aa6; } .askj-number { color: #1c00cf; }
        .askj-bool, .askj-null { color: #aa0d91; } .askj-punct { opacity: 0.6; }
        .askj-count { opacity: 0.5; margin: 0 4px; font-style: italic; }
        @media (prefers-color-scheme: dark) {
          .askj-key { color: #e36eec; } .askj-string { color: #f29766; } .askj-number { color: #9980ff; }
          .askj-bool, .askj-null { color: #ff7ab2; }
        }
        pre.askj-raw { margin: 0; padding: 8px 12px; white-space: pre-wrap; word-break: break-word; }
      `);
      const bar = el("div", "askj-bar");
      bar.setAttribute("role", "toolbar");
      bar.setAttribute("aria-label", "JSON");
      const tree = el("div", "askj-view");
      tree.append(render(data, undefined, 0));
      const rawView = el("pre", "askj-raw", pretty);
      rawView.hidden = true;
      const button = (title, action) => {
        const b = el("button", "", title);
        b.type = "button";
        b.addEventListener("click", action);
        bar.append(b);
        return b;
      };
      const treeButton = button("Tree", () => show(false));
      const rawButton = button("Raw", () => show(true));
      button("Expand All", () => tree.querySelectorAll("details").forEach(d => d.open = true));
      button("Collapse All", () => tree.querySelectorAll("details").forEach(d => d.open = false));
      const copyButton = button("Copy", async () => {
        try { await navigator.clipboard.writeText(pretty); copyButton.textContent = "Copied"; }
        catch (e) { copyButton.textContent = "Copy failed"; }
        setTimeout(() => copyButton.textContent = "Copy", 1500);
      });
      const show = asRaw => {
        tree.hidden = asRaw; rawView.hidden = !asRaw;
        treeButton.setAttribute("aria-pressed", String(!asRaw));
        rawButton.setAttribute("aria-pressed", String(asRaw));
      };
      show(false);
      body.replaceChildren(bar, tree, rawView);
      document.head.append(style);
      document.documentElement.dataset.askaraJsonViewer = "1";
    })();
    """#
}
