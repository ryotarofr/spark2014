------------------------------------------------------------------------------
--                                                                          --
--                        SPARK LIBRARY COMPONENTS                          --
--                                                                          --
--                    SPARK.CONTAINERS.FUNCTIONAL.MAPS                      --
--                                                                          --
--                                 S p e c                                  --
--                                                                          --
--          Copyright (C) 2016-2022, Free Software Foundation, Inc.         --
--                                                                          --
-- SPARK is free software;  you can  redistribute it and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion. SPARK is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.                                     --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
------------------------------------------------------------------------------

--  This unit is provided as a replacement for the unit
--  SPARK.Containers.Functional.Maps when only proof with SPARK is
--  intended. It cannot be used for execution, as all subprograms are marked
--  imported with no definition.

--  Contrary to SPARK.Containers.Functional.Maps, this unit does not
--  depend on System or Ada.Finalization, which makes it more convenient for
--  use in run-time units.

pragma Ada_2012;

with Ada.Containers; use Ada.Containers;
with SPARK.Big_Integers;
use SPARK.Big_Integers;

generic
   type Key_Type (<>) is private;
   type Element_Type (<>)  is private;

   with function Equivalent_Keys
     (Left  : Key_Type;
      Right : Key_Type) return Boolean is "=";
   with function "=" (Left, Right : Element_Type) return Boolean is <>;

   Enable_Handling_Of_Equivalence : Boolean := True;
   --  This constant should only be set to False when no particular handling
   --  of equivalence over keys is needed, that is, Equivalent_Keys defines a
   --  key uniquely.

package SPARK.Containers.Functional.Maps with
  SPARK_Mode,
  Ghost,
  Annotate => (GNATprove, Always_Return)
is

   type Map is private with
     Default_Initial_Condition => Is_Empty (Map),
     Iterable                  => (First       => Iter_First,
                                   Next        => Iter_Next,
                                   Has_Element => Iter_Has_Element,
                                   Element     => Iter_Element);
   --  Maps are empty when default initialized.
   --  "For in" quantification over maps should not be used.
   --  "For of" quantification over maps iterates over keys.
   --  Note that, for proof, "for of" quantification is understood modulo
   --  equivalence (the range of quantification comprises all the keys that are
   --  equivalent to any key of the map).

   -----------------------
   --  Basic operations --
   -----------------------

   --  Maps are axiomatized using Has_Key and Get, encoding respectively the
   --  presence of a key in a map and an accessor to elements associated with
   --  its keys. The length of a map is also added to protect Add against
   --  overflows but it is not actually modeled.

   function Has_Key (Container : Map; Key : Key_Type) return Boolean with
     Import,
     Global => null;
   --  Return True if Key is present in Container

   procedure Lemma_Has_Key_Equivalent
     (Container : Map;
      Key       : Key_Type)
   --  Has_Key returns the same result on all equivalent keys
   with
     Import,
     Ghost,
     Global => null,
     Annotate => (GNATprove, Automatic_Instantiation),
     Pre  => Enable_Handling_Of_Equivalence
       and then (for some K of Container => Equivalent_Keys (K, Key)),
     Post => Has_Key (Container, Key);

   function Get (Container : Map; Key : Key_Type) return Element_Type with
   --  Return the element associated with Key in Container

     Import,
     Global => null,
     Pre    => Has_Key (Container, Key);

   procedure Lemma_Get_Equivalent
     (Container : Map;
      Key       : Key_Type)
   --  Get returns the same result on all equivalent keys
   with
     Import,
     Ghost,
     Global => null,
     Annotate => (GNATprove, Automatic_Instantiation),
     Pre  => Enable_Handling_Of_Equivalence,
     Post => Get (Container, Key) = W_Get (Container, Witness (Container, Key))
       and (for all K of Container =>
              Equivalent_Keys (K, Key) =
               (Witness (Container, Key) = Witness (Container, K)));

   function Choose (Container : Map) return Key_Type with
   --  Return an arbitrary key in container

     Import,
     Global => null,
     Pre    => not Is_Empty (Container),
     Post   => Has_Key (Container, Choose'Result);

   function Length (Container : Map) return Big_Natural with
     Import,
     Global => null;
   --  Return the number of mappings in Container

   ------------------------
   -- Property Functions --
   ------------------------

   function "<=" (Left : Map; Right : Map) return Boolean with
   --  Map inclusion

     Import,
     Global => null,
     Post   =>
       "<="'Result =
         (for all Key of Left =>
           Has_Key (Right, Key) and then Get (Right, Key) = Get (Left, Key));

   function "=" (Left : Map; Right : Map) return Boolean with
   --  Extensional equality over maps

     Import,
     Global => null,
     Post   =>
       "="'Result =
         ((for all Key of Left =>
            Has_Key (Right, Key)
              and then Get (Right, Key) = Get (Left, Key))
              and (for all Key of Right => Has_Key (Left, Key)));

   pragma Warnings (Off, "unused variable ""Key""");
   function Is_Empty (Container : Map) return Boolean with
   --  A map is empty if it contains no key

     Import,
     Global => null,
     Post   => Is_Empty'Result = (for all Key of Container => False)
       and Is_Empty'Result = (Length (Container) = 0);
   pragma Warnings (On, "unused variable ""Key""");

   function Keys_Included (Left : Map; Right : Map) return Boolean
   --  Returns True if every Key of Left is in Right

   with
     Import,
     Global => null,
     Post   =>
       Keys_Included'Result = (for all Key of Left => Has_Key (Right, Key));

   function Same_Keys (Left : Map; Right : Map) return Boolean
   --  Returns True if Left and Right have the same keys

   with
     Import,
     Global => null,
     Post   =>
       Same_Keys'Result =
         (Keys_Included (Left, Right)
           and Keys_Included (Left => Right, Right => Left));
   pragma Annotate (GNATprove, Inline_For_Proof, Same_Keys);

   function Keys_Included_Except
     (Left    : Map;
      Right   : Map;
      New_Key : Key_Type) return Boolean
   --  Returns True if Left contains only keys of Right and possibly New_Key

   with
     Import,
     Global => null,
     Post   =>
       Keys_Included_Except'Result =
         (for all Key of Left =>
           (if not Equivalent_Keys (Key, New_Key) then
               Has_Key (Right, Key)));

   function Keys_Included_Except
     (Left  : Map;
      Right : Map;
      X     : Key_Type;
      Y     : Key_Type) return Boolean
   --  Returns True if Left contains only keys of Right and possibly X and Y

   with
     Import,
     Global => null,
     Post   =>
       Keys_Included_Except'Result =
         (for all Key of Left =>
           (if not Equivalent_Keys (Key, X)
              and not Equivalent_Keys (Key, Y)
            then
               Has_Key (Right, Key)));

   function Elements_Equal_Except
     (Left    : Map;
      Right   : Map;
      New_Key : Key_Type) return Boolean
   --  Returns True if all the keys of Left are mapped to the same elements in
   --  Left and Right except New_Key.

   with
     Import,
     Global => null,
     Post   =>
       Elements_Equal_Except'Result =
         (for all Key of Left =>
           (if not Equivalent_Keys (Key, New_Key) then
               Has_Key (Right, Key)
                 and then Get (Left, Key) = Get (Right, Key)));

   function Elements_Equal_Except
     (Left  : Map;
      Right : Map;
      X     : Key_Type;
      Y     : Key_Type) return Boolean
   --  Returns True if all the keys of Left are mapped to the same elements in
   --  Left and Right except X and Y.

   with
     Import,
     Global => null,
     Post   =>
       Elements_Equal_Except'Result =
         (for all Key of Left =>
           (if not Equivalent_Keys (Key, X)
              and not Equivalent_Keys (Key, Y)
            then
               Has_Key (Right, Key)
                 and then Get (Left, Key) = Get (Right, Key)));

   ----------------------------
   -- Construction Functions --
   ----------------------------

   --  For better efficiency of both proofs and execution, avoid using
   --  construction functions in annotations and rather use property functions.

   function Add
     (Container : Map;
      New_Key   : Key_Type;
      New_Item  : Element_Type) return Map
   --  Returns Container augmented with the mapping Key -> New_Item

   with
     Import,
     Global => null,
     Pre    => not Has_Key (Container, New_Key),
     Post   =>
       Length (Container) + 1 = Length (Add'Result)
         and Has_Key (Add'Result, New_Key)
         and Get (Add'Result, New_Key) = New_Item
         and Container <= Add'Result
         and Keys_Included_Except (Add'Result, Container, New_Key);

   function Empty_Map return Map with
   --  Return an empty Map

     Import,
     Global => null,
     Post   => Is_Empty (Empty_Map'Result);

   function Remove
     (Container : Map;
      Key       : Key_Type) return Map
   --  Returns Container without any mapping for Key

   with
     Import,
     Global => null,
     Pre    => Has_Key (Container, Key),
     Post   =>
       Length (Container) = Length (Remove'Result) + 1
         and not Has_Key (Remove'Result, Key)
         and Remove'Result <= Container
         and Keys_Included_Except (Container, Remove'Result, Key);

   function Set
     (Container : Map;
      Key       : Key_Type;
      New_Item  : Element_Type) return Map
   --  Returns Container, where the element associated with Key has been
   --  replaced by New_Item.

   with
     Import,
     Global => null,
     Pre    => Has_Key (Container, Key),
     Post   =>
       Length (Container) = Length (Set'Result)
         and Get (Set'Result, Key) = New_Item
         and Same_Keys (Container, Set'Result)
         and Elements_Equal_Except (Container, Set'Result, Key);

   ------------------------------
   --  Handling of Equivalence --
   ------------------------------

   --  These functions are used to specify that Get returns the same value on
   --  equivalent keys. They should not be used directly in user code.

   function Has_Witness (Container : Map; Witness : Count_Type) return Boolean
   with
     Import,
     Ghost,
     Global => null;
   --  Returns True if there is a key with witness Witness in Container

   function Witness (Container : Map; Key : Key_Type) return Count_Type with
   --  Returns the witness of Key in Container

     Import,
     Ghost,
     Global => null,
     Pre    => Has_Key (Container, Key),
     Post   => Has_Witness (Container, Witness'Result);

   function W_Get (Container : Map; Witness : Count_Type) return Element_Type
   with
   --  Returns the element associated with a witness in Container

     Import,
     Ghost,
     Global => null,
     Pre    => Has_Witness (Container, Witness);

   function Copy_Key (Key : Key_Type) return Key_Type is (Key);
   function Copy_Element (Item : Element_Type) return Element_Type is (Item);
   --  Elements and Keys of maps are copied by numerous primitives in this
   --  package. This function causes GNATprove to verify that such a copy is
   --  valid (in particular, it does not break the ownership policy of SPARK,
   --  i.e. it does not contain pointers that could be used to alias mutable
   --  data).

   ----------------------------------
   -- Iteration on Functional Maps --
   ----------------------------------

   --  The Iterable aspect can be used to quantify over a functional map.
   --  However, if it is used to create a for loop, it will not allow users to
   --  prove their loops as there is no way to speak about the elements which
   --  have or have not been traversed already in a loop invariant. The
   --  function Iterate returns an object of a type Iterable_Map which can be
   --  used for iteration. The cursor is a functional map containing all the
   --  elements which have not been traversed yet. The current element being
   --  traversed being the result of Choose on this map.

   type Iterable_Map is private with
     Iterable =>
       (First       => First,
        Has_Element => Has_Element,
        Next        => Next,
        Element     => Element);

   function Map_Logic_Equal (Left, Right : Map) return Boolean with
     Import,
     Ghost,
     Annotate => (GNATprove, Logical_Equal);
   --  Logical equality on maps

   function Iterate (Container : Map) return Iterable_Map with
     Import,
     Global => null,
     Post   => Map_Logic_Equal (Get_Map (Iterate'Result), Container);
   --  Return an iterator over a functional map

   function Get_Map (Iterator : Iterable_Map) return Map with
     Import,
     Global => null;
   --  Retrieve the map associated with an iterator

   function Valid_Submap
     (Iterator : Iterable_Map;
      Cursor   : Map) return Boolean
   with
     Import,
     Global => null,
     Post   => (if Valid_Submap'Result then Cursor <= Get_Map (Iterator));
   --  Return True on all maps which can be reached by iterating over
   --  Container.

   function Element (Iterator : Iterable_Map; Cursor : Map) return Key_Type
   with
     Import,
     Global => null,
     Pre    => not Is_Empty (Cursor),
     Post   => Element'Result = Choose (Cursor);
   --  The next element to be considered for the iteration is the result of
   --  choose on Cursor.

   function First (Iterator : Iterable_Map) return Map with
     Import,
     Global => null,
     Post   => Map_Logic_Equal (First'Result, Get_Map (Iterator))
       and then Valid_Submap (Iterator, First'Result);
   --  In the first iteration, the cursor is the map associated with Iterator

   function Next (Iterator : Iterable_Map; Cursor : Map) return Map with
     Import,
     Global => null,
     Pre    => Valid_Submap (Iterator, Cursor) and then not Is_Empty (Cursor),
     Post   => Valid_Submap (Iterator, Next'Result)
       and then
         Map_Logic_Equal (Next'Result, Remove (Cursor, Choose (Cursor)));
   --  At each iteration, remove the considered element from the Cursor map

   function Has_Element
     (Iterator : Iterable_Map;
      Cursor   : Map) return Boolean
   with
     Import,
     Global => null,
     Post   => Has_Element'Result =
       (Valid_Submap (Iterator, Cursor) and then not Is_Empty (Cursor));
   --  Return True on non-empty maps which can be reached by iterating over
   --  Container.

   --------------------------------------------------
   -- Iteration Primitives Used For Quantification --
   --------------------------------------------------

   type Private_Key is private;

   function Iter_First (Container : Map) return Private_Key with
     Import,
     Global => null;

   function Iter_Has_Element
     (Container : Map;
      Key       : Private_Key) return Boolean
   with
     Import,
     Global => null;

   function Iter_Next (Container : Map; Key : Private_Key) return Private_Key
   with
     Import,
     Global => null,
     Pre    => Iter_Has_Element (Container, Key);

   function Iter_Element (Container : Map; Key : Private_Key) return Key_Type
   with
     Import,
     Global => null,
     Pre    => Iter_Has_Element (Container, Key);
   pragma Annotate (GNATprove, Iterable_For_Proof, "Contains", Has_Key);

private

   pragma SPARK_Mode (Off);

   type Map is null record;
   type Iterable_Map is null record;
   type Private_Key is null record;

end SPARK.Containers.Functional.Maps;
