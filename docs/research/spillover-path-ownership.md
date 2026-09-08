# Spillover paths and temporary-file ownership

Research date: 2026-09-07. Design check against the current working-tree contract, not an accepted amendment or implementation proof. No runtime or normative documents changed.

## Conclusion

Ordinary absolute spillover paths read through arbitrary same-user Bash cannot satisfy all current guarantees without an additional access boundary. The conflict is substantive: the Host cannot observe every reader, stop every writable alias, or infer final release from unlinking a name. A scoped change to the guarantees is smaller than an enforced filesystem/reader mechanism, but requires an explicit decision.

The current [architecture](../../ARCHITECTURE.md#tool-output-and-spillover) selects ordinary paths and Bash retrieval. Its [temporary-file contract](../../ARCHITECTURE.md#shared-temporary-file-retention) protects outstanding reads, counts all concurrently held logical bytes against 8 GiB, prohibits growth outside the owner, and returns credit only after safe final release. It also accepts crash loss. Crash loss does not imply that an unlinked file's storage or its external handles have been released.

## Platform facts

- Removing the last pathname does not destroy an open file. Its resources are reclaimed after all references close. Thus unlinking an output while a reader holds it normally preserves that reader's bytes, but does not establish storage release. [Apple `unlink(2)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/unlink.2.html).
- The owning user may change a file's permissions with `chmod` or `fchmod`. A read-only mode on a same-user spillover file is an accident guard, not enforcement against Bash restoring write access. A private directory owned by that same user has the same limitation. [Apple `chmod(2)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/chmod.2.html).
- An ordinary open returns a descriptor; append/truncate/write access depends on the requested flags. Descriptors can survive execution of another program. `O_EXCL` and `O_NOFOLLOW` help the Host create/open the expected name; they do not govern later external opens. [Apple `open(2)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/open.2.html).
- File locks are advisory: a process may access the file without participating. Descriptor duplication and fork can retain references. The locally installed macOS SDK's `fork(2)` also specifies shared open-file descriptions inherited by the child. Neither ordinary `grep` nor arbitrary descendants acquire a Host read lease automatically. [Apple `flock(2)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html). The archived Apple pages were cross-checked against `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/share/man/man2/{fork,unlink,chmod,flock}.2`; no claim of a new macOS API is involved.

## Concrete failure traces

**Quota release without actual release:** the Host retains a 6 GiB spillover. A Bash command opens it; a descendant keeps the descriptor after the initiating shell exits. Under pressure the Host removes the name and returns 6 GiB of allowance. A second capture grows to 6 GiB. The first inode's 6 GiB remain held, so concurrent temporary contents total 12 GiB despite a Host counter of 6 GiB. Returning no credit avoids this breach, but ordinary paths give the Host no dependable notification of the descendant's final close. Permanent conservative charging prevents useful reclamation and can strand capacity across Host restart. This follows from `unlink(2)` above, independently of malicious behavior.

**Unreserved growth:** after publication, same-user Bash changes the spillover's mode, opens it for writing and extends it, including a sparse gap. The Host's tracked size and reserved-growth total do not change. Later `stat` can detect some changes after the fact; it cannot make growth admission atomic or prevent concurrent oversubscription. Restoring permissions, advisory locks, scanning shell text and periodic directory scans do not close this bypass.

**Read protection:** a shell may discover the path at runtime or pass an open descriptor to a descendant. Therefore marking only paths found in the command string as protected misses valid readers. Protecting every spillover while any Bash exists is conservative, but shell exit still does not prove every descriptor is gone. FIFO unlink may preserve an already-open reader; that is a different guarantee from excluding all outstanding reads from eviction and proving safe byte-credit release.

## Minimal choices

1. **Preserve the chosen ordinary-path experience by explicitly narrowing exposed-spillover guarantees.** Keep strict reservations and release accounting for private Host-owned scratch and active capture. For published spillovers, specify that retention accounting covers Host-produced bytes under retained names, while arbitrary external mutation, links and handles are outside the enforced allowance. Permit FIFO removal of a published name without discovering shell readers; existing descriptors have ordinary filesystem behavior. Release the retention charge after successful unlink and Host closure, explicitly acknowledging that external handles can keep storage alive. Missing references remain unavailable and the Host never reuses a published name. This is the smallest path-preserving proposal, but it **weakens** the current aggregate held-byte guarantee and outstanding-reader rule. It is not already authorized merely by selecting paths.
2. **Preserve the stronger resource guarantee by revisiting direct arbitrary access.** Readers and mutations must become observable/enforceable before the Host can reserve all growth and prove final release. A managed retrieval boundary or enforced isolation could change that, but each adds scope contrary to the selected ordinary-Bash access. This note does not propose a sandbox, lease service, privileged helper or custom filesystem.

Recommendation: present the first scoped amendment as the smallest design consistent with ordinary paths; if that weakening is unacceptable, reopen the access decision instead of claiming all current promises are implementable. Do not silently redefine the quota as a named-file counter.

## Routine implementation after the policy choice

Unique Host-instance directories and exclusive random-name creation, publishing only finalized capture paths, keeping other scratch private, and FIFO bookkeeping through the existing shared owner are ordinary implementation choices. The Host can refrain from reusing names; arbitrary same-user Bash can still alter filesystem entries, so a path alone cannot authenticate the content against external replacement. Spillovers are disposable, not canonical evidence.

Close completed-file descriptors instead of retaining one handle per saved result. Retained-file records must have an explicit bounded representation; a growing in-memory map is not justified by a byte allowance alone, particularly for other small retained files sharing this owner. A bounded-window on-disk FIFO is a candidate within the shared owner, not a selected design or a reason to add per-write SQLite transactions. No record representation solves the external-handle and writable-alias conflicts above.

## Accepted follow-through

After the 6 GiB open-reader example was explained, the user accepted the scoped accounting option on 7 September 2026. The owning contract now preserves ordinary paths and FIFO without claiming an all-process held-byte cap for published spillover. Private scratch retains strict accounting. See ARCHITECTURE.md, Shared temporary-file retention, and the corresponding ADR-0021 amendment. This records the later decision; the investigation above remains its original evidence, not production validation.
