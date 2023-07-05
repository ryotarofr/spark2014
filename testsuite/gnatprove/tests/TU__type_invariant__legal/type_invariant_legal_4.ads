--  TU: 5. Invariant checking is extended to include checking of global inputs
--  and outputs, and for all subprograms. For purposes of determining type
--  invariant verification conditions, a global of a given mode (i.e, in, out,
--  or in out) is treated like a parameter of the given mode. This rule applies
--  regardless of where the global object in question is declared.

package Type_Invariant_Legal_4 with SPARK_Mode, Abstract_State => State is

   type T is private;

   function Pub return Integer;
   function E_Pub return Integer;  --  @INVARIANT_CHECK:NONE

   procedure Pub_In;  --  @INVARIANT_CHECK:NONE
   procedure Pub_Out with Global => (Output => State);  --  @INVARIANT_CHECK:PASS
   procedure Pub_In_Out;  --  @INVARIANT_CHECK:PASS

private
   type T is new Natural with Type_Invariant => T /= 0;  --  @INVARIANT_CHECK_ON_DEFAULT_VALUE:FAIL

   X : T := 1 with Part_Of => State;  --  @INVARIANT_CHECK:PASS

   function Priv return Integer with Pre => True;
   function E_Priv return Integer;  --  @INVARIANT_CHECK:NONE

   function E_Pub return Integer is (Integer(X));
   function E_Priv return Integer is (Integer(X));

end Type_Invariant_Legal_4;
