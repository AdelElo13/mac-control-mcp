import AppKit

// ControlZoo — deterministic AX test harness for mac-control-mcp.
//
// Every control has a stable accessibilityIdentifier so the compat
// matrix can locate it without relying on titles/positions. All controls
// are pure AppKit (not SwiftUI) because AppKit gives us predictable AX
// roles — SwiftUI sometimes wraps things in AXGroup or hides roles.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var outlineView: NSOutlineView!
    var outlineItems: [String] = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"]
    /// Codex v8 #4 — observable side-effect label for btn_click so the
    /// test can assert the button did something, not just that AXPress
    /// returned ax_status == 0.
    var clickLabel: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let contentSize = NSSize(width: 720, height: 720)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ControlZoo"
        window.setContentSize(contentSize)
        window.contentView = buildRoot(size: contentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildRoot(size: NSSize) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]

        let stack = NSStackView(frame: NSRect(x: 20, y: 20, width: size.width - 40, height: size.height - 40))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.autoresizingMask = [.width, .height]

        stack.addArrangedSubview(header("ControlZoo — mac-control-mcp test harness"))

        // TextField — identifier: tf_single
        stack.addArrangedSubview(labeledRow("AXTextField:", control: makeTextField(id: "tf_single", value: "initial single-line")))

        // SecureTextField — identifier: tf_secure
        stack.addArrangedSubview(labeledRow("AXSecureTextField:", control: makeSecureField(id: "tf_secure", value: "hunter2")))

        // TextArea (NSTextView inside scroll) — identifier: ta_multi
        stack.addArrangedSubview(labeledRow("AXTextArea:", control: makeTextArea(id: "ta_multi", value: "first line\nsecond line\nthird line"), height: 70))

        // CheckBox — identifier: cb_one
        stack.addArrangedSubview(labeledRow("AXCheckBox:", control: makeCheckBox(id: "cb_one", title: "Checkbox one", checked: false)))

        // Switch — identifier: sw_one
        stack.addArrangedSubview(labeledRow("AXSwitch:", control: makeSwitch(id: "sw_one", on: false)))

        // Slider — identifier: sl_one
        stack.addArrangedSubview(labeledRow("AXSlider (0-100):", control: makeSlider(id: "sl_one", value: 25, minValue: 0, maxValue: 100)))

        // Stepper — identifier: st_one
        stack.addArrangedSubview(labeledRow("AXStepper:", control: makeStepper(id: "st_one", value: 3)))

        // PopUpButton — identifier: pu_one
        stack.addArrangedSubview(labeledRow("AXPopUpButton:", control: makePopUp(id: "pu_one", items: ["Red","Green","Blue","Yellow"], selected: "Green")))

        // LevelIndicator — identifier: li_meter (custom, like Logic level meter)
        stack.addArrangedSubview(labeledRow("AXLevelIndicator:", control: makeLevelIndicator(id: "li_meter", value: 0.6)))

        // Button — identifier: btn_click + observable side-effect label
        // (Codex v8 #4: button test now asserts observable state change)
        clickLabel = makeClickLabel()
        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        btnRow.addArrangedSubview(makeButton(id: "btn_click", title: "Click me"))
        btnRow.addArrangedSubview(clickLabel!)
        stack.addArrangedSubview(labeledRow("AXButton:", control: btnRow))

        // OutlineView (with selection) — identifier: outline_items
        stack.addArrangedSubview(labeledRow("AXOutline:", control: makeOutline(id: "outline_items"), height: 160))

        root.addSubview(stack)
        return root
    }

    // MARK: - Labeled row helper

    private func header(_ text: String) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.font = .boldSystemFont(ofSize: 14)
        tf.setAccessibilityIdentifier("header_title")
        return tf
    }

    private func labeledRow(_ label: String, control: NSView, height: CGFloat = 24) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.distribution = .fill

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12)
        labelField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        labelField.setAccessibilityLabel("label_for_\(control.accessibilityIdentifier() ?? "?")")
        row.addArrangedSubview(labelField)

        if height != 24 {
            control.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        row.addArrangedSubview(control)

        return row
    }

    // MARK: - Control factories

    private func makeTextField(id: String, value: String) -> NSTextField {
        let tf = NSTextField(string: value)
        tf.setAccessibilityIdentifier(id)
        tf.isEditable = true
        tf.isSelectable = true
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.placeholderString = "Single-line text"
        return tf
    }

    private func makeSecureField(id: String, value: String) -> NSSecureTextField {
        let tf = NSSecureTextField(string: value)
        tf.setAccessibilityIdentifier(id)
        tf.isEditable = true
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        return tf
    }

    private func makeTextArea(id: String, value: String) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.setAccessibilityIdentifier(id + "_scroll")

        let textView = NSTextView()
        textView.string = value
        textView.setAccessibilityIdentifier(id)
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 12)

        scroll.documentView = textView
        return scroll
    }

    private func makeCheckBox(id: String, title: String, checked: Bool) -> NSButton {
        let btn = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        btn.setAccessibilityIdentifier(id)
        btn.state = checked ? .on : .off
        return btn
    }

    private func makeSwitch(id: String, on: Bool) -> NSSwitch {
        let s = NSSwitch()
        s.setAccessibilityIdentifier(id)
        s.state = on ? .on : .off
        return s
    }

    private func makeSlider(id: String, value: Double, minValue: Double, maxValue: Double) -> NSSlider {
        let s = NSSlider(value: value, minValue: minValue, maxValue: maxValue, target: nil, action: nil)
        s.setAccessibilityIdentifier(id)
        s.allowsTickMarkValuesOnly = false
        s.numberOfTickMarks = 0
        return s
    }

    private func makeStepper(id: String, value: Double) -> NSStepper {
        let st = NSStepper()
        st.setAccessibilityIdentifier(id)
        st.minValue = 0
        st.maxValue = 100
        st.increment = 1
        st.doubleValue = value
        return st
    }

    private func makePopUp(id: String, items: [String], selected: String) -> NSPopUpButton {
        let p = NSPopUpButton(title: "", target: nil, action: nil)
        p.setAccessibilityIdentifier(id)
        p.addItems(withTitles: items)
        p.selectItem(withTitle: selected)
        return p
    }

    private func makeLevelIndicator(id: String, value: Double) -> NSLevelIndicator {
        let li = NSLevelIndicator()
        li.setAccessibilityIdentifier(id)
        li.minValue = 0
        li.maxValue = 1
        li.warningValue = 0.7
        li.criticalValue = 0.9
        li.doubleValue = value
        li.levelIndicatorStyle = .continuousCapacity
        li.isEditable = true
        return li
    }

    private func makeButton(id: String, title: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(buttonClicked(_:)))
        b.setAccessibilityIdentifier(id)
        b.bezelStyle = .rounded
        return b
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        // Codex v8 #4 — update the observable label so tests can confirm
        // the button actually ran its action. The AX tree exposes this
        // label's AXValue, which the compat matrix reads post-press.
        clickLabel?.stringValue = "clicked_\(Int(Date().timeIntervalSince1970 * 1000))"
    }

    private func makeClickLabel() -> NSTextField {
        let tf = NSTextField(labelWithString: "not_clicked")
        tf.setAccessibilityIdentifier("btn_click_label")
        tf.font = .systemFont(ofSize: 11)
        return tf
    }

    private func makeOutline(id: String) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        outlineView = NSOutlineView()
        outlineView.setAccessibilityIdentifier(id)
        let col = NSTableColumn(identifier: .init("name"))
        col.title = "Name"
        col.width = 250
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.allowsMultipleSelection = false

        scroll.documentView = outlineView
        return scroll
    }
}

extension AppDelegate: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? outlineItems.count : 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        outlineItems[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }
    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        item as? String
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
