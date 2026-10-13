//
//  ProxyProbeView.swift
//  ReplayHost — host side of the proxy-staleness probe (PROXY_PROBE=1)
//
//  A real UITextView (the same class of host as a message composer),
//  prefilled with PROBE_TEXT, that publishes its TRUE state through
//  accessibility: the text before the caret and the full text. The UI test
//  compares that with what the keyboard believes (the quoted literal slot in
//  the suggestion bar is the keyboard's current word, read straight from
//  `documentContextBeforeInput`). A disagreement is a stale proxy.
//
//  PROBE_JITTER_MS (optional): the host itself moves the caret between two
//  mid-text offsets on a timer, so a keystroke from the test can land inside
//  the window between a host selection change and the proxy's refresh.
//

import SwiftUI
import UIKit

struct ProxyProbeView: View {
    @State private var before = ""
    @State private var full = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProbeTextView(before: $before, full: $full)
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
            Text(before.isEmpty ? " " : before)
                .accessibilityIdentifier("probe-before")
                .font(.caption2.monospaced())
                .lineLimit(2)
            Text(full.isEmpty ? " " : full)
                .accessibilityIdentifier("probe-full")
                .font(.caption2.monospaced())
                .lineLimit(2)
            Spacer()
        }
        .padding()
    }
}

private struct ProbeTextView: UIViewRepresentable {
    @Binding var before: String
    @Binding var full: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .systemFont(ofSize: 20)
        view.backgroundColor = .clear
        view.autocorrectionType = .default
        view.autocapitalizationType = .sentences
        view.accessibilityIdentifier = "probe-input"
        view.delegate = context.coordinator
        view.text = ProcessInfo.processInfo.environment["PROBE_TEXT"] ?? ""
        context.coordinator.view = view
        DispatchQueue.main.async {
            view.becomeFirstResponder()
            context.coordinator.publish()
            context.coordinator.startJitterIfRequested()
        }
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {}

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: ProbeTextView
        weak var view: UITextView?
        private var timer: Timer?
        private var flip = false

        init(_ parent: ProbeTextView) { self.parent = parent }

        func publish() {
            guard let view else { return }
            let text = view.text ?? ""
            let caret = view.selectedRange.location
            let ns = text as NSString
            parent.before = ns.substring(to: min(caret, ns.length))
            parent.full = text
        }

        func textViewDidChange(_ textView: UITextView) { publish() }
        func textViewDidChangeSelection(_ textView: UITextView) { publish() }

        /// Move the caret back and forth between the end of two words.
        func startJitterIfRequested() {
            guard
                let ms = ProcessInfo.processInfo.environment["PROBE_JITTER_MS"].flatMap(Double.init),
                ms > 0
            else { return }
            var remaining = ProcessInfo.processInfo.environment["PROBE_JITTER_COUNT"].flatMap(Int.init) ?? 40
            timer = Timer.scheduledTimer(withTimeInterval: ms / 1000, repeats: true) { [weak self] timer in
                guard let self, let view = self.view else { return }
                remaining -= 1
                if remaining < 0 { timer.invalidate(); return }
                let ns = (view.text ?? "") as NSString
                let spaces = (0..<ns.length).filter { ns.character(at: $0) == 0x20 }
                guard spaces.count >= 6 else { return }
                self.flip.toggle()
                let target = self.flip ? spaces[spaces.count - 3] : spaces[spaces.count - 5]
                view.selectedRange = NSRange(location: target, length: 0)
            }
        }
    }
}
