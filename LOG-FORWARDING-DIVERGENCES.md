# Log forwarding: divergences from the plan

Every place the iOS implementation departs from
`mobile/shared/plans/client-log-forwarding.md`, what the plan says, what was built, and why.
Casing, concurrency primitive and struct-versus-class choices are not listed: those were ratified as
the implementation's own.

## Names

### `Formatter` is `LogFormatter`

**Plan**: the component is named `Formatter`.

**Built**: `LogFormatter`.

**Why**: `Formatter` is a Foundation class, the base of `DateFormatter` and `NumberFormatter`. A
module-level `Formatter` would shadow it everywhere in the app target. `format`, `pack` and
`hasReEncoding` keep their names.

## Shapes the plan under-specifies

### `Frame` carries the first record it traversed

**Plan**: the meta record is "timestamped at the first record the frame traversed, kept or
filtered", and `Frame` has no field for it.

**Built**: `Frame.firstLocalTime` and `Frame.firstTimezone`.

**Why**: the formatter is given only the frame. `records` holds kept records only, so an all-filtered
frame, or one whose first traversed record was filtered, has no way to supply that instant. Where a
frame traversed no record at all, which is a frame reporting `lostBytes` alone, the meta record falls
back to the device's current local time.

### `RenderedFrame` carries the frame id, and `Outbox.write` takes it

**Plan**: `Outbox.write(frame, bodies)`, and the staging directory is `temp-<frame-id>/`.

**Built**: `RenderedFrame.frameId`, and `Outbox.write(frameId:bodies:)`.

**Why**: the frame id is computed by the formatter from the rendered records. A `Frame` does not
carry it and the outbox cannot derive it.

### `Cursor.Complete` takes the file size

**Plan**: `Complete: Bool { get; private set } // derived: a successor exists and the COMMITTED
offset is at EOF`.

**Built**: `Cursor.isComplete(fileSize:)`.

**Why**: EOF is a fact about the file, not about the document, and the cursor document deliberately
does not store it. The reader has an open descriptor and supplies the size.

### `FileId` is reconstructed from its rendering

**Plan**: `FileId` is "opaque, platform-sourced ... Equality and rendering only: never parsed".

**Built**: `FileId(rendered:)`, used only when reading a persisted document.

**Why**: the cursor document stores `file` and `successor` as the rendered string, and the state
entry names the active cursor the same way. Resuming after a process death means turning those back
into something comparable with an observed inode. The parse is of this platform's own rendering and
is never applied to a value from elsewhere.

### Constructor dependencies

**Plan**: `LogReader(dir, prefix, extractor, declaredTimezone, softLimit)`,
`Dispatcher(outbox, destination)`, `LogForwarder(reader, formatter, outbox, dispatcher,
maxPostBytes)`.

**Built**: the reader also takes the documents directory and the state entry; the dispatcher also
takes the dispatch document, the app group identifier and `max_backoff`; the forwarder also takes the
state entry and its settings.

**Why**: persistence and the three documents have to reach the components that write them, and the
plan does not say how they are handed over. `supersede(settings:)` keeps its signature: the
unprefixed `[log_forwarding]` scalars are applied to the component that owns each one (the
dispatcher's `destination` and `max_backoff`, the reader's `softLimit`, the forwarder's
`maxPostBytes`), so superseding needs only the forward settings.

### `ForwarderConfig`

**Plan**: names the unprefixed keys, and gives `ForwardSettings` only `default`, `levels` and `tags`.

**Built**: a `ForwarderConfig` struct holding `url`, `settings`, `softLimit`, `maxPostBytes`,
`foregroundInterval`, `backgroundInterval` and `maxBackoff`, loaded from a `Config`.

**Why**: the plan assigns the unprefixed keys to no type. Keeping them out of `ForwardSettings` keeps
`requiresReplay` comparing thresholds and nothing else.

## Behaviour

### `lostBytes` after a destroyed inode is an estimate

**Plan**: on both "inode needed, not present" rows, "restart at `1.log` offset 0, report
`lostBytes`".

**Built**: `lostBytes` is `log_collection_max_file_size` minus the cursor's committed offset when our
own file was unlinked, and the whole of `log_collection_max_file_size` when a recorded successor was
destroyed before any of it was read. `LogReader` reads `Core.getLogCollectionMaxFileSize` for this,
a dependency its constructor does not declare.

**Why**: the destroyed file is gone, so its size at unlink cannot be measured and the unread tail
cannot be counted. Rotation fires when the file passes `max_file_size`, so that setting is the only
available stand-in. The alternative, reporting zero, would make the gap invisible to
`| tag="forwarder" | lost_bytes!="0"`, which is the query the field exists for. A reader of
`lost_bytes` on an iOS meta record should treat a value arising from a destroyed inode as "a gap of
about this size" rather than as a count. The `[forwarder]` WARNING written alongside it names the
file and the committed offset, which are facts.

### The dropped-body report names the body, not the cursor range

**Plan**: "The forwarder logs the drop at `WARNING` through the normal logging API, naming the cursor
range and record count."

**Built**: the WARNING names the status code and the body's content hash.

**Why**: a body is dropped from inside the transport's completion, where the only thing to hand is
the file. Recovering the cursor range would mean decompressing and parsing the body to read its meta
record, which a split body does not carry at all. The outbox directory is the frame id, so the drop
is still attributable to one frame.

### `requiresReplay` answers conservatively across namespaces

**Plan**: "does next admit anything these settings did not?"

**Built**: exact where both sides have a rule of the same kind. Where `next` adds a tag rule that the
old settings had none for, it compares against the lowest threshold the old settings could have
applied; where `next` drops a tag rule the old settings had, it compares the highest threshold `next`
could apply.

**Why**: a tag rule's counterpart is "whatever subsystem threshold that record would have fallen to",
which is not a single value. Erring towards replaying costs re-sent records; erring the other way
loses the records the escalation was asked for.

### Backoff shape

**Plan**: "a dispatch failure pushes `notBefore` out exponentially with jitter, capped at
`max_backoff`".

**Built**: two seconds to the power of the consecutive-failure count, capped at `max_backoff`, then
multiplied by a random factor in 0.5 to 1.0. An outage is reported as ended when the uncapped value
has reached `max_backoff`.

**Why**: the plan fixes neither the base nor the jitter distribution. Recorded because the numbers
should match Android's and nothing in the plan makes them.

### `Retry-After` is read as delta-seconds only

**Plan**: "`Retry-After` sets the delay".

**Built**: a non-numeric `Retry-After` (the HTTP-date form) is ignored and the computed backoff
stands.

### The 413 split re-dispatches off the session's delegate queue

**Plan**: "a 413 splits and dispatches the directory that returns".

**Built**: the re-dispatch is hopped onto a global queue.

**Why**: `dispatch` consults `inFlight()`, which round-trips through `URLSession.getAllTasks`, whose
reply is delivered on the same serial delegate queue the outcome arrived on. Calling it inline would
deadlock.

### `drain()` is a query round-trip

**Plan**: "apply outcomes the platform buffered while we were not running, before `inFlight` is
consulted".

**Built**: `getAllTasks` with a bounded wait.

**Why**: there is no API that reports "every buffered outcome has been delivered". The session's
delegate queue is serial, so a reply to a query posted now is ordered behind every delegate callback
already on it, which is the same guarantee by construction. The wait is bounded at ten seconds so a
wedged session cannot hold a run open.

### The background task takes no network or power constraint

**Plan**: on iOS, "there is nothing here for the forwarder to decide about connectivity", because
background sessions always wait for it.

**Built**: `BGProcessingTaskRequest` is submitted with neither `requiresNetworkConnectivity` nor
`requiresExternalPower` set.

**Why**: reading, rendering and making bodies durable are worth doing with no network, and the
session holds the hand-over until there is one. Requiring connectivity would defer the read as well
as the send.

## Encoding and platform mechanics

### gzip is hand-framed over the Compression framework

**Plan**: bodies are gzipped.

**Built**: the gzip header and trailer are written by hand around `COMPRESSION_ZLIB`, which is raw
DEFLATE, with a table-driven CRC-32.

**Why**: iOS exposes no zlib module to Swift, and the Compression framework emits no container.

### A split body is re-serialised by `JSONSerialization`

**Plan**: "decompress, halve logRecords, keep Resource".

**Built**: exactly that, through `JSONSerialization`, so the two halves carry the keys in that
serialiser's order rather than the formatter's.

**Why**: no byte-identity requirement reaches a split body. The frame id was computed before the
split and is already embedded in every record.

### Tag normalisation keeps Unicode letters and digits

**Plan**: "the tag lowercased with non-alphanumerics removed".

**Built**: `Character.isLetter || Character.isNumber`, which admits non-ASCII letters.

**Why**: matches what Kotlin's `isLetterOrDigit` would do on the other platform. Every tag observed
in the captures is ASCII, so the two readings differ only on content neither platform has seen.

### `max_post_bytes` has a floor

**Plan**: gives a minimum for `foreground_interval` only.

**Built**: `max_post_bytes` is floored at 1024 bytes.

**Why**: a value below the envelope's own size would produce bodies that cannot hold one record and a
`pack` that never terminates usefully.

## Work the plan describes as already done

### `Log.swift` did not set `linphone-app`

**Plan**: "The app layer adds one more, `linphone-app`, set at runtime rather than compiled in: on
iOS at `Linphone/Utils/Log.swift:46` ... replacing the bundle identifier".

**Found**: that line set `LoggingService.domain` to `Bundle.main.bundleIdentifier`, so the app layer
wrote two subsystems, one per process, and neither was `linphone-app`.

**Built**: `Log.domain`, a constant, now assigned there. `Log.output`, which feeds `os_log` and
Crashlytics rather than the log file, is untouched.

### Capture level

The plan says `CoreContext.swift:178` already sets `LogLevel.Debug`. It does, now at line 185.
`msgNotificationService` sets the same. Neither needed changing.
