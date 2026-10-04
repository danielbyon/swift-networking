# Combine Bridges

Combine publishers are available only when the platform provides Combine. They are a compatibility layer; the async `send` and `NetworkTask` APIs remain canonical.

```swift
#if canImport(Combine)
import Combine

let responsePublisher = client.publisher(for: request)
let responseCancellable = responsePublisher.sink(
    receiveCompletion: { completion in
        // Handle completion.
    },
    receiveValue: { response in
        // Use response.value.
    }
)

let task = client.task(for: request)
let valueCancellable = task.valuePublisher.sink(
    receiveCompletion: { _ in },
    receiveValue: { response in print(response.value) }
)
let progressCancellable = task.progressPublisher.sink(
    receiveCompletion: { _ in },
    receiveValue: { progress in print(progress) }
)
#endif
```

`NetworkClient.publisher(for:)` is cold: each subscription starts and owns a new task, and cancelling that subscription cancels its task. Each subscription to `NetworkTask.valuePublisher` owns an independent waiter; cancelling a waiter does not cancel the shared task. `progressPublisher` observes the task's replaying, coalesced latest-state progress. Cancelling a progress subscription stops that subscriber without cancelling the operation.

Progress failures and cancellation finish the publisher normally rather than emitting a successful terminal progress state. The response publisher reports request failures through its normal Combine failure channel.
