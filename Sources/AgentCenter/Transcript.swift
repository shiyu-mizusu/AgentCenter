import SwiftUI

struct Transcript: View {
    let items: [Item]?
    let running: Bool

    var body: some View {
        if let items {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(items) { ItemView(item: $0) }
                        if running {
                            ProgressView().controlSize(.small)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: items.last?.text.count) { if running { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ItemView: View {
    let item: Item
    @State private var expanded = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(item.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
        case .assistant:
            MarkdownText(text: item.text)
        case .tool:
            VStack(alignment: .leading, spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .frame(width: 14)
                        Text(item.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !item.detail.isEmpty {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }
                    .font(.callout.monospaced())
                    .foregroundStyle(item.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.detail.isEmpty)
                if expanded {
                    ScrollView {
                        Text(item.detail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 260)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        case .status:
            Text(item.text)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

/// Just enough Markdown for agent replies: fenced code blocks, headings, bullets and inline styles.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                if block.code {
                    ScrollView(.horizontal) {
                        Text(block.text)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(Self.inline(block.text))
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    static func blocks(_ text: String) -> [(code: Bool, text: String)] {
        var blocks: [(code: Bool, text: String)] = [], lines: [Substring] = [], code = false
        func flush() {
            let body = lines.joined(separator: "\n")
            if code || !body.trimmed.isEmpty { blocks.append((code, code ? body : body.trimmed)) }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                code.toggle()
            } else {
                lines.append(line)
            }
        }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        let markdown = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line)
                .replacingOccurrences(of: "^#{1,6}\\s+(.+)$", with: "**$1**", options: .regularExpression)
                .replacingOccurrences(of: "^(\\s*)[-*+]\\s+", with: "$1• ", options: .regularExpression)
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(text)
    }
}

struct ApprovalCard: View {
    let approval: Approval
    let answer: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Permission needed")
                    .font(.headline)
                Text(approval.title)
                    .font(.callout.monospaced())
                    .lineLimit(4)
                    .textSelection(.enabled)
                if !approval.detail.isEmpty {
                    Text(approval.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                }
            }
            Spacer(minLength: 12)
            Button("Deny") { answer(false) }
            Button("Allow") { answer(true) }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.35)))
        .frame(maxWidth: 788)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

struct Composer: View {
    let agent: Agent
    var running = false
    let placeholder: String
    let onSend: (String) -> Void
    var onStop: () -> Void = {}

    @State private var text = ""
    @FocusState private var focused: Bool
    @AppStorage private var mode: String

    init(agent: Agent, running: Bool = false, placeholder: String,
         onSend: @escaping (String) -> Void, onStop: @escaping () -> Void = {}) {
        self.agent = agent
        self.running = running
        self.placeholder = placeholder
        self.onSend = onSend
        self.onStop = onStop
        _mode = AppStorage(wrappedValue: "", agent.modeKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...12)
                .focused($focused)
                .onSubmit(send)
            HStack {
                Picker("Permissions", selection: $mode) {
                    ForEach(agent.modes, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("What \(agent.name) may do without asking")
                Spacer()
                Group {
                    if running {
                        Button(action: onStop) { Image(systemName: "stop.fill") }
                            .help("Stop")
                            .buttonStyle(.bordered)
                    } else {
                        Button(action: send) { Image(systemName: "arrow.up").fontWeight(.semibold) }
                            .help("Send (Return)")
                            .buttonStyle(.borderedProminent)
                            .tint(agent.color)
                            .disabled(text.trimmed.isEmpty)
                    }
                }
                .buttonBorderShape(.circle)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .frame(maxWidth: 788)
        .padding(16)
        .onAppear { focused = true }
    }

    private func send() {
        let prompt = text.trimmed
        guard !prompt.isEmpty, !running else { return }
        text = ""
        onSend(prompt)
    }
}
