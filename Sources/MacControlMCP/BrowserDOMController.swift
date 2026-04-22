import Foundation

/// Web-page DOM-layer introspection — Shadow DOM, iframes, visible text.
/// All three tools go through the existing BrowserController's JS-eval
/// path (`browser_eval_js` on Safari / Chrome).  The scripts below are
/// self-contained + stringified so the JSON payload round-trips cleanly.
///
/// Scope: v0.7.0 ships JS-based DOM walking; cross-origin iframes fail
/// closed with `{ok: false, reason: "cross_origin"}` because the browser
/// same-origin policy blocks our eval into them.  That's the right
/// behaviour for an MCP — we never claim access the web platform itself
/// denies us.
actor BrowserDOMController {

    private let browser: BrowserController

    init(browser: BrowserController) {
        self.browser = browser
    }

    public struct DOMNode: Codable, Sendable {
        public let tag: String
        public let id: String?
        public let classes: [String]
        public let text: String?     // first text-node content, truncated
        public let role: String?     // aria-role
        public let isShadow: Bool    // true when this node is the shadow root or inside one
        public let children: [DOMNode]
    }

    public struct DOMResult: Codable, Sendable {
        public let ok: Bool
        public let browser: String
        public let root: DOMNode?
        public let nodeCount: Int
        public let includeShadow: Bool
        public let error: String?
    }

    public struct VisibleTextResult: Codable, Sendable {
        public let ok: Bool
        public let browser: String
        public let text: String?
        public let charCount: Int
        public let error: String?
    }

    public struct IframesResult: Codable, Sendable {
        public let ok: Bool
        public let browser: String
        public let count: Int
        public let iframes: [IframeInfo]
        public let error: String?
        public struct IframeInfo: Codable, Sendable {
            public let src: String?
            public let sameOrigin: Bool
            public let width: Int?
            public let height: Int?
            public let contentDocSummary: String?  // nil when cross-origin
        }
    }

    // MARK: - Shadow-DOM-aware DOM tree

    private static let domTreeScript = #"""
    (() => {
      const MAX_DEPTH = 12;
      const MAX_TEXT = 200;
      function walk(el, depth, inShadow) {
        if (depth > MAX_DEPTH) return null;
        if (!(el instanceof Element)) return null;
        const obj = {
          tag: el.tagName.toLowerCase(),
          id: el.id || null,
          classes: Array.from(el.classList),
          text: null,
          role: el.getAttribute('role'),
          isShadow: inShadow,
          children: []
        };
        // first text node, trimmed + truncated
        for (const n of el.childNodes) {
          if (n.nodeType === 3 && n.textContent.trim().length) {
            obj.text = n.textContent.trim().slice(0, MAX_TEXT);
            break;
          }
        }
        // regular children
        for (const c of el.children) {
          const cn = walk(c, depth + 1, inShadow);
          if (cn) obj.children.push(cn);
        }
        // shadow root (open only — closed is inaccessible by spec)
        if (el.shadowRoot) {
          for (const c of el.shadowRoot.children) {
            const cn = walk(c, depth + 1, true);
            if (cn) obj.children.push(cn);
          }
        }
        return obj;
      }
      return JSON.stringify(walk(document.body, 0, false));
    })()
    """#

    func domTree(browser browserName: String) async -> DOMResult {
        let b = BrowserController.Browser.detect(browserName)
        let r = await browser.evalJS(browser: b, code: Self.domTreeScript)
        guard r.success, let jsonStr = r.value else {
            return DOMResult(ok: false, browser: browserName, root: nil,
                             nodeCount: 0, includeShadow: true,
                             error: r.error ?? "eval failed")
        }
        guard let data = jsonStr.data(using: .utf8),
              let root = try? JSONDecoder().decode(DOMNode.self, from: data) else {
            return DOMResult(ok: false, browser: browserName, root: nil,
                             nodeCount: 0, includeShadow: true,
                             error: "DOM JSON parse failed")
        }
        return DOMResult(ok: true, browser: browserName, root: root,
                         nodeCount: count(node: root), includeShadow: true, error: nil)
    }

    private func count(node: DOMNode) -> Int {
        1 + node.children.reduce(0) { $0 + count(node: $1) }
    }

    // MARK: - Visible text

    private static let visibleTextScript = #"""
    (() => {
      const out = [];
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      let n;
      while ((n = walker.nextNode())) {
        const p = n.parentElement;
        if (!p) continue;
        const style = window.getComputedStyle(p);
        if (style.display === 'none' || style.visibility === 'hidden') continue;
        const t = n.textContent.trim();
        if (!t) continue;
        out.push(t);
      }
      return out.join('\n');
    })()
    """#

    func visibleText(browser browserName: String) async -> VisibleTextResult {
        let b = BrowserController.Browser.detect(browserName)
        let r = await browser.evalJS(browser: b, code: Self.visibleTextScript)
        guard r.success, let text = r.value else {
            return VisibleTextResult(
                ok: false, browser: browserName, text: nil, charCount: 0,
                error: r.error ?? "eval failed"
            )
        }
        return VisibleTextResult(
            ok: true, browser: browserName, text: text,
            charCount: text.count, error: nil
        )
    }

    // MARK: - Iframes

    private static let iframesScript = #"""
    (() => {
      const out = [];
      const frames = document.querySelectorAll('iframe');
      for (const f of frames) {
        const rect = f.getBoundingClientRect();
        const src = f.src || null;
        let sameOrigin = false;
        let summary = null;
        try {
          // Reading .contentDocument throws SecurityError cross-origin.
          const doc = f.contentDocument;
          if (doc) {
            sameOrigin = true;
            summary = doc.body ? doc.body.innerText.trim().slice(0, 500) : null;
          }
        } catch (e) {
          sameOrigin = false;
        }
        out.push({
          src: src,
          sameOrigin: sameOrigin,
          width: Math.round(rect.width),
          height: Math.round(rect.height),
          contentDocSummary: summary
        });
      }
      return JSON.stringify(out);
    })()
    """#

    func iframes(browser browserName: String) async -> IframesResult {
        let b = BrowserController.Browser.detect(browserName)
        let r = await browser.evalJS(browser: b, code: Self.iframesScript)
        guard r.success, let jsonStr = r.value else {
            return IframesResult(ok: false, browser: browserName, count: 0,
                                 iframes: [], error: r.error ?? "eval failed")
        }
        guard let data = jsonStr.data(using: .utf8),
              let arr = try? JSONDecoder().decode([IframesResult.IframeInfo].self, from: data) else {
            return IframesResult(ok: false, browser: browserName,
                                 count: 0, iframes: [],
                                 error: "iframes JSON parse failed")
        }
        return IframesResult(ok: true, browser: browserName,
                             count: arr.count, iframes: arr, error: nil)
    }
}
