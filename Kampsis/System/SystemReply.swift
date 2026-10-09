import Foundation
import Synchronization

/// один ответ системного API; закрытый запрос не принимает поздние или повторные ответы
final class SystemReply<Value: Sendable, Failure: Error & Sendable>: Sendable {
    private struct State {
        var result: Result<Value, Failure>?
        var closed = false
    }

    private let state = Mutex(State())

    @discardableResult func finish(_ result: Result<Value, Failure>) -> Bool {
        state.withLock { state in
            guard !state.closed, state.result == nil else { return false }
            state.result = result
            return true
        }
    }

    /// отмена не ждёт неотвечающий callback; срок охватывает весь запрос, а не только первый кадр
    func wait(until deadline: ContinuousClock.Instant, timeout: Failure) async throws -> Value {
        do {
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw timeout }
                if let result = state.withLock({ $0.result }) { return try result.get() }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            state.withLock { state in
                state.closed = true
                state.result = nil
            }
            throw error
        }
    }
}

typealias CaptureReply<Value: Sendable> = SystemReply<Value, CaptureTrouble>

extension SystemReply where Failure == CaptureTrouble {
    func wait(until deadline: ContinuousClock.Instant, operation: CaptureOperation) async throws -> Value {
        try await wait(until: deadline, timeout: captureTrouble(CaptureFailure.timedOut(operation)))
    }
}

enum CaptureOperation: String, Sendable {
    case displays
    case start
    case snapshot
    case stop
}
