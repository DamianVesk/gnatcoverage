------------------------------------------------------------------------------
--                                                                          --
--                              Couverture                                  --
--                                                                          --
--                     Copyright (C) 2008-2009, AdaCore                     --
--                                                                          --
-- Couverture is free software; you can redistribute it  and/or modify it   --
-- under terms of the GNU General Public License as published by the Free   --
-- Software Foundation; either version 2, or (at your option) any later     --
-- version.  Couverture is distributed in the hope that it will be useful,  --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHAN-  --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License  for more details. You  should  have  received a copy of the GNU --
-- General Public License  distributed with GNAT; see file COPYING. If not, --
-- write  to  the Free  Software  Foundation,  59 Temple Place - Suite 330, --
-- Boston, MA 02111-1307, USA.                                              --
--                                                                          --
------------------------------------------------------------------------------

with Ada.Text_IO;  use Ada.Text_IO;
with Interfaces;

with Elf_Disassemblers; use Elf_Disassemblers;
with Hex_Images;        use Hex_Images;
with Strings;           use Strings;
with Traces;            use Traces;
with Traces_Elf;        use Traces_Elf;
with Traces_Names;      use Traces_Names;

package body Decision_Map is

   procedure Analyze_Routine
     (Name : String_Acc;
      Info : in out Subprogram_Info);
   --  Build decision map for the given subprogram

   procedure Analyze_Conditional_Branch
     (Exe  : Exe_File_Acc;
      Insn : Binary_Content);
   --  Process one conditional branch instruction: identify relevant source
   --  coverable construct, and record association in the decision map.

   -------------
   -- Analyze --
   -------------

   procedure Analyze is
   begin
      Traces_Names.Iterate (Analyze_Routine'Access);
   end Analyze;

   --------------------------------
   -- Analyze_Conditional_Branch --
   --------------------------------

   procedure Analyze_Conditional_Branch
     (Exe  : Exe_File_Acc;
      Insn : Binary_Content)
   is
      Sloc : constant Addresses_Info_Acc :=
               Get_Address_Info (Exe.all, Line_Addresses, Insn'First);
      --  Source location of Insn
   begin
      if Sloc = null then
         --  No associated source, so no further processing required for source
         --  coverage analysis.

         return;
      end if;

      Put_Line ("conditional branch at " & Hex_Image (Insn'First)
                & " for sloc " & Image (Sloc));
   end Analyze_Conditional_Branch;

   ---------------------
   -- Analyze_Routine --
   ---------------------

   procedure Analyze_Routine
     (Name : String_Acc;
      Info : in out Subprogram_Info)
   is
      use type Interfaces.Unsigned_32;

      PC       : Pc_Type;
      Insn_Len : Natural;

      procedure Load_Symbol_Text
        (Name : String_Acc;
         Info : in out Subprogram_Info);
      --  Load subprogram object code

      ----------------------
      -- Load_Symbol_Text --
      ----------------------

      procedure Load_Symbol_Text
        (Name : String_Acc;
         Info : in out Subprogram_Info)
      is
         Sym : Addresses_Info_Acc renames Info.Sym;
      begin
         if Info.Insns /= null then
            raise Constraint_Error with
              "text of " & Name.all & " already set";
         end if;

         Load_Section_Content (Info.Exec.all, Sym.Parent);
         Info.Insns :=
           new Binary_Content'
             (Sym.Parent.Section_Content (Sym.First .. Sym.Last));
      end Load_Symbol_Text;

   --  Start of processing for Analyze_Routine

   begin
      Put_Line ("Building decision map for " & Name.all);

      Load_Symbol_Text (Name, Info);
      Build_Debug_Lines (Info.Exec.all);

      if Info.Insns = null then
         Put_Line ("No instructions for " & Name.all);
         return;
      end if;

      --  Iterate over instructions, looking for conditional branches

      PC := Info.Insns'First;
      while PC < Info.Insns'Last loop
         Insn_Len :=
           Disa_For_Machine (Machine).
             Get_Insn_Length (Info.Insns (PC .. Info.Insns'Last));

         declare
            Insn : Binary_Content renames
                     Info.Insns (PC .. PC + Pc_Type (Insn_Len) - 1);

            Branch     : Branch_Kind;
            Flag_Indir : Boolean;
            Flag_Cond  : Boolean;
            Dest       : Pc_Type;
            --  Properties of Insn

         begin
            Disa_For_Machine (Machine).Get_Insn_Properties
              (Insn_Bin   => Insn,
               Pc         => PC,
               Branch     => Branch,
               Flag_Indir => Flag_Indir,
               Flag_Cond  => Flag_Cond,
               Dest       => Dest);

            if Branch = Br_Jmp and then Flag_Cond then
               Analyze_Conditional_Branch (Info.Exec, Insn);
            end if;
         end;

         PC := PC + Pc_Type (Insn_Len);

         --  Handle case where PC wraps

         exit when PC = 0;
      end loop;
   end Analyze_Routine;

   --------------
   -- Dump_Map --
   --------------

   procedure Dump_Map is
   begin
      Put_Line ("Dump_Map: Not implemented");
   end Dump_Map;

end Decision_Map;
