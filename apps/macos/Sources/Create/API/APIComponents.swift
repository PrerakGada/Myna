// APIComponents.swift — the small views the API pane is built from: a
// copy button that says it copied, a selectable code block on a raised
// surface, a one-line copyable value, and an HTTP method tag.
//
// Code is monospaced, selectable and wraps rather than scrolling
// sideways, so nothing is cut off at the Dashboard's minimum width.
import AppKit
import SwiftUI

enum APIClipboard {
    @MainActor
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

enum APIDesign {
    /// Code surface: one step above the card it sits on.
    static let codeSurface = Color.white.opacity(0.045)
    static let codeBorder = Color.white.opacity(0.08)
    static let codeFont = Font.system(size: 12, design: .monospaced)
    static let codeRadius: CGFloat = 8
}

/// "Copy" that flips to "Copied" for a moment.
struct APICopyButton: View {
    let text: String
    var label = "Copy"
    var compact = false

    @State private var copied = false

    var body: some View {
        Button {
            APIClipboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                copied = false
            }
        } label: {
            if compact {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? DashboardDesign.positive : DashboardDesign.secondary)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            } else {
                Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? DashboardDesign.positive : DashboardDesign.body)
            }
        }
        .buttonStyle(.borderless)
        .help(copied ? "Copied" : label)
        .accessibilityLabel(copied ? "Copied" : label)
    }
}

/// A block of code with a language tag and a copy button above it.
/// `copyText` lets the screen show a masked key while Copy carries the
/// real one.
struct APICodeBlock: View {
    let code: String
    var language: String?
    var copyText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let language {
                    Text(language)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(DashboardDesign.tertiary)
                }
                Spacer(minLength: 0)
                APICopyButton(text: copyText ?? code)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Text(code)
                .font(APIDesign.codeFont)
                .foregroundStyle(DashboardDesign.body)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: APIDesign.codeRadius, style: .continuous)
                .fill(APIDesign.codeSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: APIDesign.codeRadius, style: .continuous)
                .strokeBorder(APIDesign.codeBorder, lineWidth: 1)
        )
    }
}

/// One value (a URL, a key, a route) in monospace with a copy button.
struct APICopyField: View {
    let value: String
    var display: String?
    var fontSize: CGFloat = 12
    var dimmed = false

    var body: some View {
        HStack(spacing: 8) {
            Text(display ?? value)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(dimmed ? DashboardDesign.tertiary : DashboardDesign.title)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            APICopyButton(text: value, compact: true)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: APIDesign.codeRadius, style: .continuous)
                .fill(APIDesign.codeSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: APIDesign.codeRadius, style: .continuous)
                .strokeBorder(APIDesign.codeBorder, lineWidth: 1)
        )
    }
}

/// `GET` / `POST` / `DELETE`, colour-coded the way API docs usually are.
struct APIMethodTag: View {
    let method: String
    /// Column width so paths line up in a table; nil hugs the tag.
    var width: CGFloat? = 50

    private var tint: Color {
        switch method.uppercased() {
        case "GET": return DashboardDesign.info
        case "POST": return DashboardDesign.positive
        case "DELETE": return DashboardDesign.negative
        default: return DashboardDesign.secondary
        }
    }

    var body: some View {
        Text(method.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.14)))
            .frame(width: width, alignment: .leading)
    }
}

/// Inline code inside prose: `Text` concatenation keeps it wrapping with
/// the sentence.
enum APIText {
    static func code(_ value: String) -> Text {
        Text(value).font(.system(size: 11, design: .monospaced)).foregroundColor(DashboardDesign.body)
    }
}
