--------------------------- MODULE SessionReplay ---------------------------
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS MaxCrashes, RecoverAdmission, PinWait, CheckPending
ASSUME /\ MaxCrashes \in Nat
       /\ RecoverAdmission \in BOOLEAN
       /\ PinWait \in BOOLEAN
       /\ CheckPending \in BOOLEAN

\* One existing Session, one keyed workflow operation W, and one keyless
\* external submission X. Turn numbers and message positions are internal.
\* The booleans independently enable three deliberately broken alternatives.
VARIABLES entries, processed, settled, active, turnCount,
          up, crashes, phase, snapshot, wpc, target, externalSent,
          observations

vars == <<entries, processed, settled, active, turnCount,
          up, crashes, phase, snapshot, wpc, target, externalSent,
          observations>>
MaxEntries == MaxCrashes + 2
Positions == 1..Len(entries)
WorkflowEntries == {i \in Positions : entries[i].caller = "W"}
Members(t) == {i \in Positions : entries[i].turn = t}
LatestSettled == CHOOSE t \in settled : \A s \in settled : s <= t

Init ==
    /\ entries = << >>
    /\ processed = {}
    /\ settled = {}
    /\ active = 0
    /\ turnCount = 0
    /\ up = TRUE
    /\ crashes = 0
    /\ phase = "idle"
    /\ snapshot = {}
    /\ wpc = "submit"
    /\ target = 0
    /\ externalSent = FALSE
    /\ observations = {}

\* One atomic Store transaction chooses the active/new Turn, appends the
\* message, and binds workflow key W. Recovery looks up that same binding.
\* Fixed key and fixed content are assumed; changed bindings are out of scope.
SubmitWorkflow ==
    /\ up /\ wpc = "submit"
    /\ IF RecoverAdmission /\ WorkflowEntries # {}
       THEN /\ target' = CHOOSE i \in WorkflowEntries : TRUE
            /\ UNCHANGED <<entries, active, turnCount>>
       ELSE /\ Len(entries) < MaxEntries
            /\ LET t == IF active = 0 THEN turnCount + 1 ELSE active
               IN /\ entries' = Append(entries, [caller |-> "W", turn |-> t])
                  /\ active' = t
                  /\ turnCount' = t
            /\ target' = Len(entries) + 1
    /\ wpc' = "ack"
    /\ UNCHANGED <<processed, settled, up, crashes, phase, snapshot,
                   externalSent, observations>>

\* Delivery is separate from durable admission, so a crash can lose the ack.
DeliverAcknowledgment ==
    /\ up /\ wpc = "ack"
    /\ wpc' = "wait"
    /\ UNCHANGED <<entries, processed, settled, active, turnCount,
                   up, crashes, phase, snapshot, target, externalSent,
                   observations>>

\* The external caller submits once, without a replay key. It can join active
\* work or create a later Turn. We do not silently retry it after a lost reply.
SubmitExternal ==
    /\ up /\ ~externalSent /\ WorkflowEntries # {}
    /\ Len(entries) < MaxEntries
    /\ LET t == IF active = 0 THEN turnCount + 1 ELSE active
       IN /\ entries' = Append(entries, [caller |-> "X", turn |-> t])
          /\ active' = t
          /\ turnCount' = t
    /\ externalSent' = TRUE
    /\ UNCHANGED <<processed, settled, up, crashes, phase, snapshot,
                   wpc, target, observations>>

\* A request sees a fixed prefix. Admission during flight cannot change it.
StartProvider ==
    /\ up /\ wpc # "paused" /\ active # 0 /\ phase = "idle"
    /\ Members(active) \ processed # {}
    /\ snapshot' = Members(active) \ processed
    /\ phase' = "flight"
    /\ UNCHANGED <<entries, processed, settled, active, turnCount,
                   up, crashes, wpc, target, externalSent, observations>>

ReturnProvider ==
    /\ up /\ phase = "flight"
    /\ phase' = "returned"
    /\ UNCHANGED <<entries, processed, settled, active, turnCount,
                   up, crashes, snapshot, wpc, target, externalSent,
                   observations>>

\* Completion application and the pending-message check share one Store
\* transaction. A newly admitted message forces another model request before
\* successful settlement. Every provider response here is a candidate final.
CommitProvider ==
    /\ up /\ phase = "returned"
    /\ LET done == processed \cup snapshot
           finish == ~CheckPending \/ Members(active) \subseteq done
       IN /\ processed' = done
          /\ settled' = IF finish THEN settled \cup {active} ELSE settled
          /\ active' = IF finish THEN 0 ELSE active
    /\ snapshot' = {}
    /\ phase' = "idle"
    /\ UNCHANGED <<entries, turnCount, up, crashes, wpc, target,
                   externalSent, observations>>

\* Answer t is an abstract immutable answer for Turn t, not actual text.
\* observations is a checker-only history: it is NOT proposed runtime storage.
ObserveAnswer ==
    /\ up /\ wpc = "wait" /\ target \in Positions
    /\ entries[target].turn \in settled
    /\ LET expected == entries[target].turn
           answer == IF PinWait THEN expected ELSE LatestSettled
       IN observations' = observations \cup {[target |-> expected, answer |-> answer]}
    /\ wpc' = "done"
    /\ UNCHANGED <<entries, processed, settled, active, turnCount,
                   up, crashes, phase, snapshot, target, externalSent>>

\* Durable records survive; request/response and evaluator-local state do not.
\* This abstracts a worst-case server/evaluator loss, not all recovery effects.
Crash ==
    /\ up /\ crashes < MaxCrashes
    /\ up' = FALSE /\ crashes' = crashes + 1
    /\ phase' = "idle" /\ snapshot' = {}
    /\ wpc' = "paused" /\ target' = 0
    /\ UNCHANGED <<entries, processed, settled, active, turnCount,
                   externalSent, observations>>

RestartServer ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<entries, processed, settled, active, turnCount,
                   crashes, phase, snapshot, wpc, target, externalSent,
                   observations>>

\* An explicit resume is separate from restarting the server. Fairness below
\* assumes a caller eventually chooses it; it is not an automatic-resume rule.
ResumeWorkflow ==
    /\ up /\ wpc = "paused" /\ wpc' = "submit"
    /\ UNCHANGED <<entries, processed, settled, active, turnCount,
                   up, crashes, phase, snapshot, target, externalSent,
                   observations>>

Next == SubmitWorkflow \/ DeliverAcknowledgment \/ SubmitExternal
        \/ StartProvider \/ ReturnProvider \/ CommitProvider \/ ObserveAnswer
        \/ Crash \/ RestartServer \/ ResumeWorkflow

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ entries \in Seq([caller : {"W", "X"}, turn : 1..MaxEntries])
    /\ Len(entries) <= MaxEntries
    /\ processed \subseteq Positions
    /\ settled \subseteq 1..turnCount
    /\ active \in 0..turnCount /\ turnCount \in 0..MaxEntries
    /\ up \in BOOLEAN /\ crashes \in 0..MaxCrashes
    /\ phase \in {"idle", "flight", "returned"}
    /\ snapshot \subseteq Positions
    /\ wpc \in {"submit", "ack", "wait", "done", "paused"}
    /\ target \in 0..Len(entries) /\ externalSent \in BOOLEAN
    /\ observations \subseteq [target : 1..MaxEntries, answer : 1..MaxEntries]

UniqueWorkflowAdmission == Cardinality(WorkflowEntries) <= 1
NoStrandedMessages == \A i \in Positions :
    entries[i].turn \in settled => i \in processed
AnswerMatchesAdmission == \A o \in observations : o.answer = o.target
AdmissionAssigned == \A i \in Positions :
    entries[i].turn = active \/ entries[i].turn \in settled
AcknowledgmentBound == wpc \in {"ack", "wait", "done"} =>
    target \in WorkflowEntries
\* Negated reachability check: its expected violation witnesses replay after
\* an answer was already observed, with the durable observation still present.
NoReplayWitness == ~(crashes > 0 /\ observations # {} /\ wpc = "wait")

ActiveNotSettled == active # 0 => active \notin settled
SnapshotBelongsToActive == phase # "idle" => snapshot \subseteq Members(active)

\* Conditional progress only: finitely many crashes and messages, eventual
\* explicit restart/resume, fair Host execution, and a returning provider.
LiveSpec == Spec
    /\ WF_vars(SubmitWorkflow) /\ WF_vars(DeliverAcknowledgment)
    /\ WF_vars(StartProvider) /\ WF_vars(ReturnProvider)
    /\ WF_vars(CommitProvider) /\ WF_vars(ObserveAnswer)
    /\ WF_vars(RestartServer) /\ WF_vars(ResumeWorkflow)
EveryMessageProcessed == \A i \in 1..MaxEntries :
    (i \in Positions) ~> (i \in processed)
WorkflowEventuallyAnswers ==
    (wpc \in {"submit", "ack", "wait"}) ~> (wpc = "done")
=============================================================================
