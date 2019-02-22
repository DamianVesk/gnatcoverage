------------------------------------------------------------------------------
--                                                                          --
--                               GNATcoverage                               --
--                                                                          --
--                     Copyright (C) 2009-2016, AdaCore                     --
--                                                                          --
-- GNATcoverage is free software; you can redistribute it and/or modify it  --
-- under terms of the GNU General Public License as published by the  Free  --
-- Software  Foundation;  either version 3,  or (at your option) any later  --
-- version. This software is distributed in the hope that it will be useful --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Ada.Unchecked_Deallocation;

with Coverage.Source;
with Files_Table;
with Instrument.Common;
with Outputs;           use Outputs;
with Traces_Files_List;

package body Checkpoints is

   Checkpoint_Magic : constant String := "GNATcov checkpoint" & ASCII.NUL;

   type Checkpoint_Header is record
      Magic   : String (1 .. Checkpoint_Magic'Length) := Checkpoint_Magic;
      Version : Interfaces.Unsigned_32;
   end record;

   procedure Free is
     new Ada.Unchecked_Deallocation (SFI_Map_Array, SFI_Map_Acc);
   procedure Free is
     new Ada.Unchecked_Deallocation (SCO_Id_Map_Array, SCO_Id_Map_Acc);
   procedure Free is
     new Ada.Unchecked_Deallocation (Inst_Id_Map_Array, Inst_Id_Map_Acc);

   ---------------------
   -- Checkpoint_Save --
   ---------------------

   procedure Checkpoint_Save
     (Filename : String;
      Context  : access Coverage.Context;
      Version  : Checkpoint_Version := Default_Checkpoint_Version)
   is
      SF  : Ada.Streams.Stream_IO.File_Type;
      CSS : Checkpoint_Save_State;
   begin
      Create (SF, Out_File, Filename);
      CSS.Version := Version;
      CSS.Stream  := Stream (SF);

      Checkpoint_Header'Write
        (CSS.Stream, (Version => Version, others => <>));
      Coverage.Levels_Type'Write
        (CSS.Stream, Coverage.Current_Levels);

      Files_Table.Checkpoint_Save (CSS);
      SC_Obligations.Checkpoint_Save (CSS);
      if not CSS.Version_Less (Than => 2) then
         Instrument.Common.Checkpoint_Save (CSS);
      end if;
      Coverage.Source.Checkpoint_Save (CSS);
      Traces_Files_List.Checkpoint_Save (CSS, Context);
      Close (SF);
   end Checkpoint_Save;

   ---------------------
   -- Checkpoint_Load --
   ---------------------

   procedure Checkpoint_Load (Filename : String) is
      SF     : Ada.Streams.Stream_IO.File_Type;
      CLS    : Checkpoint_Load_State;

      CP_Header : Checkpoint_Header;
      Levels : Coverage.Levels_Type;

   begin
      CLS.Filename := To_Unbounded_String (Filename);

      Open (SF, In_File, Filename);
      CLS.Stream := Stream (SF);

      Checkpoint_Header'Read (CLS.Stream, CP_Header);
      if CP_Header.Magic /= Checkpoint_Magic then
         Fatal_Error ("invalid checkpoint file " & Filename);

      elsif CP_Header.Version not in Checkpoint_Version then
         Fatal_Error
           ("invalid checkpoint version" & CP_Header.Version'Img);

      else
         CLS.Version := CP_Header.Version;
         Coverage.Levels_Type'Read (CLS.Stream, Levels);
         declare
            Error_Msg : constant String :=
               Coverage.Is_Load_Allowed (Filename, Levels);
         begin
            if Error_Msg'Length > 0 then
               Fatal_Error (Error_Msg);
            end if;
         end;

         Files_Table.Checkpoint_Load (CLS);
         SC_Obligations.Checkpoint_Load (CLS);
         if not CLS.Version_Less (Than => 2) then
            Instrument.Common.Checkpoint_Load (CLS);
         end if;
         Coverage.Source.Checkpoint_Load (CLS);
         Traces_Files_List.Checkpoint_Load (CLS);

         Free (CLS.SFI_Map);
         Free (CLS.SCO_Map);
         Free (CLS.Inst_Map);
      end if;

      Close (SF);
   end Checkpoint_Load;

   ---------------
   -- Remap_SFI --
   ---------------

   procedure Remap_SFI
     (CLS                : Checkpoint_Load_State'Class;
      CP_SFI             : in out Source_File_Index;
      Require_Valid_File : Boolean := True)
   is
   begin
      if CP_SFI /= No_Source_File then
         CP_SFI := CLS.SFI_Map (CP_SFI);
         pragma Assert
           (not Require_Valid_File or else CP_SFI /= No_Source_File);
      end if;
   end Remap_SFI;

end Checkpoints;
