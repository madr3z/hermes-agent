import Foundation
import Observation

/// Retains the outgoing conversation when the call screen is minimized or chat navigation changes.
@MainActor @Observable final class CallPresentation {
    static let shared = CallPresentation()
    var outgoing: ChatStore?
    var isPresented = false
    func open(_ chat: ChatStore) {
        if outgoing !== chat { outgoing?.voice.stop() }
        outgoing = chat; isPresented = true
    }
    func closeScreen() {
        isPresented = false
        if outgoing?.voice.active != true && outgoing?.voice.connecting != true { outgoing = nil }
    }
}

enum CallDestination: Identifiable {
    case incoming(UUID)
    case outgoing(ChatStore)
    var id: String {
        switch self {
        case .incoming(let id): return "incoming-" + id.uuidString
        case .outgoing(let chat): return "outgoing-" + String(describing: ObjectIdentifier(chat))
        }
    }
}
