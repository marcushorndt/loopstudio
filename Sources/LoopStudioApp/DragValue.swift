import AppKit
import SwiftUI

/// A number field that a drag changes, like in Final Cut Pro: a press shows the up/down pointer, a drag up or
/// down steps the value (Shift: finer), and a click without a move puts the focus in the field with the whole
/// value marked, ready to type over. While the field has the focus, clicks are the field's own.
struct DragValueModifier: ViewModifier {
    var focus: FocusState<Bool>.Binding
    let pixelsPerStep: CGFloat
    let step: (Int, Bool) -> Void
    @State private var pressed = false
    @State private var moved = false
    @State private var done = 0

    func body(content: Content) -> some View {
        content.overlay {
            if !focus.wrappedValue {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { g in
                            if !pressed { pressed = true; NSCursor.resizeUpDown.push() }
                            NSCursor.resizeUpDown.set()
                            if abs(g.translation.height) > 2 || abs(g.translation.width) > 2 { moved = true }
                            let n = Int(-g.translation.height / pixelsPerStep)
                            if n != done { step(n - done, NSEvent.modifierFlags.contains(.shift)); done = n }
                        }
                        .onEnded { _ in
                            if pressed { NSCursor.pop() }
                            pressed = false
                            done = 0
                            if !moved {
                                focus.wrappedValue = true
                                DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil) }
                            }
                            moved = false
                        })
            }
        }
    }
}

/// The up/down pointer for as long as a press lasts, from the press on: a value that a vertical drag changes.
struct PressCursorModifier: ViewModifier {
    @State private var pressed = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !pressed { pressed = true; NSCursor.resizeUpDown.push() }
                NSCursor.resizeUpDown.set()
            }
            .onEnded { _ in if pressed { NSCursor.pop() }; pressed = false })
    }
}

extension View {
    func dragsValue(focus: FocusState<Bool>.Binding, pixelsPerStep: CGFloat = 4, step: @escaping (Int, Bool) -> Void) -> some View {
        modifier(DragValueModifier(focus: focus, pixelsPerStep: pixelsPerStep, step: step))
    }

    func upDownCursorWhilePressed() -> some View { modifier(PressCursorModifier()) }
}
