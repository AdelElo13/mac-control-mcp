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

    static func search(_ nodes: [Node], role: String? = nil, title: String? = nil, value: String? = nil, exact: Bool = false, semantic: String? = nil, regex: Bool = false) -> [Hit] {
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
        func alias(_ labels: [(String, String)], _ names: [String]) -> LabelMatch? {
            names.compactMap { match(labels, pattern: $0, exact: false) }.min { $0.quality < $1.quality }
        }
        func semanticMatch(_ target: String, index: Int, parents: [Int]) -> (LabelMatch, Int)? {
            let attrs = nodes[index].attrs, role = attrs.role ?? ""
            let own = labels(attrs)
            switch target {
            case "search_field":
                let names = ["search", "zoeken", "zoek", "address and search", "adres en zoek", "omnibox"]
                if ["AXTextField", "AXComboBox", "AXSearchField"].contains(role) {
                    if let label = alias(own + [("subrole", attrs.subrole ?? "")], names) { return (label, 0) }
                    // v0.10 C5: Settings publishes an untitled field beside its Search button.
                    if let parent = nodes[index].parent {
                        let siblingLabels = children[parent].filter { nodes[$0].attrs.role == "AXButton" }
                            .flatMap { labels(nodes[$0].attrs).map { ("sibling." + $0.0, $0.1) } }
                        if let label = alias(siblingLabels, names) { return (label, 0) }
                    }
                }
                // v0.10 C5: Finder exposes only the search activation button until opened.
                if role == "AXButton", let label = alias(own, names) { return (label, 1) }
            case "back", "forward", "close", "ok", "cancel":
                guard role == "AXButton" else { return nil }
                if target == "close", attrs.subrole == "AXCloseButton" { return (LabelMatch(field: "subrole", quality: 0), 0) }
                let names: [String]
                switch target {
                case "back": names = ["back", "go back", "terug", "vorige"]
                case "forward": names = ["forward", "go forward", "vooruit", "volgende"]
                case "close": names = ["close", "sluiten"]
                case "ok": names = ["ok", "okay"]
                default: names = ["cancel", "annuleren"]
                }
                if let label = alias(own, names) { return (label, 0) }
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
        struct Ranked {
            let hit: Hit
            let score: [Double]
        }
        var results: [Ranked] = []
        for (index, node) in nodes.enumerated() {
            let attrs = node.attrs
            if regex {
                guard match([("role", attrs.role ?? "AXUnknown")], pattern: role, exact: false, expression: roleRegex) != nil else { continue }
            } else if !roleMatches(role, attrs.role) { continue }
            guard let label = match(labels(attrs), pattern: title, exact: exact, expression: titleRegex),
                  let valueMatch = match([("value", attrs.value ?? "")], pattern: value, exact: exact, expression: valueRegex) else { continue }
            let parents = ancestors(index)
            var chosen = (title?.isEmpty == false) ? label : ((value?.isEmpty == false) ? valueMatch : label)
            var preference = 0
            if let semantic {
                guard let (semanticLabel, priority) = semanticMatch(semantic, index: index, parents: parents) else { continue }
                chosen = semanticLabel
                preference = priority
            }
            let menu = ([index] + parents).contains { ["AXMenuBar", "AXMenu", "AXMenuItem", "AXMenuBarItem"].contains(nodes[$0].attrs.role ?? "") }
            let interactive = AXPayload.isInteractive(role: attrs.role) || (semantic != nil && ["AXRow", "AXCell", "AXTab"].contains(attrs.role ?? ""))
            let container = ["AXGroup", "AXWindow", "AXApplication", "AXScrollArea", "AXSplitGroup"].contains(attrs.role ?? "")
            let area = attrs.size.map { max(0, Double($0.width * $0.height)) } ?? Double.greatestFiniteMagnitude
            let kind = ["exact", "prefix", "substring"][chosen.quality]
            let reason = "\(kind); \(menu ? "menu" : "window content"); \(interactive ? "interactive" : (container ? "container" : "content")); smaller area first"
            results.append(Ranked(hit: Hit(index: index, field: chosen.field, kind: kind, reason: reason), score: [Double(chosen.quality), menu ? 1 : 0, Double(preference), interactive ? 0 : 1, container ? 1 : 0, area, Double(index)]))
        }
        return results.sorted { $0.score.lexicographicallyPrecedes($1.score) }.map(\.hit)
    }
}
