import Foundation
import os

private final class GeminiEphemeralTokenPendingWait: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<GeminiEphemeralToken, Error>?
        var result: Result<GeminiEphemeralToken, Error>?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func install(
        _ continuation: CheckedContinuation<GeminiEphemeralToken, Error>
    ) {
        let result = lock.withLock { state -> Result<GeminiEphemeralToken, Error>? in
            if let result = state.result {
                return result
            }
            state.continuation = continuation
            return nil
        }
        if let result {
            continuation.resume(with: result)
        }
    }

    @discardableResult
    func resolve(_ result: Result<GeminiEphemeralToken, Error>) -> Bool {
        let continuation = lock.withLock { state -> CheckedContinuation<
            GeminiEphemeralToken,
            Error
        >? in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
        return continuation != nil
    }
}

actor GeminiEphemeralTokenProvider {
    typealias MintOperation = @Sendable (Date) async throws -> GeminiEphemeralToken

    private struct InFlight {
        let id: UUID
        let task: Task<GeminiEphemeralToken, Error>
        var waiterIDs: Set<UUID>
    }

    private let now: @Sendable () -> Date
    private let refreshMargin: TimeInterval
    private let mintOperation: MintOperation
    private var cachedToken: GeminiEphemeralToken?
    private var inFlight: InFlight?

    init(
        apiKey: String,
        transport: HardenedAITransport = .ephemeralToken,
        now: @escaping @Sendable () -> Date = { Date() },
        refreshMargin: TimeInterval = 15
    ) {
        let client = GeminiEphemeralTokenClient(
            apiKey: apiKey,
            transport: transport
        )
        self.now = now
        self.refreshMargin = refreshMargin
        self.mintOperation = { date in
            try await client.mint(at: date)
        }
    }

    init(
        now: @escaping @Sendable () -> Date,
        refreshMargin: TimeInterval,
        mint: @escaping MintOperation
    ) {
        self.now = now
        self.refreshMargin = refreshMargin
        self.mintOperation = mint
    }

    func token() async throws -> String {
        let requestedAt = now()
        if let cachedToken,
           cachedToken.newSessionExpireTime.timeIntervalSince(requestedAt) > refreshMargin {
            return cachedToken.name
        }
        cachedToken = nil

        let waiterID = UUID()
        let flight: InFlight
        if var existing = inFlight {
            existing.waiterIDs.insert(waiterID)
            inFlight = existing
            flight = existing
        } else {
            let flightID = UUID()
            let mintOperation = self.mintOperation
            let task = Task {
                try await mintOperation(requestedAt)
            }
            let created = InFlight(
                id: flightID,
                task: task,
                waiterIDs: [waiterID]
            )
            inFlight = created
            flight = created
        }

        return try await withTaskCancellationHandler {
            do {
                let mintedToken = try await awaitMint(flight.task)
                try Task.checkCancellation()
                return try finishSuccess(
                    mintedToken,
                    flightID: flight.id,
                    waiterID: waiterID
                )
            } catch is CancellationError {
                finishCancellation(flightID: flight.id, waiterID: waiterID)
                throw CancellationError()
            } catch {
                finishFailure(flightID: flight.id, waiterID: waiterID)
                throw GeminiEphemeralTokenError.requestFailed
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    flightID: flight.id,
                    waiterID: waiterID
                )
            }
        }
    }

    private func awaitMint(
        _ task: Task<GeminiEphemeralToken, Error>
    ) async throws -> GeminiEphemeralToken {
        let pending = GeminiEphemeralTokenPendingWait()
        Task {
            do {
                pending.resolve(.success(try await task.value))
            } catch {
                pending.resolve(.failure(error))
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
                if Task.isCancelled {
                    pending.resolve(.failure(CancellationError()))
                }
            }
        } onCancel: {
            pending.resolve(.failure(CancellationError()))
        }
    }

    private func finishSuccess(
        _ token: GeminiEphemeralToken,
        flightID: UUID,
        waiterID: UUID
    ) throws -> String {
        guard GeminiEphemeralToken.isValidName(token.name),
              token.newSessionExpireTime.timeIntervalSince(now()) > refreshMargin else {
            finishFailure(flightID: flightID, waiterID: waiterID)
            throw GeminiEphemeralTokenError.invalidToken
        }
        cachedToken = token
        removeWaiter(flightID: flightID, waiterID: waiterID, cancelIfEmpty: false)
        return token.name
    }

    private func finishFailure(flightID: UUID, waiterID: UUID) {
        cachedToken = nil
        removeWaiter(flightID: flightID, waiterID: waiterID, cancelIfEmpty: false)
    }

    private func finishCancellation(flightID: UUID, waiterID: UUID) {
        removeWaiter(flightID: flightID, waiterID: waiterID, cancelIfEmpty: true)
    }

    private func cancelWaiter(flightID: UUID, waiterID: UUID) {
        removeWaiter(flightID: flightID, waiterID: waiterID, cancelIfEmpty: true)
    }

    private func removeWaiter(
        flightID: UUID,
        waiterID: UUID,
        cancelIfEmpty: Bool
    ) {
        guard var current = inFlight, current.id == flightID else { return }
        current.waiterIDs.remove(waiterID)
        if current.waiterIDs.isEmpty {
            if cancelIfEmpty {
                current.task.cancel()
            }
            inFlight = nil
        } else {
            inFlight = current
        }
    }
}
