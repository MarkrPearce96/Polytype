import AppKit
import NaturalLanguage

/// When Compose is pressed with nothing manually selected, finds the paragraph
/// around the text cursor in the frontmost app's focused field — via the
/// Accessibility API — and expands the field's own selection to cover it, so
/// the normal ⌘C copy that follows grabs just that paragraph instead of the
/// whole field.
///
/// This depends on the focused element properly supporting AX's text-range
/// attributes. Native Cocoa text views (TextEdit, Notes, Mail, Messages)
/// support this well; some web-based text areas don't, and every step here
/// fails safely (returns false) rather than guessing — the caller falls back
/// to the old select-all behavior in that case.
@MainActor
enum SmartSelection {
    /// Attempts to select the paragraph at the cursor. Returns true if it
    /// actually changed the target app's selection.
    static func selectParagraphAtCursor() -> Bool {
        guard let element = focusedElement(),
              let text = stringValue(of: element),
              let cursor = selectedRange(of: element)?.location,
              let nsRange = paragraphRange(in: text, at: cursor),
              nsRange.length > 0
        else { return false }
        return setSelectedRange(nsRange, on: element)
    }

    /// The paragraph boundary around `location` (a UTF-16 offset, matching
    /// what AX reports), using real linguistic segmentation rather than a
    /// naive newline split — handles line-wrapped paragraphs, etc.
    private static func paragraphRange(in text: String, at location: Int) -> NSRange? {
        let ns = text as NSString
        guard location >= 0, location <= ns.length else { return nil }
        let tokenizer = NLTokenizer(unit: .paragraph)
        tokenizer.string = text
        guard let stringLocation = text.utf16Index(at: location, limitedBy: text.endIndex) else { return nil }
        let tokenRange = tokenizer.tokenRange(at: stringLocation)
        guard !tokenRange.isEmpty else { return nil }
        return NSRange(tokenRange, in: text)
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func setSelectedRange(_ range: NSRange, on element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
    }
}

private extension String {
    /// A `String.Index` for a UTF-16 offset (what AX reports positions in).
    func utf16Index(at offset: Int, limitedBy end: String.Index) -> String.Index? {
        utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex)
            .flatMap { Index($0, within: self) }
    }
}
