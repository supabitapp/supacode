import AppKit
import Observation

/// SwiftUI↔AppKit bridge between `NotesFormatBar` and the editor's `NSTextView`.
/// Holds a weak reference to the text view, applies formatting to the current
/// selection (or to the typing attributes when the selection is empty), and
/// publishes the active formatting state so the format bar can highlight buttons.
///
/// All formatting uses RTF-safe primitives (font traits, underline/strikethrough
/// attributes, paragraph style + marker text) so it round-trips through
/// `NSAttributedString.rtf(...)` losslessly.
@MainActor
@Observable
final class NoteEditorController {
  @ObservationIgnored weak var textView: NSTextView?

  private(set) var isBold = false
  private(set) var isItalic = false
  private(set) var isUnderline = false
  private(set) var isStrikethrough = false
  private(set) var isInlineCode = false
  private(set) var activeStyle: NoteTextStyle = .body

  private var defaultFont: NSFont { NoteTextStyle.body.baseFont }

  /// Registers the text view and syncs the initial active state.
  func attach(_ textView: NSTextView) {
    self.textView = textView
    refreshActiveState()
  }

  // MARK: - Commands

  func toggleBold() { toggleFontTrait(.boldFontMask) }
  func toggleItalic() { toggleFontTrait(.italicFontMask) }
  func toggleUnderline() { toggleStyleAttribute(.underlineStyle) }
  func toggleStrikethrough() { toggleStyleAttribute(.strikethroughStyle) }

  /// Sets the named size preset on the selection, preserving bold/italic traits.
  func setStyle(_ style: NoteTextStyle) {
    applyFontTransform { font in
      let manager = NSFontManager.shared
      let traits = manager.traits(of: font)
      var resolved = style.baseFont
      if traits.contains(.boldFontMask) { resolved = manager.convert(resolved, toHaveTrait: .boldFontMask) }
      if traits.contains(.italicFontMask) { resolved = manager.convert(resolved, toHaveTrait: .italicFontMask) }
      return resolved
    }
  }

  /// Toggles a monospaced font run (inline code) across the selection.
  func toggleInlineCode() {
    let shouldAdd = !isInlineCode
    let fallbackSize = defaultFont.pointSize
    applyFontTransform { font in
      if shouldAdd {
        let manager = NSFontManager.shared
        let weight: NSFont.Weight = manager.traits(of: font).contains(.boldFontMask) ? .bold : .regular
        return NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: weight)
      }
      return NSFont.systemFont(ofSize: font.isFixedPitch ? font.pointSize : fallbackSize)
    }
  }

  /// Toggles a code block (monospaced + indented) across the selected paragraphs.
  func toggleCodeBlock() {
    let makeCode = !paragraphsAreCodeBlock()
    let monospaced = NSFont.monospacedSystemFont(ofSize: defaultFont.pointSize, weight: .regular)
    let body = defaultFont
    applyToParagraphs { storage, range in
      let style = NSMutableParagraphStyle()
      if makeCode {
        style.firstLineHeadIndent = 14
        style.headIndent = 14
        storage.addAttribute(.paragraphStyle, value: style, range: range)
        storage.addAttribute(.font, value: monospaced, range: range)
      } else {
        storage.addAttribute(.paragraphStyle, value: style, range: range)
        storage.addAttribute(.font, value: body, range: range)
      }
    }
  }

  func toggleBulletList() { toggleMarkerList(numbered: false) }
  func toggleNumberedList() { toggleMarkerList(numbered: true) }

  // MARK: - Active state

  /// Recomputes the published formatting flags from the current selection.
  /// Called by the editor on selection changes and after each command.
  func refreshActiveState() {
    guard let textView else { return }
    let manager = NSFontManager.shared
    let font = currentFont(textView)
    isBold = manager.traits(of: font).contains(.boldFontMask)
    isItalic = manager.traits(of: font).contains(.italicFontMask)
    isInlineCode = font.isFixedPitch
    activeStyle = NoteTextStyle.from(pointSize: font.pointSize)
    isUnderline = hasStyleAttribute(.underlineStyle)
    isStrikethrough = hasStyleAttribute(.strikethroughStyle)
  }

  // MARK: - Font helpers

  private func toggleFontTrait(_ trait: NSFontTraitMask) {
    let shouldAdd = !traitEverywhere(trait)
    applyFontTransform { font in
      let manager = NSFontManager.shared
      return shouldAdd ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait)
    }
  }

  private func traitEverywhere(_ trait: NSFontTraitMask) -> Bool {
    guard let textView else { return false }
    let manager = NSFontManager.shared
    let range = textView.selectedRange()
    if range.length == 0 {
      return manager.traits(of: currentFont(textView)).contains(trait)
    }
    guard let storage = textView.textStorage else { return false }
    var all = true
    storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
      let font = (value as? NSFont) ?? self.defaultFont
      if !manager.traits(of: font).contains(trait) {
        all = false
        stop.pointee = true
      }
    }
    return all
  }

  private func applyFontTransform(_ transform: @escaping (NSFont) -> NSFont) {
    guard let textView else { return }
    let range = textView.selectedRange()
    if range.length == 0 {
      var attrs = textView.typingAttributes
      let current = (attrs[.font] as? NSFont) ?? defaultFont
      attrs[.font] = transform(current)
      textView.typingAttributes = attrs
      refreshActiveState()
      return
    }
    guard let storage = textView.textStorage,
      textView.shouldChangeText(in: range, replacementString: nil)
    else { return }
    storage.beginEditing()
    storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
      let current = (value as? NSFont) ?? self.defaultFont
      storage.addAttribute(.font, value: transform(current), range: subRange)
    }
    storage.endEditing()
    textView.didChangeText()
    refreshActiveState()
  }

  private func currentFont(_ textView: NSTextView) -> NSFont {
    let range = textView.selectedRange()
    if range.length == 0 {
      return (textView.typingAttributes[.font] as? NSFont) ?? defaultFont
    }
    guard let storage = textView.textStorage, range.location < storage.length else {
      return (textView.typingAttributes[.font] as? NSFont) ?? defaultFont
    }
    return (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? defaultFont
  }

  // MARK: - Style-attribute helpers (underline / strikethrough)

  private func toggleStyleAttribute(_ key: NSAttributedString.Key) {
    guard let textView else { return }
    let shouldAdd = !hasStyleAttribute(key)
    let value = shouldAdd ? NSUnderlineStyle.single.rawValue : 0
    let range = textView.selectedRange()
    if range.length == 0 {
      var attrs = textView.typingAttributes
      attrs[key] = value
      textView.typingAttributes = attrs
      refreshActiveState()
      return
    }
    guard let storage = textView.textStorage,
      textView.shouldChangeText(in: range, replacementString: nil)
    else { return }
    storage.beginEditing()
    storage.addAttribute(key, value: value, range: range)
    storage.endEditing()
    textView.didChangeText()
    refreshActiveState()
  }

  private func hasStyleAttribute(_ key: NSAttributedString.Key) -> Bool {
    guard let textView else { return false }
    let range = textView.selectedRange()
    if range.length == 0 {
      if let value = textView.typingAttributes[key] as? Int { return value != 0 }
      return false
    }
    guard let storage = textView.textStorage, range.location < storage.length else { return false }
    if let value = storage.attribute(key, at: range.location, effectiveRange: nil) as? Int {
      return value != 0
    }
    return false
  }

  // MARK: - Paragraph helpers

  private func applyToParagraphs(_ transform: (NSTextStorage, NSRange) -> Void) {
    guard let textView, let storage = textView.textStorage else { return }
    let nsString = storage.string as NSString
    let paraRange = nsString.paragraphRange(for: textView.selectedRange())
    guard textView.shouldChangeText(in: paraRange, replacementString: nil) else { return }
    storage.beginEditing()
    transform(storage, paraRange)
    storage.endEditing()
    textView.didChangeText()
    refreshActiveState()
  }

  private func paragraphsAreCodeBlock() -> Bool {
    guard let textView, let storage = textView.textStorage else { return false }
    let nsString = storage.string as NSString
    let paraRange = nsString.paragraphRange(for: textView.selectedRange())
    guard paraRange.length > 0, paraRange.location < storage.length else { return false }
    let font = storage.attribute(.font, at: paraRange.location, effectiveRange: nil) as? NSFont
    let style = storage.attribute(.paragraphStyle, at: paraRange.location, effectiveRange: nil) as? NSParagraphStyle
    return (font?.isFixedPitch ?? false) && (style?.headIndent ?? 0) > 0
  }

  // MARK: - Marker lists (RTF-safe: marker text + hanging indent)

  private func toggleMarkerList(numbered: Bool) {
    guard let textView, let storage = textView.textStorage else { return }
    let preEdit = storage.string as NSString
    let paraRange = preEdit.paragraphRange(for: textView.selectedRange())
    var paragraphStarts: [Int] = []
    preEdit.enumerateSubstrings(in: paraRange, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
      paragraphStarts.append(range.location)
    }
    guard !paragraphStarts.isEmpty else { return }
    let listed = paragraphStarts.allSatisfy { Self.markerPrefixLength(preEdit, atParagraphStart: $0) > 0 }
    guard textView.shouldChangeText(in: paraRange, replacementString: nil) else { return }
    storage.beginEditing()
    // Edit bottom-up so earlier paragraph offsets stay valid as we mutate.
    for (index, start) in paragraphStarts.enumerated().reversed() {
      let current = storage.string as NSString
      guard start <= current.length else { continue }
      if listed {
        let prefixLength = Self.markerPrefixLength(current, atParagraphStart: start)
        if prefixLength > 0 {
          storage.deleteCharacters(in: NSRange(location: start, length: prefixLength))
        }
        let resolved = (storage.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
        storage.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: resolved)
      } else {
        let marker = numbered ? "\(index + 1).\t" : "•\t"
        let style = NSMutableParagraphStyle()
        style.headIndent = 20
        var attrs = Self.insertionAttributes(storage, at: start, fallback: textView.typingAttributes)
        attrs[.paragraphStyle] = style
        storage.insert(NSAttributedString(string: marker, attributes: attrs), at: start)
        let resolved = (storage.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
        storage.addAttribute(.paragraphStyle, value: style, range: resolved)
      }
    }
    storage.endEditing()
    textView.didChangeText()
    refreshActiveState()
  }

  private static func markerPrefixLength(_ string: NSString, atParagraphStart start: Int) -> Int {
    let length = string.length
    guard start < length else { return 0 }
    if length - start >= 2, string.substring(with: NSRange(location: start, length: 2)) == "•\t" {
      return 2
    }
    var cursor = start
    while cursor < length,
      let scalar = string.substring(with: NSRange(location: cursor, length: 1)).unicodeScalars.first,
      CharacterSet.decimalDigits.contains(scalar)
    {
      cursor += 1
    }
    if cursor > start, cursor + 2 <= length,
      string.substring(with: NSRange(location: cursor, length: 2)) == ".\t"
    {
      return (cursor - start) + 2
    }
    return 0
  }

  private static func insertionAttributes(
    _ storage: NSTextStorage,
    at index: Int,
    fallback: [NSAttributedString.Key: Any]
  ) -> [NSAttributedString.Key: Any] {
    if index < storage.length {
      return storage.attributes(at: index, effectiveRange: nil)
    }
    if storage.length > 0 {
      return storage.attributes(at: storage.length - 1, effectiveRange: nil)
    }
    return fallback
  }
}
