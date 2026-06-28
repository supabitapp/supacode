import SwiftUI

/// Minimalist formatting toolbar shown above the notes editor. Reads the active
/// formatting state from `NoteEditorController` to highlight toggles and routes
/// each tap to the controller (which mutates the `NSTextView` selection). Uses
/// only system SF Symbols and system colors per the project's UX standards.
struct NotesFormatBar: View {
  let controller: NoteEditorController

  var body: some View {
    HStack(spacing: 2) {
      toggle("bold", "Negrito", isOn: controller.isBold) { controller.toggleBold() }
      toggle("italic", "Itálico", isOn: controller.isItalic) { controller.toggleItalic() }
      toggle("underline", "Sublinhado", isOn: controller.isUnderline) { controller.toggleUnderline() }
      toggle("strikethrough", "Tachado", isOn: controller.isStrikethrough) { controller.toggleStrikethrough() }

      separator

      toggle(
        "chevron.left.forwardslash.chevron.right", "Código inline", isOn: controller.isInlineCode
      ) { controller.toggleInlineCode() }
      toggle("curlybraces", "Bloco de código", isOn: false) { controller.toggleCodeBlock() }
      toggle("list.bullet", "Lista com marcadores", isOn: false) { controller.toggleBulletList() }
      toggle("list.number", "Lista numerada", isOn: false) { controller.toggleNumberedList() }

      separator

      sizePicker

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity)
    .background(.bar)
  }

  private var separator: some View {
    Divider().frame(height: 16)
  }

  private var sizePicker: some View {
    Picker(
      "Tamanho",
      selection: Binding(
        get: { controller.activeStyle },
        set: { controller.setStyle($0) }
      )
    ) {
      ForEach(NoteTextStyle.allCases) { style in
        Text(style.label).tag(style)
      }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .fixedSize()
    .help("Tamanho do texto")
  }

  private func toggle(
    _ symbol: String,
    _ label: String,
    isOn: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .frame(width: 24, height: 22)
        .contentShape(.rect)
        .accessibilityLabel(label)
    }
    .buttonStyle(.plain)
    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
    .help(label)
  }
}
