(* This file is generated by Why3's Coq-realize driver *)
(* Beware! Only edit allowed sections below    *)
Require Import BuiltIn.
Require BuiltIn.
Require HighOrd.
Require bool.Bool.

Require Coq.Logic.FunctionalExtensionality.
Require Import Classical.
Require Import ClassicalEpsilon.
Require Import Psatz.

(* The component type can be any inhabited type *)
Local Parameter p_component_type : Type.
Hypothesis p_component_type_WhyType : WhyType p_component_type.
Existing Instance p_component_type_WhyType.

(* Why3 goal *)
Definition t : Type.
Proof.
exact Z.
Defined.

(* Why3 goal *)
Definition le : t -> t -> Prop.
Proof.
exact Z.le.
Defined.

(* Why3 goal *)
Definition lt : t -> t -> Prop.
Proof.
exact Z.lt.
Defined.

(* Why3 goal *)
Definition gt : t -> t -> Prop.
Proof.
exact Z.gt.
Defined.

(* Why3 goal *)
Definition add : t -> t -> t.
Proof.
intros x y; exact (x + y)%Z.
Defined.

(* Why3 goal *)
Definition sub : t -> t -> t.
Proof.
intros x y; exact (x - y)%Z.
Defined.

(* Why3 goal *)
Definition one : t.
Proof.
exact (1)%Z.
Defined.

(* Why3 goal *)
Definition component_type : Type.
Proof.
exact p_component_type.
Defined.

(* Why3 goal *)
Definition map : Type.
Proof.
exact (t -> component_type).
Defined.

(* Why3 goal *)
Definition projection_to_array : map -> t -> component_type.
Proof.
intros m x; exact (m x).
Defined.

(* Why3 assumption *)
Inductive map__ref :=
  | map__ref'mk : map -> map__ref.
Axiom map__ref_WhyType : WhyType map__ref.
Existing Instance map__ref_WhyType.

(* Why3 assumption *)
Definition map__content1 (v:map__ref) : map :=
  match v with
  | map__ref'mk x => x
  end.

Definition dummy : p_component_type.
Proof.
exact why_inhabitant.
Defined.

(* Why3 goal *)
Definition has_bounds : map -> t -> t -> Prop.
Proof.
intros m f l; exact (forall x : t, (x < f \/ l < x)%Z -> m x = dummy).
Defined.

(* Why3 goal *)
Definition get : map -> t -> component_type.
Proof.
intros m x; exact (m x).
Defined.

(* Why3 goal *)
Lemma get_proj :
  forall (m:map) (i:t), ((get m i) = (projection_to_array m i)).
Proof.
intros m i; unfold get, projection_to_array; auto.
Qed.

(* Why3 goal *)
Definition eq_ext : map -> map -> t -> t -> Prop.
Proof.
intros a1 a2 _ _; exact (a1 = a2).
Defined.

(* Why3 goal *)
Lemma eq_ext_def :
  forall (a1:map) (a2:map) (f:t) (l:t), eq_ext a1 a2 f l <-> (a1 = a2).
Proof.
intros a1 a2 f l; unfold eq_ext; split; auto.
Qed.

(* Why3 goal *)
Lemma extensionality :
  forall (a1:map) (a2:map) (f:t) (l:t), ~ (a1 = a2) -> has_bounds a1 f l ->
  has_bounds a2 f l ->
  exists i:t, le f i /\ le i l /\ ~ ((get a1 i) = (get a2 i)).
Proof.
intros a1 a2 f l; unfold has_bounds, get.
intros a1_neq_a2 has_bounds_a1 has_bounds_a2.
(* Inverse the current inverse the current goal with a1_neq_a2 *)
apply not_all_not_ex; intro q_cases; apply a1_neq_a2; clear a1_neq_a2.
(* Apply extensionality *)
apply (FunctionalExtensionality.functional_extensionality a1 a2).
(* Specialize q_cases on x *)
intro x; specialize (q_cases x) as cases; clear q_cases.
(* Finish by a case analysis *)
destruct (Z_lt_le_dec l x) as [Hlx | Hlx];
try (rewrite has_bounds_a1; try auto; rewrite has_bounds_a2; auto).
destruct (Z_lt_le_dec x f) as [Hfx | Hfx];
try (rewrite has_bounds_a1; try auto; rewrite has_bounds_a2; auto).
apply NNPP; intro Eq; apply cases; split; auto; split; auto.
Qed.

(* Why3 goal *)
Definition set : map -> t -> component_type -> map.
Proof.
intros m x y.
intros x'.
destruct (why_decidable_eq x x') as [H|H].
exact y.
exact (m x').
Defined.

(* Why3 goal *)
Lemma set_eq :
  forall (a:map) (i:t) (v:component_type), ((get (set a i v) i) = v).
Proof.
intros a i v; unfold get, set.
destruct (why_decidable_eq i i) as [H|H]; auto; contradiction.
Qed.

(* Why3 goal *)
Lemma set_neq :
  forall (a:map) (i:t) (v:component_type), forall (j:t), ~ (i = j) ->
  ((get (set a i v) j) = (get a j)).
Proof.
intros a i v j hij; unfold get, set.
destruct (why_decidable_eq i j) as [H|H]; auto; contradiction.
Qed.

(* Why3 goal *)
Lemma set_has_bounds :
  forall (a:map) (i:t) (f:t) (l:t) (v:component_type), le f i /\ le i l ->
  has_bounds a f l -> has_bounds (set a i v) f l.
Proof.
intros a i f l v; unfold le, has_bounds, set; intros (h1,h2) h3 x h4.
destruct (why_decidable_eq i x) as [H|H]; auto; contradict h4; rewrite <- H; lia.
Qed.

(* Why3 goal *)
Definition slide : map -> t -> t -> map.
Proof.
intros a of nf.
destruct (Z.eq_dec of nf) as [_ | _].
exact a.
exact (fun x => a (x - nf + of)%Z).
Defined.

(* Why3 goal *)
Lemma slide_eq : forall (a:map) (first:t), ((slide a first first) = a).
Proof.
intros a first.
unfold slide; simpl.
destruct (Z.eq_dec first first) as [_ | Hwrong];
[| contradict Hwrong]; auto.
Qed.

(* Why3 goal *)
Lemma slide_def :
  forall (a:map) (old_first:t) (new_first:t),
  (forall (i:t),
   ((get (slide a old_first new_first) i) =
    (get a (sub i (sub new_first old_first))))) /\
  (forall (new_last:t),
   has_bounds a old_first (sub new_last (sub new_first old_first)) ->
   has_bounds (slide a old_first new_first) new_first new_last).
Proof.
intros a old_first new_first.
split.
* intro i; unfold slide; unfold sub; simpl.
  destruct (Z.eq_dec old_first new_first) as [Ha | _].
   - rewrite Ha.
     rewrite Zminus_diag.
     rewrite <- Zminus_0_l_reverse.
     auto.
   - rewrite Z.sub_sub_distr.
     auto.
* intro new_last; unfold slide, sub, has_bounds; simpl.
  intros has_bounds_a x Hx.
  destruct (Z.eq_dec old_first new_first) as [Ha | Ha];
  apply has_bounds_a; lia.
Qed.

(* Why3 goal *)
Definition const : component_type -> t -> t -> map.
Proof.
intros e f l x.
destruct (Z_lt_le_dec l x) as [Hlx | Hlx].
* exact dummy.
* destruct (Z_lt_le_dec x f) as [Hfx | Hfx].
  - exact dummy.
  - exact e.
Defined.

(* Why3 goal *)
Lemma const_def :
  forall (v:component_type) (first:t) (last:t),
  (forall (i:t), le first i /\ le i last ->
   ((get (const v first last) i) = v)) /\
  has_bounds (const v first last) first last.
Proof.
intros v f l; unfold le, const, get, has_bounds; split.
* intros i [Hfi Hli].
  destruct (Z_lt_le_dec l i) as [Bad | _]; [contradict Bad; lia |].
  destruct (Z_lt_le_dec i f) as [Bad | _]; [contradict Bad; lia |].
  auto.
* intros x Hx.
  destruct (Z_lt_le_dec l x) as [_ | Hlx]; [auto |].
  destruct (Z_lt_le_dec x f) as [_ | Hfx]; [auto |].
  contradict Hx; lia.
Qed.

(* Why3 goal *)
Definition slice : map -> t -> t -> map.
Proof.
intros a f l x.
destruct (Z_lt_le_dec l x) as [Hlx | Hlx].
* exact dummy.
* destruct (Z_lt_le_dec x f) as [Hfx | Hfx].
  - exact dummy.
  - exact (a x).
Defined.

(* Why3 goal *)
Lemma slice_eq :
  forall (a:map) (f:t) (l:t), has_bounds a f l -> ((slice a f l) = a).
Proof.
unfold has_bounds; intros a f l has_bounds_a.
(* Apply extensionality *)
apply (FunctionalExtensionality.functional_extensionality (slice a f l) a).
intro x; unfold slice.
destruct (Z_lt_le_dec l x) as [Hlx | Hlx]; [rewrite has_bounds_a; auto |].
destruct (Z_lt_le_dec x f) as [Hfx | Hfx]; [rewrite has_bounds_a; auto |].
auto.
Qed.

(* Why3 goal *)
Lemma slice_slice :
  forall (a:map) (f1:t) (l1:t) (f2:t) (l2:t), le f1 f2 /\ le l2 l1 ->
  ((slice (slice a f1 l1) f2 l2) = (slice a f2 l2)).
Proof.
unfold le; intros a f1 l1 f2 l2 (hf, hl).
(* Apply extensionality *)
apply (FunctionalExtensionality.functional_extensionality (slice (slice a f1 l1) f2 l2) (slice a f2 l2)).
intro x; unfold slice.
destruct (Z_lt_le_dec l2 x) as [Hl2x | Hl2x]; [auto |].
destruct (Z_lt_le_dec x f2) as [Hf2x | Hf2x]; [auto |].
destruct (Z_lt_le_dec l1 x) as [Hl1x | _]; [contradict Hl1x; lia |].
destruct (Z_lt_le_dec x f1) as [Hf1x | _]; [contradict Hf1x; lia |].
auto.
Qed.

(* Why3 goal *)
Lemma slice_def :
  forall (a:map) (f:t) (l:t), forall (i:t), le f i /\ le i l ->
  ((get (slice a f l) i) = (get a i)).
Proof.
unfold le, slice, get; intros a f l i (hfi, hli).
destruct (Z_lt_le_dec l i) as [Bad | _]; [contradict Bad; lia |].
destruct (Z_lt_le_dec i f) as [Bad | _]; [contradict Bad; lia |].
auto.
Qed.

(* Why3 goal *)
Lemma slice_has_bounds :
  forall (a:map) (f:t) (l:t), has_bounds (slice a f l) f l.
Proof.
unfold has_bounds, slice; intros a f l x Hx.
destruct (Z_lt_le_dec l x) as [_ | Hlx]; [auto |].
destruct (Z_lt_le_dec x f) as [_ | Hfx]; [auto |].
contradict Hx; lia.
Qed.

(* Why3 goal *)
Lemma slice_extensional :
  forall (a:map) (b:map) (f:t) (l:t), ~ ((slice a f l) = (slice b f l)) ->
  exists i:t,
  le f i /\ le i l /\ ~ ((get (slice a f l) i) = (get (slice b f l) i)).
Proof.
intros a b f l h1.
apply extensionality; auto; apply slice_has_bounds.
Qed.

(* Why3 goal *)
Definition concat : map -> t -> t -> map -> t -> t -> t -> map.
Proof.
intros a af al b bf bl l x.
destruct (Z_lt_le_dec al x) as [Halx | Halx].
* destruct (Z_lt_le_dec l x) as [Hlx | Hlx].
  - exact dummy.
  - exact (b (x - al + (bf - 1))%Z).
* destruct (Z_lt_le_dec x af) as [Hafx | Hafx].
  - exact dummy.
  - exact (a x).
Defined.

(* Why3 goal *)
Lemma concat_def :
  forall (a:map) (b:map) (a_first:t) (a_last:t) (b_first:t) (b_last:t)
    (new_last:t),
  (le a_first a_last -> le a_last new_last ->
   has_bounds (concat a a_first a_last b b_first b_last new_last) a_first
   new_last) /\
  (forall (i:t),
   (le a_first i /\ le i a_last ->
    ((get (concat a a_first a_last b b_first b_last new_last) i) = (get a i))) /\
   (gt i a_last /\ le i new_last ->
    ((get (concat a a_first a_last b b_first b_last new_last) i) =
     (get b (add (sub i a_last) (sub b_first one)))))).
Proof.
intros a b a_first a_last b_first b_last new_last.
unfold le, has_bounds, concat.
split.
* intros Hafal Halnl x Hx.
  destruct (Z_lt_le_dec a_last x) as [Halx | Halx].
  - destruct (Z_lt_le_dec new_last x) as [_ | Hnlx]; [auto | contradict Hx; lia].
  - destruct (Z_lt_le_dec x a_first) as [_ | Hafx]; [auto | contradict Hx; lia].
* intros i; unfold get, add, sub, one, gt; split.
  - intros [Hafi Hali].
    destruct (Z_lt_le_dec a_last i) as [Bad | _]; [contradict Bad; lia |].
    destruct (Z_lt_le_dec i a_first) as [Bad | _]; [contradict Bad; lia |].
    auto.
  - intros [Hafi Hali].
    destruct (Z_lt_le_dec a_last i) as [_ | Bad]; [| contradict Bad; lia].
    destruct (Z_lt_le_dec new_last i) as [Bad | _]; [contradict Bad; lia |].
    auto.
Qed.

(* Why3 goal *)
Definition concat_singleton_left :
  component_type -> t -> map -> t -> t -> t -> map.
Proof.
intros a af b bf bl l x.
destruct (Z_dec x af) as [[Hafx|Hafx]|Hafx].
* exact dummy.
* destruct (Z_lt_le_dec l x) as [Hlx | Hlx].
  - exact dummy.
  - exact (b (x - af + (bf - 1))%Z).
* exact a.
Defined.

(* Why3 goal *)
Lemma concat_singleton_left_def :
  forall (a:component_type) (b:map) (a_first:t) (b_first:t) (b_last:t)
    (new_last:t),
  (le a_first new_last ->
   has_bounds (concat_singleton_left a a_first b b_first b_last new_last)
   a_first new_last) /\
  ((get (concat_singleton_left a a_first b b_first b_last new_last) a_first)
   = a) /\
  (forall (i:t), gt i a_first /\ le i new_last ->
   ((get (concat_singleton_left a a_first b b_first b_last new_last) i) =
    (get b (add (sub i a_first) (sub b_first one))))).
Proof.
intros a b a_first b_first b_last new_last.
unfold le, has_bounds, concat_singleton_left, get, gt, add, sub, one.
split; [| split ].
* intros Hafal x Hx.
  destruct (Z_dec x a_first) as [[_|Hafx]|Hafx]; [auto | | contradict Hx; lia].
  destruct (Z_lt_le_dec new_last x) as [_ | Hlx]; [auto | contradict Hx; lia].
* destruct (Z_dec a_first a_first) as [[Bad|Bad]|_]; [| | auto]; contradict Bad; lia.
* intros x Hx.
  destruct (Z_dec x a_first) as [[Hafx|_]|Hafx]; [contradict Hx; lia | | contradict Hx; lia].
  destruct (Z_lt_le_dec new_last x) as [Hlx | _]; [contradict Hx; lia | auto].
Qed.

(* Why3 goal *)
Lemma concat_singleton_left_def_eq :
  forall (a:component_type) (b:map) (a_first:t) (b_last:t) (new_last:t) (i:t),
  gt i a_first /\ le i new_last ->
  ((get (concat_singleton_left a a_first b a_first b_last new_last) i) =
   (get b (sub i one))).
Proof.
unfold gt, le, concat_singleton_left, get, add, sub, one.
intros a b a_first b_last new_last i (Hfi, Hli).
destruct (Z_dec i a_first) as [[Bad|_]|Bad]; [contradict Bad; lia | | contradict Bad; lia].
destruct (Z_lt_le_dec new_last i) as [Bad | _]; [contradict Bad; lia |].
apply f_equal; lia.
Qed.

(* Why3 goal *)
Definition concat_singleton_right :
  map -> t -> t -> component_type -> t -> map.
Proof.
intros a af al b l x.
destruct (Z_lt_le_dec al x) as [Halx|Halx].
* destruct (why_decidable_eq x (al + 1)%Z) as [Heq | Hneq].
  - exact b.
  - exact dummy.
* destruct (Z_lt_le_dec x af) as [Hafx|Hafx].
  - exact dummy.
  - exact (a x).
Defined.

(* Why3 goal *)
Lemma concat_singleton_right_def :
  forall (a:map) (b:component_type) (a_first:t) (a_last:t) (new_last:t),
  (le a_first a_last /\ lt a_last new_last -> has_bounds a a_first a_last ->
   has_bounds (concat_singleton_right a a_first a_last b new_last) a_first
   new_last) /\
  (lt a_last (add a_last one) ->
   ((get (concat_singleton_right a a_first a_last b new_last)
     (add a_last one))
    = b)) /\
  (forall (i:t), le a_first i /\ le i a_last ->
   ((get (concat_singleton_right a a_first a_last b new_last) i) = (get a i))).
Proof.
intros a b a_first a_last new_last.
unfold lt, le, concat_singleton_right, get, add, one.
split; [| split ].
* unfold has_bounds.
  intros (Hafal, Halnl) has_bounds_a x Hx.
  destruct (Z_lt_le_dec a_last x) as [Halx|Halx].
  - destruct (why_decidable_eq x (a_last + 1)%Z) as [Heq|_]; [contradict Hx; lia| auto].
  - destruct (Z_lt_le_dec x a_first) as [_|Hafx]; [ auto | contradict Hx; lia].
* intros Hdummy.
  destruct (Z_lt_le_dec a_last (a_last + 1)) as [_|Bad]; [|contradict Bad; lia].
  unfold t; destruct (why_decidable_eq (a_last + 1)%Z (a_last + 1)%Z) as [_|Bad]; [auto | contradict Bad; lia].
* intros x (Hafx, Halx).
  destruct (Z_lt_le_dec a_last x) as [Bad|_]; [contradict Bad; lia |].
  destruct (Z_lt_le_dec x a_first) as [Bad|_]; [contradict Bad; lia | auto].
Qed.

(* Why3 goal *)
Definition concat_singletons :
  component_type -> t -> component_type -> t -> map.
Proof.
intros a af b l x.
destruct (why_decidable_eq x af%Z) as [Ha | Hna].
* exact a.
* destruct (why_decidable_eq x (af + 1)%Z) as [Hb | Hnb].
  - exact b.
  - exact dummy.
Defined.

(* Why3 goal *)
Lemma concat_singletons_def :
  forall (a:component_type) (b:component_type) (a_first:t) (new_last:t),
  (lt a_first new_last ->
   has_bounds (concat_singletons a a_first b new_last) a_first new_last) /\
  ((get (concat_singletons a a_first b new_last) a_first) = a) /\
  ((get (concat_singletons a a_first b new_last) (add a_first one)) = b).
Proof.
intros a b a_first new_last.
unfold lt, has_bounds, concat_singletons, get, add, one.
split; [| split ].
* intros Hafnl x Hx.
  destruct (why_decidable_eq x a_first%Z) as [Bad | _]; [ contradict Bad; lia |].
  destruct (why_decidable_eq x (a_first + 1)%Z) as [Bad | _]; [ contradict Bad; lia | auto ].
* destruct (why_decidable_eq a_first a_first%Z) as [_ | Bad]; [ auto | contradict Bad; lia ].
* unfold t; destruct (why_decidable_eq (a_first + 1)%Z a_first%Z) as [Bad | _]; [ contradict Bad; lia |].
  unfold t;  destruct (why_decidable_eq (a_first + 1)%Z (a_first + 1)%Z) as [_ | Bad]; [ auto | contradict Bad; lia ].
Qed.

(* Why3 goal *)
Definition singleton : component_type -> t -> map.
Proof.
intros e i x.
destruct (why_decidable_eq x i) as [Heq | Hneq].
* exact e.
* exact dummy.
Defined.

(* Why3 goal *)
Lemma singleton_bounds :
  forall (v:component_type) (i:t),
  has_bounds (singleton v i) i i /\ ((get (singleton v i) i) = v).
Proof.
intros v i.
unfold singleton, has_bounds, get.
split.
* intros x Hx.
  destruct (why_decidable_eq x i) as [Bad|_]; [contradict Bad; lia | auto].
* destruct (why_decidable_eq i i) as [_|Bad]; [auto | contradict Bad; lia].
Qed.
