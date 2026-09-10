# libcurl and serialized cancellation

Research date: 2026-09-08. Status: evidence for an architecture candidate, not an accepted amendment or runtime test. The candidate uses curl's multi interface; this does not describe the existing OnePage easy-interface implementation.

## Finding

One owner can order completion and cancellation locally. libcurl does not force OnePage to accept competing late results or introduce a separate result-arbitration layer. This is an architectural inference from the APIs below, not a guarantee supplied by curl about OnePage's database or event queues.

## What curl guarantees

- Removing an active easy handle from its multi handle halts that transfer and removes it from the multi's control. Removal must happen outside libcurl callbacks. It is a direct API operation, not a request to await a later completion message. A connection can remain in the multi's pool for reuse; transfer removal does not imply every socket closes. [Removal API](https://curl.se/libcurl/c/curl_multi_remove_handle.html)
- Easy cleanup frees the easy handle's resources, and the handle is unusable afterward. Remove it from the multi first. Cleanup can invoke configured progress or header callbacks for some protocols, so callback context must remain alive through the call. [Easy cleanup](https://curl.se/libcurl/c/curl_easy_cleanup.html)
- A completion-message pointer becomes invalid after removal or cleanup. Copy any required status before those operations; do not retain that pointer in an application queue. [Completion messages](https://curl.se/libcurl/c/curl_multi_info_read.html)
- Multi cleanup closes its pooled connections and can invoke socket callbacks. Easy handles must be separately removed and cleaned first. Multi-owned caches and connections therefore have a different lifetime from one request. [Multi cleanup](https://curl.se/libcurl/c/curl_multi_cleanup.html)
- A handle must not be used concurrently from multiple threads. A single owner satisfies that constraint; another thread can send the owner a cancellation command rather than manipulate its handle. [Thread safety](https://curl.se/libcurl/c/threadsafe.html)

The release-tagged source corroborates an important callback detail: `curl_multi_remove_handle` can call `multi_done`, which can invoke `Curl_pgrsDone`, finish client writes and update event handling. Cancellation must disable application result publication before calling removal, rather than assuming removal executes no callbacks. [curl 8.20.0 multi.c, removal and multi_done](https://github.com/curl/curl/blob/curl-8_20_0/lib/multi.c#L639-L863). This tag is a source snapshot, not a selected OnePage dependency version.

## Small candidate lifecycle

1. The same owner handles completion and cancellation at explicit event boundaries, outside curl callbacks.
2. If completion is handled first, copy its status and finish the ordinary result path.
3. If cancellation is handled first, mark the request unable to publish a result; remove it from curl, check the removal result, and clean up the easy handle. Keep callback context valid throughout.
4. Discard any application-owned completion already staged for that cancelled request. The simplest design avoids a second asynchronous completion publisher entirely.
5. Release request buffers, scratch and request capacity once those resources actually end. Retain separately budgeted runtime-owned resources until their own cleanup boundary.

This ordering is OnePage's responsibility. A curl callback should collect transport data, not independently publish an authoritative durable outcome. A process crash between local cancellation and saving interruption still requires the existing recovery policy; serialization does not make memory and durable storage atomic.

## Limit of synchronous cancellation

Easy cleanup is not proof that all transport-related process resources have vanished. In particular, even `curl_global_cleanup` does not wait for curl-created resolver threads to terminate. A bundled resolver configuration needs its own resource-accounting evidence before request-slot release can stand for total memory release. This is a bounded-resource question, not a reason to permit late result publication. [Global cleanup warning](https://curl.se/libcurl/c/curl_global_cleanup.html)

Stopping local delivery also cannot establish that a provider stopped processing a request it already received. That external uncertainty survives even with perfectly serialized local decisions.

## Conclusion and remaining evidence

Prefer one local execution owner and straightforward request teardown. Keep result ownership separate from resource lifetimes only where the resource actually persists, such as pooled connections or resolver work. Do not generalize these HTTP findings to Bash process cleanup or uncertain filesystem effects.

No code or tests were run. Implementation evidence still needs cancellation during DNS, connect, streaming and queued completion; callback-context lifetime checks; and resource measurements for the selected pinned curl/resolver/TLS build. These checks can establish the candidate lifecycle without presupposing a general late-result arbitration framework.
