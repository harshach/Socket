import AppKit
import BrowserCore

struct WorkspaceEditorDraft {
    var title: String
    var iconGlyph: String
    var profileMode: WorkspaceProfileMode
    var startURL: String
}

@MainActor
enum PromptPresenter {
    static func presentSheet(
        title: String,
        message: String,
        placeholder: String,
        for window: NSWindow?,
        completion: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.placeholderString = placeholder
        textField.stringValue = placeholder
        alert.accessoryView = textField

        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn {
                completion(textField.stringValue)
            }
            return
        }

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            completion(textField.stringValue)
        }
    }

    static func presentDualFieldSheet(
        title: String,
        message: String,
        primaryPlaceholder: String,
        secondaryPlaceholder: String,
        completion: @escaping (String, String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let primaryField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        primaryField.placeholderString = primaryPlaceholder

        let secondaryField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        secondaryField.placeholderString = secondaryPlaceholder
        secondaryField.stringValue = secondaryPlaceholder

        stack.addArrangedSubview(primaryField)
        stack.addArrangedSubview(secondaryField)
        alert.accessoryView = stack

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return
        }
        completion(primaryField.stringValue, secondaryField.stringValue)
    }

    static func presentWorkspaceEditor(
        title: String,
        message: String,
        draft: WorkspaceEditorDraft,
        includeStartURL: Bool,
        for window: NSWindow?,
        completion: @escaping (WorkspaceEditorDraft) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: includeStartURL ? "Create" : "Save")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleField = makeField(placeholder: "Workspace title", value: draft.title)
        let iconField = makeField(placeholder: "Emoji icon", value: draft.iconGlyph)

        let profileLabel = NSTextField(labelWithString: "Profile")
        profileLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        profileLabel.textColor = .secondaryLabelColor

        let profilePopup = NSPopUpButton()
        profilePopup.addItems(withTitles: ["Shared browsing profile", "Isolated browsing profile"])
        profilePopup.selectItem(at: draft.profileMode == .shared ? 0 : 1)

        stack.addArrangedSubview(labeledRow(label: "Title", field: titleField))
        stack.addArrangedSubview(labeledRow(label: "Icon", field: iconField))
        stack.addArrangedSubview(profileLabel)
        stack.addArrangedSubview(profilePopup)

        let startField: NSTextField?
        if includeStartURL {
            let field = makeField(placeholder: "https://www.apple.com", value: draft.startURL)
            stack.addArrangedSubview(labeledRow(label: "Start page", field: field))
            startField = field
        } else {
            startField = nil
        }

        alert.accessoryView = stack

        let submit = {
            let cleanedTitle = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let glyph = iconField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = WorkspaceEditorDraft(
                title: cleanedTitle,
                iconGlyph: glyph.isEmpty ? "🧩" : String(glyph.prefix(2)),
                profileMode: profilePopup.indexOfSelectedItem == 0 ? .shared : .isolated,
                startURL: startField?.stringValue ?? draft.startURL
            )
            completion(result)
        }

        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn {
                submit()
            }
            return
        }

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            submit()
        }
    }

    private static func makeField(placeholder: String, value: String) -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        field.stringValue = value
        return field
    }

    private static func labeledRow(label: String, field: NSTextField) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let row = NSStackView(views: [titleLabel, field])
        row.orientation = .vertical
        row.spacing = 4
        return row
    }
}
