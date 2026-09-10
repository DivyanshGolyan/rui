----------------------- MODULE SessionContinuation -----------------------
EXTENDS Naturals, FiniteSets, TLC
\* Bounded safety probe: one Session, two Turns, three messages, one Run
\* and a separate continuation caller; zero to MaxCrashes host crashes.
\* Atomic commits, unique immutable admissions, ordered projection,
\* settled effects and provider validity are assumptions. Sets abstract
\* payload/order/storage; this model does not prove those assumptions.
\* Wait target belongs to an external observer retained across Host crashes;
\* no socket or durable server-side waiter is modeled. No liveness claim.
CONSTANTS DropPending, RewriteResult, RetargetWait, MaxCrashes
VARIABLES active, outcome, pending, projected, excluded, admitted,
          failedPending, failedOnce, continuation, run, stopTarget,
          idleStopped, idleContinuation, waitTarget, waitResult, up, crashes
vars == <<active, outcome, pending, projected, excluded, admitted,
          failedPending, failedOnce, continuation, run, stopTarget,
          idleStopped, idleContinuation, waitTarget, waitResult, up, crashes>>

\* One Session; Run A owns messages 1/2 in Turn 1. Another caller owns
\* message 3, which continues the Session in Turn 2. Start after admission
\* of message 1. projected is model-context inclusion, not provider receipt.
Init == /\ active = 1
        /\ outcome = [t \in 1..2 |-> "open"]
        /\ pending = {} /\ projected = {1} /\ excluded = {}
        /\ admitted = {1} /\ failedPending = {} /\ failedOnce = FALSE
        /\ continuation = FALSE /\ run = "live" /\ stopTarget = 0
        /\ idleStopped = FALSE /\ idleContinuation = FALSE /\ waitTarget = 0 /\ waitResult = 0
        /\ up = TRUE /\ crashes = 0

SubmitSecond ==
    /\ up /\ active = 1 /\ run = "live" /\ 2 \notin admitted
    /\ admitted' = admitted \cup {2} /\ pending' = pending \cup {2}
    /\ UNCHANGED <<active, outcome, projected, excluded, failedPending,
                   failedOnce, continuation, run, stopTarget, idleStopped, idleContinuation,
                   waitTarget, waitResult, up, crashes>>

\* Projection and request admission are one atomic step. Tool/effect
\* settlement is assumed complete before terminal transitions below.
Apply ==
    /\ up /\ active # 0 /\ pending # {}
    /\ ~(stopTarget = active)
    /\ projected' = projected \cup pending /\ pending' = {}
    /\ UNCHANGED <<active, outcome, excluded, admitted, failedPending,
                   failedOnce, continuation, run, stopTarget, idleStopped, idleContinuation,
                   waitTarget, waitResult, up, crashes>>

Fail ==
    /\ up /\ active # 0
    /\ ~(stopTarget = active)
    /\ outcome' = [outcome EXCEPT ![active] = "failed"]
    /\ failedOnce' = (failedOnce \/ active = 1)
    /\ failedPending' = failedPending \cup pending
    /\ pending' = IF DropPending THEN {} ELSE pending
    /\ active' = 0
    /\ UNCHANGED <<projected, excluded, admitted, continuation, run,
                   stopTarget, idleStopped, idleContinuation, waitTarget, waitResult, up, crashes>>

Succeed ==
    /\ up /\ active # 0 /\ pending = {}
    /\ ~(stopTarget = active)
    /\ outcome' = IF RewriteResult /\ active = 2 /\ failedOnce
                    THEN [t \in 1..2 |-> "completed"]
                    ELSE [outcome EXCEPT ![active] = "completed"]
    /\ active' = 0
    /\ UNCHANGED <<pending, projected, excluded, admitted, failedPending,
                   failedOnce, continuation, run, stopTarget, idleStopped, idleContinuation,
                   waitTarget, waitResult, up, crashes>>

\* Fresh input after failed work starts a new Turn and includes retained
\* pending input first. Original message/result binding stays Turn 1.
Continue ==
    /\ up /\ active = 0 /\ outcome[1] = "failed" /\ ~continuation
    /\ active' = 2 /\ continuation' = TRUE
    /\ idleContinuation' = (run = "done" /\ idleStopped /\ 2 \in pending)
    /\ admitted' = admitted \cup {3}
    /\ projected' = projected \cup pending \cup {3} /\ pending' = {}
    /\ UNCHANGED <<outcome, excluded, failedPending, failedOnce, run,
                   stopTarget, idleStopped, waitTarget, waitResult, up, crashes>>

CancelRun ==
    /\ up /\ run = "live" /\ run' = "requested"
    /\ UNCHANGED <<active, outcome, pending, projected, excluded, admitted,
                   failedPending, failedOnce, continuation, stopTarget,
                   idleStopped, idleContinuation, waitTarget, waitResult, up, crashes>>

\* Run A has one used Session. Its stop selects current work regardless
\* of who submitted it. An idle stop selects nothing, including no dormant
\* pending input. Pass completion is deliberately a separate commit.
RequestStop ==
    /\ up /\ run = "requested"
    /\ stopTarget' = active
    /\ run' = IF active = 0 THEN "pass_done" ELSE "stopping"
    /\ idleStopped' = (idleStopped \/ active = 0)
    /\ UNCHANGED <<active, outcome, pending, projected, excluded, admitted,
                   failedPending, failedOnce, continuation, idleContinuation,
                   waitTarget, waitResult, up, crashes>>

FinishStop ==
    /\ up /\ run = "stopping" /\ active = stopTarget /\ active # 0
    /\ outcome' = [outcome EXCEPT ![active] = "cancelled"]
    /\ excluded' = excluded \cup pending /\ pending' = {}
    /\ active' = 0 /\ run' = "pass_done"
    /\ UNCHANGED <<projected, admitted, failedPending, failedOnce,
                   continuation, stopTarget, idleStopped, idleContinuation, waitTarget,
                   waitResult, up, crashes>>

FinishRun ==
    /\ up /\ run = "pass_done" /\ run' = "done"
    /\ UNCHANGED <<active, outcome, pending, projected, excluded, admitted,
                   failedPending, failedOnce, continuation, stopTarget,
                   idleStopped, idleContinuation, waitTarget, waitResult, up, crashes>>

StartWait ==
    /\ up /\ active # 0 /\ waitTarget = 0
    /\ waitTarget' = active
    /\ UNCHANGED <<active, outcome, pending, projected, excluded, admitted,
                   failedPending, failedOnce, continuation, run, stopTarget,
                   idleStopped, idleContinuation, waitResult, up, crashes>>
FinishWait ==
    /\ up /\ waitTarget # 0 /\ waitResult = 0
    /\ outcome[waitTarget] # "open"
    /\ waitResult' = IF RetargetWait /\ continuation /\ outcome[2] # "open"
                       THEN 2 ELSE waitTarget
    /\ UNCHANGED <<active, outcome, pending, projected, excluded, admitted,
                   failedPending, failedOnce, continuation, run, stopTarget,
                   idleStopped, idleContinuation, waitTarget, up, crashes>>

Crash ==
    /\ up /\ crashes < MaxCrashes /\ up' = FALSE /\ crashes' = crashes + 1
    /\ UNCHANGED <<active, outcome, pending, projected, excluded, admitted,
                   failedPending, failedOnce, continuation, run, stopTarget,
                   idleStopped, idleContinuation, waitTarget, waitResult>>
Restart ==
    /\ ~up /\ up' = TRUE
    /\ run' = IF run \in {"stopping", "pass_done"} THEN "requested" ELSE run
    \* Ordinary stop intent stays durable even when the Run repeats its pass.
    /\ UNCHANGED stopTarget
    /\ UNCHANGED <<active, outcome, pending, projected, excluded, admitted,
                   failedPending, failedOnce, continuation, idleStopped, idleContinuation,
                   waitTarget, waitResult, crashes>>

Next == SubmitSecond \/ Apply \/ Fail \/ Succeed \/ Continue \/ CancelRun
        \/ RequestStop \/ FinishStop \/ FinishRun \/ StartWait \/ FinishWait
        \/ Crash \/ Restart
Spec == Init /\ [][Next]_vars

TypeOK == /\ active \in 0..2
          /\ outcome \in [1..2 -> {"open", "failed", "completed", "cancelled"}]
          /\ pending \subseteq admitted /\ projected \subseteq admitted
          /\ excluded \subseteq admitted /\ admitted \subseteq 1..3
          /\ run \in {"live", "requested", "stopping", "pass_done", "done"}
          /\ waitTarget \in 0..2 /\ waitResult \in 0..2
NoInputLoss == admitted = pending \cup projected \cup excluded
InputPartition == pending \cap projected = {}
NoRevival == /\ projected \cap excluded = {} /\ pending \cap excluded = {}
FailedInputRetained == failedPending \subseteq pending \cup projected \cup excluded
OriginalResultStable == failedOnce => outcome[1] = "failed"
WaitPinned == waitResult # 0 => waitResult = waitTarget
SingleActive == active # 0 => outcome[active] = "open"
CompletedCancellationStable == (run = "done") => (run' = "done")
NoPropagationAfterDone == (run = "done") => (excluded' = excluded)
StableCancellation == [][CompletedCancellationStable]_vars
StablePropagation == [][NoPropagationAfterDone]_vars
Safety == TypeOK /\ NoInputLoss /\ NoRevival /\ FailedInputRetained
          /\ OriginalResultStable /\ WaitPinned /\ SingleActive
\* Expected counterexample demonstrates an allowed trace, not a defect.
NoIdleContinuationWitness == ~idleContinuation
=============================================================================
