--------------------------- MODULE ChainProtocol ---------------------------
(***************************************************************************)
(* Upstream path of the ZEQ-200 daisy chain (rtl/zeq_link.v), at byte      *)
(* granularity.                                                            *)
(*                                                                         *)
(* Chip 1 is next to the controller, chip Chips at the top. Each chip      *)
(* buffers bytes arriving on RI (from the chip above) in a FIFO of Cap     *)
(* bytes and transmits on RO one byte per tick. This is the historical     *)
(* equal-clock arbitration abstraction; current RTL also has per-hop       *)
(* byte pacing, which is NOT represented here. The old RTL can starve      *)
(* under sustained traffic and overflow with clock drift. Finite Budget   *)
(* delivery below does not prove the implemented chain's liveness.         *)
(* The model's arbiter is:                                                 *)
(*   idle:  if FIFO non-empty and not (own_turn and own_has)               *)
(*            -> forward the whole head packet, own_turn := TRUE           *)
(*          elif own_has -> send an own packet, own_turn := FALSE          *)
(*   own_has requires own_room: FIFO level <= Room (flow control).         *)
(* All chips transmit at the same baud rate, so the model advances every   *)
(* link in one synchronous Tick (one byte time).                           *)
(*                                                                         *)
(* Checked: no FIFO ever overflows, bytes of a packet are never           *)
(* interleaved with another packet's anywhere on the path, and every      *)
(* packet a chip produces is delivered to the controller (no starvation,  *)
(* no deadlock).                                                           *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Chips,    \* chips in the chain
          MaxLen,   \* longest packet, bytes
          Budget,   \* packets each chip produces
          Cap,      \* RI FIFO capacity, bytes (RTL: two max packets)
          Room      \* own_room threshold (RTL: Cap/2 minus slack)

ASSUME Chips >= 1 /\ MaxLen >= 1 /\ Cap >= 1 /\ Room < Cap

Chip == 1..Chips
Lens == 1..MaxLen

\* a byte: <<source chip, packet number, index in packet, packet length>>
Byte(c, p, k, l) == <<c, p, k, l>>

VARIABLES
    fifo,       \* fifo[i]: bytes buffered at chip i (from chip i+1)
    ownq,       \* ownq[i]: lengths of chip i's own packets ready to send
    made,       \* made[i]: packets chip i has produced
    tx,         \* tx[i]: current transmission
    turn,       \* turn[i]: TRUE = own packet goes next if waiting
    delivered,  \* bytes received by the controller
    overflow    \* set if any FIFO ever exceeded Cap

vars == <<fifo, ownq, made, tx, turn, delivered, overflow>>

Idle == [kind |-> "idle"]

Init ==
    /\ fifo = [i \in Chip |-> <<>>]
    /\ ownq = [i \in Chip |-> <<>>]
    /\ made = [i \in Chip |-> 0]
    /\ tx = [i \in Chip |-> Idle]
    /\ turn = [i \in Chip |-> TRUE]
    /\ delivered = <<>>
    /\ overflow = FALSE

\* a chip's CPU-side report becomes ready (any time, any length)
Produce(i, l) ==
    /\ made[i] < Budget
    /\ made' = [made EXCEPT ![i] = @ + 1]
    /\ ownq' = [ownq EXCEPT ![i] = Append(@, l)]
    /\ UNCHANGED <<fifo, tx, turn, delivered, overflow>>

OwnHas(i) == Len(ownq[i]) > 0 /\ Len(fifo[i]) <= Room

\* the arbiter's choice for an idle chip at the start of a byte time
Decide(i) ==
    IF tx[i].kind /= "idle" THEN tx[i]
    ELSE IF Len(fifo[i]) > 0 /\ ~(turn[i] /\ OwnHas(i))
         THEN [kind |-> "fwd", left |-> Head(fifo[i])[4]]
    ELSE IF OwnHas(i)
         THEN [kind |-> "own", pkt |-> made[i] - Len(ownq[i]) + 1,
               len |-> Head(ownq[i]), idx |-> 1]
    ELSE Idle

NewTurn(i) ==
    IF tx[i].kind /= "idle" THEN turn[i]
    ELSE IF Len(fifo[i]) > 0 /\ ~(turn[i] /\ OwnHas(i)) THEN TRUE
    ELSE IF OwnHas(i) THEN FALSE
    ELSE turn[i]

\* the byte chip i puts on RO this tick (if any), given its decision d
Out(i, d) ==
    CASE d.kind = "fwd" -> <<Head(fifo[i])>>
      [] d.kind = "own" -> <<Byte(i, d.pkt, d.idx, d.len)>>
      [] OTHER          -> <<>>

After(d) ==
    CASE d.kind = "fwd" -> IF d.left = 1 THEN Idle ELSE [d EXCEPT !.left = @ - 1]
      [] d.kind = "own" -> IF d.idx = d.len THEN Idle ELSE [d EXCEPT !.idx = @ + 1]
      [] OTHER          -> Idle

Tick ==
    LET d == [i \in Chip |-> Decide(i)]
        o == [i \in Chip |-> Out(i, d[i])]
        popped(i) == IF d[i].kind = "fwd" THEN Tail(fifo[i]) ELSE fifo[i]
        newfifo == [i \in Chip |->
                      IF i < Chips THEN popped(i) \o o[i + 1] ELSE popped(i)]
    IN /\ \E i \in Chip : d[i].kind /= "idle"
       /\ fifo' = newfifo
       /\ tx' = [i \in Chip |-> After(d[i])]
       /\ turn' = [i \in Chip |-> NewTurn(i)]
       /\ ownq' = [i \in Chip |->
                     IF d[i].kind = "own" /\ tx[i].kind = "idle" THEN Tail(ownq[i])
                     ELSE ownq[i]]
       /\ delivered' = delivered \o o[1]
       /\ overflow' = overflow \/ \E i \in Chip : Len(newfifo[i]) > Cap
       /\ UNCHANGED made

Done ==
    /\ \A i \in Chip : made[i] = Budget /\ Len(ownq[i]) = 0 /\ Len(fifo[i]) = 0
                       /\ tx[i].kind = "idle"
    /\ UNCHANGED vars

Next == (\E i \in Chip, l \in Lens : Produce(i, l)) \/ Tick \/ Done

Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ \A i \in Chip, l \in Lens : WF_vars(Produce(i, l))

---------------------------------------------------------------------------
\* ------------------------------------------------------------ properties

NoOverflow == ~overflow /\ \A i \in Chip : Len(fifo[i]) <= Cap

\* consecutive bytes of a sequence belong to one packet in order, and a new
\* packet starts only after the previous one is complete
Contiguous(s) ==
    \A k \in 1..(Len(s) - 1) :
        IF s[k][3] < s[k][4]
        THEN s[k + 1] = Byte(s[k][1], s[k][2], s[k][3] + 1, s[k][4])
        ELSE s[k + 1][3] = 1

\* the controller sees packets whole, and every FIFO holds whole-packet runs
NoInterleave == Contiguous(delivered) /\ \A i \in Chip : Contiguous(fifo[i])

\* per source, packets arrive in the order they were produced
InOrder ==
    \A k1, k2 \in 1..Len(delivered) :
        (k1 < k2 /\ delivered[k1][1] = delivered[k2][1]) =>
            delivered[k1][2] <= delivered[k2][2]

TypeOK == /\ \A i \in Chip : made[i] \in 0..Budget
          /\ overflow \in BOOLEAN

\* liveness: everything produced is eventually delivered
AllDelivered ==
    <>(/\ \A i \in Chip : made[i] = Budget /\ Len(ownq[i]) = 0 /\ Len(fifo[i]) = 0
                          /\ tx[i].kind = "idle")
=============================================================================
