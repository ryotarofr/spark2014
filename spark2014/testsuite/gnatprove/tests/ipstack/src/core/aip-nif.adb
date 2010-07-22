------------------------------------------------------------------------------
--                            IPSTACK COMPONENTS                            --
--             Copyright (C) 2010, Free Software Foundation, Inc.           --
------------------------------------------------------------------------------

with Ada.Unchecked_Conversion;

package body AIP.NIF is

   type Netif is record
      State             : Netif_State;
      --  Interface state

      Name              : Netif_Name;
      --  Unique name of interface

      LL_Address        : LL_Address_Storage;
      --  Link-level address

      LL_Address_Length : LL_Address_Range;
      --  Actual length of link level address

      MTU               : U16_T;
      --  Maximum Transmission Unit

      IP                : IPaddrs.IPaddr;
      --  IP address

      Mask              : IPaddrs.IPaddr;
      --  Netmask

      Broadcast         : IPaddrs.IPaddr;
      --  Broadcast address: (IP and mask) or (not mask)

      Input_CB          : Callbacks.CBK_Id;
      --  Packet input callback
      --  procedure I (Nid : Netif_Id; Buf : Buffer_Id);

      Output_CB         : Callbacks.CBK_Id;
      --  Packet output callback (called by network layer)
      --  procedure O (Nid : Netif_Id; Buf : Buffer_Id; Dst_Address : IPaddr);

      Link_Output_CB   : Callbacks.CBK_Id;
      --  Link level packet output callback (called by ARP layer)
      --  procedure LO (Nid : Netif_Id; Buf : Buffer_Id);

      Dev               : System.Address;
      --  Driver private information
   end record;
   pragma Convention (C, Netif);

   type NIF_Array is array (Netif_Id) of aliased Netif;

   NIFs : NIF_Array;

   --------------------
   -- Allocate_Netif --
   --------------------

   procedure Allocate_Netif (Nid : out EID) is
   begin
      Nid := IF_NOID;
      for J in NIFs'Range loop
         if NIFs (J).State = Invalid then
            Nid := J;

            --  Mark NIF as allocated

            NIFs (J).State := Down;
            exit;
         end if;
      end loop;
   end Allocate_Netif;

   --------------------
   -- Get_LL_Address --
   --------------------

   procedure Get_LL_Address
     (Nid               : Netif_Id;
      LL_Address        : out AIP.LL_Address;
      LL_Address_Length : out AIP.LL_Address_Range)
   is
      pragma Assert (LL_Address'First = 1);
      subtype This_LL_Address_Range is
        LL_Address_Range range 1 .. NIFs (Nid).LL_Address_Length;
   begin
      LL_Address (This_LL_Address_Range) :=
        NIFs (Nid).LL_Address (This_LL_Address_Range);
      LL_Address_Length := NIFs (Nid).LL_Address_Length;
   end Get_LL_Address;

   ---------------
   -- Get_Netif --
   ---------------

   function Get_Netif (Nid : Netif_Id) return System.Address is
   begin
      return NIFs (Nid)'Address;
   end Get_Netif;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      for J in NIFs'Range loop
         declare
            NIF : Netif renames NIFs (J);
         begin
            NIF.State := Invalid;

            NIF.Input_CB       := Callbacks.NOCB;
            NIF.Output_CB      := Callbacks.NOCB;
            NIF.Link_Output_CB := Callbacks.NOCB;
         end;
      end loop;
   end Initialize;

   ----------------------
   -- Is_Local_Address --
   ----------------------

   function Is_Local_Address
     (Nid  : Netif_Id;
      Addr : IPaddrs.IPaddr) return Boolean
   is
   begin
      return Addr = NIF_Addr (Nid);
   end Is_Local_Address;

   --------------------------
   -- Is_Broadcast_Address --
   --------------------------

   function Is_Broadcast_Address
     (Nid  : Netif_Id;
      Addr : IPaddrs.IPaddr) return Boolean
   is
   begin
      return Addr = IPaddrs.IP_ADDR_BCAST
               or else Addr = NIF_Broadcast (Nid);
   end Is_Broadcast_Address;

   -----------------
   -- Link_Output --
   -----------------

   procedure Link_Output
     (Nid : Netif_Id;
      Buf : Buffers.Buffer_Id)
   is
      --# hide Link_Output;

      type Link_Output_CB_Ptr is
        access procedure (Nid : Netif_Id; Buf : Buffers.Buffer_Id);
      function To_Ptr is new Ada.Unchecked_Conversion
        (Callbacks.CBK_Id, Link_Output_CB_Ptr);
   begin
      To_Ptr (NIFs (Nid).Link_Output_CB) (Nid, Buf);
   end Link_Output;

   -------------------
   -- NIF_Broadcast --
   -------------------

   function NIF_Broadcast (Nid : Netif_Id) return IPaddrs.IPaddr is
   begin
      return NIFs (Nid).Broadcast;
   end NIF_Broadcast;

   ------------
   -- NIF_Addr --
   ------------

   function NIF_Addr (Nid : Netif_Id) return IPaddrs.IPaddr is
   begin
      return NIFs (Nid).IP;
   end NIF_Addr;

   --------------
   -- NIF_Mask --
   --------------

   function NIF_Mask (Nid : Netif_Id) return IPaddrs.IPaddr is
   begin
      return NIFs (Nid).Mask;
   end NIF_Mask;

   ------------
   -- Output --
   ------------

   procedure Output
     (Nid         : Netif_Id;
      Buf         : Buffers.Buffer_Id;
      Dst_Address : IPaddrs.IPaddr)
   is
      --# hide Output;

      type Output_CB_Ptr is access procedure
        (Nid         : Netif_Id;
         Buf         : Buffers.Buffer_Id;
         Dst_Address : IPaddrs.IPaddr);
      function To_Ptr is new Ada.Unchecked_Conversion
        (Callbacks.CBK_Id, Output_CB_Ptr);
   begin
      To_Ptr (NIFs (Nid).Output_CB) (Nid, Buf, Dst_Address);
   end Output;

end AIP.NIF;
