/-!
# Soundness of the ZEQ-200 solver's construction

Every row the hardware builds is the pair of two rows from the previous
level whose next collision chunk is equal, and it stores the XOR of the two
values with the chunks already matched cleared (`mask`). This file proves
that every tree built that way satisfies Zcash's `IsValidSolution`
collision conditions, and that the final-round check (remaining bits zero)
makes the XOR of all 2^K leaf hashes zero.

The value space is abstract: a Boolean group (XOR) with linear chunk
projections `proj j` (j = 1 .. K+1) that together determine a value, and
masks that clear the first h chunks. `BitVec N` with contiguous chunks is
one model; nothing below depends on the bit layout.
-/
namespace Zeq

/-- XOR values with chunk structure. -/
class ChunkSpace (V : Type) where
  xor : V → V → V
  zero : V
  xor_comm : ∀ a b, xor a b = xor b a
  xor_assoc : ∀ a b c, xor (xor a b) c = xor a (xor b c)
  xor_zero : ∀ a, xor a zero = a
  xor_self : ∀ a, xor a a = zero
  /-- number of collision rounds, K -/
  K : Nat
  /-- chunk j of a value (meaningful for 1 ≤ j ≤ K+1) -/
  proj : Nat → V → V
  proj_xor : ∀ j a b, proj j (xor a b) = xor (proj j a) (proj j b)
  proj_zero : ∀ j, proj j zero = zero
  /-- the chunks determine the value -/
  ext : ∀ a b, (∀ j, 1 ≤ j → j ≤ K + 1 → proj j a = proj j b) → a = b
  /-- clear chunks 1 .. h -/
  mask : Nat → V → V
  proj_mask : ∀ h j x, proj j (mask h x) = if j ≤ h then zero else proj j x

open ChunkSpace

variable {V : Type} [S : ChunkSpace V]

/-- A candidate solution tree over leaf indices. -/
inductive Tree
  | leaf (i : Nat)
  | node (l r : Tree)

/-- XOR of the hashes of all leaves of a tree. -/
def Tree.X (H : Nat → V) : Tree → V
  | .leaf i => H i
  | .node l r => xor (Tree.X H l) (Tree.X H r)

/-- Zcash's collision conditions (`IsValidSolution` without ordering and
distinctness, which are separate): at height h+1 the two subtrees agree on
chunk h+1 of their XOR. -/
inductive Valid (H : Nat → V) : Nat → Tree → Prop
  | leaf (i : Nat) : Valid H 0 (.leaf i)
  | node {h l r} : Valid H h l → Valid H h r →
      proj (h + 1) (Tree.X H l) = proj (h + 1) (Tree.X H r) →
      Valid H (h + 1) (.node l r)

/-- What the hardware builds: level-0 rows are leaf hashes; a level-(h+1)
row pairs two level-h rows whose chunk h+1 matches (same collision group),
storing mask (h+1) of the XOR of their stored values. -/
inductive Built (H : Nat → V) : Nat → Tree → V → Prop
  | leaf (i : Nat) : Built H 0 (.leaf i) (H i)
  | pair {h ta tb va vb} : Built H h ta va → Built H h tb vb →
      proj (h + 1) va = proj (h + 1) vb →
      Built H (h + 1) (.node ta tb) (mask (h + 1) (xor va vb))

theorem proj_eq_zero_of_eq {a b : V} (j : Nat) (h : proj j a = proj j b) :
    proj j (xor a b) = zero := by
  rw [proj_xor, h, xor_self]

theorem xor_eq_of_eq_zero_left {a b : V} (h : a = zero) : xor a b = b := by
  rw [h, xor_comm, xor_zero]

/-- The stored value of a level-h row is its subtree XOR with chunks 1..h
cleared. -/
theorem stored_eq_mask {H : Nat → V} {h t v} (hb : Built H h t v) :
    v = mask h (Tree.X H t) := by
  induction hb with
  | leaf i =>
    apply ext
    intro j hj _
    rw [proj_mask]
    have : ¬ j ≤ 0 := by omega
    simp [this, Tree.X]
  | pair ha hb' hk iha ihb =>
    rename_i h ta tb va vb
    apply ext
    intro j hj _
    rw [proj_mask, proj_mask, iha, ihb]
    by_cases hjh : j ≤ h + 1
    · simp [hjh]
    · have hjh' : ¬ j ≤ h := by omega
      simp only [hjh, if_false, proj_xor, proj_mask, hjh', Tree.X]

/-- Chunks 1..h of a level-h row's subtree XOR are zero. -/
theorem zero_below {H : Nat → V} {h t v} (hb : Built H h t v) :
    ∀ j, 1 ≤ j → j ≤ h → proj j (Tree.X H t) = zero := by
  induction hb with
  | leaf i => intro j _ hj; omega
  | pair ha hb' hk iha ihb =>
    rename_i h ta tb va vb
    intro j hj1 hj2
    simp only [Tree.X, proj_xor]
    by_cases hjh : j ≤ h
    · rw [iha j hj1 hjh, ihb j hj1 hjh, xor_zero]
    · have hj : j = h + 1 := by omega
      subst hj
      -- the pairing condition on stored values is the condition on XORs
      have ea := stored_eq_mask ha
      have eb := stored_eq_mask hb'
      have hk' : proj (h + 1) (Tree.X H ta) = proj (h + 1) (Tree.X H tb) := by
        have := hk
        have hn : ¬ (h + 1 ≤ h) := by omega
        rw [ea, eb, proj_mask, proj_mask] at this
        simpa [hn] using this
      rw [hk', xor_self]

/-- Every row the hardware builds satisfies Zcash's collision conditions. -/
theorem built_valid {H : Nat → V} {h t v} (hb : Built H h t v) : Valid H h t := by
  induction hb with
  | leaf i => exact Valid.leaf i
  | pair ha hb' hk iha ihb =>
    rename_i h ta tb va vb
    refine Valid.node iha ihb ?_
    have ea := stored_eq_mask ha
    have eb := stored_eq_mask hb'
    have hn : ¬ (h + 1 ≤ h) := by omega
    rw [ea, eb, proj_mask, proj_mask] at hk
    simpa [hn] using hk

/-- Final round: two level-(K-1) rows in the same group (chunk K equal)
whose masked XOR is zero (the RTL's `(pair_x & lowmask) == 0`) form a tree
that is Valid at height K and whose leaf hashes XOR to zero: a Zcash
solution up to ordering and distinct indices. -/
theorem final_sound {H : Nat → V} {ta tb va vb}
    (hK : 1 ≤ S.K)
    (ha : Built H (S.K - 1) ta va) (hb : Built H (S.K - 1) tb vb)
    (hk : proj S.K va = proj S.K vb)
    (hz : mask S.K (xor va vb) = zero) :
    Valid H S.K (.node ta tb) ∧ Tree.X H (.node ta tb) = zero := by
  have hK1 : S.K - 1 + 1 = S.K := by omega
  have built : Built H S.K (.node ta tb) (mask S.K (xor va vb)) := by
    have := Built.pair ha hb (by rw [hK1]; exact hk)
    rw [hK1] at this
    exact this
  refine ⟨built_valid built, ?_⟩
  -- chunks 1..K are zero by construction, chunk K+1 by the final check
  have zb := zero_below built
  have e := stored_eq_mask built
  apply ext
  intro j hj1 hj2
  rw [proj_zero]
  by_cases hjK : j ≤ S.K
  · exact zb j hj1 hjK
  · have hj : j = S.K + 1 := by omega
    subst hj
    have := congrArg (proj (S.K + 1)) hz
    rw [e, proj_mask, proj_zero] at this
    simpa using this

end Zeq
