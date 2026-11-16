---------------------------- MODULE MysqlOwnership ----------------------------
(***************************************************************************)
(* Who may write a MySQL Store, and what a Host may conclude after it      *)
(* loses its connection around a COMMIT.                                   *)
(*                                                                         *)
(* Code it describes (map and sync commit in the verify-mysql-ownership *)
(* skill under .claude/skills):                                           *)
(*   src/store/engine/mysql_open.zig  open, reclaim                        *)
(*   src/store/engine/Mysql.zig       appendControls (fence), lost,       *)
(*                                    settleLostCommit, recover, reconnect *)
(*   src/store/Store.zig              recoverRerun, armRerun, fence        *)
(*                                                                         *)
(* One write batch is one message: START TRANSACTION, the fence           *)
(*   UPDATE store_owner SET commit_seq=commit_seq+1                        *)
(*     WHERE epoch=<seen> AND commit_seq=<seen>                            *)
(* with its guard, the batch's writes and COMMIT (`appendCommit`). The     *)
(* server runs it whole or, when the fence's guard fails, runs nothing     *)
(* past it. A server session outlives its client's connection until the   *)
(* server ends it (KILL, wait_timeout, a reset), and it may still run a    *)
(* message it received; that is the race this model exists for.           *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    WorkA,        \* write batches Host "A" runs; it may open first
    WorkB,        \* write batches Host "B" runs: a restart's new Host,
                  \* or a second Host pointed at the same database
    MaxSessions,  \* bound on server sessions ever opened
    MaxLosses,    \* bound on lost connections in one behaviour
    LockMayVanish,\* GET_LOCK can stop excluding a live session: a proxy or
                  \* cluster route reaches a server that does not hold it.
                  \* Multi-primary is unsupported, but the contract says
                  \* GET_LOCK "only refuses early", so the safety rules must
                  \* hold with this TRUE.
    \* Switches that break one guard each, so the checks can be seen failing.
    \* All FALSE describes the code.
    BreakFenceEpoch,    \* the fence compares commit_seq only
    BreakLockWait,      \* reclaim reads commit_seq without waiting for GET_LOCK
    BreakSettleEpoch    \* settleLostCommit ignores a changed epoch

None == 0
Hosts == {"A", "B"}
Work == [h \in Hosts |-> IF h = "A" THEN WorkA ELSE WorkB]

VARIABLES
    dbEpoch,    \* store_owner.epoch
    dbSeq,      \* store_owner.commit_seq
    log,        \* committed batches: <<host, batch, fence epoch, epoch at commit>>
    lock,       \* session holding GET_LOCK(database), or None
    sess,       \* [1..MaxSessions -> session]
    nextSid,    \* next unused session id
    owner,      \* [epoch -> Host that opened it]
    pc,         \* each Host's phase
    mode,       \* "settle" (lost COMMIT) or "recover" (lost before COMMIT)
    epoch,      \* State.epoch
    seq,        \* State.commit_seq
    conn,       \* the session this Host's connection reaches, or None
    held,       \* State.connection_id: the session the Host took GET_LOCK on
    batch,      \* the batch this Host is running
    rerun,      \* the batch is on its second run, so no longer armed
    outcome,    \* [Hosts -> [batch -> what the Host told its caller]]
    losses

vars == <<dbEpoch, dbSeq, log, lock, sess, nextSid, owner, pc, mode, epoch,
          seq, conn, held, batch, rerun, outcome, losses>>

Sids == 1..MaxSessions
NoMsg == [b |-> 0, e |-> 0, c |-> 0, h |-> "none"]
Outcomes == {"none", "saved", "notSaved", "unknown"}
MaxWork == CHOOSE n \in {Work[h] : h \in Hosts} : \A h \in Hosts : Work[h] <= n

Init ==
    /\ dbEpoch = 0 /\ dbSeq = 0 /\ log = <<>> /\ lock = None
    /\ sess = [s \in Sids |-> [alive |-> FALSE, msg |-> NoMsg, reply |-> "none"]]
    /\ nextSid = 1
    /\ owner = <<>>
    /\ pc = [h \in Hosts |-> "down"]
    /\ mode = [h \in Hosts |-> "none"]
    /\ epoch = [h \in Hosts |-> 0]
    /\ seq = [h \in Hosts |-> 0]
    /\ conn = [h \in Hosts |-> None]
    /\ held = [h \in Hosts |-> None]
    /\ batch = [h \in Hosts |-> 1]
    /\ rerun = [h \in Hosts |-> FALSE]
    /\ outcome = [h \in Hosts |-> [b \in 1..MaxWork |-> "none"]]
    /\ losses = 0

Attached(s) == \E h \in Hosts : conn[h] = s
NewSession == [sess EXCEPT ![nextSid] = [alive |-> TRUE, msg |-> NoMsg, reply |-> "none"]]
Tell(h, what) == outcome' = [outcome EXCEPT ![h][batch[h]] = what]
\* The Store fences: the Host drains and exits; its connection closes.
FenceWith(h, what) ==
    /\ Tell(h, what)
    /\ pc' = [pc EXCEPT ![h] = "fenced"]
    /\ conn' = [conn EXCEPT ![h] = None]

(* mysql_open.open: GET_LOCK(db, 0), then one transaction raises epoch.    *)
HostOpens(h) ==
    /\ pc[h] = "down" /\ lock = None /\ nextSid \in Sids
    /\ sess' = NewSession
    /\ nextSid' = nextSid + 1
    /\ lock' = nextSid
    /\ dbEpoch' = dbEpoch + 1
    /\ owner' = Append(owner, h)
    /\ epoch' = [epoch EXCEPT ![h] = dbEpoch + 1]
    /\ seq' = [seq EXCEPT ![h] = dbSeq]
    /\ conn' = [conn EXCEPT ![h] = nextSid]
    /\ held' = [held EXCEPT ![h] = nextSid]
    /\ pc' = [pc EXCEPT ![h] = "ready"]
    /\ UNCHANGED <<dbSeq, log, mode, batch, rerun, outcome, losses>>

(* GET_LOCK(db, 0) answers 0: `store_locked`.                              *)
HostRefused(h) ==
    /\ pc[h] = "down" /\ lock # None
    /\ pc' = [pc EXCEPT ![h] = "refused"]
    /\ UNCHANGED <<dbEpoch, dbSeq, log, lock, sess, nextSid, owner, mode, epoch,
                   seq, conn, held, batch, rerun, outcome, losses>>

(* appendCommit: fence, writes and COMMIT leave as one message.            *)
HostSendsBatch(h) ==
    /\ pc[h] = "ready" /\ batch[h] <= Work[h] /\ conn[h] # None
    /\ sess' = [sess EXCEPT ![conn[h]].msg =
                  [b |-> batch[h], e |-> epoch[h], c |-> seq[h], h |-> h]]
    /\ pc' = [pc EXCEPT ![h] = "committing"]
    /\ UNCHANGED <<dbEpoch, dbSeq, log, lock, nextSid, owner, mode, epoch, seq,
                   conn, held, batch, rerun, outcome, losses>>

(* The server runs a message it holds, whether or not anyone still reads  *)
(* the answer. The fence's guard stops the message before COMMIT.          *)
ServerRuns(s) ==
    LET m == sess[s].msg
        fenceHolds == /\ BreakFenceEpoch \/ m.e = dbEpoch
                      /\ m.c = dbSeq
    IN /\ sess[s].alive /\ m.b # 0
       /\ IF fenceHolds
          THEN /\ dbSeq' = dbSeq + 1
               /\ log' = Append(log, <<m.h, m.b, m.e, dbEpoch>>)
               /\ sess' = [sess EXCEPT ![s].msg = NoMsg, ![s].reply = "ok"]
          ELSE /\ sess' = [sess EXCEPT ![s].msg = NoMsg, ![s].reply = "fenced"]
               /\ UNCHANGED <<dbSeq, log>>
       /\ UNCHANGED <<dbEpoch, lock, nextSid, owner, pc, mode, epoch, seq, conn,
                      held, batch, rerun, outcome, losses>>

(* The server ends a session no Host reads: its open transaction rolls    *)
(* back, an unrun message is dropped and GET_LOCK frees.                   *)
ServerEndsSession(s) ==
    /\ sess[s].alive /\ ~Attached(s)
    /\ sess' = [sess EXCEPT ![s] = [alive |-> FALSE, msg |-> NoMsg, reply |-> "none"]]
    /\ lock' = IF lock = s THEN None ELSE lock
    /\ UNCHANGED <<dbEpoch, dbSeq, log, nextSid, owner, pc, mode, epoch, seq,
                   conn, held, batch, rerun, outcome, losses>>

(* The lock no longer excludes the session that took it (see            *)
(* LockMayVanish). Counted as a loss to keep behaviours finite.            *)
ServerForgetsLock ==
    /\ LockMayVanish /\ lock # None /\ losses < MaxLosses
    /\ lock' = None
    /\ losses' = losses + 1
    /\ UNCHANGED <<dbEpoch, dbSeq, log, sess, nextSid, owner, pc, mode, epoch,
                   seq, conn, held, batch, rerun, outcome>>

(* COMMIT's own OK arrives (`committed`).                                  *)
HostCommitted(h) ==
    /\ pc[h] = "committing" /\ conn[h] # None /\ sess[conn[h]].reply = "ok"
    /\ sess' = [sess EXCEPT ![conn[h]].reply = "none"]
    /\ seq' = [seq EXCEPT ![h] = seq[h] + 1]
    /\ Tell(h, "saved")
    /\ batch' = [batch EXCEPT ![h] = batch[h] + 1]
    /\ rerun' = [rerun EXCEPT ![h] = FALSE]
    /\ pc' = [pc EXCEPT ![h] = "ready"]
    /\ UNCHANGED <<dbEpoch, dbSeq, log, lock, nextSid, owner, mode, epoch, conn,
                   held, losses>>

(* The fence changed no row: OwnershipLost. Nothing of this run saved,   *)
(* but an earlier run of the batch may have, so the Host claims nothing.  *)
HostFenceFailed(h) ==
    /\ pc[h] = "committing" /\ conn[h] # None /\ sess[conn[h]].reply = "fenced"
    /\ sess' = [sess EXCEPT ![conn[h]].reply = "none"]
    /\ FenceWith(h, "unknown")
    /\ UNCHANGED <<dbEpoch, dbSeq, log, lock, nextSid, owner, mode, epoch, seq,
                   held, batch, rerun, losses>>

(* `lost`: the connection drops. The session lives on until the server    *)
(* ends it. Lost while committing is CommitOutcomeUnknown and settles;     *)
(* lost before COMMIT is StoreConnectionLost, rerun only while armed.      *)
HostLosesConnection(h) ==
    /\ losses < MaxLosses
    /\ \/ /\ pc[h] = "committing"
          /\ pc' = [pc EXCEPT ![h] = "reconnect"]
          /\ mode' = [mode EXCEPT ![h] = "settle"]
          /\ UNCHANGED outcome
       \/ /\ pc[h] = "ready" /\ batch[h] <= Work[h]
          /\ IF rerun[h]
             THEN /\ pc' = [pc EXCEPT ![h] = "fenced"]
                  /\ Tell(h, "notSaved")
                  /\ UNCHANGED mode
             ELSE /\ pc' = [pc EXCEPT ![h] = "reconnect"]
                  /\ mode' = [mode EXCEPT ![h] = "recover"]
                  /\ UNCHANGED outcome
    /\ conn' = [conn EXCEPT ![h] = None]
    /\ losses' = losses + 1
    /\ UNCHANGED <<dbEpoch, dbSeq, log, lock, sess, nextSid, owner, epoch, seq,
                   held, batch, rerun>>

(* reclaim, first message: IS_USED_LOCK and the epoch on a new session.   *)
HostReclaimReads(h) ==
    /\ pc[h] = "reconnect" /\ nextSid \in Sids
    /\ sess' = NewSession
    /\ nextSid' = nextSid + 1
    /\ IF dbEpoch # epoch[h] \/ (lock # None /\ lock # held[h])
       THEN \* OwnershipLost or StoreLocked: no retry helps, the Store fences.
            FenceWith(h, "unknown")
       ELSE /\ conn' = [conn EXCEPT ![h] = nextSid]
            /\ pc' = [pc EXCEPT ![h] = "lockWait"]
            /\ UNCHANGED outcome
    /\ UNCHANGED <<dbEpoch, dbSeq, log, lock, owner, mode, epoch, seq, held,
                   batch, rerun, losses>>

Decide(h, readEpoch, readSeq) ==
    IF mode[h] = "settle"
    THEN IF readEpoch # epoch[h] /\ ~BreakSettleEpoch
         THEN /\ FenceWith(h, "unknown") /\ UNCHANGED <<seq, batch, rerun>>
         ELSE IF readSeq = seq[h] + 1
         THEN \* Landed: success, the reads after COMMIT are sent again.
              /\ Tell(h, "saved")
              /\ seq' = [seq EXCEPT ![h] = seq[h] + 1]
              /\ batch' = [batch EXCEPT ![h] = batch[h] + 1]
              /\ rerun' = [rerun EXCEPT ![h] = FALSE]
              /\ pc' = [pc EXCEPT ![h] = "ready"]
              /\ UNCHANGED conn
         ELSE IF readSeq = seq[h]
         THEN \* Not landed: `replaced`; recoverRerun runs it again if armed.
              IF rerun[h]
              THEN /\ FenceWith(h, "notSaved") /\ UNCHANGED <<seq, batch, rerun>>
              ELSE /\ rerun' = [rerun EXCEPT ![h] = TRUE]
                   /\ pc' = [pc EXCEPT ![h] = "ready"]
                   /\ UNCHANGED <<outcome, seq, batch, conn>>
         ELSE /\ FenceWith(h, "unknown") /\ UNCHANGED <<seq, batch, rerun>>
    ELSE IF readEpoch = epoch[h] /\ readSeq = seq[h]
         THEN /\ rerun' = [rerun EXCEPT ![h] = TRUE]
              /\ pc' = [pc EXCEPT ![h] = "ready"]
              /\ UNCHANGED <<outcome, seq, batch, conn>>
         ELSE /\ FenceWith(h, "unknown") /\ UNCHANGED <<seq, batch, rerun>>

(* reclaim, second message: KILL the old session (if it held the lock),   *)
(* GET_LOCK(db, 10) waits for its end, then epoch and commit_seq.          *)
HostReclaimsLock(h) ==
    /\ pc[h] = "lockWait"
    /\ BreakLockWait \/ lock = None
    /\ lock' = IF BreakLockWait THEN lock ELSE conn[h]
    /\ held' = [held EXCEPT ![h] = conn[h]]
    /\ Decide(h, dbEpoch, dbSeq)
    /\ UNCHANGED <<dbEpoch, dbSeq, log, sess, nextSid, owner, mode, epoch, losses>>

(* GET_LOCK(db, 10) times out: StoreLocked, the Store fences.             *)
HostLockTimesOut(h) ==
    /\ pc[h] = "lockWait" /\ lock # None
    /\ FenceWith(h, "unknown")
    /\ UNCHANGED <<dbEpoch, dbSeq, log, lock, sess, nextSid, owner, mode, epoch,
                   seq, held, batch, rerun, losses>>

(* The reconnect's own connection drops, after GET_LOCK may have run.     *)
HostLosesReclaim(h) ==
    /\ pc[h] = "lockWait" /\ losses < MaxLosses
    /\ lock' \in IF lock = None THEN {None, conn[h]} ELSE {lock}
    /\ conn' = [conn EXCEPT ![h] = None]
    /\ pc' = [pc EXCEPT ![h] = "reconnect"]
    /\ losses' = losses + 1
    /\ UNCHANGED <<dbEpoch, dbSeq, log, sess, nextSid, owner, mode, epoch, seq,
                   held, batch, rerun, outcome>>

(* All batches done: RELEASE_ALL_LOCKS and close.                         *)
HostCloses(h) ==
    /\ pc[h] = "ready" /\ batch[h] > Work[h]
    /\ lock' = IF lock = conn[h] THEN None ELSE lock
    /\ sess' = [sess EXCEPT ![conn[h]].alive = FALSE]
    /\ conn' = [conn EXCEPT ![h] = None]
    /\ pc' = [pc EXCEPT ![h] = "closed"]
    /\ UNCHANGED <<dbEpoch, dbSeq, log, nextSid, owner, mode, epoch, seq, held,
                   batch, rerun, outcome, losses>>

\* Every Host stopped and no session holds an unrun batch: an end, not a deadlock.
Finished ==
    /\ \A h \in Hosts : pc[h] \in {"closed", "fenced", "refused", "down"}
    /\ \A s \in Sids : ~sess[s].alive \/ sess[s].msg = NoMsg
    /\ UNCHANGED vars

Next ==
    \/ \E h \in Hosts :
          \/ HostOpens(h) \/ HostRefused(h) \/ HostSendsBatch(h)
          \/ HostCommitted(h) \/ HostFenceFailed(h) \/ HostLosesConnection(h)
          \/ HostReclaimReads(h) \/ HostReclaimsLock(h) \/ HostLockTimesOut(h)
          \/ HostLosesReclaim(h) \/ HostCloses(h)
    \/ \E s \in Sids : ServerRuns(s) \/ ServerEndsSession(s)
    \/ ServerForgetsLock
    \/ Finished

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules. Each is one sentence a reader can check against the contract.   *)

InLog(h, b) == \E i \in 1..Len(log) : log[i][1] = h /\ log[i][2] = b

TypeOK ==
    /\ \A h \in Hosts : \A b \in 1..MaxWork : outcome[h][b] \in Outcomes
    /\ lock \in Sids \cup {None}

\* A batch is saved at most once, however often it runs.
SavedOnce ==
    \A h \in Hosts : \A b \in 1..Work[h] :
        Cardinality({i \in 1..Len(log) : log[i][1] = h /\ log[i][2] = b}) <= 1

\* A Host that tells its caller "saved" is right.
SavedMeansSaved ==
    \A h \in Hosts : \A b \in 1..Work[h] : outcome[h][b] = "saved" => InLog(h, b)

\* A Host that tells its caller "nothing was saved" stays right.
NotSavedMeansNotSaved ==
    \A h \in Hosts : \A b \in 1..Work[h] : outcome[h][b] = "notSaved" => ~InLog(h, b)

\* A batch runs again only while nothing of it is saved.
RerunOnlyUnsaved ==
    \A h \in Hosts :
        (rerun[h] /\ batch[h] <= Work[h] /\ pc[h] = "ready")
            => ~InLog(h, batch[h])

\* Only the Host that opened the Store last writes it: once another Host
\* opens, nothing the earlier one sent can commit.
OnlyLatestOwnerWrites ==
    \A i \in 1..Len(log) : log[i][3] = log[i][4] /\ owner[log[i][4]] = log[i][1]
=============================================================================
