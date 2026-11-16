import Zeq.Soundness
/-!
# A concrete model of `ChunkSpace`

An N-bit Equihash value with N = (K+1)·CB is K+1 chunks of CB bits. Model
it as a function from chunk index to a CB-bit vector, XOR chunkwise. This
instance shows the axioms used in `Soundness` are consistent (satisfiable)
and are exactly the chunked-XOR structure of the hardware's values.
-/
namespace Zeq

/-- values: chunk j (1 ≤ j ≤ K+1) ↦ CB-bit word; index 0 and > K+1 unused -/
structure Chunked (K CB : Nat) where
  c : Nat → BitVec CB
  -- chunks outside 1..K+1 are zero (normal form)
  outside : ∀ j, (j = 0 ∨ K + 1 < j) → c j = 0

namespace Chunked
variable {K CB : Nat}

@[ext] theorem ext' (a b : Chunked K CB) (h : a.c = b.c) : a = b := by
  cases a; cases b; simp at h; subst h; rfl

def xor (a b : Chunked K CB) : Chunked K CB :=
  ⟨fun j => a.c j ^^^ b.c j, fun j hj => by simp [a.outside j hj, b.outside j hj]⟩

def zero : Chunked K CB := ⟨fun _ => 0, fun _ _ => rfl⟩

def proj (j : Nat) (a : Chunked K CB) : Chunked K CB :=
  ⟨fun i => if i = j then a.c i else 0, fun i hi => by
    have := a.outside i hi
    by_cases h : i = j
    · simp only [h, if_true]; rw [← h]; exact this
    · simp [h]⟩

def mask (h : Nat) (a : Chunked K CB) : Chunked K CB :=
  ⟨fun i => if i ≤ h then 0 else a.c i, fun i hi => by
    have := a.outside i hi
    by_cases hh : i ≤ h <;> simp [hh, this]⟩

end Chunked

instance chunkSpace (K CB : Nat) : ChunkSpace (Chunked K CB) where
  xor := Chunked.xor
  zero := Chunked.zero
  xor_comm a b := by ext1; funext j; simp [Chunked.xor, BitVec.xor_comm]
  xor_assoc a b c := by ext1; funext j; simp [Chunked.xor, BitVec.xor_assoc]
  xor_zero a := by ext1; funext j; simp [Chunked.xor, Chunked.zero]
  xor_self a := by ext1; funext j; simp [Chunked.xor, Chunked.zero]
  K := K
  proj := Chunked.proj
  proj_xor j a b := by
    ext1; funext i; simp only [Chunked.proj, Chunked.xor]
    by_cases h : i = j <;> simp [h]
  proj_zero j := by ext1; funext i; simp [Chunked.proj, Chunked.zero]
  ext a b h := by
    ext1; funext i
    by_cases hi : i = 0 ∨ K + 1 < i
    · rw [a.outside i hi, b.outside i hi]
    · have h1 : 1 ≤ i := by omega
      have h2 : i ≤ K + 1 := by omega
      have := congrArg (fun x : Chunked K CB => x.c i) (h i h1 h2)
      simpa [Chunked.proj] using this
  mask := Chunked.mask
  proj_mask h j x := by
    ext1; funext i
    simp only [Chunked.proj, Chunked.mask, Chunked.zero]
    by_cases hij : i = j
    · subst hij; by_cases hh : i ≤ h <;> simp [hh]
    · by_cases hh : j ≤ h <;> simp [hij, hh]

/-- The soundness theorem applied to the concrete chunked values, e.g. the
mainnet shape K = 9, CB = 20 (N = 200). -/
example (H : Nat → Chunked 9 20) (ta tb : Tree) (va vb : Chunked 9 20)
    (ha : Built H 8 ta va) (hb : Built H 8 tb vb)
    (hk : ChunkSpace.proj 9 va = ChunkSpace.proj 9 vb)
    (hz : ChunkSpace.mask 9 (ChunkSpace.xor va vb) = ChunkSpace.zero) :
    Valid H 9 (.node ta tb) ∧ Tree.X H (.node ta tb) = ChunkSpace.zero :=
  final_sound (S := chunkSpace 9 20) (by decide) ha hb hk hz

end Zeq
