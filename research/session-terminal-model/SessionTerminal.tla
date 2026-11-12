-------------------------- MODULE SessionTerminal --------------------------
EXTENDS Naturals, Sequences, FiniteSets, TLC
CONSTANTS MaxCrashes, CarryExcluded, PretendApplied, FenceLateResults
ASSUME /\ MaxCrashes \in Nat
       /\ CarryExcluded \in BOOLEAN
       /\ PretendApplied \in BOOLEAN
       /\ FenceLateResults \in BOOLEAN

\* An existing Session: A initiates work 1; B may arrive during it;
\* C explicitly starts work 2 after work 1 ends. IDs are internal.
Messages == {"A", "B", "C"}
Turns == {1, 2}
Origin(m) == IF m = "C" THEN 2 ELSE 1
Terminal == {"success", "failed", "stopped"}
MaxRequests == MaxCrashes + 3
Ids == 1..MaxRequests
VARIABLE s
vars == <<s>>
Members(t) == {m \in s.admitted : Origin(m) = t}
Pending(t) == Members(t) \ s.projected
RequestIds == 1..Len(s.requests)
Unaccepted(t) == {r \in RequestIds : s.requests[r].turn = t} \ s.receipts

Init == s = [
    admitted |-> {"A"}, projected |-> {"A"}, active |-> 1,
    outcome |-> [t \in Turns |-> IF t = 1 THEN "open" ELSE "unused"],
    fence |-> [t \in Turns |-> "none"],
    requests |-> << >>, current |-> 0, launched |-> {}, retired |-> {},
    reply |-> [r \in Ids |-> "none"], receipts |-> {}, discarded |-> {},
    up |-> TRUE, enabled |-> TRUE, epoch |-> 0, crashes |-> 0,
    excluded |-> {}, invalid |-> {}, frozen |-> [t \in Turns |-> "none"]]

\* Immutable admissions are retained. Rejected sends do not create rows.
AdmitB ==
    /\ s.up /\ s.active = 1 /\ s.fence[1] = "none"
    /\ "B" \notin s.admitted
    /\ s' = [s EXCEPT !.admitted = @ \cup {"B"}]

Continue ==
    /\ s.up /\ s.active = 0 /\ s.outcome[1] \in Terminal
    /\ "C" \notin s.admitted
    /\ s' = [s EXCEPT !.admitted = @ \cup {"C"},
             !.projected = @ \cup {"C"}, !.active = 2,
             !.outcome[2] = "open"]

\* Projection and manifest preparation commit before transport launch.
\* Earlier projected conversation remains context; excluded pending rows do not.
Prepare ==
    /\ s.up /\ s.enabled /\ s.active # 0
    /\ s.fence[s.active] = "none" /\ s.current = 0
    /\ Len(s.requests) < MaxRequests
    /\ LET input == IF CarryExcluded THEN s.admitted
                    ELSE s.projected \cup Pending(s.active)
           r == [turn |-> s.active, epoch |-> s.epoch, input |-> input]
       IN s' = [s EXCEPT !.projected = input,
                !.requests = Append(@, r), !.current = Len(s.requests) + 1]

Launch ==
    /\ s.up /\ s.enabled /\ s.current # 0
    /\ s.fence[s.active] = "none"
    /\ s.requests[s.current].epoch = s.epoch
    /\ s.current \notin s.launched
    /\ s' = [s EXCEPT !.launched = @ \cup {s.current}]

\* A remote request may finish even after local detachment or server crash.
\* Recording this environmental reply is NOT accepting provider output.
Return(r) ==
    /\ r \in s.launched /\ s.reply[r] = "none"
    /\ \E result \in {"ok", "error"} :
        s' = [s EXCEPT !.reply[r] = result]

Valid(r) == /\ r = s.current
            /\ s.requests[r].epoch = s.epoch
            /\ s.requests[r].turn = s.active
            /\ s.outcome[s.requests[r].turn] = "open"
            /\ s.fence[s.requests[r].turn] = "none"

CommitSuccess(r) ==
    /\ s.up /\ s.enabled /\ r \in RequestIds
    /\ s.reply[r] = "ok" /\ r \notin s.receipts \cup s.discarded
    /\ (~FenceLateResults \/ Valid(r))
    /\ LET t == s.requests[r].turn
           finish == Pending(t) = {}
       IN s' = [s EXCEPT
           !.receipts = @ \cup {r},
           !.current = IF s.current = r THEN 0 ELSE @,
           !.outcome[t] = IF finish THEN "success" ELSE @,
           !.active = IF finish /\ s.active = t THEN 0 ELSE @,
           !.frozen[t] = IF finish /\ @ = "none" THEN "success" ELSE @]

\* An irreversible failure decision, not a retryable provider error:
\* either capacity failure before preparation, or a current provider error.
\* fence abstracts its causal failure fact, not a proposed new table or phase.
Fail ==
    /\ s.up /\ s.enabled /\ s.active # 0
    /\ s.fence[s.active] = "none"
    /\ (IF s.current = 0 THEN TRUE ELSE s.reply[s.current] = "error")
    /\ s' = [s EXCEPT !.fence[s.active] = "failed",
             !.excluded = @ \cup Pending(s.active),
             !.invalid = @ \cup Unaccepted(s.active)]

Stop ==
    /\ s.up /\ s.active # 0 /\ s.fence[s.active] = "none"
    /\ s' = [s EXCEPT !.fence[s.active] = "stopped",
             !.excluded = @ \cup Pending(s.active),
             !.invalid = @ \cup Unaccepted(s.active)]

\* Cleanup can suppress a prepared request or detach launched transport.
\* It does not claim the provider stopped execution or avoided billing.
Detach ==
    /\ s.up /\ s.active # 0 /\ s.fence[s.active] # "none"
    /\ s.current # 0
    /\ s' = [s EXCEPT !.retired = @ \cup {s.current}, !.current = 0]

\* Fence first; release Session occupancy only after modeled custody is gone.
\* The excluded set is ghost history. Production applicability is derived
\* from the failure/stop cause and absence of the projection relation.
Finalize ==
    /\ s.up /\ s.active # 0 /\ s.fence[s.active] # "none"
    /\ s.current = 0
    /\ LET t == s.active IN
       s' = [s EXCEPT !.outcome[t] = s.fence[t], !.active = 0,
             !.frozen[t] = s.fence[t],
             !.projected = IF PretendApplied THEN @ \cup Pending(t) ELSE @]

Discard(r) ==
    /\ s.up /\ r \in RequestIds /\ s.reply[r] # "none"
    /\ r \notin s.receipts \cup s.discarded /\ ~Valid(r)
    /\ s' = [s EXCEPT !.discarded = @ \cup {r}]

\* Crash preserves admission/projection/outcomes. It is not stop or failure.
\* epoch abstracts retirement of uncertain old attempts before replacement;
\* this is one recovery policy being checked, not a universal provider rule.
Crash ==
    /\ s.up /\ s.crashes < MaxCrashes
    /\ s' = [s EXCEPT !.up = FALSE, !.enabled = FALSE,
             !.crashes = @ + 1, !.epoch = @ + 1,
             !.invalid = @ \cup (RequestIds \ s.receipts)]

Restart == /\ ~s.up /\ s' = [s EXCEPT !.up = TRUE]

\* Explicit resume retires the old attempt and permits a new request.
\* It never clears a committed stop/failure fence or reactivates excluded rows.
Resume ==
    /\ s.up /\ ~s.enabled
    /\ s' = [s EXCEPT !.enabled = TRUE, !.current = 0,
             !.retired = IF s.current = 0 THEN @ ELSE @ \cup {s.current}]

Next == AdmitB \/ Continue \/ Prepare \/ Launch \/ Fail \/ Stop
        \/ Detach \/ Finalize \/ Crash \/ Restart \/ Resume
        \/ (\E r \in Ids : Return(r) \/ CommitSuccess(r) \/ Discard(r))
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ s.admitted \subseteq Messages /\ s.projected \subseteq s.admitted
    /\ s.active \in {0, 1, 2}
    /\ s.outcome \in [Turns -> Terminal \cup {"open", "unused"}]
    /\ s.fence \in [Turns -> {"none", "failed", "stopped"}]
    /\ s.requests \in Seq([turn : Turns, epoch : 0..MaxCrashes,
                            input : SUBSET Messages])
    /\ Len(s.requests) <= MaxRequests
    /\ s.current \in 0..Len(s.requests)
    /\ s.launched \subseteq RequestIds /\ s.retired \subseteq RequestIds
    /\ s.reply \in [Ids -> {"none", "ok", "error"}]
    /\ s.receipts \subseteq RequestIds /\ s.discarded \subseteq RequestIds
    /\ s.up \in BOOLEAN /\ s.enabled \in BOOLEAN
    /\ s.epoch \in 0..MaxCrashes /\ s.crashes \in 0..MaxCrashes
    /\ s.excluded \subseteq s.admitted /\ s.invalid \subseteq RequestIds
    /\ s.frozen \in [Turns -> Terminal \cup {"none"}]

\* excluded/invalid/frozen are checker-only histories, not runtime entities.
ExcludedNeverApplied == s.excluded \cap s.projected = {}
ExcludedNeverRequested == \A r \in RequestIds :
    s.requests[r].input \cap s.excluded = {}
NoLateAcceptance == s.receipts \cap s.invalid = {}
TerminalOutcomesStable == \A t \in Turns :
    s.frozen[t] # "none" => s.outcome[t] = s.frozen[t]
TerminalMessagesAccounted == \A m \in s.admitted :
    s.outcome[Origin(m)] \in Terminal => m \in s.projected \cup s.excluded
Occupancy == s.active # 0 => s.outcome[s.active] = "open"

\* Expected violations prove that the interesting scenarios are reachable.
HasLaterRequest == \E r \in s.launched : s.requests[r].turn = 2
NoFailedContinuationWitness ==
    ~(s.outcome[1] = "failed" /\ "B" \in s.excluded /\ HasLaterRequest)
NoStoppedContinuationWitness ==
    ~(s.outcome[1] = "stopped" /\ "B" \in s.excluded /\ HasLaterRequest)
NoLateAfterContinuationWitness ==
    ~(s.outcome[1] \in {"failed", "stopped"} /\ HasLaterRequest
      /\ (\E r \in s.discarded : s.requests[r].turn = 1 /\ s.reply[r] = "ok"))
NoCrashRecoveryWitness ==
    ~(s.crashes > 0 /\ s.active # 0 /\ s.fence[s.active] = "none"
      /\ s.current > 1 /\ s.current \in s.launched)

\* Finite messages/crashes, eventual explicit resume, fair cleanup and Host
\* scheduling, and eventual provider return. Stop and Continue are optional.
LiveSpec == Spec /\ WF_vars(Prepare) /\ WF_vars(Launch) /\ WF_vars(Fail)
    /\ WF_vars(Detach) /\ WF_vars(Finalize)
    /\ WF_vars(Restart) /\ WF_vars(Resume)
    /\ (\A r \in Ids : WF_vars(Return(r)) /\ WF_vars(CommitSuccess(r)))
EveryWorkSettles == \A t \in Turns :
    (s.outcome[t] = "open") ~> (s.outcome[t] \in Terminal)
EveryMessageAccounted == \A m \in Messages :
    (m \in s.admitted) ~> (m \in s.projected \cup s.excluded)
=============================================================================
