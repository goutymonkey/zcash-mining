import Zeq.Soundness
/-!
# Canonical ordering (the solver's ORD/SWP step)

Zcash requires, at every node, that the index list of the left half
compares below the right half (`IndicesBefore`, a memcmp of big-endian
index lists, i.e. lexicographic order on indices). The hardware puts the
2^K indices in order bottom-up: at each level it swaps two halves when the
right one starts with the smaller index. `canon` is that operation on the
tree. Proved: it only permutes leaves, keeps the tree Valid, keeps the XOR,
and yields the Zcash order at every node (leaves distinct, as the
hardware's repeat check guarantees).
-/
namespace Zeq

open ChunkSpace

variable {V : Type} [S : ChunkSpace V]

def Tree.leaves : Tree → List Nat
  | .leaf i => [i]
  | .node l r => l.leaves ++ r.leaves

def Tree.first : Tree → Nat
  | .leaf i => i
  | .node l _ => l.first

/-- the hardware's ordering: swap halves whose right side starts lower -/
def canon : Tree → Tree
  | .leaf i => .leaf i
  | .node l r =>
    let a := canon l
    let b := canon r
    if b.first < a.first then .node b a else .node a b

/-- Zcash order: at every node the left half's first index is below the
right half's (with distinct indices this decides the lexicographic
comparison of the two index lists). -/
inductive Ordered : Tree → Prop
  | leaf (i : Nat) : Ordered (.leaf i)
  | node {l r} : Ordered l → Ordered r → l.first < r.first → Ordered (.node l r)

theorem leaves_ne_nil (t : Tree) : t.leaves ≠ [] := by
  induction t with
  | leaf i => simp [Tree.leaves]
  | node l r ihl _ => simp [Tree.leaves, ihl]

theorem first_mem (t : Tree) : t.first ∈ t.leaves := by
  induction t with
  | leaf i => simp [Tree.first, Tree.leaves]
  | node l r ihl _ => simp [Tree.first, Tree.leaves, ihl]

theorem first_is_head (t : Tree) : t.leaves.head? = some t.first := by
  induction t with
  | leaf i => simp [Tree.first, Tree.leaves]
  | node l r ihl _ =>
    simp only [Tree.leaves, Tree.first]
    cases h : l.leaves with
    | nil => exact absurd h (leaves_ne_nil l)
    | cons x xs => rw [h] at ihl; simpa using ihl

/-- `canon` only rearranges: the multiset of leaves is unchanged. -/
theorem canon_perm (t : Tree) : (canon t).leaves.Perm t.leaves := by
  induction t with
  | leaf i => simp [canon]
  | node l r ihl ihr =>
    simp only [canon]
    split
    · simp only [Tree.leaves]
      exact (List.perm_append_comm).trans (List.Perm.append ihl ihr)
    · simp only [Tree.leaves]
      exact List.Perm.append ihl ihr

theorem canon_first_mem (t : Tree) : (canon t).first ∈ t.leaves :=
  (canon_perm t).subset (first_mem (canon t))

/-- `canon` keeps the XOR of the leaf hashes. -/
theorem canon_X (H : Nat → V) (t : Tree) : Tree.X H (canon t) = Tree.X H t := by
  induction t with
  | leaf i => simp [canon]
  | node l r ihl ihr =>
    simp only [canon]
    split
    · simp only [Tree.X, ihl, ihr]; exact xor_comm _ _
    · simp only [Tree.X, ihl, ihr]

/-- `canon` keeps Zcash's collision conditions (they are symmetric). -/
theorem canon_valid {H : Nat → V} {h t} (hv : Valid H h t) : Valid H h (canon t) := by
  induction hv with
  | leaf i => exact Valid.leaf i
  | node _ _ hc ihl ihr =>
    rename_i h l r
    simp only [canon]
    split
    · exact Valid.node ihr ihl (by rw [canon_X, canon_X]; exact hc.symm)
    · exact Valid.node ihl ihr (by rw [canon_X, canon_X]; exact hc)

/-- With distinct leaves, `canon` produces Zcash order at every node. -/
theorem canon_ordered (t : Tree) (hd : t.leaves.Nodup) : Ordered (canon t) := by
  induction t with
  | leaf i => exact Ordered.leaf i
  | node l r ihl ihr =>
    simp only [Tree.leaves] at hd
    have hpa := List.pairwise_append.mp hd
    have hdl : l.leaves.Nodup := hpa.1
    have hdr : r.leaves.Nodup := hpa.2.1
    have hdis := hpa.2.2
    have ol := ihl hdl
    have or' := ihr hdr
    -- the two halves start with different indices (they share none)
    have hne : (canon l).first ≠ (canon r).first := by
      intro heq
      have m1 := canon_first_mem l
      have m2 := canon_first_mem r
      rw [heq] at m1
      exact hdis _ m1 _ m2 rfl
    simp only [canon]
    split
    · rename_i hlt; exact Ordered.node or' ol hlt
    · rename_i hge; exact Ordered.node ol or' (by omega)

/-- In Zcash order the left index list is lexicographically below the
right one (what `IndicesBefore` checks), node by node. -/
theorem ordered_lex {l r : Tree} (h : l.first < r.first) :
    List.lt l.leaves r.leaves := by
  cases hl : l.leaves with
  | nil => exact absurd hl (leaves_ne_nil l)
  | cons a as =>
    cases hr : r.leaves with
    | nil => exact absurd hr (leaves_ne_nil r)
    | cons b bs =>
      have ha := first_is_head l
      have hb := first_is_head r
      rw [hl] at ha; rw [hr] at hb
      simp at ha hb
      subst ha; subst hb
      exact List.lt.head _ _ h

end Zeq
