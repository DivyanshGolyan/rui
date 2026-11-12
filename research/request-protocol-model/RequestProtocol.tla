----------------------- MODULE RequestProtocol -----------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Keys, MaxCrashes, CheckPending, ReplayTool
VARIABLES intent, sent, answer, reply, recorded, cancelling, cancelled,
          stage, starts, stopAsked, crashes
vars == <<intent, sent, answer, reply, recorded, cancelling, cancelled,
          stage, starts, stopAsked, crashes>>
Init == /\ intent = {}
        /\ sent = {}
        /\ answer = [k \in Keys |-> "none"]
        /\ reply = {}
        /\ recorded = {}
        /\ cancelling = FALSE /\ cancelled = FALSE
        /\ stage = [k \in Keys |-> "none"]
        /\ starts = [k \in Keys |-> 0]
        /\ stopAsked = {} /\ crashes = 0
SaveIntent(k) == /\ ~cancelling /\ k \notin intent
                 /\ intent' = intent \cup {k}
                 /\ UNCHANGED <<sent, answer, reply, recorded, cancelling,
                     cancelled, stage, starts, stopAsked, crashes>>
Send(k) == /\ k \in intent \ recorded /\ ~cancelled
           /\ sent' = sent \cup {k}
           /\ UNCHANGED <<intent, answer, reply, recorded, cancelling,
               cancelled, stage, starts, stopAsked, crashes>>
Core(k) == /\ k \in sent
           /\ sent' = sent \ {k}
           /\ reply' = reply \cup {k}
           /\ IF answer[k] = "none"
                 THEN \E a \in {"accepted", "rejected"}:
                    /\ answer' = [answer EXCEPT ![k] = a]
                    /\ stage' = [stage EXCEPT ![k] = IF a = "accepted" THEN "ready" ELSE "none"]
                 ELSE UNCHANGED <<answer, stage>>
           /\ UNCHANGED <<intent, recorded, cancelling, cancelled, starts, stopAsked, crashes>>
Record(k) == /\ k \in reply /\ ~cancelled
             /\ recorded' = recorded \cup {k}
             /\ reply' = reply \ {k}
             /\ UNCHANGED <<intent, sent, answer, cancelling, cancelled, stage, starts, stopAsked, crashes>>
Cancel == /\ ~cancelling /\ cancelling' = TRUE
          /\ UNCHANGED <<intent, sent, answer, reply, recorded, cancelled, stage, starts, stopAsked, crashes>>
Admit(k) == /\ stage[k] = "ready" /\ k \notin stopAsked
            /\ stage' = [stage EXCEPT ![k] = "admitted"]
            /\ UNCHANGED <<intent, sent, answer, reply, recorded, cancelling, cancelled, starts, stopAsked, crashes>>
Start(k) == /\ stage[k] = "admitted" /\ k \notin stopAsked
            /\ starts' = [starts EXCEPT ![k] = @ + 1]
            /\ stage' = [stage EXCEPT ![k] = "running"]
            /\ UNCHANGED <<intent, sent, answer, reply, recorded, cancelling, cancelled, stopAsked, crashes>>
Complete(k) == /\ stage[k] = "running"
               /\ stage' = [stage EXCEPT ![k] = "done"]
               /\ UNCHANGED <<intent, sent, answer, reply, recorded, cancelling, cancelled, starts, stopAsked, crashes>>
AskStop(k) == /\ cancelling /\ k \in recorded /\ answer[k] = "accepted"
              /\ stopAsked' = stopAsked \cup {k}
              /\ UNCHANGED <<intent, sent, answer, reply, recorded, cancelling, cancelled, stage, starts, crashes>>
FinishStop(k) == /\ k \in stopAsked /\ stage[k] \in {"ready", "admitted", "running"}
                /\ stage' = [stage EXCEPT ![k] = "stopped"]
                /\ UNCHANGED <<intent, sent, answer, reply, recorded, cancelling, cancelled, starts, stopAsked, crashes>>
Terminal(k) == stage[k] \in {"done", "stopped", "uncertain"}
FinishCancel == /\ cancelling /\ ~cancelled
                /\ (~CheckPending \/ intent \subseteq recorded)
                /\ \A k \in recorded: answer[k] = "accepted" => Terminal(k)
                /\ cancelled' = TRUE
                /\ UNCHANGED <<intent, sent, answer, reply, recorded, cancelling, stage, starts, stopAsked, crashes>>
Crash == /\ crashes < MaxCrashes
         /\ crashes' = crashes + 1
         /\ sent' = {} /\ reply' = {}
         /\ stage' = [k \in Keys |-> IF stage[k] \in {"admitted", "running"}
                        THEN IF ReplayTool THEN "ready" ELSE "uncertain"
                        ELSE stage[k]]
         /\ UNCHANGED <<intent, answer, recorded, cancelling, cancelled, starts, stopAsked>>
Next == Cancel \/ FinishCancel \/ Crash \/ \E k \in Keys:
          SaveIntent(k) \/ Send(k) \/ Core(k) \/ Record(k) \/ Admit(k) \/ Start(k)
          \/ Complete(k) \/ AskStop(k) \/ FinishStop(k)
Spec == Init /\ [][Next]_vars
TypeOK == /\ intent \subseteq Keys /\ sent \subseteq intent
          /\ reply \subseteq intent /\ recorded \subseteq intent
          /\ answer \in [Keys -> {"none", "accepted", "rejected"}]
          /\ stage \in [Keys -> {"none", "ready", "admitted", "running", "done", "stopped", "uncertain"}]
          /\ starts \in [Keys -> 0..2] /\ crashes \in 0..MaxCrashes
          /\ cancelling \in BOOLEAN /\ cancelled \in BOOLEAN /\ stopAsked \subseteq recorded
RecordedAnswer == \A k \in recorded: answer[k] # "none"
NoReplay == \A k \in Keys: starts[k] <= 1
SafeCancellation == cancelled => /\ intent \subseteq recorded
                                 /\ \A k \in intent: answer[k] = "accepted" => Terminal(k)
StableAnswers == [][\A k \in Keys: answer[k] # "none" => answer'[k] = answer[k]]_vars
FairSpec == Spec /\ WF_vars(FinishCancel)
            /\ \A k \in Keys: WF_vars(Send(k)) /\ WF_vars(Core(k))
               /\ WF_vars(Record(k)) /\ WF_vars(AskStop(k)) /\ WF_vars(FinishStop(k))
CancellationProgress == cancelling ~> cancelled
=============================================================================
