# Progress and Cancellation

Create a ``NetworkTask`` when work needs progress or explicit shared-operation cancellation. Its `value` is the eventual response; its `progress` sequence reports the latest upload or download state.

```swift
let task = client.task(for: request)

for await update in task.progress {
    print(update)
}

let response = try await task.value
```

Progress is a replaying multicast latest-state stream, not a complete event history. Each subscriber can receive the latest value, and intermediate values may be coalesced. A successful terminal progress state is emitted only after the logical operation succeeds. Failed or cancelled operations finish without a successful terminal state.

Cancelling a task value waiter or one progress subscriber only ends that wait or subscription. It does not cancel the shared network operation. Call `task.cancel()` to cancel the operation itself; that cancellation is observed by all waiters and subscribers.

For task-owned Combine publishers, see <doc:CombineBridges>. A publisher returned by `NetworkClient.publisher(for:)` instead creates and owns a separate task for each subscription.
