------------------------------------------------------------------------------
--                                                                          --
--                              Couverture                                  --
--                                                                          --
--                        Copyright (C) 2009, AdaCore                       --
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

with Traces; use Traces;
with Ada.Containers; use Ada.Containers;

package body Execs_Dbase is

   Exec_Base        : aliased Execs_Maps.Map;
   Exec_Base_Handle : constant Exec_Base_Type := Exec_Base'Access;

   function Get_Exec_Base return Exec_Base_Type  is
   begin
      return Exec_Base_Handle;
   end Get_Exec_Base;

   function Equal (L, R : Exec_Base_Entry) return Boolean is
   begin
      return L.Elf_File_Name = R.Elf_File_Name;
   end Equal;

   procedure Open_Exec
     (Execs     : Exec_Base_Type;
      File_Name : String;
      Exec      : out Exe_File_Acc)
   is
      use Execs_Maps;
      Text_Start     : constant Pc_Type := 0;
      Exec_File_Name : String_Acc := new String'(File_Name);
      Base_Entry     : Exec_Base_Entry;
      Position       : constant Cursor := Find (Execs.all,
                                                Exec_File_Name);
   begin
      if Position /= No_Element then
         Exec := Element (Position).Exec;
         Unchecked_Deallocation (Exec_File_Name);
      else
         Exec := new Exe_File_Type;
         Base_Entry.Elf_File_Name := Exec_File_Name;
         Base_Entry.Exec := Exec;
         Open_File (Exec.all,
                    Exec_File_Name.all,
                    Text_Start);
         Insert (Execs.all, Exec_File_Name, Base_Entry);
      end if;
   end Open_Exec;

   procedure Insert_Exec
     (Execs     : Exec_Base_Type;
      File_Name : String)
   is
      Ignored_Exec : Exe_File_Acc;
      pragma Unreferenced (Ignored_Exec);
   begin
      Open_Exec (Execs, File_Name, Ignored_Exec);
   end Insert_Exec;

   procedure Build_Routines_Names (Execs : Exec_Base_Type) is
   begin
      --  If there is more than one exec in the base, return an error;
      --  otherwise, we may not know how to handle the ambiguities.
      --  We may want to be more subtle at some point; but for now
      --  it seems reasonable to refuse to deduce the function from
      --  several different exec files.
      if Execs_Maps.Length (Execs.all) /= 1 then
         raise Routine_Name_Ambiguity;
      end if;

      declare
         First      : constant Execs_Maps.Cursor
           := Execs_Maps.First (Execs.all);
         First_Exec : constant Exe_File_Acc
           := Execs_Maps.Element (First).Exec;
      begin
         Build_Routines_Name (First_Exec.all);
      end;
   end Build_Routines_Names;

   procedure Build_Elf (Execs : Exec_Base_Type) is
      use Execs_Maps;
      Position : Cursor := First (Execs.all);
      Exec     : Exe_File_Acc;
   begin
      while Position /= No_Element loop
         Exec := Element (Position).Exec;
         Build_Sections (Exec.all);
         Build_Symbols (Exec.all);
         Next (Position);
      end loop;
   end Build_Elf;

   procedure Build_Traces
     (Execs : Exec_Base_Type;
      Base  : in out Traces_Base)
   is
      use Execs_Maps;
      Position : Cursor := First (Execs.all);
      Exec     : Exe_File_Acc;
   begin
      while Position /= No_Element loop
         Exec := Element (Position).Exec;
         Set_Trace_State (Exec.all, Base);
         Add_Subprograms_Traces (Exec.all, Base);
         Next (Position);
      end loop;
   end Build_Traces;

   procedure Build_Debug
     (Execs : Exec_Base_Type;
      Base  : in out Traces_Base)
   is
      use Execs_Maps;
      Position : Cursor := First (Execs.all);
      Exec     : Exe_File_Acc;
   begin
      while Position /= No_Element loop
         Exec := Element (Position).Exec;
         --  ??? The build of the debug information should not be needed
         --  for every exec; only the ones for which we need to gather
         --  source information. The former can be much bigger than
         --  than the latter, so we'd rather avoid build the debug info
         --  for it if they are not useful.
         --  This means that this operation should probably not be done
         --  in execs_dbase, but in traces_names.
         Build_Debug_Lines (Exec.all);
         Build_Source_Lines (Exec.all, Base);
         Next (Position);
      end loop;
   end Build_Debug;

   function Deprecated_First_Exec
     (Execs : Exec_Base_Type)
     return Exe_File_Acc
   is
      First : constant Execs_Maps.Cursor := Execs_Maps.First (Execs.all);
   begin
      return Execs_Maps.Element (First).Exec;
   end Deprecated_First_Exec;

end Execs_Dbase;
