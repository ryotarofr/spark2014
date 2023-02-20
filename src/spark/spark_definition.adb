------------------------------------------------------------------------------
--                                                                          --
--                            GNAT2WHY COMPONENTS                           --
--                                                                          --
--                      S P A R K _ D E F I N I T I O N                     --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--                     Copyright (C) 2011-2023, AdaCore                     --
--              Copyright (C) 2016-2023, Capgemini Engineering              --
--                                                                          --
-- gnat2why is  free  software;  you can redistribute  it and/or  modify it --
-- under terms of the  GNU General Public License as published  by the Free --
-- Software  Foundation;  either version 3,  or (at your option)  any later --
-- version.  gnat2why is distributed  in the hope that  it will be  useful, --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of  MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public License  distributed with  gnat2why;  see file COPYING3. --
-- If not,  go to  http://www.gnu.org/licenses  for a complete  copy of the --
-- license.                                                                 --
--                                                                          --
-- gnat2why is maintained by AdaCore (http://www.adacore.com)               --
--                                                                          --
------------------------------------------------------------------------------

with Atree;                           use Atree;
with Ada.Strings.Unbounded;           use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Aspects;                         use Aspects;
with Assumption_Types;                use Assumption_Types;
with Checked_Types;                   use Checked_Types;
with Common_Iterators;                use Common_Iterators;
with Debug;
with Einfo.Utils;                     use Einfo.Utils;
with Elists;                          use Elists;
with Errout;                          use Errout;
with Exp_Util;                        use Exp_Util;
with Flow_Dependency_Maps;            use Flow_Dependency_Maps;
with Flow_Generated_Globals.Phase_2;  use Flow_Generated_Globals.Phase_2;
with Flow_Utility;                    use Flow_Utility;
with Flow_Utility.Initialization;     use Flow_Utility.Initialization;
with Flow_Types;                      use Flow_Types;
with Gnat2Why_Args;
with Lib;
with Namet;                           use Namet;
with Nlists;                          use Nlists;
with Nmake;
with Opt;                             use Opt;
with Rtsfind;                         use Rtsfind;
with Sem_Aux;                         use Sem_Aux;
with Sem_Disp;
with Sem_Prag;                        use Sem_Prag;
with Sinfo.Utils;                     use Sinfo.Utils;
with Sinput;                          use Sinput;
with Snames;                          use Snames;
with SPARK_Atree.Entities;
with SPARK_Util;                      use SPARK_Util;
with SPARK_Definition.Annotate;       use SPARK_Definition.Annotate;
with SPARK_Definition.Violations;     use SPARK_Definition.Violations;
with SPARK_Util.Hardcoded;            use SPARK_Util.Hardcoded;
with SPARK_Util.Subprograms;          use SPARK_Util.Subprograms;
with SPARK_Util.Types;                use SPARK_Util.Types;
with Stand;                           use Stand;
with String_Utils;                    use String_Utils;
with Tbuild;
with Uintp;                           use Uintp;
with Urealp;                          use Urealp;
with VC_Kinds;                        use VC_Kinds;

package body SPARK_Definition is

   -----------------------------------------
   -- Marking of Entities in SPARK or Not --
   -----------------------------------------

   --  This pass detects which entities are in SPARK and which are not, based
   --  on the presence of SPARK_Mode pragmas in the source, and the violations
   --  of SPARK restrictions. Entities that are not in SPARK may still be
   --  translated in Why, although differently than entities in SPARK
   --  (variables not in SPARK are still declared in case they appear in Global
   --  contracts).

   --  As definitions of entities may be recursive, this pass follows
   --  references to entities not yet marked to decide whether they are in
   --  SPARK or not. We remember which entities are being marked, to avoid
   --  looping. So an entity may be marked at the point where it is declared,
   --  or at some previous point, because it was referenced from another
   --  entity. (This is specially needed for Itypes and class-wide types, which
   --  may not have an explicit declaration, or one that is attached to the
   --  AST.)

   --  Any violation of SPARK rules results in the current toplevel subprogram
   --  (unit subprogram, or subprogram only contained in packages all the
   --  way to the unit level) to be not in SPARK, as well as everything it
   --  defines locally.

   --  An error is raised if an entity that has a corresponding SPARK_Mode
   --  pragma of On is determined to be not in SPARK.

   --  Each entity is added to the list of entities Entity_List. The
   --  translation will depend on the status (in SPARK or not) of each entity,
   --  and on where the entity is declared (in the current unit or not).

   --  A subprogram spec can be in SPARK even if its body is not in SPARK.

   --  Except for private types and deferred constants, a unique entity is used
   --  for multiple views of the same entity. For example, the entity attached
   --  to a subprogram body or a body stub is not used.

   --  Private types are always in SPARK (except currently record (sub)type
   --  with private part), even if the underlying type is not in SPARK. This
   --  allows operations which do not depend on the underlying type to be in
   --  SPARK, which is the case in client code that does not have access to the
   --  underlying type. Since only the partial view of a private type is used
   --  in the AST (except at the point of declaration of the full view), even
   --  when visibility over the full view is needed, the nodes that need this
   --  full view are treated specially, so that they are in SPARK only if the
   --  most underlying type is in SPARK. This most underlying type is the last
   --  type obtained by taking:
   --  . for a private type, its underlying type
   --  . for a record subtype, its base type
   --  . for any other type, the type itself
   --  until reaching a non-private type that is not a record subtype.

   --  Partial views of deferred constants may be in SPARK even if their full
   --  view is not in SPARK. This is the case if the type of the constant is
   --  in SPARK, while its initializing expression is not.

   -------------------------------------
   -- Adding Entities for Translation --
   -------------------------------------

   Inside_Actions : Boolean := False;
   --  Set to True when traversing actions (statements introduced by the
   --  compiler inside expressions), which require a special translation.
   --  Those entities are stored in Actions_Entity_Set.

   --  There are two possibilities when marking an entity, depending on whether
   --  this is in the context of a toplevel subprogram body or not. In the
   --  first case, violations are directly attached to the toplevel subprogram
   --  entity, and local entities are added or not as a whole, after the
   --  subprogram body has been fully marked. In the second case, violations
   --  are attached to the entity itself, which is directly added to the lists
   --  for translation after marking.

   function SPARK_Pragma_Of_Entity (E : Entity_Id) return Node_Id;
   --  Return SPARK_Pragma that applies to entity E. This function is basically
   --  the same as Einfo.SPARK_Pragma, but it is more general because it will
   --  work for any entity.
   --
   --  SPARK_Pragma cannot be directly specified for types nor declare blocks
   --  but comes from the most immediate scope where pragma SPARK_Mode can be
   --  attached. Then, for SPARK_Pragma coming from package entity (either body
   --  or spec) it may be the pragma given for private/statements section.

   Entity_List : Node_Lists.List;
   --  List of entities that should be translated to Why3. This list contains
   --  non-package entities in SPARK and packages with explicit SPARK_Mode =>
   --  On. VCs should be generated only for entities in the current unit. Each
   --  entity may be attached to a declaration or not (for Itypes).

   Entity_Set : Hashed_Node_Sets.Set;
   --  Set of all entities marked so far. It contains entities from both the
   --  current compilation unit and other units.

   Entities_In_SPARK : Hashed_Node_Sets.Set;
   --  Entities in SPARK. An entity is added to this set if, after marking,
   --  no violations where attached to the corresponding scope. Standard
   --  entities are individually added to this set.

   Bodies_In_SPARK : Hashed_Node_Sets.Set;
   --  Unique defining entities whose body is marked in SPARK; for kinds of
   --  entities in this set see the contract of Entity_Body_In_SPARK.

   Bodies_Compatible_With_SPARK : Hashed_Node_Sets.Set;
   --  Unique defining entities for expression functions whose body does not
   --  contain SPARK violations. Entities that are in this set and not in
   --  Bodies_In_SPARK are expression functions that are compatible with
   --  SPARK and subject to SPARK_Mode of Auto. Thus, their body should not
   --  be analyzed for AoRTE, but it can be used as implicit postcondition
   --  for analyzing calls to the function. This ensures that GNATprove treats
   --  similarly a subprogram with an explicit postcondition and an expression
   --  function with an implicit postcondition when they are subject to
   --  SPARK_Mode of Auto.

   Full_Views_Not_In_SPARK : Node_Sets.Set;
   --  Registers type entities in SPARK whose full view was declared in a
   --  private part with SPARK_Mode => Off or a subtype or derived type of such
   --  an entity.

   Delayed_Type_Aspects : Node_Maps.Map;
   --  Stores subprograms from aspects of types whose analysis should be
   --  delayed until the end of the analysis and maps them either to their
   --  SPARK_Mode entity if there is one or to their type entity in discovery
   --  mode.

   Access_To_Incomplete_Types : Node_Lists.List;
   --  Stores access types designating incomplete types. We cannot mark
   --  them when they are encountered as it might pull entities in an
   --  inappropiate order. We mark them at the end and raise an error if they
   --  are not in SPARK.

   Access_To_Incomplete_Views : Node_Maps.Map;
   --  Links full views of incomplete types to an access type designating the
   --  incomplete type.

   Loop_Entity_Set : Hashed_Node_Sets.Set;
   --  Set of entities defined in loops before the invariant, which may require
   --  a special translation. See gnat2why.ads for details.

   Actions_Entity_Set : Hashed_Node_Sets.Set;
   --  Set of entities defined in actions which require a special translation.
   --  See gnat2why.ads for details.

   Annot_Pkg_Seen : Hashed_Node_Sets.Set;
   --  Set of package entities that have already been processed to look for
   --  pragma Annotate.

   Marking_Queue : Node_Lists.List;
   --  This queue is used to store entities for marking, in the case where
   --  calling Mark_Entity directly would not be appropriate, e.g. for
   --  primitive operations of a tagged type.

   Goto_Labels : Node_Sets.Set;
   --  Goto labels encountered during marking

   Raise_Exprs_From_Pre : Node_Sets.Set;
   --  Store raise expressions occuring in preconditions

   Relaxed_Init : Node_To_Bool_Maps.Map;
   --  Map representative types which can be parts of objects with relaxed
   --  initialization to a flag which is true if the type has relaxed
   --  initialization itself.

   function Entity_In_SPARK (E : Entity_Id) return Boolean
     renames Entities_In_SPARK.Contains;

   function Entity_Marked (E : Entity_Id) return Boolean
     renames Entity_Set.Contains;

   function Entity_Body_In_SPARK (E : Entity_Id) return Boolean
     renames Bodies_In_SPARK.Contains;

   function Entity_Body_Compatible_With_SPARK
     (E : E_Function_Id)
      return Boolean
   is (Bodies_Compatible_With_SPARK.Contains (E));

   function Full_View_Not_In_SPARK (E : Type_Kind_Id) return Boolean is
     (Full_Views_Not_In_SPARK.Contains (E));

   function Has_Incomplete_Access (E : Type_Kind_Id) return Boolean is
     (Access_To_Incomplete_Views.Contains (Retysp (E)));

   function Get_Incomplete_Access (E : Type_Kind_Id) return Access_Kind_Id is
     (Access_To_Incomplete_Views.Element (Retysp (E)));

   function Raise_Occurs_In_Pre (N : N_Raise_Expression_Id) return Boolean is
     (Raise_Exprs_From_Pre.Contains (N));

   function Is_Loop_Entity (E : Constant_Or_Variable_Kind_Id) return Boolean is
      (Loop_Entity_Set.Contains (E));

   function Is_Actions_Entity (E : Entity_Id) return Boolean
     renames Actions_Entity_Set.Contains;

   function Is_Valid_Allocating_Context (Alloc : Node_Id) return Boolean;
   --  Return True if node Alloc is a valid allocating context (SPARK RM 4.8).
   --  i.e. the newly allocated memory is stored in an object as part of an
   --  assignment, a declaration or a return statement.

   procedure Discard_Underlying_Type (T : Type_Kind_Id);
   --  Mark T's underlying type as seen and store T as its partial view

   procedure Queue_For_Marking (E : Entity_Id);
   --  Register E for marking at a later stage

   procedure Check_Source_Of_Borrow_Or_Observe
     (Expr       : N_Subexpr_Id;
      In_Observe : Boolean)
   with
     Post => (if not Violation_Detected
              then Is_Path_Expression (Expr)
                and then Present (Get_Root_Object (Expr)));
   --  Check that a borrow or observe has a valid source (stand-alone object
   --  or call to a traversal function, that does not go through a slice in
   --  the case of a borrow).

   procedure Check_Source_Of_Move
     (Expr        : N_Subexpr_Id;
      To_Constant : Boolean := False);
   --  Check that a move has a valid source

   procedure Check_Compatible_Access_Types
     (Expected_Type : Type_Kind_Id;
      Expression    : N_Has_Etype_Id);
   --  If Expected_Type is an anonymous access type, check that the type of
   --  Expression and Expected_Type have compatible designated types. This is
   --  used to ensure that there can be no conversions between access types
   --  with different representative types.

   procedure Check_User_Defined_Eq
     (Ty  : Type_Kind_Id;
      E   : Entity_Id;
      Msg : String);
   --  If Ty is a record type, mark the user-defined equality on it and check
   --  that it does not have a precondition. If a precondition is found, raise
   --  a violation on E using the string Msg to refer to E.

   ------------------------------
   -- Body_Statements_In_SPARK --
   ------------------------------

   function Body_Statements_In_SPARK (E : E_Package_Id) return Boolean is
      Prag : constant Node_Id :=
        SPARK_Aux_Pragma (Defining_Entity (Package_Body (E)));
   begin
      return
        (if Present (Prag) then Get_SPARK_Mode_From_Annotation (Prag) /= Off);
   end Body_Statements_In_SPARK;

   --------------------------
   -- Entity_Spec_In_SPARK --
   --------------------------

   function Entity_Spec_In_SPARK (E : Entity_Id) return Boolean is
      Prag : constant Node_Id := SPARK_Pragma (E);
   begin
      return
        Present (Prag) and then Get_SPARK_Mode_From_Annotation (Prag) = Opt.On;
   end Entity_Spec_In_SPARK;

   ---------------------------
   -- Private_Spec_In_SPARK --
   ---------------------------

   function Private_Spec_In_SPARK (E : Entity_Id) return Boolean is
   begin
      return
        Entity_Spec_In_SPARK (E) and then
        Get_SPARK_Mode_From_Annotation (SPARK_Aux_Pragma (E)) /= Off;
   end Private_Spec_In_SPARK;

   ----------------------
   -- Inhibit_Messages --
   ----------------------

   procedure Inhibit_Messages is
   begin
      --  This procedure can be called only once, before the marking itself
      pragma Assert (Emit_Messages and then Entity_Set.Is_Empty);

      Emit_Messages := False;
   end Inhibit_Messages;

   ----------------------------------
   -- Recursive Marking of the AST --
   ----------------------------------

   procedure Mark (N : Node_Id);
   --  Generic procedure for marking code

   procedure Mark_Constant_Globals (Globals : Node_Sets.Set);
   --  Mark constant objects in the Initializes or Global/Depends contract (or
   --  their refined variant). We want to detect constants not in SPARK, even
   --  if they only appear in the flow contracts, to handle them as having no
   --  variable input.

   function Most_Underlying_Type_In_SPARK (Id : Type_Kind_Id) return Boolean;
   --  Mark the Retysp of Id and check that it is not completely private

   function Retysp_In_SPARK (E : Type_Kind_Id) return Boolean
     with Post => (if not Retysp_In_SPARK'Result then not Entity_In_SPARK (E));
   --  Returns whether the representive type of the entity E is in SPARK;
   --  computes this information by calling Mark_Entity, which is very cheap.
   --  Theoretically, it is equivalent to In_SPARK (Retyps (E)) except that
   --  Retysp can only be called on Marked entities.

   procedure Mark_Entity (E : Entity_Id);
   --  Push entity E on the stack, mark E, and pop E from the stack. Always
   --  adds E to the set of Entity_Set as a result. If no violation was
   --  detected, E is added to the Entities_In_SPARK.

   --  Marking of declarations

   procedure Mark_Object_Declaration          (N : N_Object_Declaration_Id);

   procedure Mark_Package_Body                (N : N_Package_Body_Id);
   procedure Mark_Package_Declaration         (N : N_Package_Declaration_Id);

   procedure Mark_Concurrent_Type_Declaration (N : Node_Id);
   --  Mark declarations of concurrent types

   procedure Mark_Protected_Body              (N : N_Protected_Body_Id);
   --  Mark bodies of protected types

   procedure Mark_Subprogram_Body             (N : Node_Id);
   --  Mark bodies of functions, procedures, task types and entries

   procedure Mark_Subprogram_Declaration      (N : Node_Id);
   --  N is either a subprogram declaration node, or a subprogram body node
   --  for those subprograms which do not have a prior declaration (not
   --  counting a stub as a declaration); it works also for entry and task
   --  type declarations.

   --  Special treatment for marking some kinds of nodes
   --  ??? Do we want preconditions on these? For example
   --  Mark_Identifier_Or_Expanded_Name on N_Entry_Body is wrong but does
   --  not fail.

   procedure Mark_Attribute_Reference         (N : N_Attribute_Reference_Id);
   procedure Mark_Binary_Op                   (N : N_Binary_Op_Id);

   procedure Mark_Call                        (N : Node_Id) with
     Pre => Nkind (N) in N_Subprogram_Call | N_Entry_Call_Statement;

   procedure Mark_Address                     (E : Entity_Id)
     with Pre => Ekind (E) in Object_Kind | E_Function | E_Procedure;

   procedure Mark_Component_Association       (N : N_Component_Association_Id);
   procedure Mark_Handled_Statements
     (N : N_Handled_Sequence_Of_Statements_Id);
   procedure Mark_Identifier_Or_Expanded_Name (N : Node_Id);
   procedure Mark_If_Expression               (N : N_If_Expression_Id);
   procedure Mark_If_Statement                (N : N_If_Statement_Id);
   procedure Mark_Iteration_Scheme            (N : N_Iteration_Scheme_Id);
   procedure Mark_Pragma                      (N : N_Pragma_Id);
   procedure Mark_Simple_Return_Statement
     (N : N_Simple_Return_Statement_Id);
   procedure Mark_Extended_Return_Statement
     (N : N_Extended_Return_Statement_Id);
   procedure Mark_Unary_Op                    (N : N_Unary_Op_Id);
   procedure Mark_Subtype_Indication          (N : N_Subtype_Indication_Id);

   procedure Mark_Stmt_Or_Decl_List           (L : List_Id);
   --  Mark a list of statements and declarations, and register any pragma
   --  Annotate (GNATprove) which may be part of that list.

   procedure Mark_Aspect_Clauses_And_Pragmas_In_List (L : List_Id);
   --  Mark only pragmas and aspect clauses in a list of statements and
   --  declarations. Do not register pragmas Annotate (GNATprove) which are
   --  part of that list.

   procedure Mark_Actions (N : Node_Id; L : List_Id);
   --  Mark a possibly null list of actions L from node N. It should be
   --  called before the node to which the actions apply is marked, so
   --  that declarations of constants in actions are possibly marked in SPARK.

   procedure Mark_List (L : List_Id);
   --  Call Mark on all nodes in list L

   procedure Mark_Pragma_Annot_In_Pkg (E : E_Package_Id);
   --  Mark pragma Annotate that could appear at the beginning of a declaration
   --  list of a package.

   procedure Mark_Type_With_Relaxed_Init
     (N   : Node_Id;
      Ty  : Type_Kind_Id;
      Own : Boolean := False)
     with Pre => Entity_In_SPARK (Ty);
   --  Checks restrictions on types marked with a Relaxed_Initialization aspect
   --  and store them in the Relaxed_Init map for further use.
   --  @param N node on which violations should be emitted.
   --  @param Ty type which should be compatible with relaxed initialization.
   --  @param Own True if Ty is itself annotated with relaxed initialization.

   function Emit_Warning_Info_Messages return Boolean is
     (Emit_Messages and then Gnat2Why_Args.Limit_Subp = Null_Unbounded_String);
   --  Emit warning/info messages only when messages should be emitted, and
   --  analysis is not restricted to a single subprogram/line (typically during
   --  interactive use in IDEs), to avoid reporting messages on pieces of code
   --  not belonging to the analyzed subprogram/line.

   function Is_Incomplete_Type_From_Limited_With (E : Entity_Id) return Boolean
   is
     ((Is_Incomplete_Type (E) or else Is_Class_Wide_Type (E))
      and then From_Limited_With (E));
   --  Return true of the limited view of a type coming from a limited with

   procedure Reject_Incomplete_Type_From_Limited_With
     (Limited_View  : Entity_Id;
      Marked_Entity : Entity_Id)
   with Pre => Is_Incomplete_Type_From_Limited_With (Limited_View);
   --  For now, reject incomplete types coming from limited with.
   --  They need to be handled using their No_Limited_View if they
   --  have one. Unlike other incomplete types, the frontend does
   --  not replace them by their non-limited view when they occur as a
   --  parameter subtype or the result type in a subprogram
   --  declaration, so we cannot avoid marking them altogether as we
   --  do for regular incomplete types with a full view.
   --  As limited view do not have an appropriate location, when an entity
   --  Marked_Entity has a limited type, the violation is emited on
   --  Marked_Entity instead.

   -----------------------------------
   -- Check_Compatible_Access_Types --
   -----------------------------------

   procedure Check_Compatible_Access_Types
     (Expected_Type : Type_Kind_Id;
      Expression    : N_Has_Etype_Id)
   is
      Actual_Type     : constant Type_Kind_Id := Etype (Expression);
      Actual_Des_Ty   : Type_Kind_Id;
      Expected_Des_Ty : Type_Kind_Id;
   begin
      if Is_Anonymous_Access_Object_Type (Expected_Type) then

         --  Get the designated types of the root type of the actual and
         --  expected types.

         Actual_Des_Ty := Directly_Designated_Type (Root_Retysp (Actual_Type));
         Expected_Des_Ty :=
           Directly_Designated_Type (Root_Retysp (Expected_Type));
         if Is_Incomplete_Type (Actual_Des_Ty)
           and then Present (Full_View (Actual_Des_Ty))
         then
            Actual_Des_Ty := Full_View (Actual_Des_Ty);
         end if;
         if Is_Incomplete_Type (Expected_Des_Ty)
           and then Present (Full_View (Expected_Des_Ty))
         then
            Expected_Des_Ty := Full_View (Expected_Des_Ty);
         end if;

         --  Check if they have the same Retysp. Only do this check if both
         --  designated types are in SPARK (we need to check this here as
         --  marking of the designated type of recursive access types might be
         --  deferred).

         if In_SPARK (Actual_Des_Ty)
           and then In_SPARK (Expected_Des_Ty)
           and then Retysp (Actual_Des_Ty) /= Retysp (Expected_Des_Ty)
         then
            Mark_Unsupported (Lim_Access_Conv, Expression);
         end if;
      end if;
   end Check_Compatible_Access_Types;

   ---------------------------------------
   -- Check_Source_Of_Borrow_Or_Observe --
   ---------------------------------------

   procedure Check_Source_Of_Borrow_Or_Observe
     (Expr       : N_Subexpr_Id;
      In_Observe : Boolean)
   is
      function Path_Goes_Through_Slice (Expr : Node_Id) return Boolean;
      --  Determine if borrowed path Expr goes through a slice

      -----------------------------
      -- Path_Goes_Through_Slice --
      -----------------------------

      function Path_Goes_Through_Slice (Expr : Node_Id) return Boolean is
      begin
         case Nkind (Expr) is
            when N_Slice =>
               return True;

            when N_Attribute_Reference
               | N_Explicit_Dereference
               | N_Indexed_Component
               | N_Selected_Component
            =>
               return Path_Goes_Through_Slice (Prefix (Expr));

            when N_Qualified_Expression
               | N_Type_Conversion
               | N_Unchecked_Type_Conversion
            =>
               return Path_Goes_Through_Slice (Expression (Expr));

            when others =>
               return False;
         end case;
      end Path_Goes_Through_Slice;

      --  Local variables

      Root : constant Opt_Object_Kind_Id :=
        (if Is_Path_Expression (Expr) then Get_Root_Object (Expr)
         else Empty);

   --  Start of processing for Check_Source_Of_Borrow_Or_Observe

   begin
      --  SPARK RM 3.10(4): If the target of an assignment operation is an
      --  object of an anonymous access-to-object type (including copy-in for
      --  a parameter), then the source shall be a name denoting a part of a
      --  stand-alone object, a part of a parameter, or a call to a traversal
      --  function.

      if No (Root) then
         Mark_Violation
           ((if Nkind (Expr) = N_Function_Call
             then "borrow or observe of a non-traversal function call"
             else "borrow or observe of an expression which is not part of "
                  & "stand-alone object or parameter"),
            Expr,
            SRM_Reference => "SPARK RM 3.10(4))");

      --  The root object should not be effectively volatile

      elsif Is_Effectively_Volatile (Root) then
         Mark_Violation
           ("borrow or observe of a volatile object", Expr);

      --  In case of a borrow, the root should not be a constant object or it
      --  should be the first parameter of a borrowing traversal function in
      --  which case the borrower is constant.

      elsif not In_Observe
        and then Is_Constant_In_SPARK (Root)
        and then
          not (Ekind (Root) = E_In_Parameter
               and then Ekind (Scope (Root)) = E_Function
               and then Is_Borrowing_Traversal_Function (Scope (Root))
               and then Root = First_Formal (Scope (Root)))
      then
         Mark_Violation ("borrow of a constant object", Expr);

      --  In case of a borrow, the path should not traverse an
      --  access-to-constant type.

      elsif not In_Observe and then Traverse_Access_To_Constant (Expr) then
         Mark_Violation
           ("borrow of an access-to-constant part of an object", Expr);

      --  Borrows going through a slice are not supported, and are not
      --  necessary either since the slice is necessary followed by an
      --  indexed_component.

      elsif not In_Observe
        and then Path_Goes_Through_Slice (Expr)
      then
         Mark_Violation ("borrow through a slice", Expr);
      end if;
   end Check_Source_Of_Borrow_Or_Observe;

   --------------------------
   -- Check_Source_Of_Move --
   --------------------------

   procedure Check_Source_Of_Move
     (Expr        : N_Subexpr_Id;
      To_Constant : Boolean := False) is
   begin
      if not Is_Path_Expression (Expr) then
         Mark_Violation ("expression as source of move", Expr);
      elsif not To_Constant and then Traverse_Access_To_Constant (Expr) then
         Mark_Violation
           ("access-to-constant part of an object as source of move", Expr);
      elsif Path_Contains_Traversal_Calls (Expr) then
         Mark_Violation
           ("call to a traversal function as source of move", Expr);
      else
         declare
            Root : constant Opt_Object_Kind_Id := Get_Root_Object (Expr);
         begin
            if Present (Root)
              and then Is_Effectively_Volatile (Root)
            then
               Mark_Violation ("move of a volatile object", Expr);
            end if;
         end;
      end if;
   end Check_Source_Of_Move;

   ---------------------------
   -- Check_User_Defined_Eq --
   ---------------------------

   procedure Check_User_Defined_Eq
     (Ty  : Type_Kind_Id;
      E   : Entity_Id;
      Msg : String)
   is
      Eq : Entity_Id := SPARK_Util.Types.Get_User_Defined_Eq (Base_Type (Ty));
   begin
      if Is_Record_Type (Unchecked_Full_Type (Ty))
        and then Present (Eq)
      then
         Eq := Ultimate_Alias (Eq);

         Mark_Entity (Eq);
         if not Entity_In_SPARK (Eq) then
            Mark_Violation
              (Msg & " whose primitive equality is not in SPARK",
               E);
            Mark_Violation (E, From => Eq);
         elsif not Find_Contracts (Eq, Pragma_Precondition).Is_Empty then
            Mark_Violation
              ("precondition on primitive equality of " & Msg, E);
         end if;
      end if;
   end Check_User_Defined_Eq;

   -----------------------------
   -- Discard_Underlying_Type --
   -----------------------------

   procedure Discard_Underlying_Type (T : Type_Kind_Id) is
      U : constant Type_Kind_Id := Underlying_Type (T);
   begin
      if U /= T then
         Entity_Set.Include (U);
         if not Is_Full_View (U) then
            Set_Partial_View (U, T);
         end if;
      end if;
   end Discard_Underlying_Type;

   --------------------
   -- Get_SPARK_JSON --
   --------------------

   function Get_SPARK_JSON return JSON_Value is
      SPARK_Status_JSON : constant JSON_Value := Create_Object;

   begin
      --  ??? Iterating over all entities is not efficient, but we do it only
      --  once. Perhaps iteration over hierarchical Entity_Tree would allow to
      --  skip entities from non-main unit and those whose parent is not in
      --  SPARK. However, Entity_Tree does not contain protected types (maybe
      --  it should?) while we want to generate SPARK status for them (maybe
      --  we should not?).

      for E of Entity_List loop
         --  Only add infomation for an entity if analysis is requested for it.
         --  Then, absence of errors in flow and warnings in proof for it can
         --  be interpreted as a correct flow analysis or proof for it.

         if Ekind (E) in Entry_Kind       |
                         E_Function       |
                         E_Procedure      |
                         E_Package        |
                         E_Protected_Type |
                         E_Task_Type
           and then Analysis_Requested (E, With_Inlined => True)
         then
            declare
               V            : constant Subp_Type :=
                 Entity_To_Subp_Assumption (E);

               SPARK_Status : constant SPARK_Mode_Status :=
                 (if Entity_Body_In_SPARK (E)
                  then All_In_SPARK
                  elsif Entity_Spec_In_SPARK (E)
                  then
                    (if Ekind (E) = E_Package and then No (Package_Body (E))
                     then All_In_SPARK
                     else Spec_Only_In_SPARK)
                  else Not_In_SPARK);
            begin
               Set_Field (SPARK_Status_JSON, To_Key (V),
                          To_JSON (SPARK_Status));
            end;

         elsif Is_Type (E)
           and then Entity_In_SPARK (E)
           and then E = Retysp (E)
           and then Analysis_Requested (E, With_Inlined => True)
           and then
             (Needs_Default_Checks_At_Decl (E)
              or else (Is_Access_Subprogram_Type (E)
                       and then No (Parent_Retysp (E))))
         then

            --  If the entity is a record or private type with fields hidden
            --  from SPARK, then the default initialization was not verified.

            declare
               V            : constant Subp_Type :=
                 Entity_To_Subp_Assumption (E);
               SPARK_Status : constant SPARK_Mode_Status :=
                 (if
                    (Has_Record_Type (E)
                     or else Has_Incomplete_Or_Private_Type (E))
                    and then Has_Private_Fields (E)
                  then Not_In_SPARK
                  else All_In_SPARK);
            begin
               Set_Field (SPARK_Status_JSON, To_Key (V),
                          To_JSON (SPARK_Status));
            end;
         end if;
      end loop;

      return SPARK_Status_JSON;
   end Get_SPARK_JSON;

   ----------------------
   -- Has_Relaxed_Init --
   ----------------------

   function Has_Relaxed_Init (E : Type_Kind_Id) return Boolean is
      use Node_To_Bool_Maps;
      C : constant Node_To_Bool_Maps.Cursor :=
        Relaxed_Init.Find (Base_Retysp (E));
   begin
      return Has_Element (C) and then Element (C);
   end Has_Relaxed_Init;

   ---------------------
   -- In_Relaxed_Init --
   ---------------------

   function In_Relaxed_Init (E : Type_Kind_Id) return Boolean is
     (Relaxed_Init.Contains (Base_Retysp (E)));

   --------------
   -- In_SPARK --
   --------------

   function In_SPARK (E : Entity_Id) return Boolean is
   begin
      --  Incomplete types coming from limited with should never be marked as
      --  they have an inappropriate location. The construct referencing them
      --  should be rejected instead.

      if Is_Incomplete_Type_From_Limited_With (E) then
         return False;
      end if;

      Mark_Entity (E);
      return Entities_In_SPARK.Contains (E);
   end In_SPARK;

   ----------------------
   -- Is_Clean_Context --
   ----------------------

   function Is_Clean_Context return Boolean is
     (No (Current_SPARK_Pragma)
      and not Violation_Detected
      and not Inside_Actions
      and Marking_Queue.Is_Empty
      and Delayed_Type_Aspects.Is_Empty
      and Access_To_Incomplete_Types.Is_Empty);

   ---------------------------------
   -- Is_Valid_Allocating_Context --
   ---------------------------------

   function Is_Valid_Allocating_Context (Alloc : Node_Id) return Boolean is
      Subcontext : Node_Id := Alloc;
      Context    : Node_Id := Parent (Subcontext);
   begin
      --  The allocating expression appears in an assertion. This is allowed,
      --  even though a resource leak is certain to occur in that case if
      --  assertions are enabled, and will be reported by GNATprove.

      if In_Assertion_Expression_Pragma (Alloc) then
         return True;
      end if;

      loop
         case Nkind (Context) is

            --  The allocating expression appears on the rhs of an assignment,
            --  object declaration or return statement, which is not inside a
            --  declare expression.

            when N_Assignment_Statement
               | N_Object_Declaration
               | N_Simple_Return_Statement
            =>
               return Present (Expression (Context))
                 and then Expression (Context) = Subcontext
                 and then
                   Nkind (Parent (Context)) /= N_Expression_With_Actions;

            --  The allocating expression is the expression of a type
            --  conversion or a qualified expression occurring in a
            --  valid allocating context.

            when N_Qualified_Expression
               | N_Type_Conversion
               | N_Unchecked_Type_Conversion
            =>
               null;

            --  The allocating expression occurs as the expression in another
            --  initialized allocator.

            when N_Allocator =>
               return True;

            --  The allocating expression corresponds to a component value in
            --  an aggregate occurring in an allocating context.

            when N_Aggregate
               | N_Component_Association
               | N_Iterated_Component_Association
               | N_Delta_Aggregate
               | N_Extension_Aggregate
            =>
               null;

            when others =>
               return False;
         end case;

         Subcontext := Context;
         Context := Parent (Context);
      end loop;
   end Is_Valid_Allocating_Context;

   ----------
   -- Mark --
   ----------

   procedure Mark (N : Node_Id) is

      -----------------------
      -- Local subprograms --
      -----------------------

      procedure Check_Loop_Invariant_Placement
        (Stmts       : List_Id;
         Goto_Labels : in out Node_Sets.Set;
         Nested      : Boolean);
      --  Checks that no non-scalar object declaration appears before the
      --  last loop-invariant or variant in a loop's list of statements. Also
      --  stores scalar objects declared before the last loop-invariant in
      --  Loop_Entity_Set. Nested should be true when checking statements
      --  coming from a nested construct of the loop (if, case, extended
      --  return statements and nested loops). Goto_Labels contains the labels
      --  encountered while traversing statements occurring after the loop
      --  invariant in the initial loop.

      procedure Check_Loop_Invariant_Placement (Stmts : List_Id);
      --  Same as above with Nested set to False and Goto_Labels initialized to
      --  the empty set.

      procedure Check_Unrolled_Loop (Loop_Stmt : N_Loop_Statement_Id);
      --  If Loop_Stmt is candidate for loop unrolling, then mark all objects
      --  declared in the loop so that their translation into Why3 does not
      --  introduce constants.

      procedure Check_No_Deep_Duplicates_In_Assoc (N : N_Aggregate_Kind_Id);
      --  Search for associations mapping a single deep value to several
      --  components in the Component_Associations of N.

      function Is_Update_Aggregate (Aggr : Node_Id) return Boolean;
      --  Detect whether Aggr is an aggregate node modelling 'Update. Returns
      --  false for a normal aggregate.

      function Is_Update_Unconstr_Multidim_Aggr
        (Aggr : N_Aggregate_Id)
         return Boolean
      with Pre => Is_Update_Aggregate (N);
      --  Detect whether a 'Update aggregate is an update of an
      --  unconstrained multidimensional array.

      function Is_Special_Multidim_Update_Aggr
        (Aggr : N_Aggregate_Id)
         return Boolean;
      --  Detect special case of AST node.
      --  For an 'Update of a multidimensional array, the indexed components
      --    (the expressions (1, 1), (2, 2) and (3, 3) in example
      --     Arr_A2D'Update ((1, 1) => 1,  (2, 2) => 2, (3, 3) => 3,
      --     where Arr_A2D is a two-dimensional array)
      --  are modelled in the AST using an aggregate node which does not have a
      --  a type. An aggregate node is expected to have a type, but this kind
      --  of expression (indexed components) is not, so need to detect special
      --  case here.
      --  Why aren't these kind of nodes Indexed_Components instead?

      ------------------------------------
      -- Check_Loop_Invariant_Placement --
      ------------------------------------

      procedure Check_Loop_Invariant_Placement (Stmts : List_Id) is
         Goto_Labels : Node_Sets.Set;
      begin
         Check_Loop_Invariant_Placement (Stmts, Goto_Labels, False);
      end Check_Loop_Invariant_Placement;

      procedure Check_Loop_Invariant_Placement
        (Stmts       : List_Id;
         Goto_Labels : in out Node_Sets.Set;
         Nested      : Boolean)
      is
         use Node_Lists;

         Loop_Stmts : constant Node_Lists.List :=
           Get_Flat_Statement_And_Declaration_List (Stmts);
         Inv_Found  : Boolean := Nested;
         --  We only call Check_Loop_Invariant_Placement on nested list of
         --  statements if an invariant has been found.

      begin
         for N of reverse Loop_Stmts loop

            if not Inv_Found then

               --  Find last loop invariant/variant from the loop

               if Is_Pragma_Check (N, Name_Loop_Invariant)
                 or else Is_Pragma (N, Pragma_Loop_Variant)
               then
                  Inv_Found := True;
               elsif Nkind (N) = N_Label then
                  Goto_Labels.Insert (Entity (Identifier (N)));
               end if;

            else
               --  Check that there are no non-scalar objects declarations
               --  before the last invariant/variant.

               case Nkind (N) is
                  when N_Object_Declaration =>
                     if Is_Scalar_Type (Etype (Defining_Entity (N))) then
                        --  Store scalar entities defined in loops before the
                        --  invariant in Loop_Entity_Set.

                        Loop_Entity_Set.Include (Defining_Entity (N));
                     else
                        Mark_Unsupported (Lim_Object_Before_Inv, N);
                     end if;

                  when N_Package_Declaration =>
                     Mark_Unsupported (Lim_Package_Before_Inv, N);

                  when N_Subprogram_Declaration
                     | N_Subprogram_Body
                  =>
                     Mark_Unsupported (Lim_Subprogram_Before_Inv, N);

                  --  Go inside if, case, exended return statements and
                  --  nested loops to check for absence of non-scalar
                  --  object declarations.

                  when N_If_Statement =>
                     Check_Loop_Invariant_Placement
                       (Then_Statements (N), Goto_Labels, True);
                     declare
                        Cur : Node_Id := First (Elsif_Parts (N));
                     begin
                        while Present (Cur) loop
                           Check_Loop_Invariant_Placement
                             (Then_Statements (Cur), Goto_Labels, True);
                           Next (Cur);
                        end loop;
                     end;
                     Check_Loop_Invariant_Placement
                       (Else_Statements (N), Goto_Labels, True);

                  when N_Case_Statement =>
                     declare
                        Cases : constant List_Id := Alternatives (N);
                        Cur   : Node_Id := First_Non_Pragma (Cases);
                     begin
                        while Present (Cur) loop
                           Check_Loop_Invariant_Placement
                             (Statements (Cur), Goto_Labels, True);
                           Next_Non_Pragma (Cur);
                        end loop;
                     end;

                  when N_Extended_Return_Statement =>
                     Check_Loop_Invariant_Placement
                       (Return_Object_Declarations (N), Goto_Labels, True);
                     Check_Loop_Invariant_Placement
                       (Statements (Handled_Statement_Sequence (N)),
                        Goto_Labels, True);

                  when N_Loop_Statement =>
                     Check_Loop_Invariant_Placement
                       (Statements (N), Goto_Labels, True);

                  when N_Goto_Statement =>

                     --  Reject goto statements crossing loop invariants

                     if Goto_Labels.Contains (Entity (Name (N))) then
                        Mark_Unsupported (Lim_Goto_Cross_Inv, N);
                     end if;

                  when others => null;
               end case;
            end if;
         end loop;
      end Check_Loop_Invariant_Placement;

      ---------------------------------------
      -- Check_No_Deep_Duplicates_In_Assoc --
      ---------------------------------------

      procedure Check_No_Deep_Duplicates_In_Assoc (N : N_Aggregate_Kind_Id) is

         function Can_Be_Duplicated (N : Node_Id) return Boolean;
         --  Return True if the value N can be duplicated in an aggregate
         --  without creating an alias.

         -----------------------
         -- Can_Be_Duplicated --
         -----------------------

         function Can_Be_Duplicated (N : Node_Id) return Boolean is
         begin
            --  If the type is not deep, then no aliases can occur

            if not Is_Deep (Etype (N)) then
               return True;
            end if;

            case Nkind (N) is

               --  Null can always be safely duplicated

               when N_Null =>
                  return True;

               --  Allocators are fine as long as the allocated value itself
               --  can be duplicated.

               when N_Allocator =>
                  return Nkind (Expression (N)) /= N_Qualified_Expression
                    or else Can_Be_Duplicated (Expression (N));

               when N_Qualified_Expression =>
                  return Can_Be_Duplicated (Expression (N));

               --  Allocating function calls are fine, they necessarily return
               --  new data-structures.

               when N_Function_Call =>
                  return Is_Allocating_Function (Get_Called_Entity (N));

               --  Aggregates are safe if all their expressions can be
               --  duplicated.

               when N_Aggregate =>
                  declare
                     Assocs : constant List_Id := Component_Associations (N);
                     Exprs  : constant List_Id := Expressions (N);
                     Assoc  : Node_Id := Nlists.First (Assocs);
                     Expr   : Node_Id := Nlists.First (Exprs);
                  begin
                     while Present (Assoc) loop
                        if not Box_Present (Assoc)
                          and then not Can_Be_Duplicated (Expression (Assoc))
                        then
                           return False;
                        end if;
                        Next (Assoc);
                     end loop;

                     while Present (Expr) loop
                        if not Can_Be_Duplicated (Expr) then
                           return False;
                        end if;
                        Next (Expr);
                     end loop;

                     return True;
                  end;

               --  Other expressions are not handled precisely yet

               when others =>
                  return False;
            end case;
         end Can_Be_Duplicated;

         Assocs  : constant List_Id := Component_Associations (N);
         Assoc   : Node_Id := First (Assocs);
         Choices : List_Id;

      --  Start of processing for Check_No_Deep_Duplicates_In_Assoc

      begin
         while Present (Assoc) loop
            Choices := Choice_List (Assoc);

            --  There can be only one element for a value of deep type
            --  in order to avoid aliasing.

            if not Box_Present (Assoc)
              and then not Is_Singleton_Choice (Choices)
              and then not Can_Be_Duplicated (Expression (Assoc))
            then
               Mark_Violation
                 ("duplicate value of a type with ownership",
                  First (Choices),
                  Cont_Msg =>
                    "singleton choice required to prevent aliasing");
            end if;

            Next (Assoc);
         end loop;
      end Check_No_Deep_Duplicates_In_Assoc;

      -------------------------
      -- Check_Unrolled_Loop --
      -------------------------

      procedure Check_Unrolled_Loop (Loop_Stmt : N_Loop_Statement_Id) is

         function Handle_Object_Declaration
           (N : Node_Id) return Traverse_Result;
         --  Register specially an object declared in an unrolled loop

         -------------------------------
         -- Handle_Object_Declaration --
         -------------------------------

         function Handle_Object_Declaration
           (N : Node_Id) return Traverse_Result
         is
         begin
            if Nkind (N) = N_Object_Declaration then
               Loop_Entity_Set.Include (Defining_Entity (N));
            end if;

            return OK;
         end Handle_Object_Declaration;

         procedure Handle_All_Object_Declarations is new
           Traverse_More_Proc (Handle_Object_Declaration);

      --  Start of processing for Check_Unrolled_Loop

      begin
         if Is_Selected_For_Loop_Unrolling (Loop_Stmt) then
            Handle_All_Object_Declarations (Loop_Stmt);
         end if;
      end Check_Unrolled_Loop;

      -------------------------
      -- Is_Update_Aggregate --
      -------------------------

      function Is_Update_Aggregate (Aggr : Node_Id) return Boolean is
      begin
         return Nkind (Aggr) = N_Aggregate
            and then Is_Attribute_Update (Parent (Aggr));
      end Is_Update_Aggregate;

      --------------------------------------
      -- Is_Update_Unconstr_Multidim_Aggr --
      --------------------------------------

      function Is_Update_Unconstr_Multidim_Aggr
        (Aggr : N_Aggregate_Id)
         return Boolean
      is
         Pref_Type : constant Type_Kind_Id := Etype (Prefix (Parent (Aggr)));
      begin
         return Is_Array_Type (Pref_Type)
           and then Number_Dimensions (Pref_Type) > 1
           and then not Is_Static_Array_Type (Pref_Type);
      end Is_Update_Unconstr_Multidim_Aggr;

      -------------------------------------
      -- Is_Special_Multidim_Update_Aggr --
      -------------------------------------

      function Is_Special_Multidim_Update_Aggr
        (Aggr : N_Aggregate_Id)
         return Boolean
      is
         Pref, Par, Grand_Par, Grand_Grand_Par : Node_Id;
      begin
         Par := Parent (Aggr);

         if Present (Par) then
            Grand_Par := Parent (Par);

            if Present (Grand_Par)
              and then Is_Update_Aggregate (Grand_Par)
            then
               Grand_Grand_Par := Parent (Grand_Par);
               Pref := Prefix (Grand_Grand_Par);

               if Is_Array_Type (Etype (Pref))
                 and then Number_Dimensions (Etype (Pref)) > 1
               then
                  return True;
               end if;
            end if;
         end if;

         return False;
      end Is_Special_Multidim_Update_Aggr;

   --  Start of processing for Mark

   begin
      Current_Error_Node := N;

      --  The type may be absent on kinds of nodes that should have types,
      --  in very special cases, like the fake aggregate node in a 'Update
      --  attribute_reference, and the fake identifier node for an abstract
      --  state. So we also check that the type is explicitly present and that
      --  it is indeed a type (and not Standard_Void_Type).

      if Nkind (N) in N_Has_Etype
        and then Present (Etype (N))
        and then Is_Type (Etype (N))
      then
         --  If an expression is of type Universal_Real, then we cannot
         --  translate it into Why3. This may occur when asserting properties
         --  fully over real values. Compiler will pick the largest
         --  floating-point type in that case. GNATprove should reject
         --  such cases.

         if Etype (N) = Universal_Real then
            --  Specialize the error message for fixed-point multiplication or
            --  division with one argument of type Universal_Real, and suggest
            --  to fix by qualifying the literal value.

            if Nkind (Parent (N)) in N_Op_Multiply | N_Op_Divide
              and then Has_Fixed_Point_Type (Etype (Parent (N)))
            then
               Mark_Violation
                 ("real literal argument to fixed-point "
                  & "multiplication or division", N,
                  Cont_Msg => "use qualification to give a fixed-point type "
                  & "to the real literal");
            else
               Mark_Violation
                 ("expression of type root_real", N,
                  Cont_Msg => "value is dependent on the compiler and target");
            end if;

            --  Return immediately to avoid issuing the same message on all
            --  sub-expressions of this expression.

            return;

         --  If present, the type of N should be in SPARK. This also allows
         --  marking Itypes and class-wide types at their first occurrence
         --  (inside In_SPARK).

         --  The Itype may be located in some other unit than the expression,
         --  and a violation of SPARK_Mode on the Itype may mask another
         --  violation on the expression. As we prefer to have the error
         --  located on the expression, we mark the type of the node after
         --  the expression.

         elsif not Retysp_In_SPARK (Etype (N)) then
            Mark_Violation (N, From => Etype (N));
         end if;
      end if;

      --  Dispatch on node kind

      case Nkind (N) is

         when N_Abstract_Subprogram_Declaration =>
            Mark_Subprogram_Declaration (N);

         when N_Aggregate =>

            --  Reject 'Update on unconstrained multidimensional array

            if Is_Update_Aggregate (N)
              and then Is_Update_Unconstr_Multidim_Aggr (N)
            then
               Mark_Unsupported (Lim_Multidim_Update, N);

            --  Special aggregates for indexes of updates of multidim arrays do
            --  not have a type, see comment on
            --  Is_Special_Multidim_Update_Aggr.

            elsif not Is_Special_Multidim_Update_Aggr (N)
              and then not Most_Underlying_Type_In_SPARK (Etype (N))
            then
               Mark_Violation (N, From => Etype (N));
            else
               Mark_List (Expressions (N));
               Mark_List (Component_Associations (N));
               Check_No_Deep_Duplicates_In_Assoc (N);
            end if;

         when N_Allocator =>
            if not Is_Valid_Allocating_Context (N) then
               Mark_Violation
                 ("allocator not stored in object as "
                  & "part of assignment, declaration or return", N);

            --  Currently forbid the use of an uninitialized allocator (for
            --  a type which defines full default initialization) inside
            --  an expression function, as this requires translating the
            --  expression in the term domain. As the frontend does not
            --  expand the default value of the type here, this would
            --  require using an epsilon in Why3 which we prefer avoid
            --  doing outside of axiom guards.

            elsif Nkind (Expression (N)) /= N_Qualified_Expression
              and then Nkind (Enclosing_Declaration (N)) =
                N_Subprogram_Body
              and then Is_Expression_Function_Or_Completion
                  (Unique_Defining_Entity (Enclosing_Declaration (N)))
            then
               Mark_Unsupported (Lim_Uninit_Alloc_In_Expr_Fun, N);

            --  Check that the type of the allocator is visibly an access
            --  type.

            elsif Retysp_In_SPARK (Etype (N))
              and then Is_Access_Type (Retysp (Etype (N)))
            then
               --  If the expression is a qualified expression, then we
               --  have an initialized allocator.

               if Nkind (Expression (N)) = N_Qualified_Expression then
                  Mark (Expression (N));

               --  Otherwise the expression is a subtype indicator and we
               --  have an uninitialized allocator.

               else
                  declare
                     --  In non-interfering contexts the subtype indicator
                     --  is always a subtype name, because frontend creates
                     --  an itype for each constrained subtype indicator.
                     Expr : constant Node_Id := Expression (N);
                     pragma Assert (Is_Entity_Name (Expr));

                     Typ  : constant Type_Kind_Id := Entity (Expr);
                  begin
                     if not In_SPARK (Typ) then
                        Mark_Violation (Expr, Typ);

                     elsif Default_Initialization (Typ)
                     not in Full_Default_Initialization
                       | No_Possible_Initialization
                     then
                        Mark_Violation ("uninitialized allocator without"
                                        & " default initialization", N);
                     end if;
                  end;
               end if;

               --  The initial value of the allocator is moved. We need
               --  to consider it specifically in the case of allocators
               --  to access-to-constant types as the allocator type is
               --  not itself of a deep type.

               if Is_Access_Constant (Retysp (Etype (N)))
                 and then Nkind (Expression (N)) = N_Qualified_Expression
               then
                  declare
                     Des_Ty : Type_Kind_Id :=
                       Directly_Designated_Type (Retysp (Etype (N)));
                  begin
                     if Is_Incomplete_Type (Des_Ty) then
                        Des_Ty := Full_View (Des_Ty);
                     end if;

                     if Is_Deep (Des_Ty) then
                        Check_Source_Of_Move
                          (Expression (N), To_Constant => True);
                     end if;
                  end;
               end if;
            else
               Mark_Violation (N, Etype (N));
            end if;

         when N_Assignment_Statement =>
            declare
               Var  : constant Node_Id := Name (N);
               Expr : constant Node_Id := Expression (N);
            begin
               Mark (Var);
               Mark (Expr);

               --  ??? We need a rule that forbids targets of assignment for
               --  which the path is not known, for example when there is a
               --  function call involved (which includes calls to traversal
               --  functions). Otherwise there is no way to update the
               --  corresponding path permission.

               if not Is_Path_Expression (Var)
                 or else No (Get_Root_Object
                             (Var, Through_Traversal => False))
               then
                  Mark_Violation ("assignment to a complex expression", Var);

               --  Assigned object should not be a constant

               elsif Is_Constant_In_SPARK (Get_Root_Object (Var)) then
                  Mark_Violation ("assignment into a constant object", Var);

               --  Assigned object should not be inside an access-to-constant
               --  type.

               elsif Traverse_Access_To_Constant (Var) then
                  Mark_Violation ("assignment into an access-to-constant part"
                                  & " of an object", Var);

               --  SPARK RM 3.10(8): If the type of the target is an anonymous
               --  access-to-variable type (an owning access type), the source
               --  shall be an owning access object [..] whose root object is
               --  the target object itself.

               --  ??? We are currently using the same restriction for
               --  observers as for borrowers. To be seen if the SPARK RM
               --  current rule really allows more uses.
               --  Note that for borrowers which are handled as observers
               --  (those rooted at the first parameter of borrowing traversal
               --  functions), we should keep the rules of borrowers.

               elsif Is_Anonymous_Access_Object_Type (Etype (Var)) then

                  Check_Source_Of_Borrow_Or_Observe
                    (Expr, Is_Access_Constant (Etype (Var)));

                  if Is_Path_Expression (Expr)
                    and then Present (Get_Root_Object (Expr))
                    and then Get_Root_Object
                    (Get_Observed_Or_Borrowed_Expr (Expr)) /=
                      Get_Root_Object (Var)
                  then
                     Mark_Violation
                       ((if Is_Access_Constant (Etype (Var))
                           then "observed" else "borrowed")
                        & " expression which does not have the left-hand side"
                        & " as a root",
                        Expr,
                        SRM_Reference => "SPARK RM 3.10(8)");
                  end if;

               --  If we are performing a move operation, check that we are
               --  moving a path.

               elsif Is_Deep (Etype (Var)) then
                  Check_Source_Of_Move (Expr);
               end if;
            end;

         when N_Attribute_Reference =>
            Mark_Attribute_Reference (N);

         when N_Binary_Op =>
            Mark_Binary_Op (N);

         when N_Block_Statement =>
            Mark_Stmt_Or_Decl_List (Declarations (N));
            Mark (Handled_Statement_Sequence (N));

         when N_Case_Expression
            | N_Case_Statement
         =>
            Mark (Expression (N));
            Mark_List (Alternatives (N));

         when N_Case_Expression_Alternative =>
            Mark_List (Discrete_Choices (N));
            Mark_Actions (N, Actions (N));
            Mark (Expression (N));

         when N_Case_Statement_Alternative =>
            Mark_List (Discrete_Choices (N));
            Mark_Stmt_Or_Decl_List (Statements (N));

         when N_Code_Statement =>
            Mark_Violation ("code statement", N);

         when N_Component_Association =>
            pragma Assert (No (Loop_Actions (N)));
            Mark_Component_Association (N);

         when N_Iterated_Component_Association =>
            if Present (Iterator_Specification (N)) then
               Mark_Unsupported (Lim_Iterator_In_Component_Assoc, N);
            else
               Mark_Actions (N, Loop_Actions (N));
               Mark_Entity (Defining_Identifier (N));
               Mark_List (Discrete_Choices (N));
               Mark (Expression (N));
            end if;

         when N_Delay_Relative_Statement
            | N_Delay_Until_Statement
         =>
            Mark (Expression (N));

         when N_Exit_Statement =>
            if Present (Condition (N)) then
               Mark (Condition (N));
            end if;

         when N_Expanded_Name
            | N_Identifier
         =>
            Mark_Identifier_Or_Expanded_Name (N);

         when N_Explicit_Dereference =>
            if not Most_Underlying_Type_In_SPARK (Etype (Prefix (N))) then
               Mark_Violation (N, From => Etype (Prefix (N)));
            else
               Mark (Prefix (N));
            end if;

         when N_Extended_Return_Statement =>
            Mark_Extended_Return_Statement (N);

         when N_Extension_Aggregate =>
            if not Most_Underlying_Type_In_SPARK (Etype (N)) then
               Mark_Violation (N, From => Etype (N));

            elsif Nkind (Ancestor_Part (N)) in N_Identifier | N_Expanded_Name
              and then Is_Type (Entity (Ancestor_Part (N)))
            then
               --  The ancestor part of an aggregate can be either an
               --  expression or a subtype.
               --  The second case is not currently supported in SPARK.

               Mark_Unsupported (Lim_Ext_Aggregate_With_Type_Ancestor, N);
            else
               Mark (Ancestor_Part (N));
               Mark_List (Expressions (N));
               Mark_List (Component_Associations (N));
            end if;

         when N_Function_Call =>
            Mark_Call (N);

         when N_Goto_Statement =>
            --  If the goto label was encountered before the goto statement,
            --  it is a backward goto. Reject it.

            if Goto_Labels.Contains (Entity (Name (N))) then
               Mark_Violation ("backward goto statement", N);
            end if;

         when N_Handled_Sequence_Of_Statements =>
            Mark_Handled_Statements (N);

         when N_If_Expression =>
            Mark_If_Expression (N);

         when N_If_Statement =>
            Mark_If_Statement (N);

         when N_Indexed_Component =>
            if not Most_Underlying_Type_In_SPARK (Etype (Prefix (N))) then
               Mark_Violation (N, From => Etype (Prefix (N)));
            else
               Mark (Prefix (N));
               Mark_List (Expressions (N));
            end if;

         when N_Iterated_Element_Association =>

            Mark_Unsupported (Lim_Iterated_Element_Association, N);

         when N_Iterator_Specification =>

            --  Mark the iterator filter if any

            if Present (Iterator_Filter (N)) then
               Mark (Iterator_Filter (N));
            end if;

            --  Retrieve Iterable aspect specification if any

            declare
               Iterable_Aspect : constant Node_Id :=
                 Find_Aspect (Id => Etype (Name (N)), A => Aspect_Iterable);
            begin

               if Present (Iterable_Aspect) then
                  Mark_Iterable_Aspect (Iterable_Aspect);
                  if Present (Subtype_Indication (N)) then
                     Mark (Subtype_Indication (N));
                  end if;
                  Mark (Name (N));

               elsif Of_Present (N)
                 and then Has_Array_Type (Etype (Name (N)))
               then
                  if Number_Dimensions (Etype (Name (N))) > 1 then
                     Mark_Unsupported (Lim_Multidim_Iterator, N);
                  end if;

                  if Present (Subtype_Indication (N)) then
                     Mark (Subtype_Indication (N));
                  end if;
                  Mark (Name (N));

               else

                  --  If no Iterable aspect is found, raise a violation
                  --  other forms of iteration are not allowed in SPARK.

                  Mark_Violation ("iterator specification", N,
                                  SRM_Reference => "SPARK RM 5.5.2");
               end if;
            end;

            --  Mark iterator's identifier

            Mark_Entity (Defining_Identifier (N));

         when N_Label =>
            Goto_Labels.Insert (Entity (Identifier (N)));

         when N_Loop_Statement =>

            --  Detect loops coming from rewritten GOTO statements (see
            --  Find_Natural_Loops in the parser) and reject them.

            declare
               Orig : constant Node_Id := Original_Node (N);
            begin
               if Orig /= N
                 and then Nkind (Orig) = N_Goto_Statement
               then
                  Mark_Violation ("backward goto statement", Orig);
               end if;
            end;

            Check_Loop_Invariant_Placement (Statements (N));
            Check_Unrolled_Loop (N);

            --  Mark the entity for the loop, which is used in the translation
            --  phase to generate exceptions for this loop.

            Mark_Entity (Entity (Identifier (N)));

            if Present (Iteration_Scheme (N)) then
               Mark_Iteration_Scheme (Iteration_Scheme (N));

               --  We cannot precisely support iterator filters on loops over
               --  containers in proof, as we don't know how to define what the
               --  "next" valid element is. Reject them.
               --  Note that the same problem does not occur in quantified
               --  expressions.

               if Present (Iterator_Specification (Iteration_Scheme (N)))
                 and then Present
                   (Iterator_Filter
                      (Iterator_Specification (Iteration_Scheme (N))))
               then
                  Mark_Unsupported (Lim_Loop_With_Iterator_Filter, N);
               end if;
            end if;

            Mark_Stmt_Or_Decl_List (Statements (N));

         when N_Membership_Test =>
            Mark (Left_Opnd (N));
            if Present (Alternatives (N)) then
               Mark_List (Alternatives (N));
            else
               Mark (Right_Opnd (N));
            end if;

            --  Disallow membership tests if they involved the use of the
            --  predefined equality on access types (except if one of the
            --  operands is syntactically null).

            if not Is_Concurrent_Type (Retysp (Etype (Left_Opnd (N))))
              and then Predefined_Eq_Uses_Pointer_Eq (Etype (Left_Opnd (N)))
              and then Nkind (Left_Opnd (N)) /= N_Null
            then
               --  Iterate through the alternatives to see if some involve the
               --  use of the predefined equality.

               declare
                  function Alternative_Uses_Eq (Alt : Node_Id) return Boolean
                  is
                    ((not Is_Entity_Name (Alt)
                     or else not Is_Type (Entity (Alt)))
                     and then Nkind (Alt) /= N_Null);
                  --  Return True if Alt is not a type inclusion or a
                  --  comparison to null.

                  Alt : Node_Id;
               begin
                  if Present (Alternatives (N)) then
                     Alt := First (Alternatives (N));
                     while Present (Alt) loop
                        if Alternative_Uses_Eq (Alt) then
                           Mark_Violation
                             ("equality on access types", Alt);
                           exit;
                        end if;
                        Next (Alt);
                     end loop;
                  elsif Alternative_Uses_Eq (Right_Opnd (N)) then
                     pragma Annotate
                       (Xcov, Exempt_On, "X in Y is expanded into X = Y");
                     Mark_Violation ("equality on access types", N);
                     pragma Annotate (Xcov, Exempt_Off);
                  end if;
               end;
            end if;

         --  Check that the type of null is visibly an access type

         when N_Null =>
            if not Retysp_In_SPARK (Etype (N))
              or else not Is_Access_Type (Retysp (Etype (N)))
            then
               Mark_Violation (N, Etype (N));
            end if;

         when N_Object_Declaration =>
            Mark_Object_Declaration (N);

         when N_Package_Body =>
            Mark_Package_Body (N);

         when N_Package_Body_Stub =>
            Mark_Package_Body (Get_Body_From_Stub (N));

         when N_Package_Declaration =>
            Mark_Package_Declaration (N);

         when N_Parameter_Association =>
            Mark (Explicit_Actual_Parameter (N));

         when N_Pragma =>
            Mark_Pragma (N);

         when N_Procedure_Call_Statement =>
            Mark_Call (N);

         when N_Qualified_Expression =>
            Mark (Subtype_Mark (N));
            Mark (Expression (N));

         when N_Quantified_Expression =>
            if Present (Loop_Parameter_Specification (N)) then
               Mark_Entity (Defining_Identifier
                            (Loop_Parameter_Specification (N)));
               Mark (Discrete_Subtype_Definition
                       (Loop_Parameter_Specification (N)));

               --  Mark the iterator filter if any

               if Present (Iterator_Filter (Loop_Parameter_Specification (N)))
               then
                  Mark (Iterator_Filter (Loop_Parameter_Specification (N)));
               end if;
            else
               Mark (Iterator_Specification (N));
            end if;
            Mark (Condition (N));

         when N_Raise_Statement =>
            if Present (Expression (N)) then
               Mark (Expression (N));
            end if;

         --  The frontend inserts explicit raise-statements/expressions during
         --  semantic analysis in some cases that are statically known to raise
         --  an exception, like simple cases of infinite recursion or division
         --  by zero. No condition should be present in SPARK code, but accept
         --  them here as the code should in that case be rejected after
         --  marking.

         when N_Raise_xxx_Error =>
            null;

         when N_Raise_Expression =>
            declare
               procedure Check_Raise_Context (Expr : Node_Id);
               --  If a raise expression occurs in a precondition, it should
               --  not be handled as a RTE, as this is a common pattern for
               --  modifying the error raised in case of a failed precondition.
               --  The restrictions below make sure that raise expressions
               --  can be replaced by False, while still maintaining these
               --  properties:
               --  - when the original expression evaluates to True, the
               --    modified formula evaluates to True as well;
               --  - when the modified formula evaluates to True, the original
               --    formula evaluates to True or raises an exception;
               --  - when the modified formula evaluates to True, the original
               --    formula does not raise an exception.

               --  The first two properties (equivalence without taking into
               --  account exceptions) are guaranteed by making sure that raise
               --  expressions only appear in positive polarity. For the last
               --  property, we introduce these additional syntactic
               --  restrictions on precondition expressions that contain raise
               --  expressions:

               --  A and/and then B    raise expressions are allowed in A and B
               --  A or else B         raise expressions only allowed in B
               --  if A then B else C  raise expressions not allowed in A
               --  case A then is ...  raise expressions not allowed in A

               --  No raise expressions are allowed in other expressions.

               --  We store encountered Raise_Expressions in the
               --  Raise_Exprs_From_Pre set for later use.

               -------------------------
               -- Check_Raise_Context --
               -------------------------

               procedure Check_Raise_Context (Expr : Node_Id) is
                  Prag : Node_Id;
                  --  Node to store the precondition enclosing Expr if any

                  N    : Node_Id := Expr;
                  P    : Node_Id;
               begin
                  --  First, decide if we are in a precondition

                  Prag := Parent (N);
                  while Present (Prag) loop
                     exit when Nkind (Prag) = N_Pragma_Argument_Association
                       and then Get_Pragma_Id (Pragma_Name (Parent (Prag))) in
                       Pragma_Precondition | Pragma_Pre | Pragma_Pre_Class;
                     Prag := Parent (Prag);
                  end loop;

                  --  If we are in a precondition, check whether it is safe to
                  --  translate raise statements as False.

                  if Present (Prag) then
                     while Parent (N) /= Prag loop
                        P := Parent (N);
                        case Nkind (P) is

                        --  And connectors will ensure both operands hold, so
                        --  the operands will be protected by the precondition.
                        --  For example, (X and Y) protects:
                        --  (X or else raise) and (Y or else raise)

                        when N_Op_And | N_And_Then =>
                           null;

                        --  In or else connectors, only the right operand is
                        --  protected as the left one can evaluate to False
                        --  even when the disjunction holds.
                        --  For example, (X or else Y) protects:
                        --  X or else (Y or else raise)
                        --  but not: (X or else raise) or else Y
                        --  NB. In or connectors, no operands is protected.

                        when N_Or_Else =>
                           if N = Left_Opnd (P) then
                              exit;
                           end if;

                        --  In conditional expressions, raise expressions
                        --  should not occur in the conditions.

                        when N_If_Expression =>
                           if N = First (Expressions (P)) then
                              exit;
                           end if;
                        when N_Case_Expression =>
                           if N = Expression (P) then
                              exit;
                           end if;
                        when N_Case_Expression_Alternative =>
                           null;

                        --  Other expressions are not supported

                        when others =>
                           exit;
                        end case;
                        N := P;
                     end loop;

                     --  If we have stopped the search before reaching Prag, we
                     --  have found an unsupported construct, report it.

                     if Parent (N) /= Prag then
                        Mark_Unsupported
                          (Kind => Lim_Complex_Raise_Expr_In_Prec,
                           N    => Expr);

                     --  Otherwise, store Expr in Raise_Exprs_From_Pre

                     else
                        Raise_Exprs_From_Pre.Insert (Expr);
                     end if;
                  end if;
               end Check_Raise_Context;
            begin
               Check_Raise_Context (N);
            end;

         when N_Range =>
            Mark (Low_Bound (N));
            Mark (High_Bound (N));

         when N_Reference =>
            Mark_Violation ("reference", N);

         when N_Short_Circuit =>
            Mark_Actions (N, Actions (N));
            Mark (Left_Opnd (N));
            Mark (Right_Opnd (N));

         when N_Simple_Return_Statement =>
            Mark_Simple_Return_Statement (N);

         when N_Selected_Component =>

            --  In some cases, the static type of the prefix does not contain
            --  the selected component. This may happen for generic instances,
            --  or inlined subprograms, whose body is analyzed in the general
            --  context only. Issue an error in that case.

            declare
               Name        : constant N_Subexpr_Id := Prefix (N);
               Selector    : constant Record_Field_Kind_Id :=
                 Entity (Selector_Name (N));
               Prefix_Type : constant Type_Kind_Id :=
                 Unique_Entity (Etype (Name));

            begin
               if No (Search_Component_By_Name (Prefix_Type, Selector)) then
                  if SPARK_Pragma_Is (Opt.On) then
                     Error_Msg_NE
                       ("component not present in }", N, Prefix_Type);
                     Error_Msg_N
                       ("\static expression fails Constraint_Check", N);
                  end if;

                  return;
               end if;
            end;

            --  In most cases, it is enough to look at the record type (the
            --  most underlying one) to see whether the access is in SPARK. An
            --  exception is the access to discrimants to a private type whose
            --  full view is not in SPARK.

            if not Retysp_In_SPARK (Etype (Prefix (N))) then
               Mark_Violation (N, From  => Etype (Prefix (N)));
            end if;

            if not Violation_Detected then
               Mark (Selector_Name (N));
            end if;

            Mark (Prefix (N));

         when N_Slice =>
            if not Most_Underlying_Type_In_SPARK (Etype (Prefix (N))) then
               Mark_Violation (N, From => Etype (Prefix (N)));
            else
               Mark (Prefix (N));
               Mark (Discrete_Range (N));
            end if;

         when N_Subprogram_Body =>
            declare
               E : constant Entity_Id := Unique_Defining_Entity (N);
            begin
               if Is_Generic_Subprogram (E) then
                  null;

               --  For expression functions that have a unique declaration, the
               --  body inserted by the frontend may be far from the original
               --  point of declaration, after the private declarations of the
               --  package (to avoid premature freezing.) In those cases, mark
               --  the subprogram body at the same point as the subprogram
               --  declaration, so that entities declared afterwards have
               --  access to the axiom defining the expression function.

               elsif Is_Expression_Function_Or_Completion (E)
                 and then not Comes_From_Source (Original_Node (N))
               then
                  null;

               --  In GNATprove_Mode, a separate declaration is usually
               --  generated before the body for a subprogram if not defined
               --  by the user (unless the subprogram defines a unit or has
               --  a contract). So in general Mark_Subprogram_Declaration is
               --  always called on the declaration before Mark_Subprogram_Body
               --  is called on the body. In the remaining cases where a
               --  subprogram unit body does not have a prior declaration,
               --  call Mark_Subprogram_Declaration on the subprogram body.

               else
                  if Acts_As_Spec (N) then
                     Mark_Subprogram_Declaration (N);
                  end if;

                  if Ekind (E) = E_Function
                    and then (Is_Predicate_Function (E)
                              or else
                              Was_Expression_Function (N))
                  then
                     Mark_Entity (E);
                  else
                     Mark_Subprogram_Body (N);
                  end if;
               end if;

               --  Try inferring the Inline_For_Proof annotation for expression
               --  functions which could benefit from it.

               if Ekind (E) = E_Function then
                  Infer_Inline_Annotation (E);
               end if;
            end;

         when N_Subprogram_Body_Stub =>
            if Is_Subprogram_Stub_Without_Prior_Declaration (N) then
               Mark_Subprogram_Declaration (N);
            end if;

            if not Is_Generic_Subprogram (Unique_Defining_Entity (N)) then
               Mark_Subprogram_Body (Get_Body_From_Stub (N));
            end if;

         when N_Subprogram_Declaration =>
            if not Is_Predicate_Function (Defining_Entity (N)) then
               Mark_Subprogram_Declaration (N);
            end if;

         when N_Subtype_Indication =>
            Mark_Subtype_Indication (N);

         when N_Type_Conversion
            | N_Unchecked_Type_Conversion
         =>
            --  Mark the expression first, so that its type is marked for the
            --  rest of the checks on SPARK restrictions.

            Mark (Expression (N));

            --  Check various limitations of GNATprove and issue an error on
            --  unsupported conversions.

            if Has_Array_Type (Etype (N)) then

               --  Restrict array conversions to the cases where either:
               --  - corresponding indices have modular types of the same size
               --  - or both don't have a modular type.
               --  Supporting other cases of conversions would require
               --  generating conversion functions for each required pair of
               --  array types and index base types.

               declare
                  Target_Index : Node_Id :=
                    First_Index (Retysp (Etype (N)));

                  Source_Type_Retysp : constant Type_Kind_Id :=
                    Retysp (Etype (Expression (N)));
                  --  SPARK representation of the type of source expression

                  Source_Index : Node_Id :=
                    First_Index
                      (if Ekind (Source_Type_Retysp) = E_String_Literal_Subtype
                       then Retysp (Etype (Source_Type_Retysp))
                       else Source_Type_Retysp);
                  --  Special case string literals, since First_Index cannot be
                  --  directly called for them.

                  Dim          : constant Pos :=
                    Number_Dimensions (Retysp (Etype (N)));
                  Target_Type  : Type_Kind_Id;
                  Source_Type  : Type_Kind_Id;

               begin
                  for I in 1 .. Dim loop
                     Target_Type := Etype (Target_Index);
                     Source_Type := Etype (Source_Index);

                     --  Reject conversions between array types with modular
                     --  index types of different sizes.

                     if Has_Modular_Integer_Type (Target_Type)
                       and then Has_Modular_Integer_Type (Source_Type)
                     then
                        if Esize (Target_Type) /= Esize (Source_Type) then
                           Mark_Unsupported
                             (Lim_Array_Conv_Different_Size_Modular_Index, N);
                           exit;
                        end if;

                     --  Reject conversions between array types with modular
                     --  and non-modular index types.

                     elsif Has_Modular_Integer_Type (Target_Type)
                       or else Has_Modular_Integer_Type (Source_Type)
                     then
                        Mark_Unsupported
                          (Lim_Array_Conv_Signed_Modular_Index, N);
                        exit;
                     end if;

                     Target_Index := Next_Index (Target_Index);
                     Source_Index := Next_Index (Source_Index);
                  end loop;
               end;

            elsif Has_Access_Type (Etype (N)) then

               --  When converting to an anonymous access type, check that the
               --  expression and the target have compatible designated types.

               Check_Compatible_Access_Types (Etype (N), Expression (N));

               --  Anonymous access types are for borrows and observe. It is
               --  not allowed to convert them back into a named type.

               if Is_Anonymous_Access_Object_Type (Etype (Expression (N)))
                 and then not Is_Anonymous_Access_Object_Type (Etype (N))
               then
                  Mark_Violation
                    ("conversion from an anonymous access type to a named"
                     & " access type", N);

               --  A conversion from an access-to-variable type to an
               --  access-to-constant type is considered a move if the
               --  expression is not rooted inside a constant part of an
               --  object. In this case, we need to check that the move is
               --  allowed.

               elsif Conversion_Is_Move_To_Constant (N) then
                  Check_Source_Of_Move (Expression (N), To_Constant => True);

                  --  Moving a tracked object inside an expression is not
                  --  supported yet.

                  if Is_Path_Expression (Expression (N))
                    and then Present (Get_Root_Object (Expression (N)))
                  then
                     Mark_Unsupported (Lim_Move_To_Access_Constant, N);
                  end if;
               end if;

            else
               Scalar_Conversion : declare
                  From_Type        : constant Type_Kind_Id :=
                    Etype (Expression (N));
                  To_Type          : constant Type_Kind_Id := Etype (N);

                  From_Float       : constant Boolean :=
                    Has_Floating_Point_Type (From_Type);
                  From_Fixed       : constant Boolean :=
                    Has_Fixed_Point_Type (From_Type);
                  From_Int         : constant Boolean :=
                    Has_Signed_Integer_Type (From_Type)
                      or else Has_Modular_Integer_Type (From_Type);
                  From_Modular_128 : constant Boolean :=
                    Has_Modular_Integer_Type (From_Type)
                      and then SPARK_Atree.Entities.Modular_Size
                        (Retysp (From_Type))
                        = Uintp.UI_From_Int (128);

                  To_Float       : constant Boolean :=
                    Has_Floating_Point_Type (To_Type);
                  To_Fixed       : constant Boolean :=
                    Has_Fixed_Point_Type (To_Type);
                  To_Int         : constant Boolean :=
                    Has_Signed_Integer_Type (To_Type)
                      or else Has_Modular_Integer_Type (To_Type);
                  To_Modular_128 : constant Boolean :=
                    Has_Modular_Integer_Type (To_Type)
                      and then SPARK_Atree.Entities.Modular_Size
                        (Retysp (To_Type))
                        = Uintp.UI_From_Int (128);

               begin
                  if (From_Float and To_Fixed) or (From_Fixed and To_Float)
                  then
                     Mark_Unsupported (Lim_Conv_Fixed_Float, N);

                  --  For the operation to be in the perfect result set, the
                  --  smalls of the fixed-point types should be "compatible"
                  --  according to Ada RM G.2.3(21-24): the division of smalls
                  --  should be an integer or the reciprocal of an integer.

                  elsif From_Fixed and To_Fixed then
                     declare
                        Target_Small : constant Ureal :=
                          Small_Value (Retysp (To_Type));
                        Source_Small : constant Ureal :=
                          Small_Value (Retysp (From_Type));
                        Factor : constant Ureal := Target_Small / Source_Small;
                     begin
                        if Norm_Num (Factor) /= Uint_1
                          and then Norm_Den (Factor) /= Uint_1
                        then
                           Mark_Unsupported (Lim_Conv_Incompatible_Fixed, N);
                        end if;
                     end;

                  --  For the conversion between a fixed-point type and an
                  --  integer, the small of the fixed-point type should be an
                  --  integer or the reciprocal of an integer for the result
                  --  to be in the perfect result set (Ada RM G.2.3(24)).

                  elsif (From_Fixed and To_Int) or (From_Int and To_Fixed) then
                     declare
                        Fixed_Type : constant Type_Kind_Id :=
                          (if From_Fixed then From_Type else To_Type);
                        Small      : constant Ureal :=
                          Small_Value (Retysp (Fixed_Type));
                     begin
                        if Norm_Num (Small) /= Uint_1
                          and then Norm_Den (Small) /= Uint_1
                        then
                           Mark_Unsupported
                             (Lim_Conv_Fixed_Integer, N,
                              Cont_Msg => "fixed-point with fractional small "
                              & "leads to imprecise conversion");
                        end if;
                     end;

                  elsif (From_Modular_128 and To_Float)
                    or (From_Float and To_Modular_128)
                  then
                     Mark_Unsupported (Lim_Conv_Float_Modular_128, N);
                  end if;
               end Scalar_Conversion;
            end if;

         when N_Unary_Op =>
            Mark_Unary_Op (N);

         --  Frontend sometimes declares an Itype for the base type of a type
         --  declaration. This Itype should be marked at the point of
         --  declaration of the corresponding type, otherwise it may end up
         --  being marked multiple times in various client units, which leads
         --  to multiple definitions in Why3 for the same type.

         when N_Full_Type_Declaration
            | N_Private_Extension_Declaration
            | N_Private_Type_Declaration
            | N_Subtype_Declaration
         =>
            declare
               E : constant Type_Kind_Id := Defining_Entity (N);
            begin
               if In_SPARK (E) then
                  if Nkind (N) = N_Full_Type_Declaration then
                     declare
                        T_Def : constant Node_Id := Type_Definition (N);
                     begin
                        if Nkind (T_Def) = N_Derived_Type_Definition then
                           Mark (Subtype_Indication (T_Def));
                        end if;
                     end;
                  end if;
               end if;
            end;

         when N_Task_Type_Declaration
            | N_Protected_Type_Declaration
         =>
            --  Pick SPARK_Mode from the concurrent type definition

            declare
               Save_SPARK_Pragma : constant Opt_N_Pragma_Id :=
                 Current_SPARK_Pragma;
               E                 : constant Type_Kind_Id :=
                 Defining_Entity (N);
            begin
               Current_SPARK_Pragma := SPARK_Pragma (E);
               Mark_Entity (E);

               Mark_Concurrent_Type_Declaration (N);

               Current_SPARK_Pragma := Save_SPARK_Pragma;
            end;

         --  Supported tasking constructs

         when N_Protected_Body
            | N_Task_Body
         =>
            if Is_SPARK_Tasking_Configuration then
               case Nkind (N) is
                  when N_Protected_Body =>
                     Mark_Protected_Body (N);

                  when N_Task_Body =>
                     Mark_Subprogram_Body (N);

                  when others =>
                     raise Program_Error;

               end case;
            else
               Mark_Violation_In_Tasking (N);
            end if;

         when N_Protected_Body_Stub
            | N_Task_Body_Stub
         =>
            if Is_SPARK_Tasking_Configuration then
               Mark (Get_Body_From_Stub (N));
            else
               Mark_Violation_In_Tasking (N);
            end if;

         when N_Entry_Body =>
            Mark_Subprogram_Body (N);

         when N_Entry_Call_Statement =>
            if Is_SPARK_Tasking_Configuration then
               --  This might be either protected entry or protected subprogram
               --  call.
               Mark_Call (N);
            else
               Mark_Violation_In_Tasking (N);
            end if;

         when N_Entry_Declaration =>
            Mark_Subprogram_Declaration (N);

         when N_With_Clause =>

            --  Proof requires marking of initial conditions of all withed
            --  units.

            if not Limited_Present (N)
              and then Nkind (Unit (Library_Unit (N))) = N_Package_Declaration
            then
               declare
                  Package_E : constant E_Package_Id :=
                    Defining_Entity (Unit (Library_Unit (N)));
                  Init_Cond : constant Opt_N_Pragma_Id :=
                    Get_Pragma (Package_E, Pragma_Initial_Condition);
               begin
                  if Present (Init_Cond) then
                     declare
                        Expr : constant N_Subexpr_Id :=
                          Expression
                            (First (Pragma_Argument_Associations (Init_Cond)));
                     begin
                        Mark (Expr);
                     end;
                  end if;
               end;
            end if;

         --  Unsupported tasking constructs

         when N_Abort_Statement
            | N_Accept_Statement
            | N_Asynchronous_Select
            | N_Conditional_Entry_Call
            | N_Requeue_Statement
            | N_Selective_Accept
            | N_Timed_Entry_Call
         =>
            Mark_Violation ("tasking", N);

         --  Unsupported INOX constructs

         when N_Goto_When_Statement
            | N_Raise_When_Statement
            | N_Return_When_Statement
         =>
            Mark_Violation ("INOX", N);

         --  The following kinds can be safely ignored by marking

         when N_Ignored_In_Marking
            | N_Character_Literal
            | N_Component_Declaration
            | N_Formal_Object_Declaration
            | N_Formal_Package_Declaration
            | N_Formal_Subprogram_Declaration
            | N_Formal_Type_Declaration
            | N_Operator_Symbol
            | N_Others_Choice
            | N_String_Literal
         =>
            null;

         --  Itype reference node may be needed to express the side-effects
         --  associated to the creation of an Itype.

         when N_Itype_Reference =>
            declare
               Assoc : constant Node_Id :=
                 Associated_Node_For_Itype (Itype (N));
            begin
               if Nkind (Assoc) in N_Has_Etype then
                  Mark (Assoc);
               end if;
            end;

         when N_Real_Literal
            | N_Integer_Literal
         =>
            Mark_Entity (Etype (N));

         when N_Delta_Aggregate =>
            Mark (Expression (N));
            Mark_List (Component_Associations (N));
            Check_No_Deep_Duplicates_In_Assoc (N);

         --  Uses of object renamings are rewritten by expansion, but the name
         --  is still being evaluated at the location of the renaming, even if
         --  there are no uses of the renaming.

         when N_Object_Renaming_Declaration =>
            Mark (Name (N));

         --  N_Expression_With_Actions is only generated from declare
         --  expressions in GNATprove mode.

         when N_Expression_With_Actions =>
            pragma Assert (Comes_From_Source (N));
            Mark_Actions (N, Actions (N));
            Mark (Expression (N));

         --  The following nodes are rewritten by semantic analysis

         when N_Expression_Function
            | N_Single_Protected_Declaration
            | N_Single_Task_Declaration
         =>
            raise Program_Error;

         --  The following nodes are never generated in GNATprove mode

         when N_Compound_Statement
            | N_Unchecked_Expression
         =>
            raise Program_Error;

         --  For now, we don't support the use of target_name inside an
         --  assignment which is a move or reborrow.

         when N_Target_Name =>
            if Is_Anonymous_Access_Object_Type (Retysp (Etype (N))) then
               Mark_Unsupported (Lim_Target_Name_In_Borrow, N);
            elsif Is_Deep (Etype (N)) then
               Mark_Unsupported (Lim_Target_Name_In_Move, N);
            end if;

         when N_Interpolated_String_Literal =>
            Mark_Unsupported (Lim_Interpolated_String_Literal, N);

         --  Mark should not be called on other kinds

         when N_Abortable_Part
            | N_Accept_Alternative
            | N_Access_Definition
            | N_Access_Function_Definition
            | N_Access_Procedure_Definition
            | N_Access_To_Object_Definition
            | N_Aspect_Specification
            | N_Compilation_Unit
            | N_Compilation_Unit_Aux
            | N_Component_Definition
            | N_Component_List
            | N_Constrained_Array_Definition
            | N_Contract
            | N_Decimal_Fixed_Point_Definition
            | N_Defining_Character_Literal
            | N_Defining_Identifier
            | N_Defining_Operator_Symbol
            | N_Defining_Program_Unit_Name
            | N_Delay_Alternative
            | N_Delta_Constraint
            | N_Derived_Type_Definition
            | N_Designator
            | N_Digits_Constraint
            | N_Discriminant_Association
            | N_Discriminant_Specification
            | N_Elsif_Part
            | N_Empty
            | N_Entry_Body_Formal_Part
            | N_Entry_Call_Alternative
            | N_Entry_Index_Specification
            | N_Enumeration_Type_Definition
            | N_Error
            | N_Exception_Handler
            | N_Floating_Point_Definition
            | N_Formal_Decimal_Fixed_Point_Definition
            | N_Formal_Derived_Type_Definition
            | N_Formal_Discrete_Type_Definition
            | N_Formal_Floating_Point_Definition
            | N_Formal_Incomplete_Type_Definition
            | N_Formal_Modular_Type_Definition
            | N_Formal_Ordinary_Fixed_Point_Definition
            | N_Formal_Private_Type_Definition
            | N_Formal_Signed_Integer_Type_Definition
            | N_Free_Statement
            | N_Function_Specification
            | N_Generic_Association
            | N_Index_Or_Discriminant_Constraint
            | N_Iteration_Scheme
            | N_Loop_Parameter_Specification
            | N_Modular_Type_Definition
            | N_Ordinary_Fixed_Point_Definition
            | N_Package_Specification
            | N_Parameter_Specification
            | N_Pragma_Argument_Association
            | N_Procedure_Specification
            | N_Protected_Definition
            | N_Push_Pop_xxx_Label
            | N_Range_Constraint
            | N_Real_Range_Specification
            | N_Record_Definition
            | N_SCIL_Dispatch_Table_Tag_Init
            | N_SCIL_Dispatching_Call
            | N_SCIL_Membership_Test
            | N_Signed_Integer_Type_Definition
            | N_Subunit
            | N_Task_Definition
            | N_Terminate_Alternative
            | N_Triggering_Alternative
            | N_Unconstrained_Array_Definition
            | N_Unused_At_End
            | N_Unused_At_Start
            | N_Variant
            | N_Variant_Part
         =>
            raise Program_Error;
      end case;
   end Mark;

   ------------------
   -- Mark_Actions --
   ------------------

   procedure Mark_Actions (N : Node_Id; L : List_Id) is
      In_Declare_Expr : constant Boolean :=
        Nkind (N) = N_Expression_With_Actions;

      function Acceptable_Actions (L : List_Id) return Boolean;
      --  Go through the list of actions L and decide if it is acceptable for
      --  translation into Why. When an unfit action is found, either a
      --  precise violation is raised on the spot, and the iteration continues,
      --  or we end the iteration and return False so that a generic violation
      --  can be emitted. In particular, we do the later for actions which are
      --  not coming from declare expressions, where the declared objects do
      --  not correspond to anything user visible.

      ------------------------
      -- Acceptable_Actions --
      ------------------------

      function Acceptable_Actions (L : List_Id) return Boolean is
         N : Node_Id := First (L);

      begin
         while Present (N) loop
            --  Only actions that consist in N_Object_Declaration nodes for
            --  constants are translated. All types are accepted and
            --  corresponding effects (for bounds of dynamic types) discarded
            --  when translating to Why.

            case Nkind (N) is
               when N_Subtype_Declaration
                  | N_Full_Type_Declaration
               =>
                  null;

               when N_Object_Declaration =>

                  --  We only accept constants

                  if Constant_Present (N) then

                     --  We don't support local borrowers/observers in actions.
                     --  They are not allowed by Ada in declare expressions,
                     --  and they do not seem to be generated in others actions
                     --  either.

                     if Is_Anonymous_Access_Object_Type
                       (Etype (Defining_Identifier (N)))
                     then
                        raise Program_Error;

                     --  We don't support moves in actions

                     elsif Is_Deep (Retysp (Etype (Defining_Identifier (N))))
                       and then Is_Path_Expression (Expression (N))
                       and then Present (Get_Root_Object (Expression (N)))
                     then
                        if In_Declare_Expr then
                           Mark_Violation
                             ("move in declare expression", N);
                        end if;
                        return In_Declare_Expr;
                     end if;
                  else
                     return False;
                  end if;

               --  Object renamings and Itype references are not ignored, but
               --  simply checked for absence of RTE.

               when N_Ignored_In_SPARK
                  | N_Itype_Reference
                  | N_Object_Renaming_Declaration
               =>
                  null;

               when N_Pragma =>
                  if Is_Ignored_Pragma_Check (N) then
                     null;

                  --  Pragma Check might occur inside declare expressions.
                  --  We currently reject pragma Assume in this context on the
                  --  ground that assumptions nested inside expressions are
                  --  bad practice, but we could easily support them.

                  elsif Is_Pragma_Check (N, Name_Assume) then
                     Mark_Violation
                       ("pragma Assume in declare expression", N);
                     return In_Declare_Expr;

                  elsif Is_Pragma (N, Pragma_Check) then
                     return In_Declare_Expr;

                  --  Other pragmas are unexpected

                  else
                     return False;
                  end if;

               when others =>
                  return False;
            end case;

            Next (N);
         end loop;

         return True;
      end Acceptable_Actions;

      Save_Inside_Actions : constant Boolean := Inside_Actions;

   --  Start of processing for Mark_Actions

   begin
      Inside_Actions := True;

      Mark_List (L);
      if not Acceptable_Actions (L) then
         --  We should never reach here

         raise Program_Error;
      end if;

      Inside_Actions := Save_Inside_Actions;
   end Mark_Actions;

   ------------------
   -- Mark_Address --
   ------------------

   procedure Mark_Address (E : Entity_Id) is
      Address : constant Node_Id := Address_Clause (E);
   begin
      if Present (Address) then
         declare
            Address_Expr    : constant Node_Id := Expression (Address);
            Aliased_Object  : constant Entity_Id :=
              Supported_Alias (Address_Expr);
            Supported_Alias : constant Boolean := Present (Aliased_Object);
            E_Is_Constant   : constant Boolean :=
              Is_Object (E) and then Is_Constant_In_SPARK (E);
         begin

            Mark (Address_Expr);

            --  If we cannot determine which object the address of E
            --  references, check whether E is annotated with some Volatile
            --  properties. If it is not the case, issue a warning that
            --  we cannot account for indirect writes. Otherwise, issue a
            --  warning that we assume the stated volatile properties, if
            --  not all properties are set. This partly addresses assumptions
            --  SPARK_EXTERNAL and SPARK_ALIASING_ADDRESS.

            if Is_Object (E)
              and then not Supported_Alias
            then
               if not Has_Volatile (E) then
                  if not No_Caching_Enabled (E) then
                     Error_Msg_NE
                       (Warning_Message (Warn_Indirect_Writes_Through_Alias),
                        Address, E);
                     Error_Msg_NE
                       ("\consider annotating & with Async_Writers",
                        Address, E);
                  else
                     Error_Msg_NE
                       (Warning_Message (Warn_Assumed_Volatile_Properties),
                        Address, E);
                  end if;

               elsif not Has_Volatile_Property (E, Pragma_Async_Readers)
                 or else not Has_Volatile_Property (E, Pragma_Async_Writers)
                 or else not Has_Volatile_Property (E, Pragma_Effective_Reads)
                 or else not Has_Volatile_Property (E, Pragma_Effective_Writes)
               then
                  Error_Msg_NE
                    (Warning_Message (Warn_Assumed_Volatile_Properties),
                     Address, E);
               end if;
            end if;

            --  If E is variable in SPARK, check here that we can account
            --  for effects to other objects induced by writing to E. The
            --  fact that we can account for indirect effects to E is
            --  verified inside proof. We emit check messages in this case.

            if Is_Object (E) and then not E_Is_Constant then

               --  If E is a variable and the address clause do not link to a
               --  part of an object, we cannot handle the case, emit a
               --  warning. This partly addresses assumptions
               --  SPARK_ALIASING_ADDRESS.

               if not Supported_Alias then

                  --  If E has a volatile annotation with Async_Readers set to
                  --  False, writing to E cannot have any effects on other
                  --  variables. Do not emit the warning.

                  if (if Has_Volatile (E)
                      then Has_Volatile_Property (E, Pragma_Async_Readers)
                      else not No_Caching_Enabled (E))
                  then
                     Error_Msg_NE
                       (Warning_Message (Warn_Indirect_Writes_To_Alias),
                        Address, E);
                     Error_Msg_NE
                       ("\make sure that all overlapping objects have"
                        & " Async_Writers set to True",
                        Address, E);
                  end if;

               --  We do not handle yet overlays between (parts of) objects of
               --  a deep type.

               else
                  if Is_Deep (Etype (E)) then
                     Mark_Unsupported (Lim_Deep_Object_With_Addr, Address);
                  elsif Is_Deep (Etype (Aliased_Object)) then
                     Mark_Unsupported (Lim_Overlay_With_Deep_Object, Address);
                  end if;
               end if;
            end if;

            --  If the address expression is a reference to the address of
            --  (a part of) another object, check that either both are
            --  mutable or both are constant for SPARK.

            if Supported_Alias
              and then E_Is_Constant /=
                (Is_Constant_In_SPARK (Aliased_Object)
                 or else Traverse_Access_To_Constant (Prefix (Address_Expr)))
            then
               declare
                  E_Mod : constant String :=
                    (if E_Is_Constant then "constant" else "mutable");
                  R_Mod : constant String :=
                    (if E_Is_Constant then "mutable" else "constant");
               begin
                  Mark_Violation
                    ("address clause for a " & E_Mod
                     & " object referencing a " & R_Mod & " part of an object",
                     Address);
               end;

            --  If E is not imported, its initialization writes to the supplied
            --  address.

            elsif not Is_Imported (E) then

               --  If E has an unsupported address, the effect is ignored, emit
               --  a warning.

               if not Supported_Alias then

                  --  Only emit the warning for constants, it is redundant for
                  --  variables.

                  if E_Is_Constant then
                     Error_Msg_NE
                       (Warning_Message (Warn_Initialization_To_Alias),
                        Address, E);
                     Error_Msg_NE
                       ("\consider annotating & with Import",
                        Address, E);
                  end if;

               --  Constants are aliased with constants, they should always be
               --  imported.

               elsif E_Is_Constant then
                  Mark_Violation
                    ("constant object with an address clause which is not"
                     & " imported", E);

               --  To avoid introducing invalid values in aliases, E
               --  should be initialized at declaration.

               else
                  declare
                     Decl    : constant Node_Id := Parent (E);
                     Is_Init : constant Boolean :=
                       Nkind (Decl) = N_Object_Declaration
                       and then Present (Expression (Decl));
                  begin
                     if not Is_Init
                       and then Default_Initialization (Etype (E)) /=
                         Full_Default_Initialization
                     then
                        Mark_Violation
                          ("object with an address clause which is not"
                           & " fully initialized at declaration", E,
                           Cont_Msg => "consider marking it as imported");
                     end if;
                  end;
               end if;
            end if;

            --  If both objects are volatile, issue a warning if volatile
            --  properties differ. We can only issue this warning in the case
            --  of supported aliases, as there is no "other object" otherwise.

            if Is_Object (E)
              and then Has_Volatile (E)
              and then Supported_Alias
              and then Has_Volatile (Aliased_Object)
            then
               declare

                  function Prop_Differs (P : Volatile_Pragma_Id)
                                          return Boolean;
                  function Prop_Name (X : Volatile_Pragma_Id) return String;

                  -------------------
                  -- Compare_Props --
                  -------------------

                  function Prop_Differs (P : Volatile_Pragma_Id)
                                          return Boolean is
                     (Has_Volatile_Property (E, P) /=
                         Has_Volatile_Property (Aliased_Object, P));

                  ---------------
                  -- Prop_Name --
                  ---------------

                  function Prop_Name (X : Volatile_Pragma_Id) return String is
                  begin
                     case X is
                        when Pragma_Async_Readers    =>
                           return "Async_Readers";
                        when Pragma_Async_Writers    =>
                           return "Async_Writers";
                        when Pragma_Effective_Reads  =>
                           return "Effective_Reads";
                        when Pragma_Effective_Writes =>
                           return "Effective_Writes";
                     end case;
                  end Prop_Name;

                  Buf   : Unbounded_String;
                  First : Boolean := True;

               begin
                  if (for some X in Volatile_Pragma_Id => Prop_Differs (X))
                  then
                     Error_Msg_NE
                       (Warning_Message (Warn_Alias_Different_Volatility),
                        Address, E);
                     for Prop in Volatile_Pragma_Id loop
                        if Prop_Differs (Prop) then
                           if First then
                              Buf := Buf & Prop_Name (Prop);
                              First := False;
                           else
                              Buf := Buf & ", " & Prop_Name (Prop);
                           end if;
                        end if;
                     end loop;
                     Error_Msg_NE
                       ("\values for property "
                        & To_String (Buf)
                        & " are different",
                        Address, E);
                  end if;
               end;
            end if;

            --  Objects whose address is taken should have consistent
            --  volatility and atomicity specifications, in the case of a
            --  precisely supported address specification. Otherwise we assume
            --  no concurrent accesses in case the object is not atomic. This
            --  partly addresses assumptions SPARK_EXTERNAL.

            if Is_Object (E) then
               if Supported_Alias then
                  if Has_Volatile (E) /= Has_Volatile (Aliased_Object) or else
                    Is_Atomic (E) /= Is_Atomic (Aliased_Object)
                  then
                     Error_Msg_NE
                       (Warning_Message (Warn_Alias_Atomic_Vol),
                        Address, E);
                  end if;
               else
                  if not Is_Atomic (E) then
                     Error_Msg_NE
                       (Warning_Message (Warn_Address_Atomic),
                        Address, E);
                  end if;
               end if;
            end if;

            if Is_Object (E) then
               if Has_Relaxed_Initialization (E) or else
                 (Supported_Alias
                  and then Ekind (Aliased_Object) /= E_Loop_Parameter
                  and then Has_Relaxed_Initialization (Aliased_Object))
               then
                  Mark_Unsupported (Lim_Relaxed_Init_Aliasing, E);
               end if;
            end if;

            if Is_Object (E)
              and then not E_Is_Constant
              and then Supported_Alias
            then
               Set_Overlay_Alias (E, Aliased_Object);
            end if;
         end;
      end if;
   end Mark_Address;

   ---------------------------------------------
   -- Mark_Aspect_Clauses_And_Pragmas_In_List --
   ---------------------------------------------

   procedure Mark_Aspect_Clauses_And_Pragmas_In_List (L : List_Id) is
      Cur : Node_Id := First (L);

   begin
      --  Only mark pragmas and aspect clauses. Ignore GNATprove annotate
      --  pragmas here.

      while Present (Cur) loop
         if Nkind (Cur) in N_Pragma | N_Representation_Clause
           and then not Is_Pragma_Annotate_GNATprove (Cur)
         then
            Mark (Cur);
         end if;
         Next (Cur);
      end loop;
   end Mark_Aspect_Clauses_And_Pragmas_In_List;

   ------------------------------
   -- Mark_Attribute_Reference --
   ------------------------------

   procedure Mark_Attribute_Reference (N : N_Attribute_Reference_Id) is
      Aname   : constant Name_Id      := Attribute_Name (N);
      P       : constant Node_Id      := Prefix (N);
      Exprs   : constant List_Id      := Expressions (N);
      Attr_Id : constant Attribute_Id := Get_Attribute_Id (Aname);

   begin
      --  This case statement must agree with the table specified in SPARK RM
      --  15.2 "Language Defined Attributes".
      --
      --  See also the analysis in Gnat2Why.Expr.Transform_Attr which defines
      --  which of these attributes are supported in proof.
      case Attr_Id is

         --  Support a subset of the attributes defined in Ada RM. These are
         --  the attributes marked "Yes" in SPARK RM 15.2 for which we support
         --  non-static values.
         when Attribute_Callable
            | Attribute_Ceiling
            | Attribute_Class
            | Attribute_Constrained
            | Attribute_Copy_Sign
            | Attribute_Enum_Rep
            | Attribute_Enum_Val
            | Attribute_First
            | Attribute_Floor
            | Attribute_Last
            | Attribute_Length
            | Attribute_Max
            | Attribute_Min
            | Attribute_Mod
            | Attribute_Modulus
            | Attribute_Pos
            | Attribute_Pred
            | Attribute_Remainder
            | Attribute_Result
            | Attribute_Rounding
            | Attribute_Succ
            | Attribute_Terminated
            | Attribute_Truncation
            | Attribute_Update
            | Attribute_Val
            | Attribute_Value
         =>
            null;

         --  These attributes are supported according to SPARM RM, but we
         --  currently only support static values in GNATprove.
         when Attribute_Adjacent
            | Attribute_Aft
            | Attribute_Caller
            | Attribute_Compose
            | Attribute_Definite
            | Attribute_Delta
            | Attribute_Denorm
            | Attribute_Digits
            | Attribute_Exponent
            | Attribute_First_Valid
            | Attribute_Fore
            | Attribute_Fraction
            | Attribute_Last_Valid
            | Attribute_Leading_Part
            | Attribute_Machine
            | Attribute_Machine_Emax
            | Attribute_Machine_Emin
            | Attribute_Machine_Mantissa
            | Attribute_Machine_Overflows
            | Attribute_Machine_Radix
            | Attribute_Machine_Rounds
            | Attribute_Machine_Rounding
            | Attribute_Model
            | Attribute_Model_Emin
            | Attribute_Model_Epsilon
            | Attribute_Model_Mantissa
            | Attribute_Model_Small
            | Attribute_Partition_ID
            | Attribute_Range
            | Attribute_Round
            | Attribute_Safe_First
            | Attribute_Safe_Last
            | Attribute_Scale
            | Attribute_Scaling
            | Attribute_Small
            | Attribute_Unbiased_Rounding
            | Attribute_Wide_Value
            | Attribute_Wide_Wide_Value
            | Attribute_Wide_Wide_Width
            | Attribute_Wide_Width
            | Attribute_Width
         =>
            Mark_Unsupported
              (Lim_Non_Static_Attribute, N, Name => Get_Name_String (Aname));

         --  We assume a maximal length for the image of any type. This length
         --  may be inaccurate for identifiers.
         when Attribute_Img
            | Attribute_Image
         =>
            --  We do not support 'Image on types which are not scalars. We
            --  could theoretically encode the attribute as an uninterpreted
            --  function for all types which do not contain subcomponents of
            --  an access type. Indeed, as we do not encode the address of
            --  access types, it would be incorrect.

            if not Retysp_In_SPARK (Etype (P))
              or else not Has_Scalar_Type (Etype (P))
            then
               Mark_Unsupported
                 (Lim_Img_On_Non_Scalar, N, Name => Get_Name_String (Aname));

            elsif Emit_Warning_Info_Messages
              and then SPARK_Pragma_Is (Opt.On)
              and then Gnat2Why_Args.Pedantic
              and then Is_Enumeration_Type (Etype (P))
            then
               Error_Msg_Name_1 := Aname;
               Error_Msg_N (Warning_Message (Warn_Image_Attribute_Length), N);
            end if;

         --  These attributes are supported, but generate a warning in
         --  "pedantic" mode, owing to their implemention-defined status.
         --  These are the attributes marked "Warn" in SPARK RM 15.2.
         when Attribute_Alignment
            | Attribute_Bit_Order
            | Attribute_Component_Size
            | Attribute_First_Bit
            | Attribute_Last_Bit
            | Attribute_Object_Size
            | Attribute_Position
            | Attribute_Size
            | Attribute_Value_Size
         =>
            --  Attribute Alignment is only supported for a type, or an object
            --  for which its value is specified explicitly. Otherwise, the
            --  value of the object alignment is not known, as it is defined by
            --  gigi which might use the value of alignment for its type, or
            --  promote it in some cases to a larger value.

            if Attr_Id = Attribute_Alignment then
               declare
                  Has_Type_Prefix : constant Boolean :=
                    Nkind (P) in N_Identifier | N_Expanded_Name
                      and then Is_Type (Entity (P));
                  Has_Known_Alignment : constant Boolean :=
                    Nkind (P) in N_Has_Entity
                      and then Present (Entity (P))
                      and then Known_Alignment (Entity (P));
               begin
                  if not (Has_Type_Prefix or else Has_Known_Alignment) then
                     Mark_Unsupported (Lim_Unknown_Alignment, N);
                     return;
                  end if;
               end;
            end if;

            if Emit_Warning_Info_Messages
              and then SPARK_Pragma_Is (Opt.On)
              and then Gnat2Why_Args.Pedantic
            then
               Error_Msg_Name_1 := Aname;
               Error_Msg_N
                 (Warning_Message (Warn_Representation_Attribute_Value), N);
            end if;

         when Attribute_Valid =>
            if Emit_Warning_Info_Messages
              and then SPARK_Pragma_Is (Opt.On)
            then
               Error_Msg_F (Warning_Message (Warn_Attribute_Valid), N);
            end if;

         --  Attribute Initialized is used on prefixes with relaxed
         --  initialization. It does not mandate the evaluation of its prefix.
         --  Thus it can be called on scalar "names" which are not initialized
         --  without generating a bounded error.

         when Attribute_Initialized =>

            if not Retysp_In_SPARK (Etype (P))
              or else not
                (Expr_Has_Relaxed_Init (P, No_Eval => True)
                 or else Has_Relaxed_Init (Etype (P))
                 or else (Nkind (P) in N_Identifier | N_Expanded_Name
                          and then Has_Relaxed_Initialization (Entity (P))))
            then
               Mark_Violation
                 ("prefix of attribute """
                  & Standard_Ada_Case (Get_Name_String (Aname))
                  & """ without initialization by proof",
                  N);
            end if;

         --  Attribute Address is only allowed inside an Address aspect
         --  or attribute definition clause (SPARK RM 15.2).
         --  We also exclude nodes that are known to make proof switch
         --  domain from Prog to Pred, as this is not supported in the
         --  translation currently.

         when Attribute_Address =>

            declare
               M : Node_Id := Parent (N);

            begin

               loop
                  if Nkind (M) = N_Attribute_Definition_Clause
                    and then Chars (M) = Name_Address
                  then
                     exit;
                  elsif Nkind (M) in N_Range
                                   | N_Quantified_Expression
                                   | N_Subtype_Indication
                  then
                     Mark_Unsupported
                       (Lim_Address_Attr_In_Unsupported_Context, N);
                     exit;
                  elsif Nkind (M) in N_Subexpr then
                     null;
                  else
                     Mark_Violation
                       ("attribute ""Address"" outside an attribute definition"
                        & " clause", N);
                     exit;
                  end if;
                  M := Parent (M);
               end loop;
            end;

            --  Reject taking the address of a subprogram

            if Nkind (P) in N_Identifier | N_Expanded_Name
              and then not Is_Object (Entity (P))
            then
               Mark_Violation ("attribute """
                               & Standard_Ada_Case (Get_Name_String (Aname))
                               & """ of a non-object entity", N);
            end if;

         --  Check SPARK RM 3.10(13) regarding 'Old and 'Loop_Entry on access
         --  types.

         when Attribute_Loop_Entry
            | Attribute_Old
         =>
            if Is_Deep (Etype (P)) then
               declare
                  Par     : constant Node_Id := Parent (N);
                  Astring : constant String :=
                    Standard_Ada_Case (Get_Name_String (Aname));

               begin
                  --  Special case: 'Old is allowed as the actual of a call to
                  --  a function annotated with At_End_Borrow.

                  if Attr_Id = Attribute_Old
                    and then Present (Par)
                    and then Nkind (Par) = N_Function_Call
                    and then Has_At_End_Borrow_Annotation
                      (Get_Called_Entity (Par))
                  then
                     null;
                  elsif Nkind (P) /= N_Function_Call then
                     Mark_Violation
                       ("prefix of """ & Astring & """ introducing aliasing",
                        P, SRM_Reference => "SPARK RM 3.10(13)",
                        Cont_Msg => "call a deep copy function for type """
                        & Source_Name (Etype (P)) & """ as prefix of """
                        & Astring & """ to avoid aliasing");

                  elsif Is_Traversal_Function_Call (P) then
                     Mark_Violation
                       ("traversal function call as a prefix of """ & Astring
                        & """ attribute",
                        P, SRM_Reference => "SPARK RM 3.10(13)");
                  end if;
               end;
            end if;

         when Attribute_Access =>
            declare
               Par : constant Node_Id := Parent (N);
            begin
               --  We support 'Access if it is directly prefixed by a
               --  subprogram name.

               if Nkind (P) in N_Identifier | N_Expanded_Name
                 and then Is_Subprogram (Entity (P))
               then
                  declare
                     Subp : constant Subprogram_Kind_Id := Entity (P);
                  begin
                     if not In_SPARK (Subp) then
                        Mark_Violation (N, From => P);

                     --  Dispatching operations need a specialised version that
                     --  called on classwide types. We do not support them is
                     --  currently.

                     elsif Is_Dispatching_Operation (Subp) then
                        Mark_Unsupported (Lim_Access_To_Dispatch_Op, N);

                     --  Volatile functions and subprograms declared within a
                     --  protected object have an implicit global parameter. We
                     --  do not support taking their access.

                     elsif Ekind (Subp) = E_Function
                       and then Is_Volatile_Function (Subp)
                     then
                        Mark_Violation ("access to volatile function", N);

                     elsif Within_Protected_Type (Subp) then
                        Mark_Violation
                          ("access to subprogram declared within a protected"
                           & " object", N);

                     --  Subprograms annotated with relaxed initialization need
                     --  a special handling at call.

                     elsif Has_Aspect (Subp, Aspect_Relaxed_Initialization)
                     then
                        Mark_Unsupported
                          (Lim_Access_To_Relaxed_Init_Subp, N);

                     --  Subprogram with non-null Global contract (either
                     --  explicit or generated). Global accesses are allowed
                     --  for specialized actuals of functions annotated with
                     --  higher order specialization.

                     elsif not Is_Specialized_Actual (N) then
                        declare
                           Globals : Global_Flow_Ids;
                        begin
                           Get_Globals
                             (Subprogram          => Subp,
                              Scope               =>
                                (Ent => Subp, Part => Visible_Part),
                              Classwide           => False,
                              Globals             => Globals,
                              Use_Deduced_Globals =>
                                 not Gnat2Why_Args.Global_Gen_Mode,
                              Ignore_Depends      => False);

                           if not Globals.Proof_Ins.Is_Empty
                             or else not Globals.Inputs.Is_Empty
                             or else not Globals.Outputs.Is_Empty
                           then
                              Mark_Violation
                                ("access to subprogram with global effects",
                                 N);
                           end if;
                        end;
                     end if;
                  end;

               --  N should visibly be of an access type

               elsif not Is_Access_Type (Retysp (Etype (N))) then
                  Mark_Violation
                    ("Access attribute of a private type", N);
                  return;

               --  The prefix must be a path rooted inside an object

               elsif not Is_Access_Object_Type (Retysp (Etype (N)))
                 or else not Is_Path_Expression (P)
               then
                  Mark_Violation
                    ("Access attribute on a complex expression", N);
                  return;

               elsif No (Get_Root_Object (P)) then
                  Mark_Violation
                    ("Access attribute of a path not rooted inside an object",
                     N);
                  return;

               --  For a named access-to-constant type, mark the prefix before
               --  checking whether it is rooted at a constant part of an
               --  object.

               elsif not Is_Anonymous_Access_Type (Etype (N))
                 and then Is_Access_Constant (Retysp (Etype (N)))
               then

                  Mark (P);
                  pragma Assert (List_Length (Exprs) = 0);

                  declare
                     Root : constant Object_Kind_Id := Get_Root_Object (P);
                  begin
                     --  Reject paths not rooted inside a constant part of an
                     --  object. Parameters of mode IN are not considered
                     --  constants as the actual might be a variable.
                     --  Also reject paths rooted inside observers which can
                     --  really be parts of variables.

                     if (Is_Anonymous_Access_Object_Type (Etype (Root))
                         or else not Is_Constant_In_SPARK (Root)
                         or else Ekind (Root) = E_In_Parameter)
                       and then not Traverse_Access_To_Constant (P)
                     then
                        Mark_Violation
                          ("Access attribute of a named access-to-constant"
                           & " type whose prefix is not a constant part of an"
                           & " object", N);
                     end if;
                  end;

                  --  We can return here, the prefix has already been marked

                  return;

               --  'Access of an anonymous access-to-object type or named
               --  access-to-variable type must occur directly inside an
               --  assignment statement, an object declaration, or a simple
               --  return statement from a non-expression function. We don't
               --  need to worry about declare expressions, 'Access is not
               --  allowed there.
               --  This is because the expression introduces a borrower/an
               --  observer/a move that we only handle currently inside
               --  declarations, assignments and on return of traversal
               --  functions. We could consider allowing it inside
               --  non-traversal function calls (probaly easy) or inside
               --  procedure calls (would require special handling in flow and
               --  proof).

               elsif No (Par)
                 or else Nkind (Par) not in N_Assignment_Statement
                                          | N_Object_Declaration
                                          | N_Simple_Return_Statement
                 or else N /= Expression (Par)
               then
                  Mark_Unsupported
                    (Lim_Access_Attr_With_Ownership_In_Unsupported_Context, N);
                  return;
               end if;
            end;

         when others =>
            Mark_Violation
              ("attribute """ & Standard_Ada_Case (Get_Name_String (Aname))
               & """", N);
            return;
      end case;

      Mark (P);
      Mark_List (Exprs);
   end Mark_Attribute_Reference;

   --------------------
   -- Mark_Binary_Op --
   --------------------

   procedure Mark_Binary_Op (N : N_Binary_Op_Id) is
      E : constant Subprogram_Kind_Id := Entity (N);

   begin
      --  Call is in SPARK only if the subprogram called is in SPARK.
      --
      --  Here we only deal with calls to operators implemented as intrinsic,
      --  because calls to user-defined operators completed with ordinary
      --  bodies have been already replaced by the frontend to N_Function_Call.
      --  These include predefined ones (like those on Standard.Boolean),
      --  compiler-defined (like concatenation of array types), and
      --  user-defined (completed with a pragma Intrinsic).

      pragma Assert (Is_Intrinsic_Subprogram (E));

      pragma Assert (Ekind (E) in E_Function | E_Operator);

      if Ekind (E) = E_Function
        and then not In_SPARK (E)
      then
         Mark_Violation (N, From => E);
      end if;

      Mark (Left_Opnd (N));
      Mark (Right_Opnd (N));

      --  Disallow equality operators tests if they involved the use of the
      --  predefined equality on access types (except if one of the operands is
      --  syntactically null).

      if Nkind (N) in N_Op_Eq | N_Op_Ne
        and then Retysp_In_SPARK (Etype (Left_Opnd (N)))
        and then Predefined_Eq_Uses_Pointer_Eq (Etype (Left_Opnd (N)))
        and then Nkind (Left_Opnd (N)) /= N_Null
        and then Nkind (Right_Opnd (N)) /= N_Null
      then
         Mark_Violation ("equality on access types", N);

      --  Only support multiplication and division operations on fixed-point
      --  types if either:
      --  - one of the arguments is an integer type, or
      --  - the result type is an integer type, or
      --  - both arguments and the result have compatible fixed-point types as
      --    defined in Ada RM G.2.3(21)

      elsif Nkind (N) in N_Op_Multiply | N_Op_Divide then
         declare
            L_Type    : constant Type_Kind_Id :=
              Base_Type (Etype (Left_Opnd (N)));
            R_Type    : constant Type_Kind_Id :=
              Base_Type (Etype (Right_Opnd (N)));
            Expr_Type : constant Type_Kind_Id := Etype (N);
            E_Type    : constant Type_Kind_Id := Base_Type (Expr_Type);

            L_Type_Is_Fixed : constant Boolean :=
              Has_Fixed_Point_Type (L_Type);
            L_Type_Is_Float : constant Boolean :=
              Has_Floating_Point_Type (L_Type);
            R_Type_Is_Fixed : constant Boolean :=
              Has_Fixed_Point_Type (R_Type);
            R_Type_Is_Float : constant Boolean :=
              Has_Floating_Point_Type (R_Type);
            E_Type_Is_Fixed : constant Boolean :=
              Has_Fixed_Point_Type (E_Type);
            E_Type_Is_Float : constant Boolean :=
              Has_Floating_Point_Type (E_Type);
         begin
            --  We support multiplication and division between different
            --  fixed-point types provided the result is in the "perfect result
            --  set" according to Ada RM G.2.3(21).

            if L_Type_Is_Fixed and R_Type_Is_Fixed then
               declare
                  L_Small : constant Ureal := Small_Value (L_Type);
                  R_Small : constant Ureal := Small_Value (R_Type);
                  E_Small : constant Ureal :=
                    (if E_Type_Is_Fixed then Small_Value (E_Type)
                     elsif Has_Integer_Type (E_Type) then Ureal_1
                     else raise Program_Error);
                  Factor  : constant Ureal :=
                    (if Nkind (N) = N_Op_Multiply then
                       (L_Small * R_Small) / E_Small
                     else
                       L_Small / (R_Small * E_Small));
               begin
                  --  For the operation to be in the perfect result set, the
                  --  smalls of the fixed-point types should be "compatible"
                  --  according to Ada RM G.2.3(21):
                  --  - for a multiplication, (l * r) / op should be an integer
                  --    or the reciprocal of an integer;
                  --  - for a division, l / (r * op) should be an integer or
                  --    the reciprocal of an integer.

                  if Norm_Num (Factor) /= Uint_1
                    and then Norm_Den (Factor) /= Uint_1
                  then
                     Mark_Unsupported (Lim_Op_Incompatible_Fixed, N);
                  end if;
               end;

            --  Operations between fixed point and floating point values are
            --  not supported yet.

            elsif (L_Type_Is_Fixed or R_Type_Is_Fixed or E_Type_Is_Fixed)
              and (L_Type_Is_Float or R_Type_Is_Float or E_Type_Is_Float)
            then
               Mark_Unsupported (Lim_Op_Fixed_Float, N);
            end if;
         end;
      end if;

      --  In pedantic mode, issue a warning whenever an arithmetic operation
      --  could be reordered by the compiler, like "A + B - C", as a given
      --  ordering may overflow and another may not. Not that a warning is
      --  issued even on operations like "A * B / C" which are not reordered
      --  by GNAT, as they could be reordered according to RM 4.5/13.

      if Emit_Warning_Info_Messages
        and then Gnat2Why_Args.Pedantic

        --  Ignore code defined in the standard library, unless the main unit
        --  is from the standard library. In particular, ignore code from
        --  instances of generics defined in the standard library (unless we
        --  are analyzing the standard library itself). As a result, no warning
        --  is generated in this case for standard library code. Such warnings
        --  are only noise, because a user sets the strict SPARK mode precisely
        --  when he uses another compiler than GNAT, with a different
        --  implementation of the standard library.

        and then not Is_Ignored_Internal (N)
        and then SPARK_Pragma_Is (Opt.On)

      then
         case N_Binary_Op'(Nkind (N)) is
            when N_Op_Add | N_Op_Subtract =>
               if Nkind (Left_Opnd (N)) in N_Op_Add | N_Op_Subtract
                 and then Paren_Count (Left_Opnd (N)) = 0
               then
                  Error_Msg_F
                    (Warning_Message (Warn_Operator_Reassociation),
                     Left_Opnd (N));
               end if;

               if Nkind (Right_Opnd (N)) in N_Op_Add | N_Op_Subtract
                 and then Paren_Count (Right_Opnd (N)) = 0
               then
                  pragma Annotate
                    (Xcov, Exempt_On, "GNAT associates to the left");
                  Error_Msg_F
                    (Warning_Message (Warn_Operator_Reassociation),
                     Right_Opnd (N));
                  pragma Annotate (Xcov, Exempt_Off);
               end if;

            when N_Multiplying_Operator =>
               if Nkind (Left_Opnd (N)) in N_Multiplying_Operator
                 and then Paren_Count (Left_Opnd (N)) = 0
               then
                  Error_Msg_F
                    (Warning_Message (Warn_Operator_Reassociation),
                     Left_Opnd (N));
               end if;

               if Nkind (Right_Opnd (N)) in N_Multiplying_Operator
                 and then Paren_Count (Right_Opnd (N)) = 0
               then
                  pragma Annotate
                    (Xcov, Exempt_On, "GNAT associates to the left");
                  Error_Msg_F
                    (Warning_Message (Warn_Operator_Reassociation),
                     Right_Opnd (N));
                  pragma Annotate (Xcov, Exempt_Off);
               end if;

            when others =>
               null;
         end case;
      end if;
   end Mark_Binary_Op;

   ---------------
   -- Mark_Call --
   ---------------

   procedure Mark_Call (N : Node_Id) is
      E : constant Callable_Kind_Id := Get_Called_Entity (N);
      --  Entity of the called subprogram or entry

      function Is_Volatile_Call (Call_Node : Node_Id) return Boolean;
      --  Returns True iff call is volatile

      procedure Mark_Param (Formal : Formal_Kind_Id; Actual : N_Subexpr_Id);
      --  Mark actuals of the call

      ----------------------
      -- Is_Volatile_Call --
      ----------------------

      function Is_Volatile_Call (Call_Node : Node_Id) return Boolean is
         Target : constant Callable_Kind_Id :=
           Get_Called_Entity (Call_Node);
      begin
         if Is_Protected_Type (Scope (Target))
           and then not Is_External_Call (Call_Node)
         then

            --  This is an internal call to protected function

            return Is_Enabled_Pragma
              (Get_Pragma (Target, Pragma_Volatile_Function));
         else
            return Is_Volatile_Function (Target);
         end if;
      end Is_Volatile_Call;

      ----------------
      -- Mark_Param --
      ----------------

      procedure Mark_Param (Formal : Formal_Kind_Id; Actual : N_Subexpr_Id) is
      begin
         --  Special checks for effectively volatile calls and objects
         if Comes_From_Source (Actual)
           and then
             (Is_Effectively_Volatile_Object_For_Reading (Actual)
              or else (Nkind (Actual) = N_Function_Call
                       and then Nkind (Name (Actual)) /= N_Explicit_Dereference
                         and then Is_Volatile_Call (Actual)))
         then
            --  An effectively volatile object may act as an actual when the
            --  corresponding formal is of a non-scalar effectively volatile
            --  type (SPARK RM 7.1.3(10)).

            if not Is_Scalar_Type (Etype (Formal))
              and then Is_Effectively_Volatile_For_Reading (Etype (Formal))
            then
               null;

            --  An effectively volatile object may act as an actual in a call
            --  to an instance of Unchecked_Conversion. (SPARK RM 7.1.3(10)).

            elsif Is_Unchecked_Conversion_Instance (E) then
               null;

            else
               Mark_Violation
                 (Msg           =>
                  (case Nkind (Actual) is
                   when N_Function_Call => "volatile function call",
                   when others => "volatile object")
                  & " as actual",
                  N             => Actual,
                  SRM_Reference => "SPARK RM 7.1.3(10)");
            end if;
         end if;

         --  Regular checks
         Mark (Actual);

         --  In a procedure or entry call, copy in of a parameter of an
         --  anonymous access type is considered to be an observe/a borrow.
         --  Check that it abides by the corresponding rules.
         --  This will also recursively check borrows occuring as part of calls
         --  of traversal functions in these parameters.

         if Is_Anonymous_Access_Object_Type (Etype (Formal))
           and then not Is_Function_Or_Function_Type (E)
         then
            if not Is_Null_Owning_Access (Actual) then
               Check_Source_Of_Borrow_Or_Observe
                 (Actual, Is_Access_Constant (Etype (Formal)));
            end if;

         --  OUT and IN OUT parameters of an access type are considered to be
         --  moved.

         elsif Is_Access_Type (Etype (Formal))
           and then Ekind (Formal) in E_In_Out_Parameter | E_Out_Parameter
           and then Ekind (Directly_Designated_Type (Etype (Formal))) /=
           E_Subprogram_Type
         then
            Check_Source_Of_Move (Actual);
         end if;

         --  We only support updates to actual parameters which are parts of
         --  variables. This is enforced by the Ada language and the frontend
         --  except when the actual parameter contains a dereference of an
         --  expression of an access-to-variable type.
         --  A parameter is considered to be modified by a call if its mode is
         --  OUT or IN OUT, or if its mode is IN, it has an access-to-variable
         --  type, and the called subprogram is not a function.

         if Ekind (Formal) in E_In_Out_Parameter | E_Out_Parameter
           or else
             (not Is_Function_Or_Function_Type (E)
              and then Ekind (Formal) = E_In_Parameter
              and then Is_Access_Variable (Etype (Formal)))
         then
            declare
               Mode : constant String :=
                 (case Ekind (Formal) is
                     when E_In_Parameter     =>
                       "`IN` parameter of an access-to-variable type",
                     when E_In_Out_Parameter =>
                       "`IN OUT` parameter",
                     when E_Out_Parameter    =>
                       "`OUT` parameter",
                     when others             =>
                        raise Program_Error);
            begin
               --  Actual should represent a part of an object

               if not Is_Path_Expression (Actual)
                 or else
                   No (Get_Root_Object (Actual, Through_Traversal => False))
               then
                  if not Is_Null_Owning_Access (Actual) then
                     Mark_Violation
                       ("expression as " & Mode, Actual);
                  end if;

               --  The root object of Actual should not be a constant objects

               elsif Is_Constant_In_SPARK (Get_Root_Object (Actual)) then
                  Mark_Violation
                    ("constant object as " & Mode, Actual);

               --  The actual should not be inside an access-to-constant type

               elsif Traverse_Access_To_Constant (Actual) then
                  Mark_Violation
                    ("access-to-constant part of an object as " & Mode,
                     Actual);
               end if;
            end;
         end if;

         --  If Formal has an anonymous access type, it can happen that Formal
         --  and Actual have incompatible designated type. Reject this case.

         if In_SPARK (Etype (Formal)) then
            Check_Compatible_Access_Types (Etype (Formal), Actual);
         end if;
      end Mark_Param;

      procedure Mark_Actuals is new Iterate_Call_Parameters (Mark_Param);

   --  Start processing for Mark_Call

   begin
      --  Early marking of the return type of E (if any), to be able to call
      --  Is_Allocating_Function afterwards.
      if Etype (E) /= Standard_Void_Type then
         Mark_Entity (Etype (E));
      end if;

      if Is_Allocating_Function (E)
        and then not Is_Valid_Allocating_Context (N)
      then
         Mark_Violation
           ("call to allocating function not stored in object as "
            & "part of assignment, declaration or return", N);
      end if;

      --  If N is a call to the predefined equality of a tagged type, mark
      --  the actual and check that the equality does not apply to access
      --  types.

      if Is_Tagged_Predefined_Eq (E) then
         Mark_Actuals (N);

         declare
            Left  : constant Node_Id := First_Actual (N);
            Right : constant Node_Id := Next_Actual (Left);
            pragma Assert (No (Next_Actual (Right)));
         begin
            if Predefined_Eq_Uses_Pointer_Eq (Etype (Left)) then
               Mark_Violation ("equality on access types", N);
            end if;
         end;

         return;
      end if;

      if Nkind (Name (N)) = N_Explicit_Dereference then
         Mark (Prefix (Name (N)));
         Mark_Actuals (N);
         return;

      else

         --  Calls to aliases, i.e. subprograms created by the frontend
         --  that operate on derived types, are rewritten with calls to
         --  corresponding subprograms that operate on the base types.

         pragma Assert
           (if Is_Overloadable (E)
            then E = Ultimate_Alias (E)
            else Ekind (E) = E_Entry_Family);
      end if;

      --  There should not be calls to default initial condition and invariant
      --  procedures.

      pragma Assert (not Subprogram_Is_Ignored_For_Proof (E));

      --  External calls to non-library-level objects are not yet supported

      if Ekind (Scope (E)) = E_Protected_Type
        and then Is_External_Call (N)
      then
         declare
            Obj : constant Opt_Object_Kind_Id :=
              Get_Enclosing_Object (Prefix (Name (N)));
         begin
            if Present (Obj) then
               case Ekind (Obj) is
                  when Formal_Kind =>
                     Mark_Unsupported (Lim_Protected_Operation_Of_Formal, N);
                     return;

                  --  Accept external calls prefixed with library-level objects

                  when E_Variable =>
                     Mark (Prefix (Name (N)));

                  when E_Component =>
                     Mark_Unsupported
                       (Lim_Protected_Operation_Of_Component, N);
                     return;

                  when others =>
                     raise Program_Error;
               end case;
            else
               Mark_Violation
                 ("call through access to protected operation", N);
               return;
            end if;
         end;
      end if;

      --  Similar limitation for suspending on suspension objects
      if Suspends_On_Suspension_Object (E) then
         declare
            Obj : constant Opt_Object_Kind_Id :=
              Get_Enclosing_Object (First_Actual (N));
         begin
            if Present (Obj) then
               case Ekind (Obj) is
                  when Formal_Kind =>
                     Mark_Unsupported (Lim_Suspension_On_Formal, N);
                     return;

                  --  Suspension on library-level objects is fine

                  when E_Variable =>
                     null;

                  when others =>
                     raise Program_Error;
               end case;
            else
               Mark_Violation
                 ("suspension through access to suspension object", N);
               return;
            end if;
         end;
      end if;

      if Ekind (E) = E_Function
        and then Is_Volatile_Call (N)
        and then
          (not Is_OK_Volatile_Context
             (Context => Parent (N), Obj_Ref => N, Check_Actuals => True)
           or else In_Loop_Entry_Or_Old_Attribute (N))
      then
         Mark_Violation ("call to a volatile function in interfering context",
                         N);
         return;
      end if;

      --  We are calling a predicate function whose predicate is not visible
      --  in SPARK. This is OK, we do not try to mark the call.

      if Ekind (E) = E_Function
        and then Is_Predicate_Function (E)
        and then not In_SPARK (E)
      then
         return;
      end if;

      Mark_Entity (E);
      Mark_Actuals (N);

      --  Call is in SPARK only if the subprogram called is in SPARK

      if not In_SPARK (E) then
         if Is_Subprogram (E) then
            declare
               --  Detect when the spec and body have the same source location,
               --  which indicates that the spec was generated by the frontend.
               --  If the body is marked as SPARK_Mode(Off), then having
               --  a separate declaration could allow marking it as
               --  SPARK_Mode(On) so that it can be called from SPARK code. Do
               --  not attempt to analyze further the context to discriminate
               --  cases where this would be sufficient.
               Spec_N : constant Node_Id := Subprogram_Spec (E);
               Body_N : constant Node_Id := Subprogram_Body (E);
               Prag_N : constant Node_Id :=
                 (if Present (Body_N) then
                    SPARK_Pragma_Of_Entity (Subprogram_Body_Entity (E))
                  else Empty);
               Cont_Msg : constant String :=
                 (if Present (Prag_N)
                    and then Sloc (Spec_N) = Sloc (Body_N)
                    and then Get_SPARK_Mode_From_Annotation (Prag_N) = Opt.Off
                  then
                     "separate subprogram declaration from subprogram body to "
                     & "allow calling it from SPARK code"
                  else "");
            begin
               Mark_Violation (N, From => E, Cont_Msg => Cont_Msg);
            end;
         else  --  Entry
            Mark_Violation (N, From => E);
         end if;

      elsif Nkind (N) in N_Subprogram_Call
        and then Present (Controlling_Argument (N))
        and then Is_Hidden_Dispatching_Operation (E)
      then
         Mark_Violation
           ("dispatching call on primitive of untagged private", N);

      --  Warn about calls to predefined and imported subprograms with no
      --  manually-written Global or Depends contracts. Exempt calls to pure
      --  subprograms (because Pure acts as "Global => null").

      elsif Emit_Warning_Info_Messages and then SPARK_Pragma_Is (Opt.On) then

         declare
            Might_Have_Flow_Assumptions : constant Boolean :=
              (Has_No_Body (E)
                 or else (Is_Ignored_Internal (E)
                            and then not Is_Ignored_Internal (N)))
              and then not Is_Unchecked_Conversion_Instance (E)
              and then not Is_Unchecked_Deallocation_Instance (E);

         begin
            if Might_Have_Flow_Assumptions then
               if not Has_User_Supplied_Globals (E) then
                  Error_Msg_NE
                    (Warning_Message (Warn_Assumed_Global_Null), N, E);
                  Error_Msg_NE
                    ("\\assuming & has no effect on global items", N, E);
               end if;

               if not Has_Any_Returning_Annotation (E) then
                  Error_Msg_NE
                    (Warning_Message (Warn_Assumed_Always_Return), N, E);
                  Error_Msg_NE
                    ("\\assuming & always returns", N, E);
               end if;
            end if;
         end;

      --  On supported unchecked conversions to access types, emit warnings
      --  stating that we assume the returned value to be valid and with no
      --  harmful aliases. The warnings are also emitted on calls to
      --  To_Pointer function from an instance of
      --  System.Address_To_Access_Conversions, which performs the same
      --  operation.

      elsif Is_System_Address_To_Access_Conversion (E)
        or else (Is_Unchecked_Conversion_Instance (E)
                 and then Has_Access_Type (Etype (E)))
      then
         Error_Msg_NE (Warning_Message (Warn_Address_To_Access), N, E);
         if Is_Access_Constant (Etype (E)) then
            Error_Msg_NE
              ("\\potential aliases of the value returned by a call"
               & " to & are assumed to be constant", N, E);
         else
            Error_Msg_NE
              ("\\the value returned by a call to & is assumed to "
               & "have no aliases", N, E);
         end if;
      end if;

      --  A possibly nonreturning procedure should only be called from
      --  another (possibly) nonreturning procedure.

      if Has_Might_Not_Return_Annotation (E) then
         declare
            Caller : constant Unit_Kind_Id :=
              Unique_Defining_Entity (Enclosing_Declaration (N));
         begin
            if not Is_Possibly_Nonreturning_Procedure (Caller) then
               Error_Msg_N ("call to possibly nonreturning procedure outside "
                            & "a (possibly) nonreturning procedure", N);
               if Ekind (Caller) = E_Procedure then
                  Error_Msg_NE
                    ("\consider annotating caller & with pragma Annotate "
                     & "('G'N'A'Tprove, Might_Not_Return)",
                     N, Caller);
               end if;
            end if;
         end;
      end if;

      --  Check that the parameter of a function annotated with At_End_Borrow
      --  is either the result of a traversal function or a path rooted at an
      --  entity. The fact that this entity references a borrower or borrowed
      --  object will be checked in the borrow checker where we keep a map
      --  of the local borrowers in the scope of the call. We still check here
      --  calls occuring in contracts, as those are not traversed in the borrow
      --  checker. Their verification is simpler as referring to borrowed
      --  entities is not allowed in nested subprograms, so the root should be
      --  a local borrower.

      if Has_At_End_Borrow_Annotation (E) then
         declare
            In_Proc_Call     : Boolean := False;
            In_Old_Attribute : Boolean := False;
            In_Contracts     : Opt_Subprogram_Kind_Id := Empty;

            function Check_Call_Context (Call : Node_Id) return Boolean;
            --  Check whether Call occurs in a context where it can be handled.
            --  If this context is the contract of a subprogram, set
            --  In_Contracts to the entity of the related subprogram.
            --  If the context is a procedure call, set In_Proc_Call to True.
            --  For now, only allow postconditions, lemmas, and assertions. We
            --  can extend later if we see a need. Set In_Old_Attribute to True
            --  if Call occurs inside a 'Loop_Entry or 'Old attribute.

            ------------------------
            -- Check_Call_Context --
            ------------------------

            function Check_Call_Context (Call : Node_Id) return Boolean is
               N : Node_Id := Call;
               P : Node_Id;
            begin
               loop
                  P := Parent (N);

                  case Nkind (P) is
                     when N_Pragma_Argument_Association =>
                        declare
                           Prag_Id : constant Pragma_Id :=
                             Get_Pragma_Id (Pragma_Name (Parent (P)));
                        begin
                           case Prag_Id is
                              when Pragma_Postcondition
                                 | Pragma_Post_Class
                                 | Pragma_Contract_Cases
                                 | Pragma_Refined_Post
                              =>
                                 In_Contracts := Unique_Defining_Entity
                                   (Find_Related_Declaration_Or_Body
                                      (Parent (P)));
                                 return True;
                              when Pragma_Check =>
                                 return True;
                              when others =>
                                 return False;
                           end case;
                        end;
                     when N_Subexpr
                        | N_Loop_Parameter_Specification
                        | N_Iterated_Component_Association
                        | N_Iterator_Specification
                        | N_Component_Association
                        | N_Parameter_Association
                     =>
                        --  We allow procedure calls if they correspond to
                        --  lemmas.

                        if Nkind (P) = N_Procedure_Call_Statement then
                           In_Proc_Call := True;

                           declare
                              Proc     : constant E_Procedure_Id :=
                                Get_Called_Entity (P);
                              Contract : constant Opt_N_Pragma_Id :=
                                Find_Contract (Proc, Pragma_Global);
                              Formal   : Opt_Formal_Kind_Id :=
                                First_Formal (Proc);

                           begin
                              --  Proc is necessarily Ghost. It is a lemma if
                              --  it has no outputs.

                              pragma Assert (Is_Ghost_Entity (Proc));

                              while Present (Formal) loop
                                 if not Is_Constant_In_SPARK (Formal) then
                                    return False;
                                 end if;
                                 Next_Formal (Formal);
                              end loop;

                              return Present (Contract)
                                and then Parse_Global_Contract
                                  (Proc, Contract).Outputs.Is_Empty;
                           end;
                        elsif Is_Attribute_Loop_Entry (P)
                          or else Is_Attribute_Old (P)
                        then
                           In_Old_Attribute := True;
                           return False;
                        end if;
                     when others =>
                        return False;
                  end case;
                  N := P;
               end loop;
            end Check_Call_Context;

            Fst_Actual             : constant Node_Id := First_Actual (N);
            Is_Result_Of_Traversal : constant Boolean :=
              Nkind (Fst_Actual) = N_Attribute_Reference
              and then Attribute_Name (Fst_Actual) = Name_Result
              and then Is_Borrowing_Traversal_Function
                (Entity (Prefix (Fst_Actual)));
            --  Fst_Actual is the result of a traversal function

            Is_Path_To_Object      : constant Boolean :=
              Is_Path_Expression (Fst_Actual)
              and then Present
                (Get_Root_Object (Fst_Actual, Through_Traversal => False));
            --  Fst_Actual is a path rooted at an object, with no calls

            Is_Borrowed_Parameter  : constant Boolean :=
              Nkind (Fst_Actual) in N_Identifier | N_Expanded_Name
              and then Ekind (Entity (Fst_Actual)) = E_In_Parameter
              and then Is_Borrowing_Traversal_Function
                (Scope (Entity (Fst_Actual)))
              and then Entity (Fst_Actual) =
                First_Formal (Scope (Entity (Fst_Actual)));
            --  Fst_Actual is the borrowed parameter of a traversal function

         begin
            --  Check that the call occurs in a supported context. Normally,
            --  we should allow all calls inside postconditions and assertions.

            if not Check_Call_Context (N) then
               if In_Old_Attribute then
                  Mark_Violation
                    ("call to a function annotated with At_End_Borrow"
                     & " occurring inside a reference to the 'Old or"
                     & " 'Loop_Entry attributes",
                     N);
               elsif In_Proc_Call then
                  Mark_Violation
                    ("call to a function annotated with At_End_Borrow"
                     & " occurring inside a procedure call which is not known"
                     & " to be free of side-effects",
                     N);
               else
                  Mark_Violation
                    ("call to a function annotated with At_End_Borrow"
                     & " occurring outside of a postcondition, contract cases,"
                     & " or assertion",
                     N);
               end if;

            --  We are inside a contract. Check the root of the actual and
            --  store the mapping here as the expression will not be traversed
            --  in the borrow checker.

            elsif In_Contracts /= Empty then

               --  In postconditions of traversal functions, we expect a
               --  reference to the 'Result attribute or the borrowed
               --  parameter.

               if Is_Result_Of_Traversal then
                  Set_At_End_Borrow_Call (N, Entity (Prefix (Fst_Actual)));
               elsif Is_Borrowed_Parameter
                 and then In_Contracts = Scope (Get_Root_Object (Fst_Actual))
               then
                  Set_At_End_Borrow_Call
                    (N, Scope (Get_Root_Object (Fst_Actual)));

               --  In any subprograms, we allow a reference to local borrowers
               --  defined globally to the subprogram, either directly or as
               --  a prefix of the 'Old attribute.

               elsif Nkind (Fst_Actual) in N_Identifier | N_Expanded_Name
                 and then Is_Local_Borrower (Entity (Fst_Actual))
               then
                  Set_At_End_Borrow_Call (N, Entity (Fst_Actual));
               elsif Is_Attribute_Old (Fst_Actual)
                 and then Nkind (Prefix (Fst_Actual)) in
                   N_Identifier | N_Expanded_Name
                 and then Is_Local_Borrower (Entity (Prefix (Fst_Actual)))
               then
                  Set_At_End_Borrow_Call (N, Entity (Prefix (Fst_Actual)));

               else
                  Mark_Violation
                    ("actual parameter of a function annotated with"
                     & " At_End_Borrow in a contract which is not a"
                     & " local borrower or the borrowed parameter of a"
                     & " traversal function",
                     Fst_Actual);
               end if;

            --  Otherwise, we only check that the actual is a path. The rest
            --  will be checked by the borrow checker.

            elsif not Is_Path_To_Object then
               Mark_Violation
                 ("actual parameter of a function annotated with At_End_Borrow"
                  & " which is not a path",
                  Fst_Actual);
            end if;
         end;
      end if;

      --  Check that cut operations occurs in a supported context, that is:
      --
      --   * As the expression of a pragma ASSERT or ASSERT_AND_CUT;
      --   * As an operand of a AND, OR, AND THEN, or OR ELSE operation which
      --     itself occurs in a supported context;
      --   * As the THEN or ELSE branch of a IF expression which itself
      --     occurs in a supported context;
      --   * As an alternative of a CASE expression which itself occurs in a
      --     supported context;
      --   * As the condition of a quantified expression which itself occurs in
      --     a supported context;
      --   * As a parameter to a call to a cut operation which itself occurs in
      --     a supported context;
      --   * As the body expression of a DECLARE expression which itself occurs
      --     in a supported context.

      if Is_From_Hardcoded_Unit (E, Cut_Operations) then
         declare
            function Check_Call_Context (Call : Node_Id) return Boolean;
            --  Check whether Call occurs in a context where it can be handled

            ------------------------
            -- Check_Call_Context --
            ------------------------

            function Check_Call_Context (Call : Node_Id) return Boolean is
               N : Node_Id := Call;
               P : Node_Id;
            begin
               loop
                  P := Parent (N);

                  case Nkind (P) is
                     when N_Pragma_Argument_Association =>
                        return Is_Pragma_Check (Parent (P), Name_Assert)
                          or else Is_Pragma_Check
                            (Parent (P), Name_Assert_And_Cut);
                     when N_Op_And
                        | N_Op_Or
                        | N_And_Then
                        | N_Or_Else
                        | N_Case_Expression_Alternative
                        | N_Quantified_Expression
                        | N_Expression_With_Actions
                        | N_Parameter_Association
                     =>
                        null;
                     when N_If_Expression =>
                        if N = First (Expressions (P)) then
                           return False;
                        end if;
                     when N_Case_Expression =>
                        if N = Expression (P) then
                           return False;
                        end if;
                     when N_Function_Call =>
                        if No (Get_Called_Entity (P))
                          or else not Is_From_Hardcoded_Unit
                            (Get_Called_Entity (P), Cut_Operations)
                        then
                           return False;
                        end if;
                     when others =>
                        return False;
                  end case;
                  N := P;
               end loop;
            end Check_Call_Context;

         begin
            if not Check_Call_Context (N) then
               Mark_Violation
                 ("call to a cut operation in an incorrect context",
                  N);
            end if;
         end;
      end if;
   end Mark_Call;

   ---------------------------
   -- Mark_Compilation_Unit --
   ---------------------------

   procedure Mark_Compilation_Unit (N : Node_Id) is
      CU        : constant Node_Id := Parent (N);
      Context_N : Node_Id;

   begin
      --  Violations within Context_Items, e.g. unknown configuration pragmas,
      --  should not affect the SPARK status of the entities in the compilation
      --  unit itself, so we reset the Violation_Detected flag to False after
      --  marking them.

      pragma Assert (not Violation_Detected);

      Context_N := First (Context_Items (CU));
      while Present (Context_N) loop
         Mark (Context_N);
         Next (Context_N);
      end loop;

      Violation_Detected := False;

      --  Mark entities in SPARK or not

      Mark (N);

      --  Violation_Detected may have been set to True while checking types.
      --  Reset it here.

      Violation_Detected := False;

      --  Mark entities from the marking queue, delayed type aspects, full
      --  views of accesses to incomplete or partial types. Conceptually, they
      --  are kept in queues; we pick an arbitrary element, process and delete
      --  it from the queue; this is repeated until all queues are empty.

      loop
         --  Go through Marking_Queue to mark remaining entities

         if not Marking_Queue.Is_Empty then

            declare
               E : constant Entity_Id := Marking_Queue.First_Element;
            begin
               Mark_Entity (E);
               Marking_Queue.Delete_First;
            end;

         --  Mark delayed type aspects

         elsif not Delayed_Type_Aspects.Is_Empty then

            --  If no SPARK_Mode is set for the type, we only mark delayed
            --  aspects for types which have been found to be in SPARK. In this
            --  case, every violation is considered an error as we can't easily
            --  backtrack the type to be out of SPARK.

            declare
               --  The procedures generated by the frontend for
               --  Default_Initial_Condition or Type_Invariant are stored
               --  as keys in the Delayed_Type_Aspects map.

               Subp                : constant E_Procedure_Id :=
                 Node_Maps.Key (Delayed_Type_Aspects.First);
               Delayed_Mapping     : constant Node_Or_Entity_Id :=
                 Delayed_Type_Aspects (Delayed_Type_Aspects.First);
               Save_SPARK_Pragma   : constant Opt_N_Pragma_Id :=
                 Current_SPARK_Pragma;
               Mark_Delayed_Aspect : Boolean;

            begin
               --  Consider delayed aspects only if type was in a scope
               --  marked SPARK_Mode(On)...

               if Nkind (Delayed_Mapping) = N_Pragma then
                  Current_SPARK_Pragma := Delayed_Mapping;
                  Mark_Delayed_Aspect := True;

               --  Or if the type entity has been found to be in SPARK. In this
               --  case (scope not marked SPARK_Mode(On)), the type entity was
               --  stored as value in the Delayed_Type_Aspects map.

               elsif Retysp_In_SPARK (Delayed_Mapping) then
                  Current_SPARK_Pragma := Empty;
                  Mark_Delayed_Aspect := True;

               else
                  Mark_Delayed_Aspect := False;
               end if;

               if Mark_Delayed_Aspect then
                  declare
                     Expr  : constant Node_Id :=
                       Get_Expr_From_Check_Only_Proc (Subp);
                     Param : constant Formal_Kind_Id := First_Formal (Subp);

                  begin
                     --  Delayed type aspects can't be processed recursively
                     pragma Assert (No (Current_Delayed_Aspect_Type));
                     Current_Delayed_Aspect_Type := Etype (Param);
                     Mark_Entity (Param);

                     pragma Assert (not Violation_Detected);
                     Mark (Expr);
                     --  ??? Violations in the aspect expressions seem ignored
                     Violation_Detected := False;

                     --  Restore global variable to its initial value
                     Current_Delayed_Aspect_Type := Empty;
                  end;

                  Current_SPARK_Pragma := Save_SPARK_Pragma;
               end if;

               Delayed_Type_Aspects.Delete (Subp);
            end;

         --  Mark full views of incomplete types and make sure that they
         --  are in SPARK (otherwise an error is raised). Also populate
         --  the Incomplete_Views map.

         elsif not Access_To_Incomplete_Types.Is_Empty then
            declare
               E : constant Type_Kind_Id :=
                 Access_To_Incomplete_Types.First_Element;

            begin
               if Entity_In_SPARK (E) then
                  declare
                     Save_SPARK_Pragma : constant Opt_N_Pragma_Id :=
                       Current_SPARK_Pragma;
                     Des_Ty            : Type_Kind_Id :=
                       Directly_Designated_Type (E);

                  begin
                     if Is_Incomplete_Type (Des_Ty) then
                        Des_Ty := Full_View (Des_Ty);
                     end if;

                     --  Get the appropriate SPARK pragma for the access type

                     Current_SPARK_Pragma := SPARK_Pragma_Of_Entity (E);

                     --  As the access type has already been found to be in
                     --  SPARK, force the reporting of errors by setting the
                     --  Current_Incomplete_Type.

                     if not SPARK_Pragma_Is (Opt.On) then
                        Current_Incomplete_Type := E;
                        Current_SPARK_Pragma := Empty;
                     end if;

                     if not Retysp_In_SPARK (Des_Ty) then
                        Mark_Violation (E, From => Des_Ty);

                     --  Reject deferred access to types for which an invariant
                     --  check is needed. This makes it possible to stop at
                     --  (possibly unmarked) deferred incomplete types when
                     --  looking for type invariants elsewhere in marking.

                     elsif Invariant_Check_Needed (Des_Ty) then
                        Mark_Unsupported (Lim_Type_Inv_Access_Type, E);

                     else

                        --  Attempt to insert the view in the incomplete views
                        --  map if the designated type is not already present
                        --  (which can happen if there are several access types
                        --  designating the same incomplete type).

                        declare
                           Pos : Node_Maps.Cursor;
                           Ins : Boolean;
                        begin
                           Access_To_Incomplete_Views.Insert
                             (Retysp (Des_Ty), E, Pos, Ins);

                           pragma Assert
                             (Is_Access_Type (Node_Maps.Element (Pos))
                              and then
                                Ekind (Directly_Designated_Type
                                  (Node_Maps.Element (Pos))) /=
                                E_Subprogram_Type
                              and then
                                (Acts_As_Incomplete_Type
                                   (Directly_Designated_Type
                                       (Node_Maps.Element (Pos)))
                                 or else
                                   (Ekind (Node_Maps.Element (Pos)) =
                                        E_Access_Subtype
                                    and then Acts_As_Incomplete_Type
                                        (Directly_Designated_Type
                                            (Base_Retysp
                                                (Node_Maps.Element (Pos)))))));
                        end;
                     end if;

                     Current_SPARK_Pragma := Save_SPARK_Pragma;
                     Violation_Detected := False;
                     Current_Incomplete_Type := Empty;
                  end;
               end if;

               Access_To_Incomplete_Types.Delete_First;
            end;
         else
            exit;
         end if;
      end loop;

      --  Everything has been marked, we can perform the left-over checks on
      --  pragmas Annotate GNATprove if any.

      Do_Delayed_Checks_On_Pragma_Annotate;
   end Mark_Compilation_Unit;

   --------------------------------
   -- Mark_Component_Association --
   --------------------------------

   procedure Mark_Component_Association (N : N_Component_Association_Id) is

      function Component_Inherits_Relaxed_Initialization
        (N : N_Component_Association_Id)
         return Boolean;
      --  Return True if the component inherits relaxed initialization
      --  from an enclosing composite type in the aggregate.

      function Component_Inherits_Relaxed_Initialization
        (N : N_Component_Association_Id)
         return Boolean
      is
         Par : constant N_Subexpr_Id := Parent (N);
         Typ : constant Type_Kind_Id := Retysp (Etype (Par));
      begin
         pragma Assert (Nkind (Par) in N_Aggregate | N_Extension_Aggregate);

         if Has_Relaxed_Init (Typ) then
            return True;
         elsif Nkind (Parent (Par)) = N_Component_Association then
            return Component_Inherits_Relaxed_Initialization (Parent (Par));
         else
            return False;
         end if;
      end Component_Inherits_Relaxed_Initialization;

   --  Start of processing for Mark_Component_Association

   begin
      --  We enforce SPARK RM 4.3(1) for which the box symbol, <>, shall not
      --  be used in an aggregate unless the type(s) of the corresponding
      --  component(s) define full default initialization, or have relaxed
      --  initialization.

      if Box_Present (N)
        and then not Component_Inherits_Relaxed_Initialization (N)
      then
         pragma Assert (Nkind (Parent (N)) in N_Aggregate
                                            | N_Extension_Aggregate);

         declare
            Typ : constant Type_Kind_Id := Retysp (Etype (Parent (N)));
            --  Type of the aggregate; ultimately this will be either an array
            --  or a record.

            pragma Assert (Is_Record_Type (Typ) or else Is_Array_Type (Typ));

         begin
            case Ekind (Typ) is
               when Record_Kind =>
                  declare
                     Choice     : constant Node_Id := First (Choices (N));
                     Choice_Typ : constant Type_Kind_Id := Etype (Choice);

                  begin
                     pragma Assert (Nkind (Choice) = N_Identifier);
                     --  In the source code Choice can be either an
                     --  N_Identifier or N_Others_Choice, but the latter
                     --  is expanded by the frontend.

                     if Default_Initialization (Choice_Typ) /=
                         Full_Default_Initialization
                       and then not Has_Relaxed_Init (Choice_Typ)
                     then
                        Mark_Violation
                          ("box notation without default or relaxed "
                           & "initialization",
                           Choice,
                           SRM_Reference => "SPARK RM 4.3(1)");
                     end if;
                  end;

               --  Arrays can be default-initialized either because each
               --  component is default-initialized (e.g. due to Default_Value
               --  aspect) or because the entire array is default-initialized
               --  (e.g. due to Default_Component_Value aspect), but default-
               --  initialization of a component implies the default-
               --  initialization of the array, so we only check the latter.

               when Array_Kind =>
                  if Default_Initialization (Typ) /=
                      Full_Default_Initialization
                    and then not Has_Relaxed_Init (Typ)
                  then
                     Mark_Violation
                       ("box notation without default or relaxed "
                        & "initialization",
                        N,
                        SRM_Reference => "SPARK RM 4.3(1)");
                  end if;

               when others =>
                  raise Program_Error;
            end case;
         end;
      end if;

      Mark_List (Choices (N));

      if not Box_Present (N) then
         Mark (Expression (N));
      end if;
   end Mark_Component_Association;

   --------------------------------------
   -- Mark_Concurrent_Type_Declaration --
   --------------------------------------

   procedure Mark_Concurrent_Type_Declaration (N : Node_Id) is
      E                       : constant Entity_Id := Defining_Entity (N);
      Type_Def                : constant Node_Id :=
        (if Ekind (E) = E_Protected_Type
         then Protected_Definition (N)
         else Task_Definition (N));
      Save_Violation_Detected : constant Boolean := Violation_Detected;

   begin
      Violation_Detected := False;

      --  Protected types declared inside other protected types are not
      --  allowed in SPARK. Indeed SPARK RM 7.1.3(3) mandates effectively
      --  volatile types to appear at library level.

      pragma Assert
        (Ekind (E) /= E_Protected_Type or else not Within_Protected_Type (E));

      if Has_Discriminants (E) then
         declare
            D : Opt_E_Discriminant_Id := First_Discriminant (E);
         begin
            while Present (D) loop
               Mark_Entity (D);
               Next_Discriminant (D);
            end loop;
         end;
      end if;

      if Present (Type_Def) then
         Mark_Stmt_Or_Decl_List (Visible_Declarations (Type_Def));

         declare
            Save_SPARK_Pragma : constant Node_Id := Current_SPARK_Pragma;

         begin
            Current_SPARK_Pragma := SPARK_Aux_Pragma (E);
            if not SPARK_Pragma_Is (Opt.Off) then
               Mark_Stmt_Or_Decl_List (Private_Declarations (Type_Def));
            end if;

            Current_SPARK_Pragma := Save_SPARK_Pragma;
         end;
      end if;

      Violation_Detected := Save_Violation_Detected;
   end Mark_Concurrent_Type_Declaration;

   ---------------------------
   -- Mark_Constant_Globals --
   ---------------------------

   procedure Mark_Constant_Globals (Globals : Node_Sets.Set) is
   begin
      for Global of Globals loop
         if Ekind (Global) = E_Constant then
            Mark_Entity (Global);
         end if;
      end loop;
   end Mark_Constant_Globals;

   -----------------
   -- Mark_Entity --
   -----------------

   procedure Mark_Entity (E : Entity_Id) is

      --  Subprograms for marking specific entities. These are defined locally
      --  so that they cannot be called from other marking subprograms, which
      --  should call Mark_Entity instead.

      procedure Mark_Parameter_Entity (E : Object_Kind_Id)
      with Pre => Ekind (E) in E_Discriminant
                             | E_Loop_Parameter
                             | E_Variable
                             | Formal_Kind;
      --  E is a subprogram or a loop parameter, or a discriminant

      procedure Mark_Number_Entity     (E : Named_Kind_Id);
      procedure Mark_Object_Entity     (E : Constant_Or_Variable_Kind_Id);

      procedure Mark_Subprogram_Entity (E : Callable_Kind_Id)
      with Pre => (if Is_Subprogram (E)
                   then (Ekind (E) = E_Function
                         and then Is_Intrinsic_Subprogram (E))
                        or else E = Ultimate_Alias (E)
                   else Ekind (E) in Entry_Kind | E_Subprogram_Type);
      --  Mark subprogram or entry. Make sure that we don't mark aliases
      --  (except for intrinsic functions).

      procedure Mark_Type_Entity       (E : Type_Kind_Id);

      use type Node_Lists.Cursor;

      Current_Concurrent_Insert_Pos : Node_Lists.Cursor;
      --  This variable is set at the start of marking concurrent type and
      --  stores the position on the list where the type itself should be
      --  inserted.
      --
      --  Concurrent types must be inserted into Entity_List before operations
      --  defined in their scope, because these operations take the type as an
      --  implicit argument.

      ------------------------
      -- Mark_Number_Entity --
      ------------------------

      procedure Mark_Number_Entity (E : Named_Kind_Id) is
         N    : constant N_Number_Declaration_Id := Parent (E);
         Expr : constant N_Subexpr_Id            := Expression (N);
         T    : constant Type_Kind_Id            := Etype (E);
      begin
         if not Retysp_In_SPARK (T) then
            Mark_Violation (N, From => T);
         end if;

         if Present (Expr) then
            Mark (Expr);
         end if;
      end Mark_Number_Entity;

      ------------------------
      -- Mark_Object_Entity --
      ------------------------

      procedure Mark_Object_Entity (E : Constant_Or_Variable_Kind_Id) is
         N        : constant N_Object_Declaration_Id := Parent (E);
         Def      : constant Node_Id                 := Object_Definition (N);
         Expr     : constant Opt_N_Subexpr_Id        := Expression (N);
         T        : constant Type_Kind_Id            := Etype (E);
         Sub      : constant Opt_Type_Kind_Id        := Actual_Subtype (E);
         Encap_Id : constant Entity_Id               :=
           Encapsulating_State (E);

      begin
         --  A variable whose Part_Of pragma specifies a single concurrent
         --  type as encapsulator must be (SPARK RM 9.4):
         --    * Of a type that defines full default initialization, or
         --    * Declared with a default value, or
         --    * Imported.

         if Present (Encap_Id)
           and then Is_Single_Concurrent_Object (Encap_Id)
           and then In_SPARK (Etype (E))
           and then Default_Initialization (Etype (E))
             not in Full_Default_Initialization | No_Possible_Initialization
           and then not Has_Initial_Value (E)
           and then not Is_Imported (E)
         then
            Mark_Violation ("not fully initialized part of " &
                            (if Ekind (Etype (Encap_Id)) = E_Task_Type
                             then "task"
                             else "protected") & " type",
                            Def, SRM_Reference => "SPARK RM 9.4");
         end if;

         --  The object is in SPARK if-and-only-if its type is in SPARK and
         --  its initialization expression, if any, is in SPARK.

         --  If the object's nominal and actual types are not in SPARK, then
         --  the expression can't be in SPARK, so we skip it to limit the
         --  number of error messages.

         if not Retysp_In_SPARK (T) then
            Mark_Violation (E, From => T);
            return;
         end if;

         --  A declaration of a stand-alone object of an anonymous access
         --  type shall have an explicit initial value and shall occur
         --  immediately within a subprogram body, an entry body, or a
         --  block statement (SPARK RM 3.10(5)).

         if Nkind (N) = N_Object_Declaration
           and then Is_Anonymous_Access_Object_Type (T)
         then
            declare
               Scop : constant Entity_Id := Scope (E);
            begin
               if not Is_Local_Context (Scop) then
                  Mark_Violation
                    ("object of anonymous access not declared "
                     & "immediately within a subprogram, entry or block",
                     N, SRM_Reference => "SPARK RM 3.10(5)");
               end if;
            end;

            if No (Expr) then
               Mark_Violation
                 ("uninitialized object of anonymous access type",
                  N, SRM_Reference => "SPARK RM 3.10(5)");
            end if;
         end if;

         if Present (Sub)
           and then not In_SPARK (Sub)
         then
            Mark_Violation (E, From => Sub);
            return;
         end if;

         --  Frontend only rejects volatile ghost objects when SPARK_Mode is On

         if Is_Ghost_Entity (E) and then Is_Effectively_Volatile (E) then
            Mark_Violation
              ("volatile ghost object", N, SRM_Reference => "SPARK RM 6.9(7)");
         end if;

         --  Do not allow type invariants on volatile data with asynchronous
         --  readers and writers as it can be broken asynchronously outside
         --  of the type enclosing unit.

         if Has_Volatile (E)
           and then (Has_Volatile_Property (E, Pragma_Async_Readers)
                     or else Has_Volatile_Property (E, Pragma_Async_Writers))
           and then Invariant_Check_Needed (Etype (E))
         then
            Mark_Unsupported (Lim_Type_Inv_Volatile, N);
         end if;

         if Present (Expr) then
            Mark (Expr);

            --  If the type of the object is an anonymous access type, then the
            --  declaration is an observe or a borrow. Check that it follows
            --  the rules.

            if Nkind (N) = N_Object_Declaration
              and then Is_Anonymous_Access_Object_Type (T)
            then
               Check_Source_Of_Borrow_Or_Observe
                 (Expr, Is_Access_Constant (T));

            --  If we are performing a move operation, check that we are
            --  moving a path.

            elsif Is_Deep (T) then
               Check_Source_Of_Move (Expr);
            end if;

            --  If T has an anonymous access type, it can happen that Expr and
            --  E have incompatible designated type. Reject this case.

            Check_Compatible_Access_Types (T, Expr);
         end if;

         --  If no violations were found and the object is annotated with
         --  relaxed initialization, populate the Relaxed_Init map.

         if not Violation_Detected
           and then Ekind (E) in E_Variable | E_Constant
           and then Has_Relaxed_Initialization (E)
         then

            --  Emit a warning when the annotation of an object with
            --  Relaxed_Initialization has no effects.

            if not Obj_Has_Relaxed_Init (E) then
               if Emit_Warning_Info_Messages then
                  Error_Msg_NE
                    (Warning_Message (Warn_Useless_Relaxed_Init_Obj), E, E);
                  Error_Msg_N
                    ("\Relaxed_Initialization annotation is useless", E);
               end if;
            else
               Mark_Type_With_Relaxed_Init
                 (N   => E,
                  Ty  => T,
                  Own => False);
            end if;
         end if;

         --  Also mark the Address clause if any

         Mark_Address (E);
      end Mark_Object_Entity;

      ---------------------------
      -- Mark_Parameter_Entity --
      ---------------------------

      procedure Mark_Parameter_Entity (E : Object_Kind_Id) is
         T : constant Type_Kind_Id := Etype (E);

      begin
         --  If T is not in SPARK, E is not in SPARK. If T is a limited view
         --  coming from a limited with, reject E directly to have a better
         --  location.

         if Is_Incomplete_Type_From_Limited_With (T) then
            Reject_Incomplete_Type_From_Limited_With (T, E);

         elsif not Retysp_In_SPARK (T) then
            Mark_Violation (E, From => T);

         --  If no violations were found and the object is annotated with
         --  relaxed initialization, populate the Relaxed_Init map.

         elsif not Violation_Detected
           and then Is_Formal (E)
           and then Has_Relaxed_Initialization (E)
         then

            --  Emit a warning when the annotation of an object with
            --  Relaxed_Initialization has no effects.

            if not Obj_Has_Relaxed_Init (E) then
               if Emit_Warning_Info_Messages then
                  Error_Msg_NE
                    (Warning_Message (Warn_Useless_Relaxed_Init_Obj), E, E);
                  Error_Msg_N
                    ("\Relaxed_Initialization annotation is useless", E);
               end if;
            else
               Mark_Type_With_Relaxed_Init
                 (N   => E,
                  Ty  => T,
                  Own => False);
            end if;
         end if;
      end Mark_Parameter_Entity;

      ----------------------------
      -- Mark_Subprogram_Entity --
      ----------------------------

      procedure Mark_Subprogram_Entity (E : Callable_Kind_Id) is

         procedure Mark_Function_Specification (Id : Function_Kind_Id);
         --  Mark violations related to impure functions

         procedure Mark_Subprogram_Contracts;
         --  Mark pre-post contracts

         procedure Mark_Subprogram_Specification (Id : Callable_Kind_Id);
         --  Mark violations related to parameters, result and contract

         procedure Process_Class_Wide_Condition
           (Expr    : N_Subexpr_Id;
            Spec_Id : Subprogram_Kind_Id);
         --  Replace the type of all references to the controlling formal of
         --  subprogram Spec_Id found in expression Expr with the corresponding
         --  class-wide type.

         ---------------------------------
         -- Mark_Function_Specification --
         ---------------------------------

         procedure Mark_Function_Specification (Id : Function_Kind_Id) is
            Is_Volatile_Func : constant Boolean :=
              (if Ekind (Id) = E_Function then Is_Volatile_Function (Id)
               else Has_Effectively_Volatile_Profile (Id));
            Formal           : Opt_Formal_Kind_Id := First_Formal (Id);

         begin
            --  A nonvolatile function shall not have a result of an
            --  effectively volatile type (SPARK RM 7.1.3(9)).

            if not Is_Volatile_Func
              and then Is_Effectively_Volatile_For_Reading (Etype (Id))
            then
               Mark_Violation
                 ("nonvolatile function with effectively volatile result", Id);
            end if;

            --  Only traversal functions can return anonymous access types.
            --  Check for the first formal to be in SPARK before calling
            --  Is_Traversal_Function to avoid calling Retysp on an unmarked
            --  type.

            if Is_Anonymous_Access_Object_Type (Etype (Id))
              and then
                (No (First_Formal (Id))
                 or else Retysp_In_SPARK (Etype (First_Formal (Id))))
              and then not Is_Traversal_Function (Id)
            then
               Mark_Violation
                 ("anonymous access type for result for "
                  & "non-traversal functions", Id);

            --  If Id is a borrowing traversal function, its first parameter
            --  must have an anonymous access-to-variable type.

            elsif Is_Borrowing_Traversal_Function (Id) then
               if not Is_Anonymous_Access_Type (Etype (First_Formal (Id)))
                 or else not Is_Access_Variable (Etype (First_Formal (Id)))
               then
                  Mark_Unsupported (Lim_Borrow_Traversal_First_Param, Id);

               --  For now we don't support volatile borrowing traversal
               --  functions.
               --  Supporting them would require some special handling as we
               --  cannot call the function in the term domain to update the
               --  value of the borrowed parameter at end.

               elsif Is_Volatile_Func then
                  Mark_Unsupported (Lim_Borrow_Traversal_Volatile, Id);
               end if;
            end if;

            --  We currently do not support functions annotated with No_Return.
            --  If the need arise, we could handle them as raise expressions,
            --  using a precondition of False to ensure that they are never
            --  called. We should take care of potential interactions with
            --  Might_Not_Return annotations. We might also want a special
            --  handling for such function calls inside preconditions (see
            --  handling of raise expressions).

            if No_Return (Id) then
               Mark_Unsupported (Lim_No_Return_Function, Id);
            end if;

            while Present (Formal) loop

               --  A nonvolatile function shall not have a formal parameter
               --  of an effectively volatile type (SPARK RM 7.1.3(9)). Do
               --  not issue this violation on compiler-generated predicate
               --  functions, as the violation is better detected on the
               --  expression itself for a better error message.

               if not Is_Volatile_Func
                 and then (Ekind (Id) /= E_Function
                           or else not Is_Predicate_Function (Id))
                 and then Is_Effectively_Volatile_For_Reading (Etype (Formal))
               then
                  Mark_Violation
                    ("nonvolatile function with effectively volatile " &
                       "parameter", Id);
               end if;

               --  A function declaration shall not have a
               --  parameter_specification with a mode of OUT or IN OUT
               --  (SPARK RM 6.1(6)).

               case Ekind (Formal) is
                  when E_Out_Parameter =>
                     Mark_Violation ("function with OUT parameter", Id);

                  when E_In_Out_Parameter =>
                     Mark_Violation ("function with `IN OUT` parameter", Id);

                  when E_In_Parameter =>
                     null;

                  when others =>
                     raise Program_Error;
               end case;

               Next_Formal (Formal);
            end loop;

            --  If the result type of a subprogram is not in SPARK, then the
            --  subprogram is not in SPARK. If the result types is a limited
            --  view coming from a limited with, reject the function directly
            --  to have a better location.

            if Is_Incomplete_Type_From_Limited_With (Etype (Id)) then
               Reject_Incomplete_Type_From_Limited_With (Etype (Id), Id);

            elsif not Retysp_In_SPARK (Etype (Id)) then
               Mark_Violation (Id, From => Etype (Id));

            --  For now we disallow access designating subprograms returning
            --  a type with invariants that may need to be checked (ie,
            --  from the current compilation unit), as the contract may
            --  depend on where the designated subprogram is declared. If the
            --  type is not in the current compilation unit, it should be fine,
            --  as all visible subprograms ensure that the invariant holds at
            --  boundaries.

            elsif Ekind (Id) in E_Subprogram_Type
              and then Invariant_Check_Needed (Etype (Id))
            then
               Mark_Unsupported (Lim_Access_Sub_Return_Type_With_Inv, Id);
            end if;

            --  Go over the global objects accessed by Id to make sure that
            --  they are not written and that they are not volatile if Id
            --  is not a volatile function. This check is done in the frontend
            --  for explict global contracts, but we need it for the generated
            --  ones.

            if Ekind (Id) = E_Function
              and then not Is_Predicate_Function (Id)
            then
               declare
                  Globals : Global_Flow_Ids;
               begin
                  Get_Globals
                    (Subprogram          => Id,
                     Scope               => (Ent => Id, Part => Visible_Part),
                     Classwide           => False,
                     Globals             => Globals,
                     Use_Deduced_Globals =>
                        not Gnat2Why_Args.Global_Gen_Mode,
                     Ignore_Depends      => False);

                  if not Globals.Outputs.Is_Empty then
                     for G of Globals.Outputs loop
                        declare
                           G_Name : constant String :=
                             (if G.Kind in Direct_Mapping then "&"
                              else '"' & Flow_Id_To_String (G, Pretty => True)
                                & '"');
                        begin
                           if G.Kind in Direct_Mapping then
                              Error_Msg_Node_2 := G.Node;
                           end if;
                           Mark_Violation
                             ("function & with output global " & G_Name,
                              Id,
                              Root_Cause_Msg =>
                                "function with global outputs");
                        end;
                     end loop;

                  else
                     for G of Globals.Inputs.Union (Globals.Proof_Ins) loop

                        --  Volatile variable with effective reads are outputs.
                        --  This case can only happen with abstract states
                        --  annotated with External. Other cases are rejected
                        --  in the frontend.

                        if Has_Effective_Reads (G) then
                           declare
                              G_Name : constant String :=
                                (if G.Kind in Direct_Mapping then "&"
                                 else '"'
                                 & Flow_Id_To_String (G, Pretty => True)
                                 & '"');
                           begin
                              if G.Kind in Direct_Mapping then
                                 Error_Msg_Node_2 := G.Node;
                              end if;
                              Mark_Violation
                                ("function & with volatile input global "
                                 & G_Name & " with effective reads",
                                 Id,
                                 Root_Cause_Msg => "function with global "
                                 & "inputs with effective reads");
                           end;
                        end if;

                        --  A nonvolatile function shall not have volatile
                        --  global inputs (SPARK RM 7.1.3(8)).

                        if not Is_Volatile_Function (Id)
                          and then Has_Async_Writers (G)
                        then
                           declare
                              G_Name : constant String :=
                                (if G.Kind in Direct_Mapping then "&"
                                 else '"'
                                 & Flow_Id_To_String (G, Pretty => True)
                                 & '"');
                           begin
                              if G.Kind in Direct_Mapping then
                                 Error_Msg_Node_2 := G.Node;
                              end if;
                              Mark_Violation
                                ("nonvolatile function & with volatile input "
                                 & "global " & G_Name,
                                 Id,
                                 Root_Cause_Msg => "nonvolatile function with "
                                 & " volatile global inputs");
                           end;
                        end if;
                     end loop;
                  end if;
               end;
            end if;
         end Mark_Function_Specification;

         -------------------------------
         -- Mark_Subprogram_Contracts --
         -------------------------------

         procedure Mark_Subprogram_Contracts is
            Prag : Node_Id := (if Present (Contract (E))
                               then Pre_Post_Conditions (Contract (E))
                               else Empty);
            Expr : Node_Id;
         begin

            while Present (Prag) loop
               Expr :=
                 Get_Pragma_Arg (First (Pragma_Argument_Associations (Prag)));

               Mark (Expr);

               --  For a class-wide condition, a corresponding expression must
               --  be created in which a reference to a controlling formal
               --  is interpreted as having the class-wide type. This is used
               --  to create a suitable pre- or postcondition expression for
               --  analyzing dispatching calls. This is done here so that the
               --  newly created expression can be marked, including its
               --  possible newly created itypes.

               if Class_Present (Prag) then
                  declare
                     New_Expr : constant Node_Id :=
                       New_Copy_Tree (Source => Expr);
                  begin
                     Process_Class_Wide_Condition (New_Expr, E);
                     Mark (New_Expr);
                     Set_Dispatching_Contract (Expr, New_Expr);
                     Set_Parent (New_Expr, Prag);
                  end;
               end if;

               Prag := Next_Pragma (Prag);
            end loop;

            Prag := Get_Pragma (E, Pragma_Contract_Cases);
            if Present (Prag) then
               declare
                  Aggr          : constant Node_Id :=
                    Expression (First (Pragma_Argument_Associations (Prag)));
                  Case_Guard    : Node_Id;
                  Conseq        : Node_Id;
                  Contract_Case : Node_Id :=
                    First (Component_Associations (Aggr));
               begin
                  while Present (Contract_Case) loop
                     Case_Guard := First (Choices (Contract_Case));
                     Conseq     := Expression (Contract_Case);

                     Mark (Case_Guard);

                     Mark (Conseq);

                     Next (Contract_Case);
                  end loop;
               end;
            end if;

            Prag := Get_Pragma (E, Pragma_Subprogram_Variant);
            if Present (Prag) then
               declare
                  Aggr : constant Node_Id :=
                    Expression (First (Pragma_Argument_Associations (Prag)));
                  pragma Assert (Nkind (Aggr) = N_Aggregate);

                  Variant : Node_Id :=
                    First (Component_Associations (Aggr));
               begin
                  while Present (Variant) loop
                     pragma Assert (Nkind (Variant) = N_Component_Association);

                     declare
                        Expr : constant Node_Id := Expression (Variant);
                     begin
                        Mark (Expr);

                        --  For structural variants, check that the expression
                        --  is a formal parameter of the subprogram.

                        if Chars (First (Choices (Variant))) = Name_Structural
                          and then
                            not (Nkind (Expr) in N_Identifier | N_Expanded_Name
                                 and then Ekind (Entity (Expr)) in Formal_Kind
                                 and then Scope (Entity (Expr)) = E)
                        then
                           Mark_Violation
                             ("structural subprogram variant which is not a"
                              & " parameter of the subprogram",
                              Expr);
                        end if;
                     end;

                     Next (Variant);
                  end loop;
               end;
            end if;
         end Mark_Subprogram_Contracts;

         -----------------------------------
         -- Mark_Subprogram_Specification --
         -----------------------------------

         procedure Mark_Subprogram_Specification (Id : Callable_Kind_Id) is
            Formal      : Opt_Formal_Kind_Id := First_Formal (Id);
            Contract    : Node_Id;
            Raw_Globals : Raw_Global_Nodes;

         begin
            case Ekind (Id) is
               when E_Subprogram_Type =>
                  if Is_Function_Type (Id) then
                     Mark_Function_Specification (Id);
                  end if;

               when E_Function =>
                  Mark_Function_Specification (Id);

               when E_Entry_Family =>
                  Mark_Unsupported (Lim_Entry_Family, Id);

               when others =>
                  null;
            end case;

            while Present (Formal) loop
               if not In_SPARK (Formal) then
                  Mark_Violation (Formal, From => Etype (Formal));

               --  For now, we disallow access designating subprograms with
               --  formals with invariants that may need to be checked (ie,
               --  from the current compilation unit), as the contract may
               --  depend on where the designated subprogram is declared.

               elsif Ekind (Id) in E_Subprogram_Type
                 and then Invariant_Check_Needed (Etype (Formal))
               then
                  Mark_Unsupported (Lim_Access_Sub_Formal_With_Inv, Formal);
               end if;

               Next_Formal (Formal);
            end loop;

            --  Parse the user-written Global/Depends, if present

            Contract := Find_Contract (E, Pragma_Global);

            if Present (Contract) then
               Raw_Globals := Parse_Global_Contract (E, Contract);

               --  ??? Parse_Global_Contract itself asks which constants have
               --  variable inputs when filtering generic actual parameters of
               --  mode IN, so this might lead to circular dependencies; this
               --  whole constant business should be revisited...

            else
               Contract := Find_Contract (E, Pragma_Depends);

               if Present (Contract) then
                  Raw_Globals := Parse_Depends_Contract (E, Contract);
               end if;
            end if;

            Mark_Constant_Globals (Raw_Globals.Proof_Ins);
            Mark_Constant_Globals (Raw_Globals.Inputs);

         end Mark_Subprogram_Specification;

         ----------------------------------
         -- Process_Class_Wide_Condition --
         ----------------------------------

         procedure Process_Class_Wide_Condition
           (Expr    : N_Subexpr_Id;
            Spec_Id : Subprogram_Kind_Id)
         is
            Disp_Typ : constant Type_Kind_Id :=
              SPARK_Util.Subprograms.Find_Dispatching_Type (Spec_Id);

            function Replace_Type (N : Node_Id) return Traverse_Result;
            --  Within the expression for a Pre'Class or Post'Class aspect for
            --  a primitive subprogram of a tagged type Disp_Typ, a name that
            --  denotes a formal parameter of type Disp_Typ is treated as
            --  having type Disp_Typ'Class. This is used to create a suitable
            --  pre- or postcondition expression for analyzing dispatching
            --  calls.

            ------------------
            -- Replace_Type --
            ------------------

            function Replace_Type (N : Node_Id) return Traverse_Result is
               Context : constant Node_Id    := Parent (N);
               Loc     : constant Source_Ptr := Sloc (N);
               CW_Typ  : Opt_Type_Kind_Id := Empty;
               Ent     : Formal_Kind_Id;
               Typ     : Type_Kind_Id;

            begin
               if Is_Entity_Name (N)
                 and then Present (Entity (N))
                 and then Is_Formal (Entity (N))
               then
                  Ent := Entity (N);
                  Typ := Etype (Ent);

                  if Nkind (Context) = N_Type_Conversion then
                     null;

                  --  Do not perform the type replacement for selector names
                  --  in parameter associations. These carry an entity for
                  --  reference purposes, but semantically they are just
                  --  identifiers.

                  elsif Nkind (Context) = N_Parameter_Association
                    and then Selector_Name (Context) = N
                  then
                     null;

                  elsif Retysp (Typ) = Disp_Typ then
                     CW_Typ := Class_Wide_Type (Typ);
                  end if;

                  if Present (CW_Typ) then
                     Rewrite (N,
                       Nmake.Make_Type_Conversion (Loc,
                         Subtype_Mark =>
                           Tbuild.New_Occurrence_Of (CW_Typ, Loc),
                         Expression   => Tbuild.New_Occurrence_Of (Ent, Loc)));
                     Set_Etype (N, CW_Typ);

                     --  When changing the type of an argument to a potential
                     --  dispatching call, make the call dispatching indeed by
                     --  setting its controlling argument.

                     if Nkind (Parent (N)) = N_Function_Call
                       and then Nkind (Name (Context)) in N_Has_Entity
                       and then Present (Entity (Name (Context)))
                       and then
                         Is_Dispatching_Operation (Entity (Name (Context)))
                     then
                        Set_Controlling_Argument (Context, N);
                     end if;
                  end if;
               end if;

               return OK;
            end Replace_Type;

            procedure Replace_Types is new Traverse_More_Proc (Replace_Type);

         --  Start of processing for Process_Class_Wide_Condition

         begin
            Replace_Types (Expr);
         end Process_Class_Wide_Condition;

      --  Start of processing for Mark_Subprogram_Entity

      begin
         --  Switch --limit-subp may be passed on for a subprogram that is
         --  always inlined. Ignore the switch in that case by resetting
         --  the value of Limit_Subp. If --limit-line or --limit-region are
         --  not already used, set the value of Limit_Region to analyze the
         --  subprogram in its calling contexts.

         if Is_Requested_Subprogram_Or_Task (E)
           and then Is_Local_Subprogram_Always_Inlined (E)
         then
            Gnat2Why_Args.Limit_Subp := Null_Unbounded_String;

            if Gnat2Why_Args.Limit_Region = Null_Unbounded_String
              and then Gnat2Why_Args.Limit_Line = Null_Unbounded_String
            then
               declare
                  function Line_Image (Val : Pos) return String;
                  --  Return the image of Val without leading whitespace

                  ----------------
                  -- Line_Image --
                  ----------------

                  function Line_Image (Val : Pos) return String is
                     S : constant String := Int'Image (Val);
                  begin
                     return S (S'First + 1 .. S'Last);
                  end Line_Image;

                  --  Local variables

                  Body_E     : constant Entity_Id := Get_Body_Entity (E);
                  This_E     : constant Entity_Id :=
                    (if Present (Body_E) then Body_E else E);
                  This_Decl  : constant Node_Id :=
                    (if Present (Body_E) then Subprogram_Body (E)
                     else Subprogram_Spec (E));
                  Slc        : constant Source_Ptr := Sloc (This_E);
                  File       : constant String := File_Name (Slc);
                  First_Line : constant Physical_Line_Number :=
                    Get_Physical_Line_Number (Slc);
                  Last_Line  : constant Physical_Line_Number :=
                    Get_Physical_Line_Number (Sloc (Last_Node (This_Decl)));
                  Limit_Str  : constant String :=
                    File
                    & ':' & Line_Image (Pos (First_Line))
                    & ':' & Line_Image (Pos (Last_Line));
               begin
                  Gnat2Why_Args.Limit_Region :=
                    To_Unbounded_String (Limit_Str);

                  --  Also add the corresponding arguments for gnatwhy3

                  Gnat2Why_Args.Why3_Args.Append ("--limit-region");
                  Gnat2Why_Args.Why3_Args.Append (Limit_Str);
               end;
            end if;
         end if;

         if Is_Protected_Operation (E)
           and then not Is_SPARK_Tasking_Configuration
         then
            Mark_Violation_In_Tasking (E);
         end if;

         --  Reject unchecked deallocation on general access types

         if Is_Unchecked_Deallocation_Instance (E)
           and then Is_General_Access_Type (Etype (First_Formal (E)))
         then
            Mark_Violation
              ("instance of Unchecked_Deallocation with a general access type",
               E);
         end if;

         Mark_Subprogram_Specification (E);

         --  In general, reject unchecked conversion when the source or target
         --  types contain access subcomponents. Converting from an integer
         --  type of System.Address to an access-to-variable type is allowed
         --  but warnings are emitted on calls.

         if Is_Unchecked_Conversion_Instance (E) then
            declare
               From : constant Type_Kind_Id :=
                 Retysp (Etype (First_Formal (E)));
               To   : constant Type_Kind_Id := Retysp (Etype (E));

            begin
               --  Reject unchecked conversions from a type containing access
               --  subcomponents. They cannot be modeled as we do not model the
               --  address of access values.

               if Contains_Access_Subcomponents (From) then
                  Mark_Violation
                    ("unchecked conversion instance from a type with access"
                     & " subcomponents",
                     E);

               --  We reject unchecked conversions to a type containing access
               --  subcomponents. We still accept conversion from integer types
               --  or System.Address to access-to-object types as they are
               --  deemed useful, but with warnings when they are called.

               elsif Is_Access_Subprogram_Type (To) then
                  Mark_Violation
                    ("unchecked conversion instance to an access to"
                     & " subprogram type", E);
               elsif not Is_Access_Type (To)
                 and then Contains_Access_Subcomponents (To)
               then
                  Mark_Violation
                    ("unchecked conversion instance to a composite type with"
                     & " access subcomponents",
                     E);
               elsif Is_Access_Type (To)
                 and then
                   (not Is_Integer_Type (From)
                    and then not Is_System_Address_Type (Base_Retysp (From)))
               then
                  Mark_Violation
                    ("unchecked conversion instance to an access-to-object"
                     & " type from a type which is neither System.Address nor"
                     & " an integer type",
                     E);
               elsif Is_Access_Type (To)
                 and then not Is_Access_Constant (To)
                 and then not Is_General_Access_Type (To)
               then
                  Mark_Violation
                    ("unchecked conversion instance to a pool-specific access"
                     & " type",
                     E);
               end if;
            end;
         end if;

         --  We mark bodies of predicate functions, and of expression functions
         --  when they are referenced (including those from other compilation
         --  units), because proof wants to use their bodies as an implicit
         --  contract.

         --  ??? It would be simpler to use
         --  Is_Expression_Function_Or_Completion, but in
         --  some cases, the results are different, see
         --  e.g. P126-025__generic_function_renaming.

         if Ekind (E) = E_Function then
            declare
               My_Body : constant Node_Id := Subprogram_Body (E);
            begin
               if Present (My_Body)
                 and then
                   (Was_Expression_Function (My_Body)
                    or else Is_Predicate_Function (E))
               then
                  Mark_Subprogram_Body (My_Body);
               end if;
            end;
         end if;

         --  ??? Preconditions in Big_Integers library contain raise
         --  expressions, which are not supported in SPARK.

         if not Is_Hardcoded_Entity (E) then
            Mark_Subprogram_Contracts;
         end if;

         --  Plain preconditions cannot be used in SPARK on dispatching
         --  subprograms. The reason for that is that otherwise the dynamic
         --  semantics of Ada combined with the verification of Liskov
         --  Substitution Principle in SPARK force Pre and Pre'Class to be
         --  equivalent. Hence it would be useless to have both. Note that
         --  it is still possible to have Pre on a primitive operation of an
         --  untagged private type, as there is no way to dispatch on such a
         --  subprogram in SPARK (dispatching on this subprogram is forbidden,
         --  and deriving such a type is also forbidden).

         if Is_Dispatching_Operation (E) then
            declare
               Typ      : constant Opt_Type_Kind_Id :=
                 SPARK_Util.Subprograms.Find_Dispatching_Type (E);
               Pre_List : constant Node_Lists.List :=
                 Find_Contracts (E, Pragma_Precondition);
               Pre      : Node_Id;
            begin
               if not Pre_List.Is_Empty then
                  Pre := Pre_List.First_Element;

                  if Present (Typ)
                    and then not Is_Hidden_Dispatching_Operation (E)
                  then
                     Mark_Violation
                       ("plain precondition on dispatching subprogram",
                        Pre,
                        SRM_Reference => "SPARK RM 6.1.1(2)",
                        Cont_Msg => "use classwide precondition Pre''Class"
                                    & " instead of Pre");
                  end if;
               end if;
            end;
         end if;

         --  Make sure to mark needed entities for checks related to interrupts

         if Ekind (E) = E_Procedure
           and then Present (Get_Pragma (E, Pragma_Attach_Handler))
         then
            Mark_Entity (RTE (RE_Is_Reserved));
         end if;

         --  Enforce the current limitation that a subprogram is only inherited
         --  from a single source, so that there is at most one inherited
         --  Pre'Class or Post'Class to consider for LSP.

         if Is_Dispatching_Operation (E) then
            declare
               Inherit_Subp_No_Intf : constant Subprogram_List :=
                 Sem_Disp.Inherited_Subprograms (E, No_Interfaces => True);
               Inherit_Subp_Intf : constant Subprogram_List :=
                 Sem_Disp.Inherited_Subprograms (E, Interfaces_Only => True);
            begin
               --  Ok to inherit a subprogram only from non-interfaces

               if Inherit_Subp_Intf'Length = 0 then
                  null;

               --  Ok to inherit a subprogram from a single interface

               elsif Inherit_Subp_No_Intf'Length = 0
                 and then Inherit_Subp_Intf'Length = 1
               then
                  null;

               --  Do not support yet a subprogram inherited from root type and
               --  from an interface.

               elsif Inherit_Subp_No_Intf'Length /= 0 then
                  Mark_Unsupported (Lim_Multiple_Inheritance_Root, E);

               --  Do not support yet a subprogram inherited from multiple
               --  interfaces.

               else
                  Mark_Unsupported (Lim_Multiple_Inheritance_Interfaces, E);
               end if;
            end;
         end if;

         --  If no violations were found and the function is annotated with
         --  relaxed initialization, populate the Relaxed_Init map.

         if not Violation_Detected
           and then Ekind (E) = E_Function
           and then Has_Relaxed_Initialization (E)
         then

            --  Emit a warning when the annotation of a function with
            --  Relaxed_Initialization has no effects.

            if not Fun_Has_Relaxed_Init (E) then
               if Emit_Warning_Info_Messages then
                  Error_Msg_NE
                    (Warning_Message (Warn_Useless_Relaxed_Init_Fun), E, E);
                  Error_Msg_N
                    ("\Relaxed_Initialization annotation is useless", E);
               end if;
            else
               Mark_Type_With_Relaxed_Init
                 (N   => E,
                  Ty  => Etype (E),
                  Own => False);
            end if;
         end if;
      end Mark_Subprogram_Entity;

      ----------------------
      -- Mark_Type_Entity --
      ----------------------

      procedure Mark_Type_Entity (E : Type_Kind_Id) is

         function Is_Private_Entity_Mode_Off (E : Type_Kind_Id) return Boolean;
         --  Return True iff E is declared in a private part with
         --  SPARK_Mode => Off.

         function Is_Controlled (E : Entity_Id) return Boolean;
         --  Return True if E is in Ada.Finalization

         procedure Mark_Default_Expression (C : Record_Field_Kind_Id);
         --  Mark default expression of component or discriminant and check it
         --  for references to the current instance of a type or subtype (which
         --  is considered to be variable input).

         -----------------------------
         -- Mark_Default_Expression --
         -----------------------------

         procedure Mark_Default_Expression (C : Record_Field_Kind_Id) is

            function Uses_Current_Type_Instance (N : Node_Id) return Boolean;
            --  Returns True iff node [N] mentions the type name [E]

            --------------------------------
            -- Uses_Current_Type_Instance --
            --------------------------------

            function Uses_Current_Type_Instance (N : Node_Id) return Boolean is
               Current_Type_Instance : constant Entity_Id := Unique_Entity (E);

               function Is_Current_Instance
                 (N : Node_Id) return Traverse_Result;
               --  Returns Abandon when a Current_Type_Instance is referenced
               --  in node N and OK otherwise.

               -------------------------
               -- Is_Current_Instance --
               -------------------------

               function Is_Current_Instance
                 (N : Node_Id)
                  return Traverse_Result is
               begin
                  case Nkind (N) is
                     when N_Identifier | N_Expanded_Name =>
                        declare
                           Ref : constant Entity_Id := Entity (N);
                           --  Referenced entity

                        begin
                           if Present (Ref)
                             and then
                              (Canonical_Entity (Ref, E) =
                                 Current_Type_Instance
                                 or else
                               (Ekind (Ref) = E_Function
                                and then Scope (Ref) = Current_Type_Instance))
                           then
                              return Abandon;
                           end if;
                        end;

                     when others =>
                        null;
                  end case;

                  return OK;
               end Is_Current_Instance;

               function Find_Current_Instance is new
                 Traverse_More_Func (Is_Current_Instance);

            begin
               return Find_Current_Instance (N) = Abandon;
            end Uses_Current_Type_Instance;

            --  Local variables

            Expr : constant Node_Id := Expression (Parent (C));

         --  Start of processing for Mark_Default_Expression

         begin
            if Present (Expr) then

               --  The default expression of a component declaration shall
               --  not contain a name denoting the current instance of the
               --  enclosing type; SPARK RM 3.8(1).

               if Uses_Current_Type_Instance (Expr) then
                  Mark_Violation ("default expression with current "
                                  & "instance of enclosing type",
                                  Expr,
                                  SRM_Reference => "SPARK RM 3.8(1)");
               else
                  Mark (Expr);
               end if;
            end if;
         end Mark_Default_Expression;

         -------------------
         -- Is_Controlled --
         -------------------

         function Is_Controlled (E : Entity_Id) return Boolean is
            S_Ptr : Entity_Id := Scope (E);
            --  Scope pointer
         begin
            if Chars (S_Ptr) /= Name_Finalization then
               return False;
            end if;

            S_Ptr := Scope (S_Ptr);

            if Chars (S_Ptr) /= Name_Ada then
               return False;
            end if;

            return Scope (S_Ptr) = Standard_Standard;
         end Is_Controlled;

         --------------------------------
         -- Is_Private_Entity_Mode_Off --
         --------------------------------

         function Is_Private_Entity_Mode_Off (E : Type_Kind_Id) return Boolean
         is
            Decl : constant Node_Id :=
              (if Is_Itype (E)
               then Associated_Node_For_Itype (E)
               else Parent (E));
            Pack_Decl : constant Node_Id := Parent (Parent (Decl));

         begin
            pragma Assert (Nkind (Pack_Decl) = N_Package_Declaration);

            return
              Present (SPARK_Aux_Pragma (Defining_Entity (Pack_Decl)))
              and then Get_SPARK_Mode_From_Annotation
                (SPARK_Aux_Pragma (Defining_Entity (Pack_Decl))) = Off;
         end Is_Private_Entity_Mode_Off;

      --  Start of processing for Mark_Type_Entity

      begin
         --  We should not mark incomplete types unless their full view is not
         --  visible.

         pragma Assert
           (not Is_Incomplete_Type (E) or else No (Full_View (E)));

         --  Controlled types are not allowed in SPARK

         if Is_Controlled (E) then
            Mark_Violation ("controlled types", E);
         end if;

         --  Hardcoded entities are private types whose definition should not
         --  be translated in SPARK. We add the entity of their full views to
         --  the set of marked entities so that they will not be considered for
         --  translation later.

         if Is_Hardcoded_Entity (E) then
            pragma Assert (Present (Full_View (E))
                           and then not Entity_Marked (Full_View (E)));
            Entity_Set.Insert (Full_View (E));
         end if;

         --  For private tagged types it is necessary to mark the full view as
         --  well for proper processing in proof. We use Mark_Entity because
         --  the full view might contain SPARK violations, but the partial view
         --  shouldn't be affected by that.

         if Ekind (E) in
           E_Record_Type_With_Private | E_Record_Subtype_With_Private
           and then Is_Tagged_Type (E)
           and then not Is_Class_Wide_Type (E)
           and then not Is_Itype (E)
         then
            Mark_Entity (Full_View (E));
         end if;

         --  The base type or original type should be marked before the current
         --  type. We also protect ourselves against the case where the Etype
         --  of a full view points to the partial view.

         if not Is_Nouveau_Type (E)
           and then Underlying_Type (Etype (E)) /= E
           and then not Retysp_In_SPARK (Etype (E))
         then
            Mark_Violation (E, From => Retysp (Etype (E)));

            --  If a violation is found, stop the marking here, other violation
            --  might not be relevant.

            return;
         end if;

         --  Store correspondence from completions of private types, so
         --  that Is_Full_View can be used for dealing correctly with
         --  private types, when the public part of the package is marked
         --  as SPARK_Mode On, and the private part of the package is
         --  marked as SPARK_Mode Off. This is also used later during
         --  generation of Why.

         if Is_Private_Type (E)
           and then Present (Full_View (E))
           and then not Is_Full_View (E)
         then
            Set_Partial_View (Full_View (E), E);
         end if;

         --  Look at the parent type for subtypes and derived types

         declare
            Anc_Subt : constant Type_Kind_Id := Parent_Type (E);
         begin
            if Anc_Subt /= Etype (E)
              and then not Retysp_In_SPARK (Anc_Subt)
            then
               Mark_Violation (E, From => Anc_Subt);
            end if;
         end;

         --  Need to mark any other interfaces the type may derive from

         if Is_Record_Type (E)
           and then Has_Interfaces (E)
         then
            for Iface of Iter (Interfaces (E)) loop
               if not In_SPARK (Iface) then
                  Mark_Violation (E, From => Iface);
               end if;
            end loop;
         end if;

         --  If the type has a Default_Initial_Condition aspect, store the
         --  corresponding procedure in the Delayed_Type_Aspects map.

         if May_Need_DIC_Checking (E) then

            --  For now, reject DIC with primitive calls which would have to
            --  be rechecked on derived types.

            if Expression_Contains_Primitives_Calls_Of
              (Get_Expr_From_Check_Only_Proc (Partial_DIC_Procedure (E)), E)
            then
               Mark_Unsupported (Lim_Primitive_Call_In_DIC, E);
            else
               declare
                  Delayed_Mapping : constant Node_Id :=
                    (if Present (Current_SPARK_Pragma)
                     then Current_SPARK_Pragma
                     else E);
               begin
                  Delayed_Type_Aspects.Include
                    (Partial_DIC_Procedure (E), Delayed_Mapping);
               end;
            end if;
         end if;

         --  A derived type cannot have explicit discriminants

         if Nkind (Parent (E)) in N_Private_Extension_Declaration
                                | N_Full_Type_Declaration
           and then not Is_Class_Wide_Type (E)
           and then Unique_Entity (Etype (E)) /= Unique_Entity (E)
           and then Present (Discriminant_Specifications (Parent (E)))
           and then Entity_Comes_From_Source (E)
         then
            Mark_Violation
              ("discriminant on derived type",
               Parent (E),
               SRM_Reference => "SPARK RM 3.7(2)");
         end if;

         --  Mark discriminants if any

         if Has_Discriminants (E)
           or else Has_Unknown_Discriminants (E)
         then
            declare
               Disc : Opt_E_Discriminant_Id := First_Discriminant (E);
               Elmt : Elmt_Id :=
                 (if Present (Disc) and then Is_Constrained (E) then
                    First_Elmt (Discriminant_Constraint (E))
                  else No_Elmt);

            begin
               while Present (Disc) loop

                  --  Check that the type of the discriminant is in SPARK

                  if not In_SPARK (Etype (Disc)) then
                     Mark_Violation (Disc, From => Etype (Disc));
                  end if;

                  --  Check that the discriminant is not of an access type as
                  --  specified in SPARK RM 3.10

                  if Has_Access_Type (Etype (Disc)) then
                     Mark_Violation ("access discriminant", Disc);
                  end if;

                  --  Check that the default expression is in SPARK

                  Mark_Default_Expression (Disc);

                  --  Check that the discriminant constraint is in SPARK

                  if Present (Elmt) then
                     Mark (Node (Elmt));
                     Next_Elmt (Elmt);
                  end if;

                  Next_Discriminant (Disc);
               end loop;
            end;
         end if;

         --  Type declarations may refer to private types whose full view has
         --  not been declared yet. However, it is this full view which may
         --  define the type in Why3, if it happens to be in SPARK. Hence the
         --  need to define it now, so that it is available for the current
         --  type definition. So we start here with marking all needed types
         --  if not already marked.

         --  Fill in the map between classwide types and their corresponding
         --  specific type, in the case of a user-defined classwide type.

         if Is_Class_Wide_Type (E) then
            if Ekind (E) = E_Class_Wide_Subtype then
               declare
                  Subty : constant Node_Id := Subtype_Indication (Parent (E));
                  Ty    : Opt_Type_Kind_Id := Empty;
               begin
                  case Nkind (Subty) is
                     when N_Attribute_Reference =>
                        pragma Assert (Attribute_Name (Subty) = Name_Class);
                        Ty := Entity (Prefix (Subty));
                     when N_Identifier | N_Expanded_Name =>
                        Ty := Entity (Subty);
                     when N_Subtype_Indication =>

                        --  Constrained class-wide types are not supported yet
                        --  as it is unclear wether we should do discriminant
                        --  checks for them or not.

                        Mark_Unsupported (Lim_Constrained_Classwide, E);
                     when others =>
                        raise Program_Error;
                  end case;

                  if Nkind (Subty) /= N_Subtype_Indication then
                     pragma Assert (Present (Ty));
                     Set_Specific_Tagged (E, Unique_Entity (Ty));
                  end if;
               end;
            end if;

         elsif Is_Incomplete_Or_Private_Type (E)
           and then not Violation_Detected
         then

            --  When a private type is defined in a package whose private part
            --  has SPARK_Mode => Off, we do not need to mark its underlying
            --  type. Indeed, either it is shared with an ancestor of E and
            --  was already handled or it will not be used.

            if Is_Nouveau_Type (E)
              and then Is_Private_Entity_Mode_Off (E)
            then
               Full_Views_Not_In_SPARK.Insert (E);
               Discard_Underlying_Type (E);

            --  The same is true for an untagged subtype or a derived type of
            --  such a type or of types whose fullview is not in SPARK.

            elsif not Is_Nouveau_Type (E)
              and then not Is_Tagged_Type (E)
              and then Full_View_Not_In_SPARK (Etype (E))
            then
               Full_Views_Not_In_SPARK.Insert (E);
               Discard_Underlying_Type (E);

            --  Incomplete types which are marked have no visible full view

            elsif Is_Incomplete_Type (E) then
               pragma Assert (No (Full_View (E)));
               Full_Views_Not_In_SPARK.Insert (E);

            else
               declare
                  Utype : constant Type_Kind_Id :=
                    (if Present (Full_View (E)) then Full_View (E)
                     else Underlying_Type (E));
                  --  Mark the fullview of the type if present before the
                  --  underlying type as this underlying type may not be in
                  --  SPARK.

               begin
                  if not In_SPARK (Utype)
                    or else Full_View_Not_In_SPARK (Utype)
                  then
                     Full_Views_Not_In_SPARK.Insert (E);
                     Discard_Underlying_Type (E);
                  end if;
               end;
            end if;
         end if;

         --  Now mark the type itself

         if Has_Own_Invariants (E) then

            --  Classwide invariants are not in SPARK

            if Has_Inheritable_Invariants (E) then
               Mark_Violation
                 ("classwide invariant", E,
                  SRM_Reference => "SPARK RM 7.3.2(2)");

            --  Partial invariants are not allowed in SPARK

            elsif Present (Partial_Invariant_Procedure (E)) then
               Mark_Violation
                 ("type invariant on private_type_declaration or"
                  & " private_type_extension", E,
                  SRM_Reference => "SPARK RM 7.3.2(2)");

            elsif Is_Effectively_Volatile_For_Reading (E) then
               Mark_Violation
                 ("type invariant on effectively volatile type",
                  E, SRM_Reference => "SPARK RM 7.3.2(4)");

            --  Only mark the invariant as part of the type's fullview

            elsif not Is_Partial_View (E)
              and then Is_Base_Type (E)
            then

               --  Invariants cannot be specified on completion of private
               --  extension in SPARK.

               declare
                  E_Partial_View : constant Opt_Type_Kind_Id :=
                    (if Present (Invariant_Procedure (E))
                     then Etype (First_Formal (Invariant_Procedure (E)))
                     else Empty);
                  --  Partial view of E. Do not use the Partial_Views from
                  --  SPARK_Util as it may not have been constructed yet.
                  Enclosing_U    : constant Unit_Kind_Id := Enclosing_Unit (E);

               begin
                  if Present (E_Partial_View)
                    and then Present (Parent (E_Partial_View))
                    and then Nkind (Parent (E_Partial_View)) =
                      N_Private_Extension_Declaration
                  then
                     Mark_Violation
                       ("type invariant on completion of "
                        & "private_type_extension", E,
                        SRM_Reference => "SPARK RM 7.3.2(2)");

                  --  We currently do not support invariants on type
                  --  declared in a nested package. This restriction results
                  --  in simplifications in invariant checks on subprogram
                  --  parameters/global variables, as well as in determining
                  --  which are the type invariants which are visible at a
                  --  given program point.

                  elsif not Is_Compilation_Unit (Enclosing_U) then
                     Mark_Unsupported (Lim_Type_Inv_Nested_Package, E);

                  elsif Is_Child_Unit (Enclosing_U)
                    and then Is_Private_Descendant (Enclosing_U)
                  then
                     Mark_Unsupported (Lim_Type_Inv_Private_Child, E);

                  --  We currently do not support invariants on protected
                  --  types. To support them, we would probably need some
                  --  new RM wording in SPARK or new syntax in Ada (see
                  --  P826-030).

                  elsif Is_Protected_Type (E) then
                     pragma Annotate
                       (Xcov, Exempt_On,
                        "Rejected by the frontend because of volatile IN " &
                          "parameter in the invariant function");
                     Mark_Unsupported (Lim_Type_Inv_Protected_Type, E);
                     pragma Annotate (Xcov, Exempt_Off);

                  --  We currently do not support invariants on tagged
                  --  types. To support them, we would need to introduce
                  --  checks for type invariants of childs on dispatching
                  --  calls to root primitives (see SPARK RM 7.3.2(8) and
                  --  test P801-002__invariant_on_tagged_types).

                  elsif Is_Tagged_Type (E) then
                     Mark_Unsupported (Lim_Type_Inv_Tagged_Type, E);
                  else

                     --  Add the type invariant to delayed aspects to be marked
                     --  later.

                     pragma Assert (Present (Invariant_Procedure (E)));

                     declare
                        Delayed_Mapping : constant Node_Id :=
                          (if Present (Current_SPARK_Pragma)
                           then Current_SPARK_Pragma
                           else E);
                     begin
                        Delayed_Type_Aspects.Include (Invariant_Procedure (E),
                                                      Delayed_Mapping);
                     end;
                  end if;
               end;
            end if;
         end if;

         --  A subtype of a type that is effectively volatile for reading
         --  cannot have a predicate (SPARK RM 3.2.4(3)). Here, we do not try
         --  to distinguish the case where the predicate is inherited from a
         --  parent whose full view is not in SPARK.

         if Has_Predicates (E)
           and then Is_Effectively_Volatile_For_Reading (E)
         then
            Mark_Violation
              ("subtype predicate on effectively volatile type for reading",
               E, SRM_Reference => "SPARK RM 3.2.4(3)");
         end if;

         --  We currently do not support invariants on components of tagged
         --  types, if the invariant is visible. It is still allowed to include
         --  types with invariants in tagged types as long as the tagged type
         --  is not visible from the scope of the invariant. To support them,
         --  we would need to introduce checks for type invariants of
         --  components of childs on dispatching calls to root primitives
         --  (see SPARK RM 7.3.2(8) and test
         --  P801-002__invariant_on_tagged_component).

         if Is_Tagged_Type (E)
           and then not Is_Partial_View (E)
           and then Is_Base_Type (E)
         then
            declare
               Comp : Opt_Record_Field_Kind_Id :=
                 First_Component_Or_Discriminant (E);

            begin
               while Present (Comp) loop
                  if Component_Is_Visible_In_SPARK (Comp)
                    and then In_SPARK (Etype (Comp))
                    and then Invariant_Check_Needed (Etype (Comp))
                  then
                     Mark_Unsupported (Lim_Type_Inv_Tagged_Comp, E);
                  end if;

                  Next_Component_Or_Discriminant (Comp);
               end loop;
            end;
         end if;

         if Is_Array_Type (E) then
            declare
               Component_Typ : constant Type_Kind_Id := Component_Type (E);
               Index         : Node_Id := First_Index (E);

            begin
               if Positive (Number_Dimensions (E)) > Max_Array_Dimensions then
                  Mark_Unsupported (Lim_Max_Array_Dimension, E);
               end if;

               --  Check that the component is not of an anonymous access type

               if Is_Anonymous_Access_Object_Type (Component_Typ) then
                  Mark_Violation
                    ("component of anonymous access type", Component_Typ);
               end if;

               --  Check that all index types are in SPARK

               while Present (Index) loop
                  if not In_SPARK (Etype (Index)) then
                     Mark_Violation (E, From => Etype (Index));
                  end if;
                  Next_Index (Index);
               end loop;

               --  Check that component type is in SPARK

               if not In_SPARK (Component_Typ) then
                  Mark_Violation (E, From => Component_Typ);
               end if;

               --  Mark default aspect if any

               if Has_Default_Aspect (E) then
                  Mark (Default_Aspect_Component_Value (E));
               end if;

               --  Mark the equality function for Component_Typ if it is used
               --  for the predefined equality of E.

               Check_User_Defined_Eq
                 (Component_Typ, E, "record component type");
            end;

         --  Most discrete and floating-point types are in SPARK

         elsif Is_Scalar_Type (E) then

            --  Modular types with modulus greater than 2 ** 128 are not
            --  supported in GNAT, so no need to support them in GNATprove for
            --  now. Supporting them would require either extending the support
            --  in Why3 and provers for bitvectors greater than 128 bits, or
            --  else having a default theory for handling these modular types
            --  too large for bitvectors.
            --  In addition, GNATprove only support single and double ieee
            --  precision floats for now. This is in order to simplify initial
            --  work on smtlib floats. Extending support to Ada's
            --  long_long_float should not pose any fundamental problem.

            if Is_Modular_Integer_Type (E)
              and then Present (Modulus (E))
              and then Modulus (E) > UI_Expon (Uint_2, Uint_128)
            then
               pragma Annotate
                 (Xcov, Exempt_On,
                  "Modulus greater than 2**128 is rejected by the frontend");
               Mark_Unsupported (Lim_Max_Modulus, E);
               return;
               pragma Annotate (Xcov, Exempt_Off);

            elsif Is_Floating_Point_Type (E) then

               --  GNAT only supports 32-bits, 64-bits and 80-bits
               --  floating-point types, which correspond respectively to the
               --  Float, Long_Float and Long_Long_Float standard types on the
               --  platforms on which they are supported.

               if Is_Single_Precision_Floating_Point_Type (E) then
                  pragma Assert (Esize (Standard_Float) = 32);

               elsif Is_Double_Precision_Floating_Point_Type (E) then
                  pragma Assert (Esize (Standard_Long_Float) = 64);

               --  Long_Long_Float is always 80-bits extended precision in
               --  GNAT, but with padding to 96 bits on x86 (32-bits machines)
               --  and to 128 bits on x86_64 (64-bits machines). Look at the
               --  mantissa instead which should be 64 for 80-bits extended
               --  precision.

               elsif Is_Extended_Precision_Floating_Point_Type (E) then
                  pragma Assert
                    (Machine_Mantissa_Value (Standard_Long_Long_Float)
                     = Uint_64);

               else
                  raise Program_Error;
               end if;

               --  Fixed-point values can be used as bounds in a floating-point
               --  type constraint, but not in type derivation. In those cases,
               --  the values for the bounds are static and are inlined by the
               --  frontend.

               declare
                  Low  : constant Node_Id := Type_Low_Bound (E) with Ghost;
                  High : constant Node_Id := Type_High_Bound (E) with Ghost;
               begin
                  pragma Assert
                    (In_SPARK (Etype (Low))
                     and then In_SPARK (Etype (High))
                     and then not Has_Fixed_Point_Type (Etype (Low))
                     and then not Has_Fixed_Point_Type (Etype (High)));
               end;
            end if;

            --  Check that the range of the type is in SPARK

            declare
               Low  : constant Node_Id := Type_Low_Bound (E);
               High : constant Node_Id := Type_High_Bound (E);
            begin
               Mark (Low);
               Mark (High);
            end;

            --  Inherit the annotation No_Wrap_Around when set on a parent
            --  type.

            if Ekind (E) = E_Modular_Integer_Type
              and then Etype (E) /= E
              and then Has_No_Wrap_Around_Annotation (Etype (E))
            then
               Set_Has_No_Wrap_Around_Annotation (E);
            end if;

         elsif Is_Class_Wide_Type (E) then

            --  Class wide types with a non SPARK root are not in SPARK.
            --  Remark that the violation is always redundant for classwide
            --  types implicitely declared on code with SPARK_Mode => On.
            --  Still, it is necessary for preventing the usage of such
            --  class wide types declared in with'ed packages without
            --  SPARK_Mode.
            --
            --  Classwide types can be used to create a recursive datastructure
            --  resulting in a tree with no incomplete types. In this case, the
            --  specific type will be rejected (deep components cannot appear
            --  in tagged types) but it might be too late to reject E. Do it
            --  directly.

            declare
               Specific_Type : constant Type_Kind_Id :=
                 Get_Specific_Type_From_Classwide (E);
            begin
               --  Constrained class-wide types are not supported yet as it is
               --  unclear wether we should do discriminant checks for them
               --  or not.

               if Has_Discriminants (Retysp (Specific_Type))
                 and then Is_Constrained (Retysp (Specific_Type))
               then
                  Mark_Unsupported
                    (Lim_Class_Attr_Of_Constrained_Type, E);

               --  Predicates are not supported on classwide subtypes as
               --  classwide types are often identified to the associated
               --  specific type which would cause the predicate to be ignored.
               --  NB. Classwide types, as opposed to subtypes, can have
               --  predicates because their associated specific type has a
               --  predicate. We don't want to reject them.

               elsif Ekind (E) = E_Class_Wide_Subtype
                 and then Has_Predicates (E)
               then
                  Mark_Unsupported (Lim_Classwide_With_Predicate, E);
               end if;
            end;

         elsif Is_Incomplete_Or_Private_Type (E) then

            --  Incomplete types coming from limited views should never be
            --  marked as they have a bad location, so constructs using them
            --  are rejected instead.

            if Is_Incomplete_Type_From_Limited_With (E) then
               raise Program_Error;
            end if;

            --  If the type and its Retysp are different entities, aspects
            --  such has predicates, invariants, and DIC can be lost if they
            --  only apply to the type. Reject these cases.

            if Present (Full_View (E))
              and then Entity_In_SPARK (Full_View (E))
              and then Is_Incomplete_Or_Private_Type (Full_View (E))
              and then Unique_Entity (Retysp (E)) /= Unique_Entity (E)
            then

               declare
                  Rep : Node_Id := First_Rep_Item (Full_View (E));

               begin
                  --  Find a predicate representation item applying to E itself
                  --  if there is one.

                  Find_Predicate_Item (E, Rep);

                  if Present (Rep)
                    or else Has_Own_DIC (E)
                    or else Has_Own_Invariants (E)
                  then
                     Mark_Unsupported
                       (Lim_Contract_On_Derived_Private_Type, E);
                  end if;
               end;
            end if;

            --  If a type has two predicates supplied with different
            --  SPARK_Mode, we cannot support it in SPARK. Indeed, we
            --  currently use the predicate function to retrieve the predicate,
            --  and this function merges all the predicates applying to the
            --  type so that we cannot tell the difference.

            if Is_Base_Type (E)
              and then Present (Full_View (E))
              and then Has_Predicates (E)
              and then Ekind (Scope (E)) = E_Package
            then
               declare
                  Scop     : constant Entity_Id := Scope (E);
                  Prag     : constant Node_Id := SPARK_Pragma (Scop);
                  Aux_Prag : constant Node_Id := SPARK_Aux_Pragma (Scop);
                  Rep      : Node_Id := First_Rep_Item (Full_View (E));
                  Found    : Boolean := False;
                  Full     : Boolean := False;

               begin
                  --  Only look for duplicate predicates if the full view
                  --  of E and its partial view do not have the same
                  --  SPARK_Mode.

                  pragma Assert (if No (Aux_Prag) then No (Prag));

                  if Present (Prag)
                    and then Aux_Prag /= Prag
                    and then Get_SPARK_Mode_From_Annotation (Prag) /=
                    Get_SPARK_Mode_From_Annotation (Aux_Prag)
                  then

                     --  Loop over the Rep_Item list to search for predicates.
                     --  When one is found, we store whether it is located on
                     --  the partial or the full view in Full and continue the
                     --  search. If a predicate is found on the full view and
                     --  another on the private view, we exit the loop and
                     --  raise a violation.

                     loop
                        Find_Predicate_Item (E, Rep);
                        exit when No (Rep);
                        declare
                           N_Full : constant Boolean :=
                             (if Nkind (Rep) = N_Pragma
                              then List_Containing (Rep) =
                                  Private_Declarations
                                    (Package_Specification (Scop))
                              else not Aspect_On_Partial_View (Rep));
                           --  A predicate is specified on the full view if
                           --  either it is a pragma contained in the
                           --  private declarations of the package, or it is an
                           --  aspect which is not on the partial view of the
                           --  type.

                        begin
                           if Found and then Full /= N_Full then
                              Mark_Unsupported
                                (Lim_Predicate_With_Different_SPARK_Mode, E);
                              exit;
                           end if;
                           Found := True;
                           Full := N_Full;
                        end;
                        Next_Rep_Item (Rep);
                     end loop;
                  end if;
               end;
            end if;

         elsif Is_Record_Type (E) then

            if Ekind (E) = E_Record_Subtype
              and then not In_SPARK (Base_Type (E))
            then
               Mark_Violation (E, From => Base_Type (E));
            end if;

            --  A record subtype might share its components with the subtype
            --  from which it is cloned. Mark the clone first before marking
            --  the components, which expects the enclosing type to be marked.

            if Ekind (E) in E_Record_Subtype | E_Class_Wide_Subtype
              and then Present (Cloned_Subtype (E))
            then
               Mark_Entity (Cloned_Subtype (E));
            end if;

            --  Components of a record type should be in SPARK for the record
            --  type to be in SPARK.

            if not Is_Interface (E) then
               declare
                  Comp              : Opt_E_Component_Id :=
                    First_Component (E);
                  Comp_Type         : Type_Kind_Id;
                  Is_Tagged_Ext     : constant Boolean :=
                    not Is_Nouveau_Type (E)
                    and then Underlying_Type (Etype (E)) /= E
                    and then Is_Tagged_Type (E);
                  Needs_No_UU_Check : constant Boolean := Is_Tagged_Ext
                    and then not Has_Unconstrained_UU_Component (Etype (E));
                  --  True if we need to make sure that the type contains no
                  --  component with an unconstrained unchecked union type.
                  --  We reject them for tagged types whose root type does not
                  --  have components with an unconstrained unchecked union
                  --  type, as the builtin dispatching equality could silently
                  --  raise Program_Error.

               begin
                  while Present (Comp) loop
                     pragma Assert (Ekind (Comp) = E_Component);

                     if not Is_Tag (Comp)
                       --  Ignore components which are declared in a part with
                       --  SPARK_Mode => Off.
                       and then Component_Is_Visible_In_SPARK (Comp)
                     then
                        Comp_Type := Etype (Comp);

                        if not In_SPARK (Comp_Type) then
                           Mark_Violation (Comp, From => Comp_Type);
                        else

                           --  Tagged extensions cannot have owning components
                           --  in SPARK.

                           if Is_Tagged_Ext
                             and then Is_Deep (Comp_Type)
                             and then Underlying_Type
                               (Scope (Original_Record_Component (Comp)))
                             = Underlying_Type (E)
                           then
                              Error_Msg_Node_1 := Comp_Type;
                              Error_Msg_Node_2 := E;
                              Mark_Violation
                                ("owning component & of tagged extension &",
                                 Comp,
                                 Root_Cause_Msg =>
                                   "owning component of tagged extension");
                           end if;

                           --  Tagged types with components with relaxed init
                           --  are not supported yet.

                           if Is_Tagged_Type (E)
                             and then Contains_Relaxed_Init_Parts (Comp_Type)
                           then
                              Error_Msg_Node_1 := Comp_Type;
                              Error_Msg_Node_2 := E;
                              Mark_Violation
                                ("component & of tagged type & with relaxed"
                                 & " initialization", Comp,
                                 Root_Cause_Msg =>
                                   "component of tagged type with relaxed"
                                   & " Initialization");
                           end if;

                           --  Check that the component is not of an anonymous
                           --  access type.

                           if Is_Anonymous_Access_Object_Type (Comp_Type) then
                              Mark_Violation
                                ("component of anonymous access type", Comp);
                           end if;

                           --  Mark the equality function for Comp_Type if it
                           --  is used for the predefined equality of E.

                           Check_User_Defined_Eq
                             (Comp_Type, Comp, "record component type");

                           --  Reject components an unconstrained unchecked
                           --  union type in a tagged extension.

                           if Needs_No_UU_Check
                             and then
                               ((Is_Unchecked_Union (Base_Retysp (Comp_Type))
                                 and then
                                   not Is_Constrained (Retysp (Comp_Type)))
                                or else Has_Unconstrained_UU_Component
                                  (Comp_Type))
                           then
                              Mark_Unsupported (Lim_UU_Tagged_Comp, Comp);
                           end if;

                           --  Mark default value of component or discriminant
                           Mark_Default_Expression (Comp);
                        end if;
                     end if;

                     Next_Component (Comp);
                  end loop;
               end;
            end if;

            --  A local derived type cannot have ancestors not defined in
            --  the same local scope. We only check direct ancestors, as the
            --  definition of these ancestors will already have checked this
            --  rule for their own ancestors.

            if Nkind (Parent (E)) = N_Full_Type_Declaration
              and then Nkind (Type_Definition (Parent (E))) =
                       N_Derived_Type_Definition
            then
               declare
                  Scop : constant Entity_Id := Enclosing_Dynamic_Scope (E);
               begin
                  if Scop /= Standard_Standard then
                     if Enclosing_Dynamic_Scope (Etype (E)) /= Scop then
                        Mark_Violation
                          ("local derived type from non-local parent",
                           E,
                           SRM_Reference => "SPARK RM 3.9.1(1)");
                     end if;

                     for Iface of Iter (Interfaces (E)) loop
                        if Enclosing_Dynamic_Scope (Iface) /= Scop then
                           Mark_Violation
                             ("local derived type from non-local interface",
                              E,
                              SRM_Reference => "SPARK RM 3.9.1(1)");
                        end if;
                     end loop;
                  end if;
               end;
            end if;

            --  A record type may have a type with full_view not in SPARK as an
            --  etype. In this case, the whole type has fullview not in SPARK.

            if Full_View_Not_In_SPARK (Etype (E)) then
               Full_Views_Not_In_SPARK.Insert (E);
            end if;

         elsif Is_Access_Type (E) then
            declare
               Des_Ty : constant Type_Kind_Id := Directly_Designated_Type (E);

            begin
               --  For access-to-subprogram types, mark the designated profile

               if Ekind (Des_Ty) = E_Subprogram_Type then
                  declare
                     Profile : constant E_Subprogram_Type_Id := Des_Ty;
                     Wrapper : constant Opt_Subprogram_Kind_Id :=
                       Access_Subprogram_Wrapper (Profile);

                  begin
                     --  We do not support access to protected subprograms yet

                     if Ekind (Base_Type (E)) in
                           E_Access_Protected_Subprogram_Type
                         | E_Anonymous_Access_Protected_Subprogram_Type
                     then
                        Mark_Unsupported (Lim_Access_Sub_Protected, E);

                     --  Borrowing traversal functions need a pledge, we do not
                     --  support storing them into an access for now.

                     elsif Is_Function_Type (Profile)
                       and then Is_Anonymous_Access_Object_Type
                         (Etype (Profile))
                       and then not Is_Access_Constant (Etype (Profile))
                     then
                        Mark_Unsupported (Lim_Access_Sub_Traversal, E);

                     --  If the profile has a contract, it is located on a
                     --  wrapper subprogram. We need to mark it to mark the
                     --  contracts.
                     --  ??? Messages on formal parameters of the wrapper seem
                     --  to be incorrectly located on the access-to-subprogram
                     --  type instead of on the corresponding formal of the
                     --  profile.

                     elsif Present (Wrapper) and then not In_SPARK (Wrapper)
                     then
                        Mark_Violation (E, From => Wrapper);

                     --  Mark the profile type. If a wrapper subprogram exists,
                     --  this should not lead to new violation, but we still
                     --  need to mark the formals of the profile which are
                     --  different entities than those of the wrapper.

                     else
                        Mark_Subprogram_Entity (Profile);
                     end if;
                  end;

               --  Storage_Pool is not in SPARK

               elsif Is_Access_Type (Underlying_Type (Root_Type (E)))
                 and then Present (Associated_Storage_Pool
                                   (Underlying_Type (Root_Type (E))))
               then
                  Mark_Violation ("access type with Storage_Pool", E);

               --  Storage_Size is not in SPARK

               elsif Is_Access_Type (Underlying_Type (Root_Type (E)))
                 and then Has_Storage_Size_Clause
                   (Underlying_Type (Root_Type (E)))
               then
                  Mark_Violation ("access type with Storage_Size", E);

               --  Store the type in the Incomplete_Type map to be marked later

               elsif Acts_As_Incomplete_Type (Des_Ty) then
                  --  Do not pull types declared in private parts with no
                  --  SPARK_mode to avoid crashes if they are out of SPARK
                  --  later.

                  if Is_Declared_In_Private (Des_Ty)
                    and then No (SPARK_Pragma_Of_Entity (Des_Ty))
                  then
                     Mark_Violation (E, From => Des_Ty);
                  else
                     Access_To_Incomplete_Types.Append (E);
                  end if;

               --  If the designated type is a limited view coming from a
               --  limited with, reject the access type directly to have a
               --  better location.

               elsif (Is_Incomplete_Type (Des_Ty)
                      or else Is_Class_Wide_Type (Des_Ty))
                 and then From_Limited_With (Des_Ty)
               then
                  Reject_Incomplete_Type_From_Limited_With (Des_Ty, E);

               --  Use the base type as some subtypes of access to incomplete
               --  types introduced by the frontend designate record subtypes
               --  instead (see CA11019).

               elsif Ekind (E) in E_Access_Subtype
                 and then Acts_As_Incomplete_Type
                   (Directly_Designated_Type (Base_Retysp (E)))
               then
                  Access_To_Incomplete_Types.Append (E);

               elsif not Retysp_In_SPARK (Des_Ty) then
                  Mark_Violation (E, From => Des_Ty);
               end if;
            end;

         elsif Is_Concurrent_Type (E) then

            --  To reference or declare a concurrent type we must be in a
            --  proper tasking configuration.

            if not Is_SPARK_Tasking_Configuration then
               Mark_Violation_In_Tasking (E);

            --  To know whether the fullview of a protected type with no
            --  SPARK_Mode is in SPARK, we need to mark its components.

            elsif Nkind (Parent (E)) in N_Protected_Type_Declaration
                                      | N_Task_Type_Declaration
            then
               declare
                  Save_SPARK_Pragma : constant Node_Id := Current_SPARK_Pragma;
                  Fullview_In_SPARK : Boolean;

                  Type_Decl : constant Node_Id := Parent (E);
                  Type_Def  : constant Node_Id :=
                    (if Nkind (Type_Decl) = N_Protected_Type_Declaration
                     then Protected_Definition (Type_Decl)
                     else Task_Definition (Type_Decl));

               begin
                  Mark_List (Interface_List (Type_Decl));

                  --  Traverse the visible and private declarations of the
                  --  type to mark pragmas and representation clauses.

                  if Present (Type_Def) then
                     Mark_Aspect_Clauses_And_Pragmas_In_List
                       (Visible_Declarations (Type_Def));

                     declare
                        Save_SPARK_Pragma : constant Node_Id :=
                          Current_SPARK_Pragma;

                     begin
                        Current_SPARK_Pragma := SPARK_Aux_Pragma (E);
                        if SPARK_Pragma_Is (Opt.On) then
                           Mark_Aspect_Clauses_And_Pragmas_In_List
                             (Private_Declarations (Type_Def));
                        end if;

                        Current_SPARK_Pragma := Save_SPARK_Pragma;
                     end;
                  end if;

                  --  Components of protected objects may be subjected to a
                  --  different SPARK_Mode.

                  Current_SPARK_Pragma := SPARK_Aux_Pragma (E);

                  --  Ignore components which are declared in a part with
                  --  SPARK_Mode => Off.

                  if Ekind (E) = E_Protected_Type
                    and then not SPARK_Pragma_Is (Opt.Off)
                  then
                     declare
                        Save_Violation_Detected : constant Boolean :=
                          Violation_Detected;
                        Comp : Opt_E_Component_Id := First_Component (E);

                     begin
                        while Present (Comp) loop

                           --  Mark type and default value of component

                           if In_SPARK (Etype (Comp)) then

                              --  Check that the component is not of an
                              --  anonymous access type.

                              if Is_Anonymous_Access_Object_Type
                                (Retysp (Etype (Comp)))
                              then
                                 Mark_Violation
                                   ("component of anonymous access type",
                                    Comp);
                              end if;

                              Mark_Default_Expression (Comp);

                              --  Protected types need full default
                              --  initialization, so we check their components.

                              if No (Expression (Parent (Comp)))
                                and then
                                  Default_Initialization (Etype (Comp))
                                  not in Full_Default_Initialization
                                       | No_Possible_Initialization
                              then
                                 Mark_Violation
                                   ("protected component "
                                    & "with no default initialization",
                                    Comp,
                                    SRM_Reference => "SPARK RM 9.4");
                              end if;

                           else
                              Mark_Violation (Comp, From => Etype (Comp));
                           end if;

                           --  Initialization by proof of protected components
                           --  is not supported yet.

                           if Contains_Relaxed_Init_Parts (Etype (Comp)) then
                              Mark_Unsupported
                                (Lim_Relaxed_Init_Protected_Component, Comp);
                           end if;

                           Next_Component (Comp);
                        end loop;

                        --  Mark Part_Of variables of single protected objects

                        if Is_Single_Concurrent_Type (E) then
                           for Part of
                             Iter (Part_Of_Constituents (Anonymous_Object (E)))
                           loop
                              Mark_Entity (Part);

                              --  Check that the part_of constituent is not of
                              --  an anonymous access type.

                              if Is_Object (Part)
                                and then Retysp_In_SPARK (Etype (Part))
                                and then Is_Anonymous_Access_Object_Type
                                  (Retysp (Etype (Part)))
                              then
                                 Mark_Violation
                                   ("anonymous access variable marked Part_Of"
                                      & " a protected object", Part);
                              end if;

                              --  Initialization by proof of Part_Of variables
                              --  is not supported yet.

                              if Ekind (Part) = E_Variable
                                and then Retysp_In_SPARK (Etype (Part))
                                and then (Obj_Has_Relaxed_Init (Part)
                                          or else Contains_Relaxed_Init_Parts
                                            (Etype (Part)))
                              then
                                 Mark_Unsupported
                                   (Lim_Relaxed_Init_Part_Of_Variable, Part);
                              end if;
                           end loop;
                        end if;

                        --  If the private part is marked On, then the full
                        --  view of the type is forced to be SPARK. Violations
                        --  found during marking of the private part are not
                        --  reverted.

                        if SPARK_Pragma_Is (Opt.On) then
                           Fullview_In_SPARK := True;

                           --  If a violation has been found while marking the
                           --  private components of the protected type, then
                           --  its full view is not in SPARK. The type itself
                           --  can still be in SPARK if no SPARK_Mode has been
                           --  specified.

                        else
                           pragma Assert (SPARK_Pragma_Is (Opt.None));

                           Fullview_In_SPARK := not Violation_Detected;
                           Violation_Detected := Save_Violation_Detected;
                        end if;
                     end;

                  --  The full view of a task is in SPARK

                  else
                     Fullview_In_SPARK := Is_Task_Type (E);
                  end if;

                  Current_SPARK_Pragma := Save_SPARK_Pragma;

                  --  If the protected type is in SPARK but not its full view,
                  --  store it in Full_Views_Not_In_SPARK.

                  if not Violation_Detected and then not Fullview_In_SPARK then
                     Full_Views_Not_In_SPARK.Insert (E);
                  end if;
               end;

            --  We have a concurrent subtype or derived type. Propagate its
            --  full view status from its base type.

            else
               pragma Assert
                 (Ekind (E) in E_Protected_Subtype | E_Task_Subtype
                    or else (Nkind (Parent (E)) = N_Full_Type_Declaration
                               and then Nkind (Type_Definition (Parent (E))) =
                               N_Derived_Type_Definition));

               if Full_View_Not_In_SPARK (Etype (E)) then
                  Full_Views_Not_In_SPARK.Insert (E);
               end if;
            end if;

            --  Record where to insert concurrent type on Entity_List. The
            --  order, which reflects dependencies between Why declarations,
            --  is: concurrent components, type, operations.

            if Ekind (E) in E_Protected_Type | E_Task_Type then
               Current_Concurrent_Insert_Pos := Entity_List.Last;
            end if;

         else
            raise Program_Error;
         end if;

         --  Check the user defined equality of record types if any, as they
         --  can be used silently as part of the classwide equality.

         if not Violation_Detected
           and then E = Base_Retysp (E)
           and then Is_Tagged_Type (E)
         then
            Check_User_Defined_Eq (E, E, "tagged type");
         end if;

         --  If no violations were found and the type is annotated with
         --  relaxed initialization, populate the Relaxed_Init map.

         if not Violation_Detected then
            if Is_First_Subtype (First_Subtype (E))
              and then Has_Relaxed_Initialization (First_Subtype (E))
            then
               Mark_Type_With_Relaxed_Init
                 (N   => E,
                  Ty  => E,
                  Own => True);

            --  For consistency between flow analysis and proof, we consider
            --  types entirely made of components with relaxed initialization
            --  to be annotated with relaxed initialization.

            elsif Is_Composite_Type (E) and then Contains_Only_Relaxed_Init (E)
            then

               --  It can happen that a subtype with a discriminant constraint
               --  is entirely made of components with relaxed initialization
               --  even though its base type is not. Reject this case.
               --  We could also detect the case where a type with
               --  discriminants can have such subtypes by going over the
               --  variant parts and treat them as if they were annotated with
               --  relaxed initialization, but it seems too heavy.

               if not Contains_Only_Relaxed_Init (Base_Retysp (E)) then
                  Mark_Unsupported
                    (Lim_Relaxed_Init_Variant_Part, E, Base_Type (E),
                     Cont_Msg =>
                       "consider annotating & with Relaxed_Initialization");

               --  Emit an info message with --info when a type is considered
               --  to be annotated with Relaxed_Initialization and it has a
               --  predicate. If it has no predicates, whether it is considered
               --  to be annotated with Relaxed_Initialization does not matter.

               else
                  if Emit_Warning_Info_Messages
                    and then Debug.Debug_Flag_Underscore_F
                    and then Has_Predicates (E)
                    and then Comes_From_Source (E)
                  then
                     Error_Msg_NE
                       ("info: ?" & "& is handled as if it was annotated with "
                        & "Relaxed_Initialization as all its components are "
                        & "annotated that way", E, E);
                     Error_Msg_NE
                       ("\consider annotating & with Relaxed_Initialization",
                        E, Base_Type (E));
                  end if;

                  Mark_Type_With_Relaxed_Init
                    (N   => E,
                     Ty  => E,
                     Own => True);
               end if;
            end if;
         end if;
      end Mark_Type_Entity;

      --  In Mark_Entity, we likely leave the previous scope of marking. We
      --  save the current state of various variables to be able to restore
      --  them later.

      Save_Violation_Detected : constant Boolean := Violation_Detected;
      Save_Last_Violation_Root_Cause_Node : constant Node_Id :=
        Last_Violation_Root_Cause_Node;
      Save_SPARK_Pragma : constant Node_Id := Current_SPARK_Pragma;
      Save_Current_Delayed_Aspect_Type : constant Node_Id :=
        Current_Delayed_Aspect_Type;
      Save_Current_Incomplete_Type : constant Node_Id :=
        Current_Incomplete_Type;

   --  Start of processing for Mark_Entity

   begin

      --  Ignore functions generated by the frontend for aspects Type_Invariant
      --  and Default_Initial_Condition. This does not include the functions
      --  generated for Predicate aspects, as these functions are translated
      --  to check absence of RTE in the predicate in the most general context.

      if Is_Subprogram (E)
        and then Subprogram_Is_Ignored_For_Proof (E)
      then
         return;
      end if;

      --  Nothing to do if the entity E was already marked

      if Entity_Marked (E) then
         return;
      end if;

      --  Store entities defined in actions in Actions_Entity_Set

      if Inside_Actions then
         Actions_Entity_Set.Insert (E);
      end if;

      if Ekind (E) in E_Protected_Type | E_Task_Type then

         --  The System unit must be already loaded; see calls to
         --  SPARK_Implicit_Load in Analyze_Protected_Type_Declaration and
         --  Analyze_Task_Type_Declaration.

         pragma Assert (RTU_Loaded (System));

         Mark_Entity (RTE (RE_Priority));
         Mark_Entity (RTE (RE_Interrupt_Priority));
      end if;

      Current_SPARK_Pragma := SPARK_Pragma_Of_Entity (E);
      Current_Delayed_Aspect_Type := Empty;
      Current_Incomplete_Type := Empty;

      --  Fill in the map between classwide types and their corresponding
      --  specific type, in the case of the implicitly declared classwide type
      --  T'Class. Also fill in the map between primitive operations and their
      --  corresponding tagged type.

      if Ekind (E) in E_Record_Type | E_Record_Subtype
        and then Is_Tagged_Type (E)
        and then (if Ekind (E) = E_Record_Subtype then
                      not (Present (Cloned_Subtype (E))))
        and then not Is_Class_Wide_Type (E)
        and then not Is_Itype (E)
      then
         Set_Specific_Tagged (Class_Wide_Type (E), E);
      end if;

      --  Include entity E in the set of marked entities

      Entity_Set.Insert (E);

      --  If the entity is declared in the scope of SPARK_Mode => Off, then do
      --  not consider whether it could be in SPARK or not. Restore SPARK_Mode
      --  pragma before returning.

      if SPARK_Pragma_Is (Opt.Off) then

         --  Define the root cause for rejecting use of an entity declared with
         --  SPARK_Mode Off.

         if Emit_Messages then
            Add_Violation_Root_Cause
              (E, Msg => "entity declared with SPARK_Mode Off");
         end if;

         --  ??? We still want to reject unsupported abstract states that are
         --  Part_Of of a single concurrent object. This exception was added
         --  here for a different reason and it is not clear if it is still
         --  needed.

         if Ekind (E) /= E_Abstract_State then
            goto Restore;
         end if;
      end if;

      --  For recursive references, start with marking the entity in SPARK

      Entities_In_SPARK.Include (E);

      --  Start with no violation being detected

      Violation_Detected := False;

      --  Reset last root cause node for violations

      Last_Violation_Root_Cause_Node := Empty;

      --  Store correspondence from completions of deferred constants, so
      --  that Is_Full_View can be used for dealing correctly with deferred
      --  constants, when the public part of the package is marked as
      --  SPARK_Mode On, and the private part of the package is marked
      --  as SPARK_Mode Off. This is also used later during generation of Why.

      if Ekind (E) = E_Constant
        and then Present (Full_View (E))
      then
         Set_Partial_View (Full_View (E), E);
         Queue_For_Marking (Full_View (E));
      end if;

      --  Mark differently each kind of entity

      case Ekind (E) is
         when Type_Kind        => Mark_Type_Entity (E);

         when Subprogram_Kind  => Mark_Subprogram_Entity (E);

         when E_Constant       |
              E_Variable       =>
            begin
               case Nkind (Parent (E)) is
                  when N_Object_Declaration     => Mark_Object_Entity (E);
                  when N_Iterator_Specification
                     | N_Iterated_Component_Association
                     => Mark_Parameter_Entity (E);
                  when others                   => raise Program_Error;
               end case;
            end;

         when E_Discriminant   |
              E_Loop_Parameter |
              Formal_Kind      => Mark_Parameter_Entity (E);

         when Named_Kind       => Mark_Number_Entity (E);

         --  The identifier of a loop is used to generate the needed
         --  exception declarations in the translation phase.

         when E_Loop           => null;

         --  Mark_Entity is called on all abstract state variables

         when E_Abstract_State =>

            --  If an abstract state is a Part_Of constituent of a single
            --  concurrent object then raise a violation.

            if Is_Part_Of_Concurrent_Object (E) then
               Mark_Unsupported
                 (Lim_Abstract_State_Part_Of_Concurrent_Obj, E);
            end if;

         when Entry_Kind       => Mark_Subprogram_Entity (E);

         when others           =>
            Ada.Text_IO.Put_Line ("[Mark_Entity] kind ="
                                  & Entity_Kind'Image (Ekind (E)));
            raise Program_Error;
      end case;

      --  Mark possible pragma nodes after the entity declaration. We skip this
      --  step if the declaration should be disregarded for pragma Annotate.
      --  This is to avoid entering a list of declarations "in the middle" of
      --  the range of a pragma. This can happen if the predicate function of a
      --  type is marked before the type itself. The pragma will still be
      --  marked, when the type is marked.

      if not Violation_Detected then
         declare
            --  See the documentation of Declaration_Node for the exception for
            --  subprograms.
            Decl_Node : constant Node_Id :=
              (if Is_Subprogram (E) then
                    Parent (Declaration_Node (E))
               else Declaration_Node (E));
            Cur       : Node_Id;
         begin
            if Is_List_Member (Decl_Node)
              and then Decl_Starts_Pragma_Annotate_Range (Decl_Node)
            then
               Cur := Next (Decl_Node);
               while Present (Cur) loop
                  if Is_Pragma_Annotate_GNATprove (Cur) then
                     Mark_Pragma_Annotate (Cur, Decl_Node,
                                           Consider_Next => True);
                  elsif Decl_Starts_Pragma_Annotate_Range (Cur)
                    and then Nkind (Cur) not in N_Pragma | N_Null_Statement
                  then
                     exit;
                  end if;
                  Next (Cur);
               end loop;

               --  If we are in a package, we also need to scan the beginning
               --  of the declaration list, in case there is a pragma Annotate
               --  that governs our declaration.

               declare
                  Spec : constant Node_Id :=
                    Parent (List_Containing (Decl_Node));
               begin
                  if Nkind (Spec) = N_Package_Specification then
                     Mark_Pragma_Annot_In_Pkg (Defining_Entity (Spec));
                  end if;
               end;
            end if;
         end;
      end if;

      --  If a violation was detected, remove E from the set of SPARK entities

      if Violation_Detected then
         if Emit_Messages
           and then Present (Last_Violation_Root_Cause_Node)
         then
            Add_Violation_Root_Cause (E, Last_Violation_Root_Cause_Node);
         end if;
         Entities_In_SPARK.Delete (E);

      --  Otherwise, add entity to appropriate list

      else

         case Ekind (E) is
            --  Concurrent types go before their visible declarations
            --  (because declarations reference them as implicit inputs).
            when E_Protected_Type | E_Task_Type =>
               pragma Assert
                 (Current_Concurrent_Insert_Pos /= Node_Lists.No_Element);

               Node_Lists.Next (Current_Concurrent_Insert_Pos);

               --  If there were no entities defined within concurrent types
               --  then Next will advance the cursor to No_Element and
               --  Insert will be equivalent to Append. This is precisely
               --  what we need.
               Entity_List.Insert
                 (Before   => Current_Concurrent_Insert_Pos,
                  New_Item => E);

               --  Abstract states are not translated like other entities; they
               --  are either fully expanded into constituents (if their
               --  refinement is not hidden behind a SPARK_Mode => Off) or
               --  translated just to represent their hidden constituents.
               --
               --  Named numbers also do not require any translation.

            when E_Abstract_State | Named_Kind =>
               null;

            when others =>

               --  Do not translate objects from declare expressions. They
               --  are handled as local objects.

               if not Comes_From_Declare_Expr (E) then
                  Entity_List.Append (E);
               end if;
         end case;

         --  Mark predicate function, if any Predicate functions should be
         --  marked after the subtype, that's why we need to do this here,
         --  after inserting the subtype into the entity list.

         if Is_Type (E) and then Has_Predicates (E) then
            declare
               PF : constant Opt_E_Function_Id := Predicate_Function (E);
            begin
               if Present (PF) then
                  Queue_For_Marking (PF);
               end if;
            end;
         end if;

         --  Currently, proof looks at overriding operations for a given
         --  subprogram operation on tagged types. To make this work, they
         --  should be marked. Easiest is to mark all primitive operations of
         --  a tagged type.

         if Is_Tagged_Type (E) then
            for Prim of Iter (Direct_Primitive_Operations (E)) loop
               Queue_For_Marking (Ultimate_Alias (Prim));
            end loop;
         end if;

         --  If E is a lemma procedure annotated with Automatic_Instantiation,
         --  also mark its associated function.

         if Has_Automatic_Instantiation_Annotation (E) then
            Queue_For_Marking
              (Retrieve_Automatic_Instantiation_Annotation (E));

         --  Go over the ghost procedure declaration directly following E to
         --  mark them in case they are lemmas with automatic instantiation.
         --  We assume that lemma procedures associated to E are declared just
         --  after E, possibly interspaced with compiler generated stuff and
         --  pragmas and that the pragma Automatic_Instantiation is always
         --  located directly after the lemma procedure declaration.

         elsif Ekind (E) = E_Function
           and then not Is_Volatile_Function (E)
         then
            declare
               Decl_Node : constant Node_Id := Parent (Declaration_Node (E));
               Cur       : Node_Id;
               Proc      : Entity_Id := Empty;

            begin
               if Is_List_Member (Decl_Node)
                 and then Decl_Starts_Pragma_Annotate_Range (Decl_Node)
               then
                  Cur := Next (Decl_Node);
                  while Present (Cur) loop

                     --  We have found a pragma Automatic_Instantiation that
                     --  applies to Proc, add Proc to the queue for marking and
                     --  continue the search.

                     if Present (Proc)
                       and then Is_Pragma_Annotate_GNATprove (Cur)
                       and then Is_Pragma_Annotate_Automatic_Instantiation
                         (Cur, Proc)
                     then
                        Queue_For_Marking (Proc);
                        Proc := Empty;

                     --  Ignore other pragmas

                     elsif Nkind (Cur) = N_Pragma then
                        null;

                     --  We have found a declaration. If Cur is not a lemma
                     --  procedure annotated with Automatic_Instantiation we
                     --  can stop the search.

                     elsif Decl_Starts_Pragma_Annotate_Range (Cur) then

                        --  Cur is a declaration of a ghost procedure. Store
                        --  it in Proc and continue the search to see if there
                        --  is an associated Automatic_Instantiation
                        --  Annotation. If there is already something in Proc,
                        --  stop the search as no pragma
                        --  Automatic_Instantiation has been found directly
                        --  after the declaration of Proc.

                        if Nkind (Cur) = N_Subprogram_Declaration
                          and then Ekind (Unique_Defining_Entity (Cur))
                            = E_Procedure
                          and then Is_Ghost_Entity
                            (Unique_Defining_Entity (Cur))
                          and then No (Proc)
                        then
                           Proc := Unique_Defining_Entity (Cur);

                        --  We have found a declaration which is not a lemma
                        --  procedure, we can stop the search.

                        else
                           exit;
                        end if;
                     end if;
                     Next (Cur);
                  end loop;
               end if;
            end;
         end if;
      end if;

      --  Restore prestate
   <<Restore>>
      Violation_Detected := Save_Violation_Detected;
      Last_Violation_Root_Cause_Node := Save_Last_Violation_Root_Cause_Node;
      Current_SPARK_Pragma := Save_SPARK_Pragma;
      Current_Delayed_Aspect_Type := Save_Current_Delayed_Aspect_Type;
      Current_Incomplete_Type := Save_Current_Incomplete_Type;
   end Mark_Entity;

   ------------------------------------
   -- Mark_Extended_Return_Statement --
   ------------------------------------

   procedure Mark_Extended_Return_Statement
     (N : N_Extended_Return_Statement_Id)
   is
      Subp    : constant E_Function_Id :=
        Return_Applies_To (Return_Statement_Entity (N));
      Ret_Obj : constant Constant_Or_Variable_Kind_Id := Get_Return_Object (N);

   begin
      --  SPARK RM 3.10(6): return statement of traversal function

      if Is_Traversal_Function (Subp) then
         Mark_Violation
           ("extended return applying to a traversal function",
            N,
            SRM_Reference => "SPARK RM 3.10(6)");
      end if;

      Mark_Stmt_Or_Decl_List (Return_Object_Declarations (N));

      if Present (Handled_Statement_Sequence (N)) then
         Mark (Handled_Statement_Sequence (N));
      end if;

      --  If Subp has an anonymous access type, it can happen that the return
      --  object and Sup have incompatible designated types. Reject this case.

      Check_Compatible_Access_Types (Etype (Subp), Ret_Obj);
   end Mark_Extended_Return_Statement;

   -----------------------------
   -- Mark_Handled_Statements --
   -----------------------------

   procedure Mark_Handled_Statements
     (N : N_Handled_Sequence_Of_Statements_Id)
   is
      Handlers : constant List_Id := Exception_Handlers (N);
   begin
      if Present (Handlers) then
         Mark_Violation ("handler", First (Handlers));
      end if;

      Mark_Stmt_Or_Decl_List (Statements (N));
   end Mark_Handled_Statements;

   --------------------------------------
   -- Mark_Identifier_Or_Expanded_Name --
   --------------------------------------

   procedure Mark_Identifier_Or_Expanded_Name (N : Node_Id) is
      E : constant Entity_Id := Entity (N);
   begin
      case Ekind (E) is
         when Object_Kind =>
            if Ekind (E) in E_Variable | E_Constant | Formal_Kind then
               if not In_SPARK (E) then
                  Mark_Violation (N, From => E);

               elsif Is_Effectively_Volatile_For_Reading (E)
                 and then
                   (not Is_OK_Volatile_Context (Context       => Parent (N),
                                                Obj_Ref       => N,
                                                Check_Actuals => True)

                    or else In_Loop_Entry_Or_Old_Attribute (N))
               then
                  Mark_Violation
                    ("volatile object in interfering context", N,
                     SRM_Reference => "SPARK RM 7.1.3(10)");
               end if;

            --  Record components and discriminants are in SPARK if they are
            --  visible in the representative type of their scope. Do not
            --  report a violation if the type itself is not SPARK, as the
            --  violation will already have been reported.

            elsif Ekind (E) in E_Discriminant | E_Component then
               declare
                  Ty : constant Type_Kind_Id := Scope (E);
               begin
                  if not Retysp_In_SPARK (Ty)
                    or else not Component_Is_Visible_In_SPARK (E)
                  then
                     Mark_Violation (N, From => Ty);
                  end if;
               end;
            end if;

         --  Subprogram names appear for example in Sub'Result

         when Entry_Kind
            | E_Function
            | E_Procedure
            | Named_Kind
            | Type_Kind
         =>
            if not In_SPARK (E) then
               Mark_Violation (N, From => E);
            end if;

         when E_Enumeration_Literal =>
            null;

         --  Loop identifiers appear in the "X'Loop_Entry [(loop_name)]"
         --  expressions.

         when E_Loop =>
            null;

         --  Abstract state entities are passed directly to Mark_Entity

         when E_Abstract_State =>
            raise Program_Error;

         --  Entry index is only visible from an entry family spec and body,
         --  and families are not supported in SPARK (yet), so we should never
         --  need to mark any entry index.

         when E_Entry_Index_Parameter =>
            raise Program_Error;

         --  Identifiers that we do not expect to mark (or that do not appear
         --  in the backend).

         when E_Label
            | E_Return_Statement
            | E_Package
            | E_Exception
            | E_Block
            | E_Operator
            | E_Package_Body
            | E_Protected_Body
            | E_Subprogram_Body
            | E_Task_Body
            | E_Void
            | Generic_Unit_Kind
         =>
            raise Program_Error;
      end case;
   end Mark_Identifier_Or_Expanded_Name;

   ------------------------
   -- Mark_If_Expression --
   ------------------------

   procedure Mark_If_Expression (N : N_If_Expression_Id) is
   begin
      Mark_Actions (N, Then_Actions (N));
      Mark_Actions (N, Else_Actions (N));

      declare
         Condition : constant Node_Id := First (Expressions (N));
         Then_Expr : constant Node_Id := Next (Condition);
         Else_Expr : constant Node_Id := Next (Then_Expr);
      begin
         Mark (Condition);
         Mark (Then_Expr);

         if Present (Else_Expr) then
            Mark (Else_Expr);
         end if;
      end;
   end Mark_If_Expression;

   -----------------------
   -- Mark_If_Statement --
   -----------------------

   procedure Mark_If_Statement (N : N_If_Statement_Id) is
   begin
      Mark (Condition (N));

      Mark_Stmt_Or_Decl_List (Then_Statements (N));

      declare
         Part : Node_Id := First (Elsif_Parts (N));

      begin
         while Present (Part) loop
            Mark_Actions (N, Condition_Actions (Part));
            Mark (Condition (Part));
            Mark_Stmt_Or_Decl_List (Then_Statements (Part));
            Next (Part);
         end loop;
      end;

      if Present (Else_Statements (N)) then
         Mark_Stmt_Or_Decl_List (Else_Statements (N));
      end if;
   end Mark_If_Statement;

   --------------------------
   -- Mark_Iterable_Aspect --
   --------------------------

   procedure Mark_Iterable_Aspect
     (Iterable_Aspect : N_Aspect_Specification_Id)
   is
      Iterable_Component_Assoc : constant List_Id :=
        Component_Associations (Expression (Iterable_Aspect));
      Iterable_Field           : Node_Id := First (Iterable_Component_Assoc);
   begin
      while Present (Iterable_Field) loop
         Mark_Entity (Entity (Expression (Iterable_Field)));
         Next (Iterable_Field);
      end loop;
   end Mark_Iterable_Aspect;

   ---------------------------
   -- Mark_Iteration_Scheme --
   ---------------------------

   procedure Mark_Iteration_Scheme (N : N_Iteration_Scheme_Id) is
   begin
      if Present (Condition (N)) then
         Mark_Actions (N, Condition_Actions (N));
         Mark (Condition (N));

      elsif Present (Loop_Parameter_Specification (N)) then
         pragma Assert (No (Condition_Actions (N)));
         Mark (Discrete_Subtype_Definition
                 (Loop_Parameter_Specification (N)));

         if Present (Iterator_Filter (Loop_Parameter_Specification (N))) then
            Mark (Iterator_Filter (Loop_Parameter_Specification (N)));
         end if;

         --  The loop parameter shall be added to the entities in SPARK
         declare
            Loop_Index : constant E_Loop_Parameter_Id :=
              Defining_Identifier (Loop_Parameter_Specification (N));
         begin
            Mark_Entity (Loop_Index);
         end;

      else
         pragma Assert (No (Condition_Actions (N)));
         pragma Assert (Present (Iterator_Specification (N)));

         Mark (Iterator_Specification (N));
      end if;
   end Mark_Iteration_Scheme;

   ---------------
   -- Mark_List --
   ---------------

   procedure Mark_List (L : List_Id) is
      N : Node_Id := First (L);
   begin
      while Present (N) loop
         Mark (N);
         Next (N);
      end loop;
   end Mark_List;

   -----------------------------
   -- Mark_Object_Declaration --
   -----------------------------

   procedure Mark_Object_Declaration (N : N_Object_Declaration_Id) is
      E : constant Object_Kind_Id := Defining_Entity (N);
   begin
      if In_SPARK (E) then
         pragma Assert (In_SPARK (Etype (E)));
      else
         Mark_Violation (N, From => E);
      end if;
   end Mark_Object_Declaration;

   -----------------------
   -- Mark_Package_Body --
   -----------------------

   procedure Mark_Package_Body (N : N_Package_Body_Id) is

      function Spec_Has_SPARK_Mode_Off (E : Package_Kind_Id) return Boolean
      is (declare
            Prag     : constant Node_Id := SPARK_Pragma (E);
            Aux_Prag : constant Node_Id := SPARK_Aux_Pragma (E);
          begin
            (Present (Prag)
              and then Get_SPARK_Mode_From_Annotation (Prag) = Off)
            or else
            (Present (Aux_Prag)
              and then Get_SPARK_Mode_From_Annotation (Aux_Prag) = Off));

      --  Local variables

      Body_E : constant E_Package_Body_Id := Defining_Entity (N);
      Spec_E : constant Package_Kind_Id := Unique_Entity (Body_E);

      Save_SPARK_Pragma       : constant Node_Id := Current_SPARK_Pragma;
      Save_Violation_Detected : constant Boolean := Violation_Detected;

   --  Start of processing for Mark_Package_Body

   begin
      --  Do not analyze generic bodies

      if Ekind (Spec_E) = E_Generic_Package
        or else not Entity_In_SPARK (Spec_E)
      then
         return;
      end if;

      Current_SPARK_Pragma := SPARK_Pragma (Body_E);

      --  Only analyze package body when SPARK_Mode /= Off, and the package
      --  spec does not have SPARK_Mode => Off on its public or private part.
      --  In particular, we still analyze a package body with no SPARK_Mode
      --  set, as it may contain subprograms or packages with SPARK_Mode => On.

      if not SPARK_Pragma_Is (Opt.Off)
        and then not Spec_Has_SPARK_Mode_Off (Spec_E)
      then
         Violation_Detected := False;
         Mark_Stmt_Or_Decl_List (Declarations (N));
         Current_SPARK_Pragma := SPARK_Aux_Pragma (Body_E);

         --  Only analyze package body statements when SPARK_Mode /= Off.
         --  In particular, we still analyze a package body with no
         --  SPARK_Mode set, as it may contain subprograms or packages
         --  with SPARK_Mode => On.

         if not SPARK_Pragma_Is (Opt.Off) then
            declare
               HSS : constant Node_Id := Handled_Statement_Sequence (N);
            begin
               if Present (HSS) then
                  Mark (HSS);
               end if;
            end;
         end if;

         if SPARK_Pragma_Is (Opt.On)
           and then not Violation_Detected
         then
            Bodies_In_SPARK.Insert (Spec_E);
         end if;

         Violation_Detected := Save_Violation_Detected;
      end if;

      Current_SPARK_Pragma := Save_SPARK_Pragma;

   end Mark_Package_Body;

   ------------------------------
   -- Mark_Package_Declaration --
   ------------------------------

   procedure Mark_Package_Declaration (N : N_Package_Declaration_Id) is
      Id         : constant E_Package_Id := Defining_Entity (N);
      Spec       : constant N_Package_Specification_Id := Specification (N);
      Vis_Decls  : constant List_Id := Visible_Declarations (Spec);
      Priv_Decls : constant List_Id := Private_Declarations (Spec);

      Save_SPARK_Pragma       : constant Opt_N_Pragma_Id :=
        Current_SPARK_Pragma;
      Save_Violation_Detected : constant Boolean := Violation_Detected;

   begin
      Current_SPARK_Pragma := SPARK_Pragma (Id);

      --  Record the package as an entity to translate iff it is
      --  explicitly marked with SPARK_Mode => On.

      if SPARK_Pragma_Is (Opt.On) then
         Entity_List.Append (Id);
      end if;

      --  Reset violation status to determine if there are any violations
      --  in the package declaration itself.

      Violation_Detected := False;

      --  Mark abstract state entities, since they may be referenced from
      --  the outside. Iff SPARK_Mode is On | None then they will be in
      --  SPARK; if SPARK_Mode is Off then they will be not. Same for
      --  visible declarations.

      if Has_Non_Null_Abstract_State (Id) then
         for State of Iter (Abstract_States (Id)) loop
            Mark_Entity (State);
         end loop;
      end if;

      --  Mark the initial condition if present

      declare
         Init_Cond : constant Node_Id :=
           Get_Pragma (Id, Pragma_Initial_Condition);

      begin
         if Present (Init_Cond) then
            declare
               Expr : constant Node_Id :=
                 Expression (First (Pragma_Argument_Associations (Init_Cond)));
            begin
               Mark (Expr);
            end;
         end if;
      end;

      Mark_Stmt_Or_Decl_List (Vis_Decls);

      --  Decide whether constants appearing in explicit Initializes are in
      --  SPARK, because this affects whether they are considered to have
      --  variable input. We need to do this after marking declarations of
      --  generic actual parameters of mode IN, as otherwise we would memoize
      --  them as having no variable inputs due to their not in SPARK status.
      --  This memoization is a side-effect of erasing constants without
      --  variable inputs while parsing the contract.

      if Present (Get_Pragma (Id, Pragma_Initializes)) then
         for Input_List of
           Parse_Initializes (Id, Scop => (Ent => Id, Part => Visible_Part))
         loop
            Mark_Constant_Globals (To_Node_Set (Input_List));
         end loop;
      end if;

      Current_SPARK_Pragma := SPARK_Aux_Pragma (Id);

      --  Private declarations cannot be referenced from the outside; if
      --  SPARK_Mode is Off then we should just skip them, but the Retysp
      --  magic relies on their marking status (which most likely hides
      --  some underlying problem).

      declare
         Violation_Detected_In_Vis_Decls : constant Boolean :=
           Violation_Detected;

      begin
         Mark_Stmt_Or_Decl_List (Priv_Decls);

         --  This is to workaround the fact that for now we cannot guard
         --  the marking of the private declarations as explained above.
         --  So, in case the private part is not in SPARK, we restore the
         --  status of Violation_Detected to before the marking of the
         --  private part happened. The proper fix would be to mark the
         --  private declarations only if the private part is in SPARK.

         if SPARK_Pragma_Is (Opt.Off) then
            Violation_Detected := Violation_Detected_In_Vis_Decls;
         end if;
      end;

      --  Finally, if the package has SPARK_Mode On | None and there are
      --  no violations then record it as in SPARK.

      Current_SPARK_Pragma := SPARK_Pragma (Id);

      if SPARK_Pragma_Is (Opt.Off) then
         --  Define the root cause for rejecting use of an entity declared with
         --  SPARK_Mode Off.

         if Emit_Messages then
            Add_Violation_Root_Cause
              (Id, Msg => "entity declared with SPARK_Mode Off");
         end if;

      elsif not Violation_Detected then
         Entities_In_SPARK.Include (Id);
      end if;

      Violation_Detected := Save_Violation_Detected;
      Current_SPARK_Pragma := Save_SPARK_Pragma;
   end Mark_Package_Declaration;

   -----------------
   -- Mark_Pragma --
   -----------------

   --  GNATprove currently deals with a subset of the Ada and GNAT pragmas.
   --  Other recognized pragmas are ignored, and a warning is issued here (and
   --  in flow analysis, and in proof) that the pragma is ignored. Any change
   --  in the set of pragmas that GNATprove supports should be reflected:
   --    . in Mark_Pragma below;
   --    . for flow analysis, in Pragma_Relevant_To_Flow in
   --      flow-control_flow_graph.adb;
   --    . for proof, in Transform_Pragma in gnat2why-expr.adb.

   procedure Mark_Pragma (N : N_Pragma_Id) is
      Pname   : constant Name_Id   := Pragma_Name (N);
      Prag_Id : constant Pragma_Id := Get_Pragma_Id (Pname);

      Arg1 : Node_Id;
      Arg2 : Node_Id;
      --  First two pragma arguments (pragma argument association nodes, or
      --  Empty if the corresponding argument does not exist).

   begin
      if Present (Pragma_Argument_Associations (N)) then
         Arg1 := First (Pragma_Argument_Associations (N));
         pragma Assert (Present (Arg1));
         Arg2 := Next (Arg1);
      else
         Arg1 := Empty;
         Arg2 := Empty;
      end if;

      case Prag_Id is

         --  Syntax of this pragma:
         --    pragma Check ([Name    =>] Identifier,
         --                  [Check   =>] Boolean_Expression
         --                [,[Message =>] String_Expression]);

         when Pragma_Check =>
            if not Is_Ignored_Pragma_Check (N) then
               Mark (Get_Pragma_Arg (Arg2));
            end if;

         --  Syntax of this pragma:
         --    pragma Loop_Variant
         --           ( LOOP_VARIANT_ITEM {, LOOP_VARIANT_ITEM } );

         --    LOOP_VARIANT_ITEM ::= CHANGE_DIRECTION => discrete_EXPRESSION

         --    CHANGE_DIRECTION ::= Increases | Decreases

         when Pragma_Loop_Variant =>
            declare
               Variant : Node_Id := First (Pragma_Argument_Associations (N));

            begin
               --  Process all expressions
               while Present (Variant) loop
                  declare
                     Expr : constant N_Subexpr_Id := Expression (Variant);

                  begin
                     --  For structural variants, check that the expression is
                     --  a variable of an anonymous access-to-object type.

                     if Chars (Variant) = Name_Structural
                       and then
                         not (Nkind (Expr) in N_Identifier | N_Expanded_Name
                              and then Ekind (Entity (Expr)) = E_Variable
                              and then Is_Anonymous_Access_Object_Type
                                (Etype (Expr)))
                     then
                        Mark_Violation
                          ("structural loop variant which is not a variable of"
                           & " an anonymous access-to-object type", Expr);
                     else
                        Mark (Expr);
                     end if;
                  end;

                  Next (Variant);
               end loop;
            end;

         --  Pragma Overflow_Mode is taken into account when used as
         --  configuration pragma in the main unit.

         when Pragma_Overflow_Mode =>
            if Nkind (Parent (N)) = N_Compilation_Unit then
               Sem_Prag.Set_Overflow_Mode (N);

            --  Emit warning on pragma Overflow_Mode being currently ignored,
            --  even in code not marked SPARK_Mode On, as otherwise no warning
            --  would be issued on configuration pragmas at the start of units
            --  whose top level declaration is marked later SPARK_Mode On. Do
            --  not emit a warning in code marked SPARK_Mode Off though.

            elsif Emit_Warning_Info_Messages
              and then not SPARK_Pragma_Is (Opt.Off)
            then
               Error_Msg_F (Warning_Message (Warn_Pragma_Overflow_Mode), N);
            end if;

         when Pragma_Attach_Handler =>
            --  Arg1 is the handler name; check if it is in SPARK, because
            --  SPARK code should not reference non-SPARK code.
            --  Arg2 is the interrupt ID.
            Mark (Expression (Arg1));
            Mark (Expression (Arg2));

         when Pragma_Interrupt_Priority =>
            --  Priority expression is optional
            if Present (Arg1) then
               Mark (Expression (Arg1));
            end if;

         when Pragma_Priority =>
            Mark (Expression (Arg1));

         when Pragma_Max_Queue_Length =>
            Mark (Expression (Arg1));

         --  Remaining pragmas fall into two major groups:
         --
         --  Group 1 - ignored
         --
         --  Pragmas that do not need any marking, either because:
         --  . they are defined by SPARK 2014, or
         --  . they are already taken into account elsewhere (contracts)
         --  . they have no effect on verification.

         --  Group 1a - RM Table 16.1, Ada language-defined pragmas marked
         --  "Yes".

         when  --  Pragma_Assert is transformed into pragma Check handled above
              Pragma_Assertion_Policy
            | Pragma_Atomic
            | Pragma_Atomic_Components
            --  Pragma_Attach_Handler is handled specially above
            | Pragma_Convention
            | Pragma_CPU
            | Pragma_Detect_Blocking
            | Pragma_Elaborate
            | Pragma_Elaborate_All
            | Pragma_Elaborate_Body
            | Pragma_Export
            | Pragma_Import
            | Pragma_Independent
            | Pragma_Independent_Components
            | Pragma_Inline
            | Pragma_Inspection_Point
            | Pragma_Interrupt_Handler
            --  Pragma_Interrupt_Priority is handled specially above
            | Pragma_Linker_Options
            | Pragma_List
            | Pragma_Locking_Policy
            | Pragma_No_Return
            | Pragma_Normalize_Scalars
            | Pragma_Optimize
            | Pragma_Pack
            | Pragma_Page
            | Pragma_Partition_Elaboration_Policy
            | Pragma_Preelaborable_Initialization
            | Pragma_Preelaborate
            --  Pragma_Priority is handled specially above
            | Pragma_Profile
            | Pragma_Pure
            | Pragma_Queuing_Policy
            | Pragma_Relative_Deadline
            | Pragma_Restrictions
            | Pragma_Reviewable
            | Pragma_Suppress
            | Pragma_Unchecked_Union
            | Pragma_Unsuppress
            | Pragma_Volatile
            | Pragma_Volatile_Components

         --  Group 1b - RM Table 16.2, SPARK language-defined pragmas marked
         --  "Yes".

            | Pragma_Abstract_State
            --  Pragma_Assert_And_Cut and Pragma_Assume are transformed into
            --  pragma Check handled above.
            | Pragma_Async_Readers
            | Pragma_Async_Writers
            | Pragma_Constant_After_Elaboration
            | Pragma_Contract_Cases
            | Pragma_Default_Initial_Condition
            | Pragma_Depends
            | Pragma_Effective_Reads
            | Pragma_Effective_Writes
            | Pragma_Extensions_Visible
            | Pragma_Ghost
            | Pragma_Global
            | Pragma_Initial_Condition
            | Pragma_Initializes
            --  Pragma_Loop_Invariant is transformed into pragma Check
            --  handled above.
            --  Pragma_Loop_Variant is handled specially above
            | Pragma_No_Caching
            | Pragma_Part_Of
            | Pragma_Refined_Depends
            | Pragma_Refined_Global
            | Pragma_Refined_Post
            | Pragma_Refined_State
            | Pragma_SPARK_Mode
            | Pragma_Unevaluated_Use_Of_Old
            | Pragma_Volatile_Function

         --  Group 1c - RM Table 16.3, GNAT implementation-defined pragmas
         --  marked "Yes".

            | Pragma_Ada_83
            | Pragma_Ada_95
            | Pragma_Ada_05
            | Pragma_Ada_12
            | Pragma_Ada_2005
            | Pragma_Ada_2012
            | Pragma_Ada_2022
            | Pragma_Annotate
            | Pragma_Assume_No_Invalid_Values
            --  Pragma_Check is handled specially above
            | Pragma_Check_Policy
            --  Pragma_Compile_Time_Error, Pragma_Compile_Time_Warning and
            --  Pragma_Debug are removed by FE and handled thus below.
            | Pragma_Default_Scalar_Storage_Order
            | Pragma_Export_Function
            | Pragma_Export_Procedure
            | Pragma_Ignore_Pragma
            | Pragma_Inline_Always
            | Pragma_Invariant
            | Pragma_Linker_Section
            --  Pragma_Max_Queue_Length is handled specially above
            | Pragma_No_Elaboration_Code_All
            | Pragma_No_Heap_Finalization
            | Pragma_No_Inline
            | Pragma_No_Tagged_Streams
            --  Pragma_Overflow_Mode is handled specially above
            | Pragma_Post
            | Pragma_Postcondition
            | Pragma_Post_Class
            | Pragma_Pre
            | Pragma_Precondition
            | Pragma_Pre_Class
            | Pragma_Predicate
            | Pragma_Predicate_Failure
            | Pragma_Provide_Shift_Operators
            | Pragma_Pure_Function
            | Pragma_Restriction_Warnings
            | Pragma_Secondary_Stack_Size
            | Pragma_Style_Checks
            | Pragma_Subprogram_Variant
            | Pragma_Test_Case
            | Pragma_Type_Invariant
            | Pragma_Type_Invariant_Class
            | Pragma_Unmodified
            | Pragma_Unreferenced
            | Pragma_Unused
            | Pragma_Validity_Checks
            | Pragma_Volatile_Full_Access
            | Pragma_Warnings
            | Pragma_Weak_External
         =>
            null;

         --  Group 1d - These pragmas are re-written and/or removed by the
         --  front-end in GNATprove, so they should never be seen here,
         --  unless they are ignored by virtue of pragma Ignore_Pragma.

         when Pragma_Assert
            | Pragma_Assert_And_Cut
            | Pragma_Assume
            | Pragma_Compile_Time_Error
            | Pragma_Compile_Time_Warning
            | Pragma_Debug
            | Pragma_Loop_Invariant
         =>
            pragma Assert (Should_Ignore_Pragma_Sem (N));

         --  Group 2 - Remaining pragmas, enumerated here rather than a
         --  "when others" to force re-consideration when SNames.Pragma_Id
         --  is extended.
         --
         --  These all generate a warning. In future, these pragmas may move to
         --  be fully ignored or to be processed with more semantic detail as
         --  required.

         --  Group 2a - GNAT Defined and obsolete pragmas

         when Pragma_Abort_Defer
            | Pragma_Allow_Integer_Address
            | Pragma_Attribute_Definition
            | Pragma_CPP_Class
            | Pragma_CPP_Constructor
            | Pragma_CPP_Virtual
            | Pragma_CPP_Vtable
            | Pragma_C_Pass_By_Copy
            | Pragma_Check_Float_Overflow
            | Pragma_Check_Name
            | Pragma_Comment
            | Pragma_Common_Object
            | Pragma_Complete_Representation
            | Pragma_Complex_Representation
            | Pragma_Component_Alignment
            | Pragma_Controlled
            | Pragma_Convention_Identifier
            | Pragma_CUDA_Global
            | Pragma_Debug_Policy
            | Pragma_Default_Storage_Pool
            | Pragma_Disable_Atomic_Synchronization
            | Pragma_Dispatching_Domain
            | Pragma_Elaboration_Checks
            | Pragma_Eliminate
            | Pragma_Enable_Atomic_Synchronization
            | Pragma_Export_Object
            | Pragma_Export_Valued_Procedure
            | Pragma_Extend_System
            | Pragma_Extensions_Allowed
            | Pragma_External
            | Pragma_External_Name_Casing
            | Pragma_Fast_Math
            | Pragma_Favor_Top_Level
            | Pragma_Finalize_Storage_Only
            | Pragma_Ident
            | Pragma_Implementation_Defined
            | Pragma_Implemented
            | Pragma_Implicit_Packing
            | Pragma_Import_Function
            | Pragma_Import_Object
            | Pragma_Import_Procedure
            | Pragma_Import_Valued_Procedure
            | Pragma_Initialize_Scalars
            | Pragma_Inline_Generic
            | Pragma_Interface
            | Pragma_Interface_Name
            | Pragma_Interrupt_State
            | Pragma_Keep_Names
            | Pragma_License
            | Pragma_Link_With
            | Pragma_Linker_Alias
            | Pragma_Linker_Constructor
            | Pragma_Linker_Destructor
            | Pragma_Loop_Optimize
            | Pragma_Machine_Attribute
            | Pragma_Main
            | Pragma_Main_Storage
            | Pragma_Memory_Size
            | Pragma_No_Body
            | Pragma_No_Run_Time
            | Pragma_No_Strict_Aliasing
            | Pragma_Obsolescent
            | Pragma_Optimize_Alignment
            | Pragma_Ordered
            | Pragma_Overriding_Renamings
            | Pragma_Passive
            | Pragma_Persistent_BSS
            | Pragma_Prefix_Exception_Messages
            | Pragma_Priority_Specific_Dispatching
            | Pragma_Profile_Warnings
            | Pragma_Propagate_Exceptions
            | Pragma_Psect_Object
            | Pragma_Rational
            | Pragma_Ravenscar
            | Pragma_Remote_Access_Type
            | Pragma_Rename_Pragma
            | Pragma_Restricted_Run_Time
            | Pragma_Share_Generic
            | Pragma_Shared
            | Pragma_Short_Circuit_And_Or
            | Pragma_Short_Descriptors
            | Pragma_Simple_Storage_Pool_Type
            | Pragma_Source_File_Name
            | Pragma_Source_File_Name_Project
            | Pragma_Source_Reference
            | Pragma_Static_Elaboration_Desired
            | Pragma_Storage_Unit
            | Pragma_Stream_Convert
            | Pragma_Subtitle
            | Pragma_Suppress_All
            | Pragma_Suppress_Debug_Info
            | Pragma_Suppress_Exception_Locations
            | Pragma_Suppress_Initialization
            | Pragma_System_Name
            | Pragma_Task_Info
            | Pragma_Task_Name
            | Pragma_Task_Storage
            | Pragma_Thread_Local_Storage
            | Pragma_Time_Slice
            | Pragma_Title
            | Pragma_Unimplemented_Unit
            | Pragma_Universal_Aliasing
            | Pragma_Unreferenced_Objects
            | Pragma_Unreserve_All_Interrupts
            | Pragma_Use_VADS_Size
            | Pragma_Warning_As_Error
            | Pragma_Wide_Character_Encoding

         --  Group 2b - Ada RM pragmas

            | Pragma_All_Calls_Remote
            | Pragma_Asynchronous
            | Pragma_Discard_Names
            | Pragma_Lock_Free
            | Pragma_Remote_Call_Interface
            | Pragma_Remote_Types
            | Pragma_Shared_Passive
            | Pragma_Storage_Size
            | Pragma_Task_Dispatching_Policy
        =>
            if Emit_Warning_Info_Messages
              and then SPARK_Pragma_Is (Opt.On)
            then
               Error_Msg_Name_1 := Pname;
               Error_Msg_N (Warning_Message (Warn_Pragma_Ignored), N);
            end if;

         --  Unknown_Pragma is treated here. We use an OTHERS case in order to
         --  deal with all the more recent pragmas introduced in GNAT for which
         --  we have not yet defined how they are supported in SPARK.

         when others =>
            Error_Msg_Name_1 := Pname;
            Mark_Violation ("unknown pragma %", N);
      end case;
   end Mark_Pragma;

   ------------------------------
   -- Mark_Pragma_Annot_In_Pkg --
   ------------------------------

   procedure Mark_Pragma_Annot_In_Pkg (E : E_Package_Id) is
      Inserted : Boolean;
      Position : Hashed_Node_Sets.Cursor;
   begin
      Annot_Pkg_Seen.Insert (E, Position, Inserted);

      if Inserted then
         declare
            Spec : constant Node_Id := Package_Specification (E);
            Decl : constant Node_Id := Package_Spec (E);

            Cur  : Node_Id := First (Visible_Declarations (Spec));

         begin
            --  First handle GNATprove annotations at the beginning of the
            --  package spec.

            while Present (Cur) loop
               if Is_Pragma_Annotate_GNATprove (Cur) then
                  Mark_Pragma_Annotate (Cur,
                                        Spec,
                                        Consider_Next => False);
               elsif Decl_Starts_Pragma_Annotate_Range (Cur)
                 and then Nkind (Cur) not in N_Pragma | N_Null_Statement
               then
                  exit;
               end if;
               Next (Cur);
            end loop;

            --  Then handle GNATprove annotations that follow the package spec,
            --  typically corresponding to aspects in the source code.

            if Nkind (Atree.Parent (Decl)) = N_Compilation_Unit then
               Cur :=
                 First (Pragmas_After (Aux_Decls_Node (Atree.Parent (Decl))));
            else
               Cur := Next (Decl);
            end if;

            while Present (Cur) loop
               if Is_Pragma_Annotate_GNATprove (Cur) then
                  Mark_Pragma_Annotate (Cur,
                                        Spec,
                                        Consider_Next => False);
               elsif Decl_Starts_Pragma_Annotate_Range (Cur)
                 and then Nkind (Cur) /= N_Pragma
               then
                  exit;
               end if;
               Next (Cur);
            end loop;
         end;
      end if;
   end Mark_Pragma_Annot_In_Pkg;

   -------------------------
   -- Mark_Protected_Body --
   -------------------------

   procedure Mark_Protected_Body (N : N_Protected_Body_Id) is
      Spec : constant E_Protected_Type_Id := Corresponding_Spec (N);
   begin
      if Entity_In_SPARK (Spec) then
         declare
            Def_E             : constant E_Protected_Body_Id :=
              Defining_Entity (N);
            Save_SPARK_Pragma : constant Opt_N_Pragma_Id :=
              Current_SPARK_Pragma;
         begin
            Current_SPARK_Pragma := SPARK_Pragma (Def_E);

            if not SPARK_Pragma_Is (Opt.Off) then
               declare
                  Save_Violation_Detected : constant Boolean :=
                    Violation_Detected;
               begin
                  Violation_Detected := False;

                  Mark_Stmt_Or_Decl_List (Declarations (N));

                  if not Violation_Detected then
                     Bodies_In_SPARK.Insert (Spec);
                  end if;

                  Violation_Detected := Save_Violation_Detected;
               end;
            end if;

            Current_SPARK_Pragma := Save_SPARK_Pragma;
         end;
      end if;
   end Mark_Protected_Body;

   ----------------------------------
   -- Mark_Simple_Return_Statement --
   ----------------------------------

   procedure Mark_Simple_Return_Statement (N : N_Simple_Return_Statement_Id) is
   begin
      if Present (Expression (N)) then
         declare
            Subp       : constant E_Function_Id :=
              Return_Applies_To (Return_Statement_Entity (N));
            Expr       : constant N_Subexpr_Id := Expression (N);
            Return_Typ : constant Type_Kind_Id := Etype (Expr);

         begin
            Mark (Expr);

            if Is_Anonymous_Access_Object_Type (Return_Typ) then

               --  If we are returning from a traversal function, we have a
               --  borrow/observe.

               if Is_Traversal_Function (Subp)
                 and then Nkind (Expr) /= N_Null
               then
                  Check_Source_Of_Borrow_Or_Observe
                    (Expr, Is_Access_Constant (Return_Typ));
               end if;

            --  If we are returning a deep type, this is a move. Check that we
            --  have a path.

            elsif Retysp_In_SPARK (Return_Typ)
              and then Is_Deep (Return_Typ)
            then
               Check_Source_Of_Move (Expr);
            end if;

            --  If Subp has an anonymous access type, it can happen that Expr
            --  and Subp have incompatible designated type. Reject this case.

            Check_Compatible_Access_Types (Etype (Subp), Expr);
         end;
      end if;
   end Mark_Simple_Return_Statement;

   ---------------------------
   -- Mark_Standard_Package --
   ---------------------------

   procedure Mark_Standard_Package is

      procedure Insert_All_And_SPARK (E : Type_Kind_Id);

      --------------------------
      -- Insert_All_And_SPARK --
      --------------------------

      procedure Insert_All_And_SPARK (E : Type_Kind_Id) is
      begin
         Entity_Set.Insert (E);
         Entities_In_SPARK.Insert (E);
      end Insert_All_And_SPARK;

      --  Standard types which are in SPARK are associated to True

      Standard_Type_Is_In_SPARK : constant array (S_Types) of Boolean :=
        (S_Boolean                => True,

         S_Short_Short_Integer    => True,
         S_Short_Integer          => True,
         S_Integer                => True,
         S_Long_Integer           => True,
         S_Long_Long_Integer      => True,
         S_Long_Long_Long_Integer => True,

         S_Natural                => True,
         S_Positive               => True,

         S_Short_Float            =>
           Is_Single_Precision_Floating_Point_Type
             (Standard_Entity (S_Short_Float)),
         S_Float                  => True,
         S_Long_Float             => True,
         S_Long_Long_Float        =>
           Is_Double_Precision_Floating_Point_Type
             (Standard_Entity (S_Long_Long_Float))
             or else
           Is_Extended_Precision_Floating_Point_Type
             (Standard_Entity (S_Long_Long_Float)),

         S_Character              => True,
         S_Wide_Character         => True,
         S_Wide_Wide_Character    => True,

         S_String                 => True,
         S_Wide_String            => True,
         S_Wide_Wide_String       => True,

         S_Duration               => True);

   --  Start of processing for Mark_Standard_Package

   begin
      for S in S_Types loop
         Entity_Set.Insert (Standard_Entity (S));
         Entity_Set.Include (Etype (Standard_Entity (S)));
         if Standard_Type_Is_In_SPARK (S) then
            Entities_In_SPARK.Insert (Standard_Entity (S));
            Entities_In_SPARK.Include (Etype (Standard_Entity (S)));
         end if;
      end loop;

      Insert_All_And_SPARK (Universal_Integer);
      Insert_All_And_SPARK (Universal_Real);
      Insert_All_And_SPARK (Universal_Fixed);

      Insert_All_And_SPARK (Standard_Integer_8);
      Insert_All_And_SPARK (Standard_Integer_16);
      Insert_All_And_SPARK (Standard_Integer_32);
      Insert_All_And_SPARK (Standard_Integer_64);

   end Mark_Standard_Package;

   ----------------------------
   -- Mark_Stmt_Or_Decl_List --
   ----------------------------

   procedure Mark_Stmt_Or_Decl_List (L : List_Id) is
      Preceding : Node_Id;
      Cur       : Node_Id := First (L);
      Is_Parent : Boolean := True;

   begin
      --  We delay the initialization after checking that we really have a list

      if No (Cur) then
         return;
      end if;

      Preceding := Parent (L);

      while Present (Cur) loop

         --  We peek into the statement node to handle the case of the Annotate
         --  pragma separately here, to avoid passing the "Preceding" node
         --  around. All other cases are handled by Mark.

         if Is_Pragma_Annotate_GNATprove (Cur) then

            --  Handle all the following pragma Annotate, with the same
            --  "Preceding" node.

            loop
               Mark_Pragma_Annotate (Cur, Preceding,
                                     Consider_Next => not Is_Parent);
               Next (Cur);
               exit when
                 No (Cur)
                 or else not Is_Pragma_Annotate_GNATprove (Cur);
            end loop;

         else
            Mark (Cur);

            --  If the current declaration breaks the pragma range, we update
            --  the "preceding" node.

            if Decl_Starts_Pragma_Annotate_Range (Cur) then
               Preceding := Cur;
               Is_Parent := False;
            end if;
            Next (Cur);
         end if;
      end loop;
   end Mark_Stmt_Or_Decl_List;

   --------------------------
   -- Mark_Subprogram_Body --
   --------------------------

   procedure Mark_Subprogram_Body (N : Node_Id) is
      Save_SPARK_Pragma : constant Opt_N_Pragma_Id := Current_SPARK_Pragma;
      Def_E             : constant Entity_Id := Defining_Entity (N);
      E                 : constant Unit_Kind_Id := Unique_Entity (Def_E);

      In_Pred_Function_Body : constant Boolean :=
        Ekind (E) = E_Function and then Is_Predicate_Function (E);
      --  Set to True iff processing body of a predicate function, which is
      --  generated by the front end.

      Save_Delayed_Aspect_Type : constant Entity_Id :=
        Current_Delayed_Aspect_Type;

      SPARK_Pragma_Is_On : Boolean;
      --  Saves the information that SPARK_Mode is On for the body, for use
      --  later in the subprogram.

   begin
      --  Ignore bodies defined in the standard library, unless the main unit
      --  is from the standard library. In particular, ignore bodies from
      --  instances of generics defined in the standard library (unless we
      --  are analyzing the standard library itself). As a result, no VC is
      --  generated in this case for standard library code.

      if Is_Ignored_Internal (N)

        --  We still mark expression functions declared in the specification
        --  of internal units, so that GNATprove can use their definition.

        and then not
          (Ekind (E) = E_Function
           and then Nkind
             (Original_Node (Parent (Subprogram_Specification (E)))) =
               N_Expression_Function
           and then Ekind (Scope (E)) = E_Package
           and then In_Visible_Declarations
             (Parent (Subprogram_Specification (E))))

        --  We still mark predicate functions declared in the specification
        --  of internal units.

        and then not In_Pred_Function_Body
      then
         return;

      --  Ignore some functions generated by the frontend for aspects
      --  Type_Invariant and Default_Initial_Condition. This does not include
      --  the functions generated for Predicate aspects, as these functions
      --  are translated to check absence of RTE in the predicate in the most
      --  general context.

      elsif Subprogram_Is_Ignored_For_Proof (E) then
         return;

      --  Ignore subprograms annotated with pragma Eliminate; this includes
      --  subprograms that front-end generates to analyze default expressions.

      elsif Is_Eliminated (E) then
         return;

      else
         if In_Pred_Function_Body then
            Current_Delayed_Aspect_Type := Etype (First_Formal (E));

            pragma Assert (Has_Predicates (Current_Delayed_Aspect_Type));

            Current_SPARK_Pragma :=
              SPARK_Pragma_Of_Entity (Current_Delayed_Aspect_Type);

         else
            Current_SPARK_Pragma := SPARK_Pragma (Def_E);
         end if;

         SPARK_Pragma_Is_On := SPARK_Pragma_Is (Opt.On);

         --  Only analyze subprogram body declarations in SPARK_Mode => On (or
         --  while processing predicate function in discovery mode, which is
         --  recognized by the call to SPARK_Pragma_Is). An exception is made
         --  for expression functions, so that their body is translated into
         --  an axiom for analysis of its callers even in SPARK_Mode => Auto,
         --  but only for dependencies, not the current unit, as otherwise the
         --  body of the expression function might be in a package body with
         --  SPARK_Mode => Auto while the private part of the package spec has
         --  SPARK_Mode => Off.

         if SPARK_Pragma_Is_On
           or else (Is_Expression_Function_Or_Completion (E)
                    and then not SPARK_Pragma_Is (Opt.Off)
                    and then not
                      Is_Declared_In_Unit (E, Scope => Lib.Main_Unit_Entity))
         then
            declare
               Save_Violation_Detected : constant Boolean :=
                 Violation_Detected;
            begin
               Violation_Detected := False;

               --  Issue warning on unreferenced local subprograms, which are
               --  analyzed anyway, unless the subprogram is marked with pragma
               --  Unreferenced. Local subprograms are identified by calling
               --  Is_Local_Subprogram_Always_Inlined, but this does not take
               --  into account local subprograms which are not inlined. It
               --  would be better to look at the scope of E. ???

               if Is_Local_Subprogram_Always_Inlined (E)
                 and then not Referenced (E)
                 and then not Has_Unreferenced (E)
                 and then Emit_Warning_Info_Messages
               then
                  case Ekind (E) is
                  when E_Function =>
                     Error_Msg_NE
                       (Warning_Message (Warn_Unreferenced_Function), N, E);

                  when E_Procedure =>
                     Error_Msg_NE
                       (Warning_Message (Warn_Unreferenced_Procedure), N, E);

                  when others =>
                     raise Program_Error;

                  end case;
               end if;

               --  Mark Actual_Subtypes of body formal parameters, if any

               if Nkind (N) /= N_Task_Body then
                  declare
                     Body_Formal : Opt_Formal_Kind_Id := First_Formal (Def_E);
                     Sub         : Opt_Type_Kind_Id;
                  begin
                     while Present (Body_Formal) loop
                        Sub := Actual_Subtype (Body_Formal);
                        if Present (Sub)
                          and then not In_SPARK (Sub)
                        then
                           Mark_Violation (Body_Formal, From => Sub);
                        end if;
                        Next_Formal (Body_Formal);
                     end loop;
                  end;
               end if;

               --  Mark entry barrier

               if Nkind (N) = N_Entry_Body then
                  Mark (Condition (Entry_Body_Formal_Part (N)));
               end if;

               --  For subprogram bodies (but not other subprogram-like
               --  nodes which are also processed by this procedure) mark
               --  Refined_Post aspect if present.
               --  Reject refined posts on entries as they do not seem very
               --  useful.

               if Nkind (N) in N_Subprogram_Body | N_Entry_Body then
                  declare
                     C : constant Node_Id := Contract (Def_E);

                  begin
                     if Present (C) then
                        declare
                           Prag : Node_Id := Pre_Post_Conditions (C);
                        begin
                           while Present (Prag) loop
                              if Get_Pragma_Id (Prag) = Pragma_Refined_Post
                              then
                                 if Nkind (N) = N_Entry_Body then
                                    Mark_Unsupported
                                      (Lim_Refined_Post_On_Entry, N);
                                    exit;
                                 end if;

                                 Mark (Expression (First (
                                       Pragma_Argument_Associations (Prag))));
                              end if;
                              Prag := Next_Pragma (Prag);
                           end loop;
                        end;
                     end if;
                  end;
               end if;

               --  For checks related to the ceiling priority protocol we need
               --  both the priority of the main subprogram of the partition
               --  (whose body we might be marking here) and for the protected
               --  objects referenced by this subprogram (which we will get
               --  from the GG machinery).

               if Ekind (E) in E_Function | E_Procedure
                 and then Is_In_Analyzed_Files (E)
                 and then Might_Be_Main (E)
               then
                  --  The System unit must be already loaded; see call to
                  --  SPARK_Implicit_Load in GNAT_To_Why.

                  pragma Assert (RTU_Loaded (System));

                  Mark_Entity (RTE (RE_Default_Priority));
                  --  ??? we only need this if there is no explicit priority
                  --  attached to the main subprogram; note: this should also
                  --  pull System.Priority (which is explicitly pulled below).

                  --  For the protected objects we might need:
                  --  * System.Any_Priority'First
                  --  * System.Priority'Last
                  --  * System.Priority'First
                  --  * System.Interrupt_Priority'First
                  --  * System.Interrupt_Priority'Last
                  --
                  --  The Any_Priority is a base type of the latter to, so it
                  --  is enough to load them and Any_Priority will be pulled.

                  Mark_Entity (RTE (RE_Priority));
                  Mark_Entity (RTE (RE_Interrupt_Priority));
               end if;

               --  Detect violations in the body itself

               Mark_Stmt_Or_Decl_List (Declarations (N));
               Mark (Handled_Statement_Sequence (N));

               --  If a violation was detected on a predicate function, then
               --  the type to which the predicate applies is not in SPARK.
               --  Remove it from the set Entities_In_SPARK if already marked
               --  in SPARK.

               if Violation_Detected then
                  if In_Pred_Function_Body then
                     Entities_In_SPARK.Exclude (Current_Delayed_Aspect_Type);
                  end if;

               else
                  --  If no violation was detected on an expression function
                  --  body, mark it as compatible with SPARK, so that its
                  --  body gets translated into an axiom for analysis of
                  --  its callers.

                  if Is_Expression_Function_Or_Completion (E) then
                     Bodies_Compatible_With_SPARK.Insert (E);
                  end if;

                  --  If no violation was detected and SPARK_Mode is On for the
                  --  body, then mark the body for translation to Why3.

                  if SPARK_Pragma_Is_On then
                     Bodies_In_SPARK.Insert (E);
                  end if;
               end if;

               Violation_Detected := Save_Violation_Detected;
            end;
         end if;

         Current_Delayed_Aspect_Type := Save_Delayed_Aspect_Type;
         Current_SPARK_Pragma := Save_SPARK_Pragma;
      end if;
   end Mark_Subprogram_Body;

   ---------------------------------
   -- Mark_Subprogram_Declaration --
   ---------------------------------

   procedure Mark_Subprogram_Declaration (N : Node_Id) is
      E : constant Callable_Kind_Id := Defining_Entity (N);
      pragma Assert
        (Ekind (E) /= E_Function or else not Is_Predicate_Function (E));
      --  Mark_Subprogram_Declaration is never called on predicate functions

   begin
      --  Ignore some functions generated by the frontend for aspects
      --  Type_Invariant and Default_Initial_Condition. This does not include
      --  the functions generated for Predicate aspects, as these functions
      --  are translated to check absence of RTE in the predicate in the most
      --  general context.

      if Subprogram_Is_Ignored_For_Proof (E) then
         return;

      --  Ignore subprograms annotated with pragma Eliminate; this includes
      --  subprograms that front-end generates to analyze default expressions.

      elsif Is_Eliminated (E) then
         return;

      --  Mark entity

      else
         declare
            Save_SPARK_Pragma : constant Node_Id := Current_SPARK_Pragma;

         begin
            Current_SPARK_Pragma := SPARK_Pragma (E);

            Mark_Entity (E);

            Current_SPARK_Pragma := Save_SPARK_Pragma;
         end;

         if Ekind (E) in E_Procedure | E_Function then
            Mark_Address (E);
         end if;
      end if;
   end Mark_Subprogram_Declaration;

   -----------------------------
   -- Mark_Subtype_Indication --
   -----------------------------

   procedure Mark_Subtype_Indication (N : N_Subtype_Indication_Id) is
      T : constant Type_Kind_Id := Etype (Subtype_Mark (N));

   begin
      --  Check that the base type is in SPARK

      if not Retysp_In_SPARK (T) then
         Mark_Violation (N, From => T);
      end if;

      --  Floating- and fixed-point constraints are static in Ada, so do
      --  not require marking. Violations in range constraints render the
      --  (implicit) type of the subtype indication as not-in-SPARK anyway,
      --  so they also do not require explicit marking here.
      --  ??? error messages for this would be better if located at the
      --  exact subexpression of the range constraint that causes problem
      --
      --  Note: in general, constraints can also be an N_Range and
      --  N_Index_Or_Discriminant_Constraint. We would see them when marking
      --  all subtype indications "syntactically", i.e. by traversing the AST;
      --  however, we mark them "semantically", i.e. by looking directly at the
      --  (implicit) type of an object/component which bypasses this routine.
      --  In fact, we may see a node of kind N_Index_Or_Discriminant_Constraint
      --  as part of an allocator in an interfering context, which will get
      --  rejected.

      pragma Assert
        (Nkind (Constraint (N)) in N_Delta_Constraint
                                 | N_Digits_Constraint
                                 | N_Range_Constraint
                                 | N_Index_Or_Discriminant_Constraint);
   end Mark_Subtype_Indication;

   ---------------------------------
   -- Mark_Type_With_Relaxed_Init --
   ---------------------------------

   procedure Mark_Type_With_Relaxed_Init
     (N   : Node_Id;
      Ty  : Type_Kind_Id;
      Own : Boolean := False)
   is
      use Node_To_Bool_Maps;
      Rep_Ty   : constant Type_Kind_Id := Base_Retysp (Ty);
      C        : Node_To_Bool_Maps.Cursor;
      Inserted : Boolean;

   begin
      --  Store Rep_Ty in the Relaxed_Init map or update its mapping if
      --  necessary.

      Relaxed_Init.Insert (Rep_Ty, Own, C, Inserted);

      if not Inserted then
         if Own then
            Relaxed_Init.Replace_Element (C, Own);
         end if;
         return;
      end if;

      --  Raise violations on currently unsupported cases

      if Has_Invariants_In_SPARK (Ty) then
         Mark_Unsupported (Lim_Relaxed_Init_Invariant, N);
      elsif Is_Tagged_Type (Rep_Ty) then
         Mark_Unsupported (Lim_Relaxed_Init_Tagged_Type, N);
      elsif Is_Access_Type (Rep_Ty) then
         Mark_Unsupported (Lim_Relaxed_Init_Access_Type, N);
      elsif Is_Concurrent_Type (Rep_Ty) then
         Mark_Unsupported (Lim_Relaxed_Init_Concurrent_Type, N);
      end if;

      --  Using conversions, expressions of any ancestor of Rep_Ty can also
      --  be partially initialized. It is not the case for scalar types as
      --  conversions would evaluate them.
      --  Descendants are not added to the map. They are handled specifically
      --  in routines deciding whether a type might be partially initialized.

      if Retysp (Etype (Rep_Ty)) /= Rep_Ty
        and then not Is_Scalar_Type (Rep_Ty)
      then
         Mark_Type_With_Relaxed_Init (N, Retysp (Etype (Rep_Ty)));
      end if;

      --  Components of composite types can be partially initialized

      if Is_Array_Type (Rep_Ty) then
         Mark_Type_With_Relaxed_Init (N, Component_Type (Rep_Ty));
      elsif Is_Record_Type (Rep_Ty) then
         declare
            Comp      : Opt_E_Component_Id := First_Component (Rep_Ty);
            Comp_Type : Type_Kind_Id;

         begin
            while Present (Comp) loop
               pragma Assert (Ekind (Comp) = E_Component);

               if not Is_Tag (Comp)

                 --  Ignore components which are declared in a part with
                 --  SPARK_Mode => Off.

                 and then Component_Is_Visible_In_SPARK (Comp)
               then
                  Comp_Type := Etype (Comp);

                  --  Protect against calling marking of relaxed init types
                  --  on components of a non spark record, in case Rep_Ty is
                  --  not in SPARK.

                  if In_SPARK (Comp_Type) then
                     Mark_Type_With_Relaxed_Init (N, Comp_Type);
                  end if;
               end if;

               Next_Component (Comp);
            end loop;
         end;
      end if;

   end Mark_Type_With_Relaxed_Init;

   -------------------
   -- Mark_Unary_Op --
   -------------------

   procedure Mark_Unary_Op (N : N_Unary_Op_Id) is
      E : constant Entity_Id := Entity (N);

   begin
      --  Call is in SPARK only if the subprogram called is in SPARK.
      --
      --  Here we only deal with calls to operators implemented as intrinsic,
      --  because calls to user-defined operators completed with ordinary
      --  bodies have been already replaced by the frontend to N_Function_Call.
      --  These include predefined ones (like those on Standard.Boolean),
      --  compiler-defined (like negation of integer types), and user-defined
      --  (completed with a pragma Intrinsic).

      pragma Assert (Is_Intrinsic_Subprogram (E)
                       and then Ekind (E) in E_Function | E_Operator);

      if Ekind (E) = E_Function
        and then not In_SPARK (E)
      then
         Mark_Violation (N, From => E);
      end if;

      Mark (Right_Opnd (N));
   end Mark_Unary_Op;

   -----------------------------------
   -- Most_Underlying_Type_In_SPARK --
   -----------------------------------

   function Most_Underlying_Type_In_SPARK (Id : Type_Kind_Id) return Boolean is
     (Retysp_In_SPARK (Id)
      and then (Retysp_Kind (Id) not in Incomplete_Or_Private_Kind
                or else Retysp_Kind (Id) in Record_Kind));

   -----------------------
   -- Queue_For_Marking --
   -----------------------

   procedure Queue_For_Marking (E : Entity_Id) is
   begin
      Marking_Queue.Append (E);
   end Queue_For_Marking;

   ----------------------------------------------
   -- Reject_Incomplete_Type_From_Limited_With --
   ----------------------------------------------

   procedure Reject_Incomplete_Type_From_Limited_With
     (Limited_View  : Entity_Id;
      Marked_Entity : Entity_Id)
   is
   begin
      Error_Msg_Node_1 := Limited_View;
      Error_Msg_Node_2 := Limited_View;
      Mark_Unsupported
        (Lim_Limited_Type_From_Limited_With,
         N              => Marked_Entity,
         E              => Limited_View,
         Cont_Msg       =>
           "consider restructuring code to avoid `LIMITED WITH`",
         Root_Cause_Msg => "limited view coming from limited with");
   end Reject_Incomplete_Type_From_Limited_With;

   ---------------------
   -- Retysp_In_SPARK --
   ---------------------

   function Retysp_In_SPARK (E : Type_Kind_Id) return Boolean is
   begin
      --  Incomplete types coming from limited with should never be marked as
      --  they have an inappropriate location. The construct referencing them
      --  should be rejected instead.

      if Is_Incomplete_Type_From_Limited_With (E) then
         return False;
      end if;

      Mark_Entity (E);
      Mark_Entity (Retysp (E));
      return Entities_In_SPARK.Contains (Retysp (E));
   end Retysp_In_SPARK;

   ----------------------------
   -- SPARK_Pragma_Of_Entity --
   ----------------------------

   function SPARK_Pragma_Of_Entity (E : Entity_Id) return Node_Id is

      subtype SPARK_Pragma_Scope_With_Type_Decl is Entity_Kind
        with Static_Predicate =>
          SPARK_Pragma_Scope_With_Type_Decl in E_Abstract_State
                                             | E_Constant
                                             | E_Variable
                                             | E_Protected_Body
                                             | E_Protected_Type
                                             | E_Task_Body
                                             | E_Task_Type
                                             | E_Entry
                                             | E_Entry_Family
                                             | E_Function
                                             | E_Operator
                                             | E_Procedure
                                             | E_Subprogram_Body
                                             | E_Package
                                             | E_Package_Body;

      function SPARK_Pragma_Of_Decl (Decl : Node_Id) return Node_Id;
      --  Return the SPARK_Pragma associated with a declaration or a pragma. It
      --  is the pragma of the first enclosing scope with a SPARK pragma.

      --------------------------
      -- SPARK_Pragma_Of_Decl --
      --------------------------

      function SPARK_Pragma_Of_Decl (Decl : Node_Id) return Node_Id is
         Scop : Node_Id := Decl;

      begin
         --  Search for the first enclosing scope with a SPARK pragma

         while Nkind (Scop) not in
           N_Declaration | N_Later_Decl_Item | N_Number_Declaration
           or else Ekind (Defining_Entity (Scop)) not in
             SPARK_Pragma_Scope_With_Type_Decl
         loop
            pragma Assert (Present (Scop));
            Scop := Parent (Scop);
         end loop;

         Scop := Defining_Entity (Scop);

         --  If the scope that carries the pragma is a
         --  package, we need to handle the special cases where the entity
         --  comes from the private declarations of the spec (first case)
         --  or the statements of the body (second case).

         case Ekind (Scop) is
            when E_Package =>
               if List_Containing (Decl) =
                 Private_Declarations (Package_Specification (Scop))
               then
                  return SPARK_Aux_Pragma (Scop);
               else
                  pragma Assert
                    (List_Containing (Decl) =
                         Visible_Declarations (Package_Specification (Scop)));
               end if;

               --  For package bodies, the entity is declared either
               --  immediately in the package body declarations or in an
               --  arbitrarily nested DECLARE block of the package body
               --  statements.

            when E_Package_Body =>
               if List_Containing (Decl) =
                 Declarations (Package_Body (Unique_Entity (Scop)))
               then
                  return SPARK_Pragma (Scop);
               else
                  return SPARK_Aux_Pragma (Scop);
               end if;

               --  Similar correction could be needed for concurrent types too,
               --  but types and named numbers can't be nested there.

            when E_Protected_Type
               | E_Task_Type
            =>
               raise Program_Error;

            when others =>
               null;
         end case;

         return SPARK_Pragma (Scop);
      end SPARK_Pragma_Of_Decl;

   --  Start of processing for SPARK_Pragma_Of_Entity

   begin
      --  Get correct type for predicate functions.
      --  Similar code is not needed for Invariants and DIC because we do not
      --  mark the corresponding procedure, just the expression.

      if Ekind (E) = E_Function and then Is_Predicate_Function (E) then

         --  The predicate function has the SPARK_Mode of the associated type.
         --  If this type has a full view, search the rep item list to know the
         --  correct SPARK_Mode.

         declare
            Ty  : constant Type_Kind_Id := Etype (First_Formal (E));
            Rep : Node_Id;
         begin
            if No (Full_View (Ty)) then
               return SPARK_Pragma_Of_Entity (Ty);
            else
               Rep := First_Rep_Item
                 (if Present (Full_View (Ty)) then Full_View (Ty) else Ty);

               Find_Predicate_Item (Ty, Rep);
               if No (Rep) then

                  --  The type only has inherited predicates. The predicate
                  --  function is empty, we can choose any SPARK_Mode.

                  return SPARK_Pragma_Of_Entity (Ty);
               elsif Nkind (Rep) = N_Pragma then

                  --  Search for the SPARK_Mode applying to the predicate

                  return SPARK_Pragma_Of_Decl (Rep);
               else
                  pragma Assert (Nkind (Rep) = N_Aspect_Specification);

                  --  Use the SPARK_Mode of the partial or full view of the
                  --  type, depending on Aspect_On_Partial_View.

                  if Aspect_On_Partial_View (Rep) then
                     return SPARK_Pragma_Of_Entity (Ty);
                  else
                     return SPARK_Pragma_Of_Entity (Full_View (Ty));
                  end if;
               end if;
            end if;
         end;

      --  For the wrapper for a function with dispatching result type pick the
      --  SPARK_Pragma of its type, because the wrapper could be inserted at
      --  the freeze node.

      elsif Is_Wrapper_For_Dispatching_Result (E) then
         declare
            Typ : constant Entity_Id := Etype (E);
         begin
            if Is_Incomplete_Or_Private_Type (Typ)
              and then Present (Full_View (Typ))
            then
               return SPARK_Pragma_Of_Entity (Full_View (Typ));
            else
               return SPARK_Pragma_Of_Entity (Typ);
            end if;
         end;
      end if;

      --  For entities that can carry a SPARK_Mode Pragma and that have one, we
      --  can just query and return it.

      if Ekind (E) in SPARK_Pragma_Scope_With_Type_Decl
        or else Scope (E) = Standard_Standard
      then
         return SPARK_Pragma (E);
      end if;

      if Is_Itype (E) then
         declare
            Decl : constant Node_Id := Associated_Node_For_Itype (E);
         begin
            pragma Assert (Present (Parent (Decl)));

            if Nkind (Parent (Decl)) = N_Package_Specification then
               declare
                  Pack_Decl : constant N_Package_Declaration_Id :=
                    Parent (Parent (Decl));
                  Pack_Ent  : constant E_Package_Id :=
                    Defining_Entity (Pack_Decl);
               begin
                  return (if In_Private_Declarations (Decl)
                          then SPARK_Aux_Pragma (Pack_Ent)
                          else SPARK_Pragma (Pack_Ent));
               end;
            end if;

            --  ??? The following pointer type is not accepted. This is related
            --  to [R525-018].
            --    type L_Ptr is access L;
            --    type SL_Ptr3 is new L_Ptr(7);

            if Is_Nouveau_Type (E) then
               case Nkind (Decl) is
                  when N_Object_Declaration =>
                     return SPARK_Pragma (Defining_Identifier (Decl));
                  when N_Procedure_Specification | N_Function_Specification =>
                     return SPARK_Pragma (Defining_Unit_Name (Decl));
                  when others =>
                     return Empty;
               end case;
            end if;
            return Empty;
         end;
      end if;

      --  For loop entities and loop variables of quantified expressions, the
      --  Lexical_Scope function does not work, so we handle them separately.

      if Ekind (E) in E_Loop_Parameter | E_Loop
        or else (Ekind (E) = E_Variable
                 and then Is_Quantified_Loop_Param (E))
      then
         return SPARK_Pragma_Of_Entity (Enclosing_Unit (E));
      end if;

      if Is_Formal (E)
        or else Ekind (E) in E_Discriminant | E_Component
      then
         return SPARK_Pragma_Of_Entity (Scope (E));
      end if;

      --  After having dealt with the special cases, we now do the "regular"
      --  search for the enclosing SPARK_Mode Pragma. We do this by climbing
      --  the lexical scope until we find an entity that can carry a
      --  SPARK_Mode pragma.

      pragma Assert (Is_Type (E) or else Is_Named_Number (E));
      return SPARK_Pragma_Of_Decl (Enclosing_Declaration (E));

   end SPARK_Pragma_Of_Entity;

   ----------------------------------------------------------------------
   --  Iterators
   ----------------------------------------------------------------------

   ------------------
   -- First_Cursor --
   ------------------

   function First_Cursor (Kind : Entity_Collection) return Cursor is
      pragma Unreferenced (Kind);
   begin
      return Cursor (Entity_List.First);
   end First_Cursor;

   -----------------
   -- Next_Cursor --
   -----------------

   function Next_Cursor
     (Kind : Entity_Collection;
      C    : Cursor)
      return Cursor
   is
      pragma Unreferenced (Kind);
   begin
      return Cursor (Node_Lists.Next (Node_Lists.Cursor (C)));
   end Next_Cursor;

   -----------------
   -- Has_Element --
   -----------------

   function Has_Element
     (Kind : Entity_Collection;
      C    : Cursor)
      return Boolean
   is
      pragma Unreferenced (Kind);
   begin
      return Node_Lists.Has_Element (Node_Lists.Cursor (C));
   end Has_Element;

   -----------------
   -- Get_Element --
   -----------------

   function Get_Element
     (Kind : Entity_Collection;
      C    : Cursor)
      return Entity_Id
   is
      pragma Unreferenced (Kind);
   begin
      return Node_Lists.Element (Node_Lists.Cursor (C));
   end Get_Element;

end SPARK_Definition;
