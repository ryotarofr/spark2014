------------------------------------------------------------------------------
--                                                                          --
--                            GNAT2WHY COMPONENTS                           --
--                                                                          --
--                 G N A T 2 W H Y _ O P T S . W R I T I N G                --
--                                                                          --
--                                 S p e c                                  --
--                                                                          --
--                     Copyright (C) 2010-2022, AdaCore                     --
--              Copyright (C) 2017-2022, Capgemini Engineering              --
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

package Gnat2Why_Opts.Writing is

   Name_GNATprove : constant String := "gnatprove";
   --  Name of the object sub-directory in which files are generated by
   --  GNATprove.

   function Pass_Extra_Options_To_Gnat2why
     (Translation_Phase : Boolean;
      Obj_Dir           : String;
      Proj_Name         : String) return String;
   --  Create a file with extra options for gnat2why and return its pathname.
   --  Translation_Phase is False for globals generation, and True for
   --  translation to Why.

end Gnat2Why_Opts.Writing;
