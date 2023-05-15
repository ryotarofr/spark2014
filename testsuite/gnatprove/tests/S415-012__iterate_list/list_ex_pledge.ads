package List_Ex_Pledge with SPARK_Mode is
    type List_Cell;
    type List is access List_Cell;
    type List_Cell is record
       Value : Integer;
       Next  : List;
    end record;

    function Length_Aux (L : access constant List_Cell) return Natural is
      (if L = null then 0
       elsif Length_Aux (L.Next) = Integer'Last then
            Integer'Last
       else 1 + Length_Aux (L.Next));

    function Length (L : access constant List_Cell) return Natural is (Length_Aux (L));

    function Get_Nth_Val (L : access constant List_Cell; N : Positive) return Integer is
      (if N = 1 then L.Value else Get_Nth_Val (L.Next, N - 1))
    with Pre => N <= Length (L);

   function At_End_Borrow (T : access constant List_Cell) return access constant List_Cell is (T) with Ghost;
   pragma Annotate (GNATprove, At_End_Borrow, Entity => At_End_Borrow);

   procedure All_Zero (L : List) with
     Pre  => Length (L) < Integer'Last,
     Post => Length (L) = Length (L)'Old
     and then (for all I in 1 .. Length (L) => Get_Nth_Val (L, I) = 0);
end List_Ex_Pledge;
