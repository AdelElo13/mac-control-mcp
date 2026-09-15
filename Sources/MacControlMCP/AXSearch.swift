import Foundation

// v0.10 C5: pure search seam keeps ranking independent of live AX handles.
enum AXSearch {
    struct Node {
        let attrs: AXAttributeBatch.Values
        let parent: Int?
    }
    struct Hit {
        let index: Int
        let field: String
        let kind: String
        let reason: String
        var score: [Double] = []
    }
    struct Query: Sendable {
        var role: String? = nil
        var title: String? = nil
        var value: String? = nil
        var exact = false
        var semantic: String? = nil
    }

    struct WalkEntry<Element> {
        let element: Element
        let attrs: AXAttributeBatch.Values
        let path: [AXPathComponent]
        let depth: Int
    }

    struct WalkResult<Element> {
        let entries: [WalkEntry<Element>]
        let hits: [Hit]
        let stoppedEarly: Bool
        let truncated: Bool
    }

    // v0.10 C5: the same traversal runs with live AX handles and synthetic
    // handles, so regression tests count actual reads rather than model cost.
    static func walk<Element: Hashable>(
        root: Element, rootPath: [AXPathComponent] = [], maxDepth: Int,
        nodeCap: Int = 5000, deadline: Date, query: Query, limit: Int,
        regex: Bool = false,
        eligible: (AXAttributeBatch.Values) -> Bool = { _ in true },
        read: (Element, Bool, Bool) -> (attrs: AXAttributeBatch.Values, children: [Element])
    ) -> WalkResult<Element> {
        var visited = Set<Element>()
        var nodes: [Node] = []
        var entries: [WalkEntry<Element>] = []
        var truncated = false
        var stoppedEarly = false
        var bestCount = 0
        var top: [Hit] = []
        let canStopEarly = query.semantic == nil && !regex
        guard limit > 0 else { return WalkResult(entries: [], hits: [], stoppedEarly: false, truncated: false) }
        func recurse(_ element: Element, depth: Int, parent: Int?, parentPath: [AXPathComponent], ordinal: Int, insideMenu: Bool) {
            guard !stoppedEarly, !truncated, depth <= maxDepth else { return }
            guard entries.count < nodeCap, Date() < deadline else { truncated = true; return }
            guard visited.insert(element).inserted else { return }
            let (attrs, children) = read(element, depth < maxDepth, parentPath.contains { $0.role == "AXWebArea" })
            let path = depth == 0 ? parentPath : AXPath.appending(parentPath, role: attrs.role, index: ordinal, identifier: attrs.identifier, title: attrs.title, subrole: attrs.subrole)
            let index = nodes.count
            nodes.append(Node(attrs: attrs, parent: parent))
            entries.append(WalkEntry(element: element, attrs: attrs, path: path, depth: depth))
            let menu = insideMenu || menuRoles.contains(attrs.role ?? "")
            // v0.10 C5 regression: retain only the ranked top-limit while
            // looking for exact hits. Prefix/substring and semantic queries
            // still need later nodes; menus cannot trigger a premature stop.
            if canStopEarly, eligible(attrs), let hit = plainHit(attrs, index: index, menu: menu, query: query) {
                let insertion = top.firstIndex { precedes(hit, $0) } ?? top.count
                if insertion < limit {
                    top.insert(hit, at: insertion)
                    if top.count > limit { top.removeLast() }
                }
                if hit.kind == "exact", !menu {
                    bestCount += 1
                    stoppedEarly = bestCount >= limit
                }
            }
            for (ordinal, child) in children.enumerated() {
                if stoppedEarly || truncated { break }
                recurse(child, depth: depth + 1, parent: index, parentPath: path, ordinal: ordinal, insideMenu: menu)
            }
        }
        recurse(root, depth: 0, parent: nil, parentPath: rootPath, ordinal: 0,
                insideMenu: rootPath.contains { menuRoles.contains($0.role) })
        let hits = canStopEarly ? top : search(nodes, role: query.role, title: query.title, value: query.value, exact: query.exact, semantic: query.semantic, regex: regex, eligible: eligible)
        return WalkResult(entries: entries, hits: Array(hits.prefix(limit)), stoppedEarly: stoppedEarly, truncated: truncated)
    }

    private struct LabelMatch {
        let field: String
        let quality: Int
    }

    static func validSemantic(_ target: String) -> Bool {
        if ["search_field", "back", "forward", "close", "ok", "cancel"].contains(target) { return true }
        return ["sidebar_item", "tab", "link"].contains { name in
            target.hasPrefix(name + "(") && target.hasSuffix(")") && target.count > name.count + 2
        }
    }

    static func roleMatches(_ filter: String?, _ role: String?) -> Bool {
        guard let filter, !filter.isEmpty else { return true }
        let normalized = filter.lowercased().hasPrefix("ax") ? filter : "AX" + filter
        return normalized.caseInsensitiveCompare(role ?? "AXUnknown") == .orderedSame
    }

    private static func labels(_ attrs: AXAttributeBatch.Values) -> [(String, String)] {
        [("title", attrs.rawTitle), ("description", attrs.description),
         ("value", attrs.value), ("identifier", attrs.identifier)].compactMap { field, value in
            value.map { (field, $0) }
        }
    }

    private static func match(_ labels: [(String, String)], pattern: String?, exact: Bool, expression: NSRegularExpression? = nil) -> LabelMatch? {
        guard let pattern, !pattern.isEmpty else { return LabelMatch(field: "role", quality: 0) }
        return labels.compactMap { field, text -> LabelMatch? in
            let range: NSRange
            if let expression {
                guard let found = expression.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else { return nil }
                range = found.range
            } else {
                let found = (text as NSString).range(of: pattern, options: .caseInsensitive)
                guard found.location != NSNotFound else { return nil }
                range = found
            }
            let quality = range.location == 0 ? (range.length == text.utf16.count ? 0 : 1) : 2
            guard !exact || quality == 0 else { return nil }
            return LabelMatch(field: field, quality: quality)
        }.min { $0.quality < $1.quality }
    }

    private static let menuRoles: Set<String> = ["AXMenuBar", "AXMenu", "AXMenuItem", "AXMenuBarItem"]

    private static func precedes(_ lhs: Hit, _ rhs: Hit) -> Bool {
        lhs.score.lexicographicallyPrecedes(rhs.score)
    }

    private static func rankedHit(_ attrs: AXAttributeBatch.Values, index: Int, field: String, quality: Int,
                                  menu: Bool, preference: Int = 0, semantic: Bool = false) -> Hit {
        let interactive = AXPayload.isInteractive(role: attrs.role) || (semantic && ["AXRow", "AXCell", "AXTab"].contains(attrs.role ?? ""))
        let container = ["AXGroup", "AXWindow", "AXApplication", "AXScrollArea", "AXSplitGroup"].contains(attrs.role ?? "")
        let area = attrs.size.map { max(0, Double($0.width * $0.height)) } ?? Double.greatestFiniteMagnitude
        let kind = ["exact", "prefix", "substring"][quality]
        let reason = "\(kind); \(menu ? "menu" : "window content"); \(interactive ? "interactive" : (container ? "container" : "content")); smaller area first"
        return Hit(index: index, field: field, kind: kind, reason: reason,
                   score: [Double(quality), menu ? 1 : 0, Double(preference), interactive ? 0 : 1, container ? 1 : 0, area, Double(index)])
    }

    private static func plainHit(_ attrs: AXAttributeBatch.Values, index: Int, menu: Bool, query: Query) -> Hit? {
        guard roleMatches(query.role, attrs.role),
              let title = match(labels(attrs), pattern: query.title, exact: query.exact),
              let value = match([("value", attrs.value ?? "")], pattern: query.value, exact: query.exact) else { return nil }
        var chosen = query.title?.isEmpty == false ? title : (query.value?.isEmpty == false ? value : LabelMatch(field: "role", quality: 0))
        // v0.10 C5: every supplied label filter must be exact before the
        // traversal may stop; an exact title cannot hide a partial value.
        if query.value?.isEmpty == false, value.quality > chosen.quality { chosen = value }
        return rankedHit(attrs, index: index, field: chosen.field, quality: chosen.quality, menu: menu)
    }

    private struct AliasPattern {
        let name: String
        let expression: NSRegularExpression
    }

    private struct AliasRules {
        let prefixes: NSRegularExpression
        let patterns: [AliasPattern]

        init(_ names: [String]) {
            patterns = names.map { name in
                let escaped = NSRegularExpression.escapedPattern(for: name)
                return AliasPattern(name: name, expression: try! NSRegularExpression(
                    pattern: "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])", options: .caseInsensitive))
            }
            // v0.10 C5: a first word must already occur in the raw label,
            // even when camelCase splitting is needed for the whole alias.
            let stems = names.map { NSRegularExpression.escapedPattern(for: String($0.split(separator: " ")[0])) }
            prefixes = try! NSRegularExpression(pattern: stems.joined(separator: "|"), options: .caseInsensitive)
        }
    }

    // v0.10 C5: these constant patterns are shared across all nodes/calls.
    // Compiling them inside alias() added seconds to Finder file-row scans.
    private static let aliasRules: [String: AliasRules] = [
        "search_field": AliasRules(["search", "zoeken", "zoek", "address and search", "adres en zoek", "omnibox"]),
        "back": AliasRules(["back", "go back", "terug", "vorige"]),
        "forward": AliasRules(["forward", "go forward", "vooruit", "volgende"]),
        "close": AliasRules(["close", "sluiten"]),
        "ok": AliasRules(["ok", "okay"]),
        "cancel": AliasRules(["cancel", "annuleren"])
    ]
    private static let camelCaseSplitter = try! NSRegularExpression(pattern: "([a-z0-9])([A-Z])")
    private static let acronymSplitter = try! NSRegularExpression(pattern: "([A-Z])([A-Z][a-z])")

    private static func alias(_ labels: [(String, String)], _ rules: AliasRules) -> LabelMatch? {
        let normalized: [(String, String)] = labels.compactMap { field, value in
            let range = NSRange(location: 0, length: value.utf16.count)
            // v0.10 C5: reject ordinary file names/identifiers before either
            // normalization or the more expensive token-boundary patterns.
            guard rules.prefixes.firstMatch(in: value, range: range) != nil else { return nil }
            guard field.hasSuffix("identifier") || field == "subrole" else { return (field, value) }
            let camel = camelCaseSplitter.stringByReplacingMatches(in: value, range: range, withTemplate: "$1 $2")
            let text = acronymSplitter.stringByReplacingMatches(in: camel, range: NSRange(location: 0, length: camel.utf16.count), withTemplate: "$1 $2")
            return (field, text)
        }
        guard !normalized.isEmpty else { return nil }
        var best: LabelMatch?
        for pattern in rules.patterns {
            if let hit = match(normalized, pattern: pattern.name, exact: false, expression: pattern.expression),
               best == nil || hit.quality < best!.quality {
                best = hit
                if hit.quality == 0 { break }
            }
        }
        return best
    }

    static func search(_ nodes: [Node], role: String? = nil, title: String? = nil, value: String? = nil, exact: Bool = false, semantic: String? = nil, regex: Bool = false, eligible: (AXAttributeBatch.Values) -> Bool = { _ in true }) -> [Hit] {
        func expression(_ pattern: String?) -> NSRegularExpression? {
            guard regex, let pattern, !pattern.isEmpty else { return nil }
            return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        }
        let roleRegex = expression(role), titleRegex = expression(title), valueRegex = expression(value)
        var children = [[Int]](repeating: [], count: nodes.count)
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent, nodes.indices.contains(parent) { children[parent].append(index) }
        }
        func ancestors(_ index: Int) -> [Int] {
            var result: [Int] = [], current = nodes[index].parent
            while let parent = current, nodes.indices.contains(parent), result.count < nodes.count {
                result.append(parent)
                current = nodes[parent].parent
            }
            return result
        }
        func descendants(_ index: Int) -> [(String, String)] {
            var result: [(String, String)] = []
            var pending = children[index], visited = Set<Int>()
            while let child = pending.popLast(), visited.count < 5000 {
                guard visited.insert(child).inserted else { continue }
                if nodes[child].attrs.role == "AXStaticText" {
                    result += labels(nodes[child].attrs).map { ("descendant." + $0.0, $0.1) }
                }
                pending += children[child]
            }
            return result
        }
        func semanticMatch(_ target: String, index: Int, parents: [Int]) -> (LabelMatch, Int)? {
            let attrs = nodes[index].attrs, role = attrs.role ?? ""
            let own = labels(attrs)
            switch target {
            case "search_field":
                let rules = aliasRules["search_field"]!
                if ["AXTextField", "AXComboBox", "AXSearchField"].contains(role) {
                    if let label = alias(own + [("subrole", attrs.subrole ?? "")], rules) { return (label, 0) }
                    // v0.10 C5: Settings publishes an untitled field beside its Search button.
                    if attrs.rawTitle == nil, attrs.description == nil, attrs.identifier == nil,
                       let parent = nodes[index].parent {
                        let siblingLabels = children[parent].filter { nodes[$0].attrs.role == "AXButton" }
                            .flatMap { labels(nodes[$0].attrs).map { ("sibling." + $0.0, $0.1) } }
                        if let label = alias(siblingLabels, rules) { return (label, 0) }
                    }
                }
                // v0.10 C5: Finder exposes only the search activation button until opened.
                if role == "AXButton", let label = alias(own, rules) { return (label, 1) }
            case "back", "forward", "close", "ok", "cancel":
                guard role == "AXButton" else { return nil }
                if target == "close", attrs.subrole == "AXCloseButton" { return (LabelMatch(field: "subrole", quality: 0), 0) }
                if let label = alias(own, aliasRules[target]!) { return (label, 0) }
            default:
                guard validSemantic(target), let opening = target.firstIndex(of: "(") else { return nil }
                let name = String(target[..<opening])
                let text = String(target[target.index(after: opening)..<target.index(before: target.endIndex)])
                let ancestorRoles = parents.compactMap { nodes[$0].attrs.role }
                switch name {
                case "sidebar_item":
                    guard ["AXRow", "AXCell"].contains(role), ancestorRoles.contains("AXOutline") || parents.contains(where: { nodes[$0].attrs.subrole == "AXSourceList" }) else { return nil }
                    if let label = match(own + descendants(index), pattern: text, exact: exact) { return (label, role == "AXCell" ? 0 : 1) }
                case "tab":
                    guard role == "AXTab" || (["AXRadioButton", "AXButton"].contains(role) && ancestorRoles.contains("AXTabGroup")) else { return nil }
                    if let label = match(own, pattern: text, exact: exact) { return (label, 0) }
                case "link":
                    guard role == "AXLink" else { return nil }
                    if let label = match(own + descendants(index), pattern: text, exact: exact) { return (label, 0) }
                default: break
                }
            }
            return nil
        }
        var results: [Hit] = []
        for (index, node) in nodes.enumerated() {
            let attrs = node.attrs
            guard eligible(attrs) else { continue }
            let parents = ancestors(index)
            let menu = ([index] + parents).contains { menuRoles.contains(nodes[$0].attrs.role ?? "") }
            if semantic == nil, !regex {
                if let hit = plainHit(attrs, index: index, menu: menu,
                                      query: Query(role: role, title: title, value: value, exact: exact)) { results.append(hit) }
                continue
            }
            var roleMatch = LabelMatch(field: "role", quality: 0)
            if regex {
                guard let matched = match([("role", attrs.role ?? "AXUnknown")], pattern: role, exact: false, expression: roleRegex) else { continue }
                roleMatch = matched
            } else if !roleMatches(role, attrs.role) { continue }
            guard let label = match(labels(attrs), pattern: title, exact: exact, expression: titleRegex),
                  let valueMatch = match([("value", attrs.value ?? "")], pattern: value, exact: exact, expression: valueRegex) else { continue }
            var chosen = (title?.isEmpty == false) ? label : ((value?.isEmpty == false) ? valueMatch : roleMatch)
            var preference = 0
            if let semantic {
                guard let (semanticLabel, priority) = semanticMatch(semantic, index: index, parents: parents) else { continue }
                chosen = semanticLabel
                preference = priority
            }
            results.append(rankedHit(attrs, index: index, field: chosen.field, quality: chosen.quality,
                                     menu: menu, preference: preference, semantic: semantic != nil))
        }
        // v0.10 C5: Finder's activation button is a fallback only. An exact
        // "Search" button must not displace a real field with a longer label.
        if semantic == "search_field", results.contains(where: { nodes[$0.index].attrs.role != "AXButton" }) {
            results.removeAll { nodes[$0.index].attrs.role == "AXButton" }
        }
        return results.sorted(by: precedes)
    }
}
