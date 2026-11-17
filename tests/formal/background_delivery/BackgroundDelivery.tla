-------------------------- MODULE BackgroundDelivery --------------------------
(***************************************************************************)
(* A background Action's final result as Session input: exactly once,     *)
(* stop wins, and the credit it keeps.                                     *)
(*                                                                         *)
(* Code (feature/final-delivery, #1550, shared saved/owed-stop predicate):                    *)
(*   src/action_control.zig            choose: promotion keeps its credit  *)
(*   src/store/domain/sourced_input.zig Final.admit                        *)
(*   src/store/domain/action.zig        SettleAttempt, RecoverUncertain,   *)
(*                                      settle_facts, uncertain_facts,     *)
(*                                      actionStoppedSql, eligibleSql      *)
(*   src/store/domain/command.zig       StopSession (session_stop row,     *)
(*                                      owed settlement), DecidePermission *)
(*   src/store/domain/model_admission.zig queued_input_sql, bind_messages  *)
(*   src/store/domain/turn.zig          parent stop owes child stops       *)
(*                                                                         *)
(* Every Store write is one serialized transaction, so each action below  *)
(* is one transaction. One Session is modelled; a stop of its attached     *)
(* parent reaches it first as an owed stop (session_stop_owed, unsettled), *)
(* and later as its own session_stop row.                                  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Actions,     \* the Session's Actions that may run in background
    Credits,     \* the Host's custody credits
    \* The fix under test: final admission also treats an owed parent stop
    \* as stopped. TRUE matches action.stoppedSql shared by every reader.
    AdmitChecksOwed,
    \* Mutations that remove a guard #1550 has. All FALSE describes it.
    BreakStoppedCheck,   \* Final.admit ignores `stopped`
    BreakResolvedGuard   \* a Resolution may be written twice

VARIABLES
    phase,       \* [Actions -> "idle" | "fg" | "bg" | "done"]
    orphan,      \* [Actions -> BOOL]: its Host died before it resolved
    admitted,    \* set of final inputs: [a, id, afterStop, bound]
    resolutions, \* [Actions -> Nat]: Resolutions written
    nextId,      \* next admission_id
    stopCut,     \* session_stop.admission_cutoff (0: never stopped)
    actStopped,  \* [Actions -> BOOL]: covered by a session_stop action_cutoff
    owed,        \* the parent's stop is owed here and unsettled
    stopAsked,   \* a stop (own or parent's) has been requested: history
    turnOpen,
    hostUp,
    waiter       \* a new foreground call: "none" | "waiting" | "running" | "done"

vars == <<phase, orphan, admitted, resolutions, nextId, stopCut, actStopped,
          owed, stopAsked, turnOpen, hostUp, waiter>>

Held == Cardinality({a \in Actions : phase[a] \in {"fg", "bg"}})
        + (IF waiter = "running" THEN 1 ELSE 0)

Init ==
    /\ phase = [a \in Actions |-> "idle"]
    /\ orphan = [a \in Actions |-> FALSE]
    /\ admitted = {}
    /\ resolutions = [a \in Actions |-> 0]
    /\ nextId = 1
    /\ stopCut = 0
    /\ actStopped = [a \in Actions |-> FALSE]
    /\ owed = FALSE /\ stopAsked = FALSE
    /\ turnOpen = FALSE /\ hostUp = TRUE
    /\ waiter = "none"

(* A model request in the Turn calls a tool: an Attempt takes a credit.    *)
Dispatch(a) ==
    /\ hostUp /\ turnOpen /\ phase[a] = "idle" /\ ~actStopped[a] /\ ~owed
    /\ Held < Credits
    /\ phase' = [phase EXCEPT ![a] = "fg"]
    /\ UNCHANGED <<orphan, admitted, resolutions, nextId, stopCut, actStopped,
                   owed, stopAsked, turnOpen, hostUp, waiter>>

(* action_control.choose: any non-core Action not stopped, no capacity.    *)
Promote(a) ==
    /\ hostUp /\ phase[a] = "fg" /\ ~actStopped[a] /\ ~orphan[a]
    /\ phase' = [phase EXCEPT ![a] = "bg"]
    /\ UNCHANGED <<orphan, admitted, resolutions, nextId, stopCut, actStopped,
                   owed, stopAsked, turnOpen, hostUp, waiter>>

(* Final.admit inside the Resolution's transaction.                       *)
StoppedForAdmit(a) ==
    /\ ~BreakStoppedCheck
    /\ actStopped[a] \/ (AdmitChecksOwed /\ owed)

Resolve(a) ==
    /\ resolutions' = [resolutions EXCEPT ![a] = resolutions[a] + 1]
    /\ phase' = [phase EXCEPT ![a] = "done"]
    /\ IF phase[a] = "bg" /\ ~StoppedForAdmit(a)
       THEN /\ admitted' = admitted \cup
                 {[a |-> a, id |-> nextId, afterStop |-> (stopAsked \/ actStopped[a]), bound |-> FALSE]}
            /\ nextId' = nextId + 1
       ELSE UNCHANGED <<admitted, nextId>>

(* SettleAttempt: the call finishes, fails, times out (its deadline) or    *)
(* ends stopped. Always possible for a live call: deadlines bound it.      *)
Settle(a) ==
    /\ hostUp /\ phase[a] \in {"fg", "bg"} /\ ~orphan[a]
    /\ Resolve(a)
    /\ UNCHANGED <<orphan, stopCut, actStopped, owed, stopAsked, turnOpen,
                   hostUp, waiter>>

(* The resolved-once guard (`resolution_code IS NULL`), broken.            *)
SettleAgain(a) ==
    /\ BreakResolvedGuard /\ hostUp /\ phase[a] = "done" /\ resolutions[a] = 1
    /\ phase' = [phase EXCEPT ![a] = "bg"]
    /\ UNCHANGED <<orphan, admitted, resolutions, nextId, stopCut, actStopped,
                   owed, stopAsked, turnOpen, hostUp, waiter>>

HostDies ==
    /\ hostUp
    /\ hostUp' = FALSE
    /\ orphan' = [a \in Actions |-> orphan[a] \/ phase[a] \in {"fg", "bg"}]
    /\ turnOpen' = FALSE
    /\ waiter' = IF waiter = "running" THEN "done" ELSE waiter
    /\ UNCHANGED <<phase, admitted, resolutions, nextId, stopCut, actStopped,
                   owed, stopAsked>>

HostStarts ==
    /\ ~hostUp /\ hostUp' = TRUE
    /\ UNCHANGED <<phase, orphan, admitted, resolutions, nextId, stopCut,
                   actStopped, owed, stopAsked, turnOpen, waiter>>

(* RecoverUncertain: an indeterminate Resolution, never a retry.          *)
Recover(a) ==
    /\ hostUp /\ orphan[a] /\ phase[a] \in {"fg", "bg"}
    /\ Resolve(a)
    /\ orphan' = [orphan EXCEPT ![a] = FALSE]
    /\ UNCHANGED <<stopCut, actStopped, owed, stopAsked, turnOpen, hostUp, waiter>>

(* StopSession on this Session: session_stop with both cutoffs; the       *)
(* selected Turn ends. Running calls then settle as stopped.               *)
ApplyStop ==
    /\ stopCut' = nextId - 1
    /\ actStopped' = [a \in Actions |-> TRUE]
    /\ turnOpen' = FALSE

UserStops ==
    /\ hostUp /\ ~stopAsked
    /\ ApplyStop
    /\ stopAsked' = TRUE
    /\ UNCHANGED <<phase, orphan, admitted, resolutions, nextId, owed, hostUp, waiter>>

(* A per-Action stop selects only this unresolved Action.                 *)
StopAction(a) ==
    /\ hostUp /\ phase[a] \in {"fg", "bg"} /\ ~actStopped[a]
    /\ actStopped' = [actStopped EXCEPT ![a] = TRUE]
    /\ UNCHANGED <<phase, orphan, admitted, resolutions, nextId, stopCut,
                   owed, stopAsked, turnOpen, hostUp, waiter>>

(* The attached parent stops: turn.zig owes this Session a stop.           *)
ParentStops ==
    /\ hostUp /\ ~stopAsked
    /\ owed' = TRUE /\ stopAsked' = TRUE
    /\ UNCHANGED <<phase, orphan, admitted, resolutions, nextId, stopCut,
                   actStopped, turnOpen, hostUp, waiter>>

(* The owed stop settles as this Session's own StopSession.               *)
OwedStopSettles ==
    /\ hostUp /\ owed
    /\ ApplyStop
    /\ owed' = FALSE
    /\ UNCHANGED <<phase, orphan, admitted, resolutions, nextId, stopAsked,
                   hostUp, waiter>>

Eligible(i) == ~i.bound /\ i.id > stopCut
BindEligible == admitted' = {[i EXCEPT !.bound = i.bound \/ Eligible(i)] : i \in admitted}

(* model_admission: queued input starts a Turn when none is open.          *)
StartTurn ==
    /\ hostUp /\ ~turnOpen /\ \E i \in admitted : Eligible(i)
    /\ BindEligible
    /\ turnOpen' = TRUE
    /\ UNCHANGED <<phase, orphan, resolutions, nextId, stopCut, actStopped,
                   owed, stopAsked, hostUp, waiter>>

(* The running Turn's next input boundary takes queued input.              *)
InputBoundary ==
    /\ hostUp /\ turnOpen /\ \E i \in admitted : Eligible(i)
    /\ BindEligible
    /\ UNCHANGED <<phase, orphan, resolutions, nextId, stopCut, actStopped,
                   owed, stopAsked, turnOpen, hostUp, waiter>>

(* A person's first message opens the Turn that calls the tools.           *)
PersonStartsTurn ==
    /\ hostUp /\ ~turnOpen /\ ~stopAsked /\ \A a \in Actions : phase[a] = "idle"
    /\ turnOpen' = TRUE
    /\ UNCHANGED <<phase, orphan, admitted, resolutions, nextId, stopCut,
                   actStopped, owed, stopAsked, hostUp, waiter>>

TurnEnds ==
    /\ turnOpen /\ \A a \in Actions : phase[a] # "fg"
    /\ turnOpen' = FALSE
    /\ UNCHANGED <<phase, orphan, admitted, resolutions, nextId, stopCut,
                   actStopped, owed, stopAsked, hostUp, waiter>>

(* Another foreground call needs a credit while background calls hold them. *)
WaiterArrives ==
    /\ waiter = "none" /\ hostUp
    /\ waiter' = "waiting"
    /\ UNCHANGED <<phase, orphan, admitted, resolutions, nextId, stopCut,
                   actStopped, owed, stopAsked, turnOpen, hostUp>>

WaiterRuns ==
    /\ waiter = "waiting" /\ hostUp /\ Held < Credits
    /\ waiter' = "running"
    /\ UNCHANGED <<phase, orphan, admitted, resolutions, nextId, stopCut,
                   actStopped, owed, stopAsked, turnOpen, hostUp>>

WaiterEnds ==
    /\ waiter = "running"
    /\ waiter' = "done"
    /\ UNCHANGED <<phase, orphan, admitted, resolutions, nextId, stopCut,
                   actStopped, owed, stopAsked, turnOpen, hostUp>>

Next ==
    \/ \E a \in Actions : Dispatch(a) \/ Promote(a) \/ Settle(a) \/ Recover(a) \/ StopAction(a)
                          \/ SettleAgain(a)
    \/ HostDies \/ HostStarts \/ UserStops \/ ParentStops \/ OwedStopSettles
    \/ StartTurn \/ InputBoundary \/ PersonStartsTurn \/ TurnEnds
    \/ WaiterArrives \/ WaiterRuns \/ WaiterEnds

\* Deadlines end every live call; the Host comes back; owed stops settle.
Fairness ==
    /\ \A a \in Actions : SF_vars(Settle(a)) /\ SF_vars(Recover(a))
    /\ WF_vars(HostStarts) /\ SF_vars(WaiterRuns) /\ SF_vars(OwedStopSettles)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
AdmissionsOf(a) == {i \in admitted : i.a = a}

\* Each final Resolution is delivered at most once.
DeliveredAtMostOnce == \A a \in Actions : Cardinality(AdmissionsOf(a)) <= 1

\* Each Action resolves once, even across Host death.
ResolvedOnce == \A a \in Actions : resolutions[a] <= 1

\* Stop wins: no Turn takes a background result that finished after the
\* Session (or its attached parent) was asked to stop.
StopWins == \A i \in admitted : i.bound => ~i.afterStop

\* Backgrounding keeps the call's credit: never more held than exist.
CreditsHeld == Held <= Credits

\* A foreground call waiting while background calls hold every credit
\* eventually runs: deadlines bound the wait.
WaiterEventuallyRuns == (waiter = "waiting") ~> (waiter # "waiting")
=============================================================================
