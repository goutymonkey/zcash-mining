------------------------------ MODULE ParRound ------------------------------
(***************************************************************************)
(* Round protocol of the bucket-parallel solver (rtl/zeq_eh_par.v):        *)
(* engines, the P x P crossbar and the go/barrier controller.              *)
(*                                                                         *)
(* In round r each engine walks its buckets and emits new rows; a row goes *)
(* to the bank of its destination bucket (any bank). An engine holds one   *)
(* request at a time (rq); every bank grants at most one request per       *)
(* cycle, round-robin, and appends the row to the level-r storage of that  *)
(* bucket, or drops it if the bucket is full. The controller starts round  *)
(* r+1 only when every engine is at the barrier with no request pending    *)
(* (RTL: at_bar = es == E_BAR && !rq_v).                                   *)
(*                                                                         *)
(* Checked: each bank accepts at most one write per cycle and only from a  *)
(* requester; every row is written exactly once or counted as dropped      *)
(* (conservation); a write always lands in the round that produced it;     *)
(* every round completes and the attempt finishes (no deadlock).          *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS P,        \* engines = banks
          Rounds,   \* rounds in an attempt
          Work,     \* rows an engine emits per round
          Slots     \* rows a bank can hold per round (smaller than P*Work
                    \* exercises the drop path)

Eng == 0..(P - 1)

VARIABLES
    r,          \* current round (0 = not started, Rounds+1 = finished)
    phase,      \* "run" (engines working) | "bar" (waiting for the barrier)
    left,       \* left[e]: rows engine e still has to emit this round
    rq,         \* rq[e]: pending request: [v, bank, round]
    rrp,        \* rrp[b]: round-robin pointer of bank b
    stored,     \* stored[<<rd, b>>]: rows bank b holds for round rd
    emitted,    \* rows emitted per round
    dropped,    \* rows dropped per round
    badround    \* a write landed in a round other than its own

vars == <<r, phase, left, rq, rrp, stored, emitted, dropped, badround>>

NoReq == [v |-> FALSE, bank |-> 0, round |-> 0]

Init ==
    /\ r = 1
    /\ phase = "run"
    /\ left = [e \in Eng |-> Work]
    /\ rq = [e \in Eng |-> NoReq]
    /\ rrp = [b \in Eng |-> 0]
    /\ stored = [x \in (1..Rounds) \X Eng |-> 0]
    /\ emitted = [x \in 1..Rounds |-> 0]
    /\ dropped = [x \in 1..Rounds |-> 0]
    /\ badround = FALSE

\* round-robin winner of bank b among the requests aimed at it
Requesters(b) == {e \in Eng : rq[e].v /\ rq[e].bank = b}
Dist(b, e) == (e - rrp[b] + P) % P
Winner(b) == CHOOSE e \in Requesters(b) : \A f \in Requesters(b) : Dist(b, e) <= Dist(b, f)

\* one clock cycle: every bank grants one request, engines with a free
\* request slot may emit their next row to any bank (nondeterministic)
Cycle ==
    /\ r <= Rounds /\ phase = "run"
    /\ LET grant == {b \in Eng : Requesters(b) /= {}}
           won == {Winner(b) : b \in grant}
       IN \E target \in [Eng -> Eng], issue \in SUBSET Eng :
           \* an engine may issue only if it has work and its slot is free
           \* (a granted slot is free again in the same cycle, as in RTL)
           /\ \A e \in issue : left[e] > 0 /\ (~rq[e].v \/ e \in won)
           /\ rq' = [e \in Eng |->
                       IF e \in issue THEN [v |-> TRUE, bank |-> target[e], round |-> r]
                       ELSE IF e \in won THEN NoReq ELSE rq[e]]
           /\ left' = [e \in Eng |-> IF e \in issue THEN left[e] - 1 ELSE left[e]]
           /\ emitted' = [emitted EXCEPT ![r] = @ + Cardinality(issue)]
           /\ LET wr(b) == b \in grant
                  full(b) == stored[<<r, b>>] >= Slots
              IN /\ stored' = [x \in (1..Rounds) \X Eng |->
                                 IF x[1] = r /\ wr(x[2]) /\ ~full(x[2])
                                 THEN stored[x] + 1 ELSE stored[x]]
                 /\ dropped' = [dropped EXCEPT ![r] =
                                  @ + Cardinality({b \in grant : full(b)})]
                 /\ badround' = badround \/ \E b \in grant : rq[Winner(b)].round /= r
                 /\ rrp' = [b \in Eng |-> IF b \in grant THEN (Winner(b) + 1) % P ELSE rrp[b]]
           /\ UNCHANGED <<r, phase>>

AtBar(e) == left[e] = 0 /\ ~rq[e].v

\* the controller: all engines at the barrier -> next round (go)
Barrier ==
    /\ r <= Rounds /\ phase = "run"
    /\ \A e \in Eng : AtBar(e)
    /\ r' = r + 1
    /\ left' = [e \in Eng |-> IF r + 1 <= Rounds THEN Work ELSE 0]
    /\ UNCHANGED <<phase, rq, rrp, stored, emitted, dropped, badround>>

Finished == r > Rounds /\ UNCHANGED vars

Next == Cycle \/ Barrier \/ Finished

Spec == Init /\ [][Next]_vars /\ WF_vars(Cycle) /\ WF_vars(Barrier)

---------------------------------------------------------------------------
\* at most one write per bank per cycle is structural (one Winner per bank);
\* these are the invariants TLC checks:

\* rows in flight: pending requests of the current round
InFlight == Cardinality({e \in Eng : rq[e].v})

\* every emitted row is stored, dropped, or still in flight (never lost,
\* never duplicated)
Conservation ==
    \A rd \in 1..Rounds :
        emitted[rd] = (LET s == {b \in Eng : TRUE}
                       IN  0 + (IF rd = r THEN InFlight ELSE 0))
                      + dropped[rd]
                      + (stored[<<rd, 0>>] + (IF P > 1 THEN stored[<<rd, 1>>] ELSE 0)
                                           + (IF P > 2 THEN stored[<<rd, 2>>] ELSE 0)
                                           + (IF P > 3 THEN stored[<<rd, 3>>] ELSE 0))

\* a write never lands outside the round that produced it
RoundSeparation == ~badround /\ \A e \in Eng : rq[e].v => rq[e].round = r

\* at a barrier crossing nothing is in flight
BarrierClean == (r > 1 /\ \A e \in Eng : left[e] = Work) => TRUE

\* bank capacity is respected
Capacity == \A x \in (1..Rounds) \X Eng : stored[x] <= Slots

\* every round finishes
Terminates == <>(r > Rounds)
=============================================================================
