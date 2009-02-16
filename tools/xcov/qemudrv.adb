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

with Ada.Text_IO; use Ada.Text_IO;
with Ada.Command_Line; use Ada.Command_Line;
with GNAT.Command_Line; use GNAT.Command_Line;
--  with GNAT.Strings; use GNAT.Strings;
with GNAT.OS_Lib; use GNAT.OS_Lib;
with Traces_Files; use Traces_Files;
with Qemu_Traces;
with Qemudrv_Base; use Qemudrv_Base;

package body Qemudrv is

   Progname : String_Access;
   --  Name of the program.  Used in error messages.

   --  Variables set by the command line.

   Target : String_Access := new String'("powerpc-elf");
   --  Target to use (AdaCore name).

   Output : String_Access;
   --  Trace output filename.

   Verbose : Boolean := False;
   --  Verbose (display more messages).

   Exe_File : String_Access;
   --  Executable to run.

   Getopt_Switches : constant String :=
     "v -verbose t: -target= o: -output= h -help -tag= -T:";
   --  String for Getopt.

   Tag : String_Access;
   --  Tag to write in the trace file.

   procedure Error (Msg : String);
   --  Display the message on the error output and set exit status.

   procedure Error (Msg : String) is
   begin
      Put_Line (Standard_Error, Msg);
      Set_Exit_Status (Failure);
   end Error;

   procedure Help (Indent : String := "") is
   begin
      if not Is_Xcov then
         Put ("Usage: " & Progname.all);
      else
         Put (Indent & "--run");
      end if;
      Put_Line (" [OPTIONS] FILE");
      Put_Line (Indent & "  Options are:");
      Put_Line (Indent & "  -t TARGET  --target=TARGET   Set the target");
   end Help;

   procedure Driver (First_Option : Natural := 1)
   is
      Arg_Count : constant Natural := Argument_Count;

      Parser : Opt_Parser;
      Args : constant String_List_Access :=
        new String_List (1 .. Arg_Count - First_Option + 1);

      S : Character;
   begin
      --  Set progname.
      if Is_Xcov then
         Progname := new String'(Command_Name & " --run");
      else
         Progname := new String'(Command_Name);
      end if;

      --  Build the command line.
      for I in First_Option .. Arg_Count loop
         Args (1 + I - First_Option) := new String'(Argument (I));
      end loop;

      --  And decode it.
      Initialize_Option_Scan (Parser, Args);
      loop
         S := Getopt (Getopt_Switches, False, Parser);
         exit when S = ASCII.NUL;

         if S = 'v'
           or else (S = '-' and then Full_Switch (Parser) = "-verbose")
         then
            Verbose := True;
         elsif S = 't'
           or else (S = '-' and then Full_Switch (Parser) = "-target")
         then
            Target := new String'(Parameter (Parser));
         elsif S = 'o'
           or else (S = '-' and then Full_Switch (Parser) = "-output")
         then
            Output := new String'(Parameter (Parser));
         elsif S = 'T'
           or else (S = '-' and then Full_Switch (Parser) = "-tag")
         then
            Tag := new String'(Parameter (Parser));
         elsif S = 'h'
           or else (S = '-' and then Full_Switch (Parser) = "-help")
         then
            Help;
            return;
         else
            raise Program_Error;
         end if;
      end loop;

      --  Exe file.
      declare
         S : constant String := Get_Argument (False, Parser);
      begin
         if S'Length = 0 then
            Error ("missing exe file to " & Progname.all);
            return;
         end if;
         Exe_File := new String'(S);
      end;

      --  Check for no extra arguments.
      declare
         S : constant String := Get_Argument (False, Parser);
      begin
         if S'Length /= 0 then
            Error ("too many arguments for " & Progname.all);
            return;
         end if;
      end;

      Free (Parser);

      if Output = null then
         Output := new String'(Exe_File.all & ".trace");
      end if;

      --  Write the tag.
      if Tag /= null then
         declare
            Trace_File : Trace_File_Type;
         begin
            Create_Trace_File (Trace_File);
            Append_Info (Trace_File,
                         Qemu_Traces.Info_Kind_User_Tag, Tag.all);
            Write_Trace_File (Output.all, Trace_File);
            Free (Trace_File);
         end;
      end if;

      --  Search for the driver.
      for I in Drivers'Range loop
         if Drivers (I).Target.all = Target.all then
            declare
               L : constant Natural := Drivers (I).Options'Length;
               Args : String_List (1 .. L + 2);
               Success : Boolean;
               Prg : String_Access;
            begin
               --  Find executable.
               Prg := Locate_Exec_On_Path (Drivers (I).Command.all);
               if Prg = null then
                  Error (Progname.all & ": cannot find "
                           & Drivers (I).Command.all
                           & " on your path");
                  return;
               end if;

               --  Copy arguments and replace meta-one.
               Args (1 .. L) := Drivers (I).Options.all;
               for J in 1 .. L loop
                  if Args (J).all = "$exe" then
                     Args (J) := Exe_File;
                  end if;
               end loop;
               Args (L + 1) := new String'("-trace");
               Args (L + 2) := Output;

               if Verbose then
                  Put ("exec: ");
                  Put (Prg.all);
                  for I in Args'Range loop
                     Put (' ');
                     Put (Args (I).all);
                  end loop;
                  New_Line;
               end if;

               --  Run.
               Spawn (Prg.all, Args, Success);
               return;
            end;
         end if;
      end loop;

      Error (Progname.all & ": unknown target " & Target.all);
      Put_Line ("Knwon targets are:");
      for I in Drivers'Range loop
         Put (' ');
         Put (Drivers (I).Target.all);
      end loop;
      New_Line;
   exception
      when Invalid_Switch =>
         Error (Progname.all
                  & ": invalid switch " & Full_Switch (Parser));
         return;
      when Invalid_Parameter =>
         Error (Progname.all
                  & ": missing parameter for " & Full_Switch (Parser));
         return;
   end Driver;
end Qemudrv;
