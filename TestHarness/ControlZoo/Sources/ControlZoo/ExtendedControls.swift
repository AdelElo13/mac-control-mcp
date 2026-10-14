import AppKit

// ControlZoo — second column: the AppKit controls the first matrix did not
// cover (radio buttons, segmented control, combo box, date picker, color
// well, tab view, table view, search field, disclosure triangle, progress
// indicator).
//
// Every control has a stable accessibilityIdentifier, and every control
// whose state an agent changes also updates an observable status label
// (`<id>_label`) from its own target/action or delegate. The matrix
// asserts on that label, so a passing check proves the APP saw the change,
// not merely that an AX call returned success.

@MainActor
final class ExtendedControls: NSObject {
    let tableItems: [(name: String, size: String)] = [
        ("Amsterdam", "872k"), ("Rotterdam", "655k"), ("Utrecht", "361k"),
        ("Haarlem", "162k"), ("Leiden", "125k"),
    ]
    private var labels: [String: NSTextField] = [:]
    private(set) var tableView: NSTableView!

    func buildColumn() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12

        stack.addArrangedSubview(header("Extended controls"))
        stack.addArrangedSubview(row("AXRadioButton:", makeRadioGroup(), labelID: "rb_label"))
        stack.addArrangedSubview(row("Segmented:", makeSegmented(id: "seg_one"), labelID: "seg_one_label"))
        stack.addArrangedSubview(row("AXComboBox:", makeComboBox(id: "combo_one"), labelID: "combo_one_label"))
        stack.addArrangedSubview(row("AXSearchField:", makeSearchField(id: "sf_one"), labelID: "sf_one_label"))
        stack.addArrangedSubview(row("Date picker:", makeDatePicker(id: "dp_one"), labelID: "dp_one_label"))
        stack.addArrangedSubview(row("AXColorWell:", makeColorWell(id: "cw_one"), labelID: "cw_one_label"))
        stack.addArrangedSubview(row("Colors panel:", makeClosePanelButton(id: "cw_close_panel"), labelID: nil))
        stack.addArrangedSubview(row("Disclosure:", makeDisclosure(id: "disc_one"), labelID: "disc_one_label"))
        stack.addArrangedSubview(row("AXProgressIndicator:", makeProgress(id: "prog_one"), labelID: nil))
        stack.addArrangedSubview(row("AXTabGroup:", makeTabView(id: "tab_one"), labelID: "tab_one_label", height: 90))
        stack.addArrangedSubview(row("AXTable:", makeTable(id: "table_one"), labelID: "table_one_label", height: 130))
        return stack
    }

    // MARK: - Layout helpers

    private func header(_ text: String) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.font = .boldSystemFont(ofSize: 14)
        tf.setAccessibilityIdentifier("header_extended")
        return tf
    }

    private func row(_ title: String, _ control: NSView, labelID: String?, height: CGFloat = 24) -> NSView {
        let r = NSStackView()
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 10
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12)
        name.widthAnchor.constraint(equalToConstant: 140).isActive = true
        r.addArrangedSubview(name)
        if height != 24 {
            control.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        r.addArrangedSubview(control)
        if let labelID {
            r.addArrangedSubview(statusLabel(labelID))
        }
        return r
    }

    private func statusLabel(_ id: String) -> NSTextField {
        let tf = NSTextField(labelWithString: "unchanged")
        tf.setAccessibilityIdentifier(id)
        tf.font = .systemFont(ofSize: 11)
        tf.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        labels[id] = tf
        return tf
    }

    private func report(_ id: String, _ value: String) {
        labels[id]?.stringValue = value
    }

    // MARK: - Radio buttons (AXRadioButton)

    private func makeRadioGroup() -> NSView {
        let group = NSStackView()
        group.orientation = .horizontal
        group.spacing = 8
        group.setAccessibilityIdentifier("rb_group")
        for (id, title) in [("rb_a", "Option A"), ("rb_b", "Option B"), ("rb_c", "Option C")] {
            let b = NSButton(radioButtonWithTitle: title, target: self, action: #selector(radioChanged(_:)))
            b.setAccessibilityIdentifier(id)
            b.state = id == "rb_a" ? .on : .off
            group.addArrangedSubview(b)
        }
        return group
    }

    @objc private func radioChanged(_ sender: NSButton) {
        // Same superview + same action => AppKit keeps them mutually exclusive.
        report("rb_label", "selected_\(sender.accessibilityIdentifier())")
    }

    // MARK: - Segmented control

    private func makeSegmented(id: String) -> NSSegmentedControl {
        let s = NSSegmentedControl(labels: ["Day", "Week", "Month"], trackingMode: .selectOne,
                                   target: self, action: #selector(segmentChanged(_:)))
        s.setAccessibilityIdentifier(id)
        s.selectedSegment = 0
        return s
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        report("seg_one_label", "segment_\(sender.selectedSegment)")
    }

    // MARK: - Combo box

    private func makeComboBox(id: String) -> NSComboBox {
        let c = NSComboBox()
        c.setAccessibilityIdentifier(id)
        c.addItems(withObjectValues: ["Indica", "Sativa", "Hybrid"])
        c.stringValue = "Indica"
        c.delegate = self
        c.target = self
        c.action = #selector(comboAction(_:))
        return c
    }

    @objc private func comboAction(_ sender: NSComboBox) {
        report("combo_one_label", "combo_\(sender.stringValue)")
    }

    // MARK: - Search field

    private func makeSearchField(id: String) -> NSSearchField {
        let s = NSSearchField()
        s.setAccessibilityIdentifier(id)
        s.placeholderString = "Search"
        s.delegate = self
        return s
    }

    // MARK: - Date picker

    private func makeDatePicker(id: String) -> NSDatePicker {
        let d = NSDatePicker()
        d.setAccessibilityIdentifier(id)
        d.datePickerStyle = .textFieldAndStepper
        d.datePickerElements = .yearMonthDay
        d.timeZone = TimeZone(identifier: "UTC")
        var parts = DateComponents()
        parts.year = 2026; parts.month = 6; parts.day = 15
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        d.calendar = cal
        d.dateValue = cal.date(from: parts)!
        d.target = self
        d.action = #selector(dateChanged(_:))
        return d
    }

    @objc private func dateChanged(_ sender: NSDatePicker) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        report("dp_one_label", "date_\(f.string(from: sender.dateValue))")
    }

    // MARK: - Color well

    private func makeColorWell(id: String) -> NSColorWell {
        let w = NSColorWell(style: .default)
        w.setAccessibilityIdentifier(id)
        w.color = .systemBlue
        w.target = self
        w.action = #selector(colorChanged(_:))
        return w
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        let c = sender.color.usingColorSpace(.sRGB) ?? sender.color
        report("cw_one_label", String(format: "color_%.2f_%.2f_%.2f", c.redComponent, c.greenComponent, c.blueComponent))
    }

    /// The matrix opens the shared Colors panel through the well's AXPress;
    /// this button closes it again deterministically (no tool can close an
    /// arbitrary window, and guessing a close button risks hitting the main
    /// window).
    private func makeClosePanelButton(id: String) -> NSButton {
        let b = NSButton(title: "Close colors", target: self, action: #selector(closeColorPanel(_:)))
        b.setAccessibilityIdentifier(id)
        b.bezelStyle = .rounded
        return b
    }

    @objc private func closeColorPanel(_ sender: NSButton) {
        NSColorPanel.shared.close()
    }

    // MARK: - Disclosure triangle

    private func makeDisclosure(id: String) -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(disclosureToggled(_:)))
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .disclosure
        b.setAccessibilityIdentifier(id)
        b.state = .off
        return b
    }

    @objc private func disclosureToggled(_ sender: NSButton) {
        report("disc_one_label", sender.state == .on ? "expanded" : "collapsed")
    }

    // MARK: - Progress indicator (read-only)

    private func makeProgress(id: String) -> NSProgressIndicator {
        let p = NSProgressIndicator()
        p.setAccessibilityIdentifier(id)
        p.style = .bar
        p.isIndeterminate = false
        p.minValue = 0
        p.maxValue = 100
        p.doubleValue = 42
        return p
    }

    // MARK: - Tab view

    private func makeTabView(id: String) -> NSTabView {
        let t = NSTabView()
        t.setAccessibilityIdentifier(id)
        for (ident, title) in [("tab_general", "General"), ("tab_advanced", "Advanced")] {
            let item = NSTabViewItem(identifier: ident)
            item.label = title
            let content = NSView()
            let marker = NSTextField(labelWithString: "content of \(title)")
            marker.setAccessibilityIdentifier("\(ident)_content")
            marker.frame = NSRect(x: 10, y: 10, width: 200, height: 18)
            content.addSubview(marker)
            item.view = content
            t.addTabViewItem(item)
        }
        t.delegate = self
        return t
    }

    // MARK: - Table view

    private func makeTable(id: String) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let table = NSTableView()
        table.setAccessibilityIdentifier(id)
        for (ident, title, width) in [("city", "City", 140.0), ("size", "Population", 100.0)] {
            let col = NSTableColumn(identifier: .init(ident))
            col.title = title
            col.width = width
            table.addTableColumn(col)
        }
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        tableView = table
        return scroll
    }
}

extension ExtendedControls: NSComboBoxDelegate, NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field.accessibilityIdentifier() {
        case "sf_one": report("sf_one_label", "search_\(field.stringValue)")
        case "combo_one": report("combo_one_label", "combo_\(field.stringValue)")
        default: break
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox, combo.indexOfSelectedItem >= 0 else { return }
        report("combo_one_label", "combo_\(combo.itemObjectValue(at: combo.indexOfSelectedItem))")
    }
}

extension ExtendedControls: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        report("tab_one_label", "tab_\(tabViewItem?.identifier as? String ?? "?")")
    }
}

extension ExtendedControls: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { tableItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = tableItems[row]
        let text = tableColumn?.identifier.rawValue == "size" ? item.size : item.name
        let cell = NSTextField(labelWithString: text)
        cell.setAccessibilityIdentifier("table_cell_\(row)_\(tableColumn?.identifier.rawValue ?? "?")")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        let row = table.selectedRow
        report("table_one_label", row >= 0 ? "row_\(tableItems[row].name)" : "row_none")
    }
}
