/-!
# Upstream buffer sizing (rtl/zeq_link.v), at the real parameters

The RI FIFO has 2^FIFO_AW bytes, FIFO_AW = clog2(2·(4·NSOL + 16)). A chip
starts one of its own packets only while the FIFO holds at most
ROOM = 2^(AW-1) - 2^(AW-6) - 2 bytes. While it sends a packet of L bytes,
at most L·(1 + drift) bytes can arrive from the chip above (same baud rate,
independent oscillators); forwarding pops as fast as bytes arrive. So the
FIFO never overflows iff ROOM + ⌈L_max·(1 + drift)⌉ ≤ 2^AW, with L_max the
largest packet (a SOLUTION: 6 bytes framing + 4 + 4·NSOL payload).

The TLA+ spec (ChainProtocol) proves the protocol safe under this rule;
this file proves the rule's inequality holds for the parameters the RTL is
built with, including 1/64 (1.6%) oscillator drift, far above crystal
tolerances.
-/
namespace Zeq

/-- ceil(log2 x), structural (so the kernel can evaluate it): the smallest
k with 2^k ≥ x, as the RTL's $clog2 -/
def clog2Go : Nat → Nat → Nat
  | 0, _ => 0
  | fuel + 1, x => if x ≤ 1 then 0 else clog2Go fuel ((x + 1) / 2) + 1
def clog2 (x : Nat) : Nat := clog2Go 64 x

def nsol (K : Nat) : Nat := 2 ^ K
def fifoAW (K : Nat) : Nat := clog2 (2 * (4 * nsol K + 16))
def room (K : Nat) : Nat := 2 ^ (fifoAW K - 1) - 2 ^ (fifoAW K - 6) - 2
def maxPacket (K : Nat) : Nat := 6 + 4 + 4 * nsol K
/-- bytes that can arrive while sending L bytes with 1/64 drift, rounded up -/
def arrivals (L : Nat) : Nat := L + (L + 63) / 64

def noOverflow (K : Nat) : Prop := room K + arrivals (maxPacket K) ≤ 2 ^ fifoAW K

instance (K : Nat) : Decidable (noOverflow K) := by unfold noOverflow; infer_instance

/-- test chip, (48,5): 512-byte FIFO, ROOM 246, largest packet 138 bytes -/
theorem noOverflow_48_5 : noOverflow 5 := by decide
/-- mainnet, (200,9): 8 KiB FIFO, ROOM 3966, largest packet 2058 bytes -/
theorem noOverflow_200_9 : noOverflow 9 := by decide
/-- (96,5) shares K = 5 -/
theorem noOverflow_96_5 : noOverflow 5 := noOverflow_48_5

/-- sanity: the numbers the RTL computes -/
example : fifoAW 5 = 9 ∧ room 5 = 246 ∧ maxPacket 5 = 138 := by decide
example : fifoAW 9 = 13 ∧ room 9 = 3966 ∧ maxPacket 9 = 2058 := by decide

/-- and an own packet never starts when it could not fit the FIFO even
without arrivals (ROOM < 2^AW). -/
theorem room_lt (K : Nat) (hK : K = 5 ∨ K = 9) : room K < 2 ^ fifoAW K := by
  rcases hK with h | h <;> subst h <;> decide

end Zeq
