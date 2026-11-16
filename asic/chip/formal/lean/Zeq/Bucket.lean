/-!
# Bucketing is lossless (the ZEQ-200X architecture)

A row's CB-bit collision key is split into a bucket (top BB bits) that
chooses the bank, and a local key (low LB = CB - BB bits) that the engine
sorts by. Two rows collide (equal full key) exactly when they are in the
same bucket and have the same local key, so processing each bucket on its
own finds exactly the collision groups of a global sort.
-/
namespace Zeq

theorem bucket_split (LB k1 k2 : Nat) :
    k1 = k2 ↔ (k1 / 2 ^ LB = k2 / 2 ^ LB ∧ k1 % 2 ^ LB = k2 % 2 ^ LB) := by
  constructor
  · intro h; subst h; exact ⟨rfl, rfl⟩
  · rintro ⟨hd, hm⟩
    rw [← Nat.div_add_mod k1 (2 ^ LB), ← Nat.div_add_mod k2 (2 ^ LB), hd, hm]

/-- The bank of a row is a function of its key, so all members of a
collision group land in the same bucket (and bank). -/
theorem group_same_bucket (LB k1 k2 : Nat) (h : k1 = k2) :
    k1 / 2 ^ LB = k2 / 2 ^ LB := (bucket_split LB k1 k2 |>.mp h).1

/-- Bucket and local key are in range: the bucket fits BB bits and the
local key LB bits when the key fits CB = BB + LB bits. -/
theorem bucket_range (BB LB k : Nat) (hk : k < 2 ^ (BB + LB)) :
    k / 2 ^ LB < 2 ^ BB ∧ k % 2 ^ LB < 2 ^ LB := by
  constructor
  · apply Nat.div_lt_of_lt_mul
    rw [← Nat.pow_add, Nat.add_comm]; exact hk
  · exact Nat.mod_lt _ (Nat.pos_pow_of_pos _ (by decide))

end Zeq
