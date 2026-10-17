# Sync lifecycle and background refresh

## Foreground ownership

`AppModel` owns app-wide refresh work through `AppSyncLifecycle`. Startup,
the initial active-scene callback, and the Study screen can arrive together.
They now share startup rather than independently restoring authentication or
starting study sync before capability loading completes.

After startup, concurrent refreshes of the same kind join the existing task.
An authenticated full refresh also satisfies a simultaneous foreground or
Study-screen refresh for the same account and credential. Different accounts
or replacement credentials wait and run their own guarded operation. A Study
screen refresh keeps its existing 60-second freshness policy; foreground
refresh keeps its existing domain policies. The lifecycle adds no freshness
window, including after failure.

Refresh tasks belong to the app lifecycle. A view disappearing or cancelling
its waiter does not cancel authentication or uploads shared by other callers.
Account checks in `AppModel` and activation generations in the stores still
prevent stale responses from publishing into a replacement account.

The regression tests exercise concurrent starts, capability ordering, account
and credential changes, cancellation of a view waiter, and subsequent retries.
The integrated startup test checks that repeated startup/active callbacks issue
one authentication verification and one capability request, while the Study
screen waits for that authority before requesting the card feed.

## Background refresh investigation

The app currently requests background audio playback only. It does not promise
scheduled background synchronization. `BGAppRefreshTask` would be the right
eventual mechanism for short metadata refreshes: Apple gives it up to 30
seconds and chooses when to run it. An earliest start date is a lower bound,
not a repeat interval or delivery guarantee. See Apple's
[background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
and [earliestBeginDate](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate).

Registering that task against today's complete sync would be unsafe. The card,
review, action, draft, and study-time outboxes own independent Swift tasks, and
waiting on their values does not propagate parent cancellation. Some requests
can last 45 seconds. Expiring a background caller therefore cannot currently
guarantee that its uploads stop before iOS suspends or terminates the app.

A follow-up needs ownership-aware cancellation of these shared operations and
an expiration test that proves requests actually stop while committed pages,
checkpoints, and pending mutations remain durable. It should then register a
bounded metadata-only task, enable background fetch, reschedule after a run,
and skip signed-out or unavailable protected storage. Daily Audio generation,
media downloads, recaps, and analytics should stay outside that short budget.
SwiftUI's [backgroundTask handler](https://developer.apple.com/documentation/swiftui/scene/backgroundtask(_:action:))
reports expiration through task cancellation; merely returning from an outer
timeout without cancelling the underlying work is insufficient.
