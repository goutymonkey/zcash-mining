------------------------------- MODULE JobTags -------------------------------
(***************************************************************************)
(* Job ids on reports (rtl/zeq_link.v). The controller broadcasts JOBs;    *)
(* a chip's lanes run attempts of the job current when each attempt        *)
(* starts; a finished attempt queues a report that goes out later (the     *)
(* upstream link is shared and may be busy).                               *)
(*                                                                         *)
(* Property: every report carries the id of the job its attempt belonged   *)
(* to. With TagCurrent = TRUE the report is stamped with the chip's        *)
(* current job when it is sent (the original RTL) and TLC finds the bug;   *)
(* with TagCurrent = FALSE the id is captured when the attempt starts (the *)
(* fixed RTL) and the property holds.                                      *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Jobs, Lanes, TagCurrent, MaxAtt   \* MaxAtt: attempts per job (bounds the model)

VARIABLES job, lane, queue, att, bad

vars == <<job, lane, queue, att, bad>>

Init ==
    /\ job = 1
    /\ lane = [l \in 1..Lanes |-> [busy |-> FALSE, j |-> 0]]
    /\ queue = <<>>        \* finished attempts waiting to be reported
    /\ att = 0             \* attempts started in the current job
    /\ bad = FALSE

NewJob ==
    /\ job < Jobs
    /\ job' = job + 1
    \* a new JOB aborts running attempts; queued reports may still be sent
    /\ lane' = [l \in 1..Lanes |-> [busy |-> FALSE, j |-> 0]]
    /\ att' = 0
    /\ UNCHANGED <<queue, bad>>

Start(l) ==
    /\ ~lane[l].busy
    /\ att < MaxAtt
    /\ att' = att + 1
    /\ lane' = [lane EXCEPT ![l] = [busy |-> TRUE, j |-> job]]
    /\ UNCHANGED <<job, queue, bad>>

Finish(l) ==
    /\ lane[l].busy
    /\ Len(queue) < 2
    /\ queue' = Append(queue, lane[l].j)          \* the attempt's true job
    /\ lane' = [lane EXCEPT ![l].busy = FALSE]
    /\ UNCHANGED <<job, att, bad>>

Send ==
    /\ Len(queue) > 0
    /\ LET truth == Head(queue)
           tag == IF TagCurrent THEN job ELSE truth
       IN bad' = (bad \/ (tag /= truth))
    /\ queue' = Tail(queue)
    /\ UNCHANGED <<job, lane, att>>

Next == NewJob \/ Send \/ \E l \in 1..Lanes : Start(l) \/ Finish(l)

Spec == Init /\ [][Next]_vars

CorrectTags == ~bad
===============================================================================
