import SwiftUI
import AppKit

// Isolates the few AppKit escape hatches the UI needs (global key handling
// and resigning text-field focus) behind SwiftUI modifiers, so views stay
// declarative and the event monitor's lifecycle is managed correctly.

extension View {
    /// Invokes `action` on Delete / Forward-Delete, unless a text field is
    /// being edited and only while `isEnabled` returns true. The underlying
    /// local event monitor is added and removed with the view, so it can't
    /// leak the way a bare `addLocalMonitorForEvents` in `onAppear` would.
    func onDeleteKey(isEnabled: @escaping () -> Bool,
                     perform action: @escaping () -> Void) -> some View {
        modifier(DeleteKeyMonitor(isEnabled: isEnabled, action: action))
    }

    /// Push-style performance launching from the computer keyboard (see
    /// `TransportEngine.performLaunchKey`). Unmodified keys only, and never
    /// while a text field is being edited — so ⌘-shortcuts and typing (track
    /// rename, effect search, tempo entry) are untouched.
    func onSessionLaunchKeys(_ engine: TransportEngine) -> some View {
        modifier(LaunchKeyMonitor(engine: engine))
    }

    /// Drops keyboard focus from an editing text field when the view is
    /// tapped — but only while a field is actually being edited, so it
    /// doesn't churn the responder chain on every click.
    func resignsTextFieldFocusOnTap() -> some View {
        simultaneousGesture(TapGesture().onEnded {
            DispatchQueue.main.async {
                guard let window = NSApp.keyWindow,
                      window.firstResponder is NSTextView else { return }
                window.makeFirstResponder(nil)
            }
        })
    }
}

private struct LaunchKeyMonitor: ViewModifier {
    let engine: TransportEngine
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // Leave modifier chords and text editing alone; only plain
                    // keys perform launches.
                    let modified = !event.modifierFlags
                        .intersection([.command, .option, .control]).isEmpty
                    let editingText = NSApp.keyWindow?.firstResponder is NSTextView
                    guard !modified, !editingText,
                          let character = event.charactersIgnoringModifiers?.first,
                          engine.performLaunchKey(character) else { return event }
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

private struct DeleteKeyMonitor: ViewModifier {
    let isEnabled: () -> Bool
    let action: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let isDeleteKey = event.keyCode == 51 || event.keyCode == 117
                    let editingText = NSApp.keyWindow?.firstResponder is NSTextView
                    guard isDeleteKey, !editingText, isEnabled() else { return event }
                    action()
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
