import SwiftUI

struct Transcript: View {
    let items: [Item]?
    let running: Bool
    @State private var atBottom: String?  // id of the row at the bottom edge, updated as you scroll

    init(items: [Item]?, running: Bool) {
        self.items = items
        self.running = running
    }

    var body: some View {
        if let items {
            let rows = Self.rows(items)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(rows) { row in
                            switch row {
                            case .item(let item): ItemView(item: item)
                            case .steps(let steps): StepsView(steps: steps)
                            }
                        }
                        if running {
                            ProgressView().controlSize(.small)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .scrollPosition(id: $atBottom, anchor: .bottom)
                .defaultScrollAnchor(.bottom)
                .onChange(of: items.count) { follow(proxy, rows: rows, sent: items.last?.kind == .user) }
                .onChange(of: items.last?.text.count) { follow(proxy, rows: rows) }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    enum Row: Identifiable {
        case item(Item)
        case steps([Item])

        var id: String {
            switch self {
            case .item(let item): item.id
            case .steps(let steps): "steps-" + (steps.first?.id ?? "")
            }
        }
    }

    /// Three or more tool calls in a row fold into one "N steps" row, so the conversation stays readable.
    static func rows(_ items: [Item]) -> [Row] {
        var rows: [Row] = [], run: [Item] = []
        func flush() {
            if run.count >= 3 { rows.append(.steps(run)) } else { rows += run.map(Row.item) }
            run = []
        }
        for item in items {
            if item.kind == .tool { run.append(item) } else { flush(); rows.append(.item(item)) }
        }
        flush()
        return rows
    }

    /// Keeps up with new output only while you're at the bottom, so reading older output isn't interrupted.
    private func follow(_ proxy: ScrollViewProxy, rows: [Row], sent: Bool = false) {
        let tail = [nil, "bottom"] + rows.suffix(2).map { Optional($0.id) }
        guard sent || tail.contains(atBottom) else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }
}

/// A folded run of tool calls: one line with the count, expandable to every step.
struct StepsView: View {
    let steps: [Item]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("\(steps.count) steps")
                        .fontWeight(.medium)
                    let failures = steps.filter(\.failed).count
                    if failures > 0 {
                        Text("· \(failures) failed").foregroundStyle(.red)
                    }
                    Text("· " + Self.summary(steps))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(steps) { ItemView(item: $0) }
                    .padding(.leading, 14)
            }
        }
    }

    /// "Read, Edit, $ npm test" — the distinct kinds of work, in order.
    private static func summary(_ steps: [Item]) -> String {
        var seen = Set<String>()
        return steps.map { $0.text.split(separator: " ").first.map(String.init) ?? $0.text }
            .filter { seen.insert($0).inserted }
            .prefix(5)
            .joined(separator: ", ")
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

/// What an agent is waiting on: Allow / Deny for one action, or its questions with one-click answers.
struct AskCard: View {
    let ask: Ask
    let respond: (_ allow: Bool, _ answers: [String: String]) -> Void
    @State private var answers: [String: String] = [:]

    init(ask: Ask, respond: @escaping (_ allow: Bool, _ answers: [String: String]) -> Void) {
        self.ask = ask
        self.respond = respond
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ask.questions.isEmpty ? "hand.raised.fill" : "questionmark.bubble.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                if ask.questions.isEmpty {
                    Text("Permission needed")
                        .font(.headline)
                    Text(ask.title)
                        .font(.callout.monospaced())
                        .lineLimit(4)
                        .textSelection(.enabled)
                    if !ask.detail.isEmpty {
                        Text(ask.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                    }
                } else {
                    Text(ask.title)
                        .font(.headline)
                    ForEach(ask.questions) { q in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(q.text)
                            ViewThatFits(in: .horizontal) {
                                HStack { options(q) }
                                VStack(alignment: .leading) { options(q) }
                            }
                            TextField("Or type an answer", text: Binding(get: { answers[q.id] ?? "" }, set: { answers[q.id] = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { if answers.count == ask.questions.count { respond(true, answers) } }
                        }
                    }
                }
            }
            Spacer(minLength: 12)
            if ask.questions.isEmpty {
                Button("Deny") { respond(false, [:]) }
                Button("Allow") { respond(true, [:]) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Skip") { respond(false, [:]) }
                Button("Send") { respond(true, answers) }
                    .buttonStyle(.borderedProminent)
                    .disabled(answers.values.filter { !$0.trimmed.isEmpty }.count < ask.questions.count)
            }
        }
        .padding(14)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.35)))
        .frame(maxWidth: 788)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func options(_ q: Ask.Question) -> some View {
        ForEach(q.options, id: \.self) { option in
            Button(option) {
                answers[q.id] = option
                if ask.questions.count == 1 { respond(true, answers) }  // one question: picking is answering
            }
            .buttonStyle(.bordered)
            .tint(answers[q.id] == option ? .accentColor : nil)
        }
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
    @AppStorage("access") private var access: Access = .ai

    init(agent: Agent, running: Bool = false, placeholder: String,
         onSend: @escaping (String) -> Void, onStop: @escaping () -> Void = {}) {
        self.agent = agent
        self.running = running
        self.placeholder = placeholder
        self.onSend = onSend
        self.onStop = onStop
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...12)
                .focused($focused)
                .onSubmit(send)
            HStack {
                Picker("Access", selection: $access) {
                    ForEach(Access.allCases) { Label($0.name, systemImage: $0.icon).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("What \(agent.name) may do without asking. AI decides: its own reviewer approves; you see what it escalates.")
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
