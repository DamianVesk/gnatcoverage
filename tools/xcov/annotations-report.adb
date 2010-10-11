------------------------------------------------------------------------------
--                                                                          --
--                              Couverture                                  --
--                                                                          --
--                     Copyright (C) 2008-2010, AdaCore                     --
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

with GNAT.Time_Stamp;
with Ada.Command_Line;
with Ada.Text_IO;  use Ada.Text_IO;

with Qemu_Traces;
with Traces_Files;
with Traces_Files_List;

with Coverage; use Coverage;
with Version;  use Version;
with Strings;  use Strings;

package body Annotations.Report is

   type Final_Report_Type is limited record
      --  Final report information

      Name   : String_Access := null;
      --  Final report's file name

      File   : aliased File_Type;
      --  Handle to the final report
   end record;

   Final_Report : aliased Final_Report_Type;

   procedure Open_Report_File (Final_Report_Name : String);
   --  Open Final_Report_Name and use it as the report file

   function Get_Output return File_Access;
   --  Return a handle to the current report file

   procedure Close_Report_File;
   --  Close the handle to the final report

   type Report_Pretty_Printer is new Pretty_Printer with record
      --  Pretty printer type for the final report

      Current_File_Index : Source_File_Index;
      --  When going through the lines of a source file,
      --  This is set to the current source file index.

      Error_Count : Natural := 0;
      --  Total number of errors in current section

      Current_Chapter : Natural := 0;
      --  Current chapter in final report

      Current_Section : Natural := 0;
      --  Current section in final report

      Exempted_Messages : Message_Vectors.Vector;
      --  Messages that have been covered by an exemption

      Exempted : Boolean := False;
      --  True if the current line is covered by an exemption
   end record;

   procedure Chapter
     (Pp    : in out Report_Pretty_Printer'Class;
      Title : String);
   --  Open a new chapter in final report

   procedure Section
     (Pp    : in out Report_Pretty_Printer'Class;
      Title : String);
   --  Open a new section in final report

   procedure End_Section (Pp : in out Report_Pretty_Printer'Class);
   --  Close the current section

   function Should_Be_Displayed (M : Message) return Boolean;
   --  Return True is M is serious enough to be included into the report

   procedure Put_Message
     (Pp : in out Report_Pretty_Printer'Class;
      M  : Message);
   --  Print M in the final report and update error count. The difference
   --  with Pretty_Print_Message is that Put_Message does not tries to
   --  know if the message should be exempted or not, and do not modify
   --  the Exempted_Messages buffer.

   --------------------------------------------------
   -- Report_Pretty_Printer's primitive operations --
   --      (inherited from Pretty_Printer)         --
   --------------------------------------------------

   procedure Pretty_Print_Start (Pp : in out Report_Pretty_Printer);

   procedure Pretty_Print_End (Pp : in out Report_Pretty_Printer);

   procedure Pretty_Print_Start_File
     (Pp   : in out Report_Pretty_Printer;
      File : Source_File_Index;
      Skip : out Boolean);

   procedure Pretty_Print_Start_Line
     (Pp : in out Report_Pretty_Printer;
      Line_Num : Natural;
      Info     : Line_Info_Access;
      Line : String);

   procedure Pretty_Print_End_File
     (Pp : in out Report_Pretty_Printer);

   procedure Pretty_Print_Message
     (Pp : in out Report_Pretty_Printer;
      M  : Message);

   -------------
   -- Chapter --
   -------------

   procedure Chapter
     (Pp    : in out Report_Pretty_Printer'Class;
      Title : String)
   is
      Output : constant File_Access := Get_Output;
   begin
      Pp.Current_Chapter := Pp.Current_Chapter + 1;
      Put_Line (Output.all, Img (Pp.Current_Chapter) & ". " & Title);
      New_Line (Output.all);
   end Chapter;

   -----------------------
   -- Close_Report_File --
   -----------------------

   procedure Close_Report_File is
   begin
      if Final_Report.Name /= null then
         Close (Final_Report.File);
         Free (Final_Report.Name);
      end if;
   end Close_Report_File;

   -----------------
   -- End_Section --
   -----------------

   procedure End_Section (Pp : in out Report_Pretty_Printer'Class) is
      Output : constant File_Access := Get_Output;
   begin
      if Pp.Error_Count = 0 then
         Put_Line (Output.all, "no error.");
      elsif Pp.Error_Count = 1 then
         Put_Line (Output.all, "1 error.");
      else
         Put_Line (Output.all, Img (Pp.Error_Count) & " errors");
      end if;

      New_Line (Output.all);
      Pp.Error_Count := 0;
   end End_Section;

   ---------------------
   -- Generate_Report --
   ---------------------

   procedure Generate_Report (Final_Report_Name : String_Access) is
      Report_PP : Report_Pretty_Printer;
   begin
      if Final_Report_Name /= null then
         Open_Report_File (Final_Report_Name.all);
      end if;

      Annotations.Generate_Report (Report_PP, True);
      Close_Report_File;
   end Generate_Report;

   ----------------
   -- Get_Output --
   ----------------

   function Get_Output return File_Access is
   begin
      if Final_Report.Name /= null then
         return Final_Report.File'Access;
      else
         return Standard_Output;
      end if;
   end Get_Output;

   ----------------------
   -- Open_Report_File --
   ----------------------

   procedure Open_Report_File (Final_Report_Name : String) is
   begin
      Final_Report.Name := new String'(Final_Report_Name);
      Create (Final_Report.File, Out_File, Final_Report_Name);
   end Open_Report_File;

   ----------------------
   -- Pretty_Print_End --
   ----------------------

   procedure Pretty_Print_End (Pp : in out Report_Pretty_Printer) is
      use Diagnostics.Message_Vectors;

      Output : constant File_Access := Get_Output;

      procedure Process_One_Message (Position : Cursor);
      --  Let Pp print message at Position

      -------------------------
      -- Process_One_Message --
      -------------------------

      procedure Process_One_Message (Position : Cursor) is
         M : constant Message := Element (Position);
      begin
         Put_Message (Pp, M);
      end Process_One_Message;

   --  Start of processing for Pretty_Print_End

   begin
      Pp.End_Section;

      Pp.Section ("EXEMPTED VIOLATIONS");
      Pp.Exempted_Messages.Iterate (Process_One_Message'Access);
      Pp.End_Section;

      Put_Line (Output.all, "END OF REPORT");
   end Pretty_Print_End;

   ---------------------------
   -- Pretty_Print_End_File --
   ---------------------------

   procedure Pretty_Print_End_File (Pp : in out Report_Pretty_Printer) is
   begin
      null;
   end Pretty_Print_End_File;

   -----------------
   -- Put_Message --
   -----------------

   procedure Put_Message
     (Pp : in out Report_Pretty_Printer'Class;
      M  : Message)
   is
      Output : constant File_Access := Get_Output;
   begin
      if M.SCO /= No_SCO_Id then
         Put (Output.all, Image (First_Sloc (M.SCO)));
         Put (Output.all, ": ");
         Put (Output.all, SCO_Kind'Image (Kind (M.SCO)) & ": ");
      else
         Put (Output.all, Image (M.Sloc));
         Put (Output.all, ": ");
      end if;

      Put (Output.all, M.Msg.all);
      Pp.Error_Count := Pp.Error_Count + 1;
      New_Line (Output.all);
   end Put_Message;

   --------------------------
   -- Pretty_Print_Message --
   --------------------------

   procedure Pretty_Print_Message
     (Pp : in out Report_Pretty_Printer;
      M  : Message) is
   begin
      if Should_Be_Displayed (M) then
         if Pp.Exempted then
            Pp.Exempted_Messages.Append (M);
         else
            Pp.Put_Message (M);
         end if;
      end if;
   end Pretty_Print_Message;

   ------------------------
   -- Pretty_Print_Start --
   ------------------------

   procedure Pretty_Print_Start (Pp : in out Report_Pretty_Printer) is
      use Ada.Command_Line;
      use Qemu_Traces;
      use Traces_Files;
      use Traces_Files_List;
      use Traces_Files_Lists;

      Output : constant File_Access := Get_Output;

      procedure Display_Trace_File_Info (Position : Cursor);
      --  Print info from trace file at Position

      -----------------------------
      -- Display_Trace_File_Info --
      -----------------------------

      procedure Display_Trace_File_Info (Position : Cursor) is
         E : constant Trace_File_Element_Acc := Element (Position);
      begin
         Put_Line (Output.all, " " & E.Filename.all);
         Put_Line (Output.all, "  program: "
                   & Get_Info (E.Trace, Exec_File_Name));
         Put_Line (Output.all, "  date: "
                   & Format_Date_Info (Get_Info (E.Trace, Date_Time)));
         Put_Line (Output.all, "  tag: " & Get_Info (E.Trace, User_Data));
         New_Line (Output.all);
      end Display_Trace_File_Info;

   --  Start of processing for Pretty_Print_Start

   begin
      Put_Line (Output.all, "COVERAGE REPORT");
      New_Line (Output.all);

      Pp.Chapter ("OVERVIEW");

      Put_Line (Output.all, "Date and time of execution: "
                & GNAT.Time_Stamp.Current_Time);
      Put_Line (Output.all, "Tool version: XCOV " & Xcov_Version);
      New_Line (Output.all);

      Put_Line (Output.all, "Command line:");
      New_Line (Output.all);
      Put (Output.all, Command_Name);
      for J in 1 .. Argument_Count loop
         Put (Output.all, ' ' & Argument (J));
      end loop;
      New_Line (Output.all, 2);

      Put_Line (Output.all, "Coverage level: " & Coverage_Option_Value);
      New_Line (Output.all);

      Put_Line (Output.all, "trace files:");
      New_Line (Output.all);
      Files.Iterate (Display_Trace_File_Info'Access);

      Pp.Chapter ("DETECTED VIOLATIONS");
      Pp.Section ("NON-EXEMPTED VIOLATIONS");
   end Pretty_Print_Start;

   -----------------------------
   -- Pretty_Print_Start_File --
   -----------------------------

   procedure Pretty_Print_Start_File
     (Pp   : in out Report_Pretty_Printer;
      File : Source_File_Index;
      Skip : out Boolean)
   is
      Info : constant File_Info_Access := Get_File (File);
      P    : constant Counters := Get_Counters (Info.Stats);
   begin
      if P.Fully /= P.Total then
         Pp.Current_File_Index := File;
         Skip := False;
      else
         Skip := True;
      end if;
   end Pretty_Print_Start_File;

   -----------------------------
   -- Pretty_Print_Start_Line --
   -----------------------------

   procedure Pretty_Print_Start_Line
     (Pp       : in out Report_Pretty_Printer;
      Line_Num : Natural;
      Info     : Line_Info_Access;
      Line     : String)
   is
      pragma Unreferenced (Line);

      function Already_Reported (Level : Coverage_Level) return Boolean;
      --  Return True if all errors for Level on this line have already
      --  been reported on previous lines

      function Default_Message
        (Level : Coverage_Level;
         State : Line_State) return Message;
      --  Return the default error message for the given coverage level
      --  and the given line state

      function Has_Messages (MV : Message_Vectors.Vector) return Boolean;
      --  Return True iff MV contains messages that are serious enough to
      --  be included into the report

      ----------------------
      -- Already_Reported --
      ----------------------

      function Already_Reported (Level : Coverage_Level) return Boolean is
         use SCO_Id_Vectors;

         Position : Cursor;
         SCO      : SCO_Id;
      begin
         case Level is
            when Insn | Branch =>
               return False;

            when Stmt | Decision | MCDC =>
               --  False if there is a statement or a decision whose first
               --  sloc is the current line

               Position := Info.SCOs.First;
               while Position /= No_Element loop
                  SCO := Element (Position);

                  if First_Sloc (SCO).Line = Line_Num then
                     return False;
                  end if;

                  Next (Position);
               end loop;
               return True;

         end case;
      end Already_Reported;

      ---------------------
      -- Default_Message --
      ---------------------

      function Default_Message
        (Level : Coverage_Level;
         State : Line_State) return Message
      is
         Sloc   : constant Source_Location := (Pp.Current_File_Index,
                                               Line_Num, 0);
         Msg    : String_Access;
      begin
         if Level = Stmt then
            Msg := new String'("statement not covered");
         else
            Msg := new String'("line " & State'Img
                               & " for " & Level'Img & " coverage");
         end if;

         return Message'(Kind => Diagnostics.Error,
                         PC   => No_PC,
                         Sloc => Sloc,
                         SCO  => No_SCO_Id,
                         Msg  => Msg);
      end Default_Message;

      ------------------
      -- Has_Messages --
      ------------------

      function Has_Messages (MV : Message_Vectors.Vector) return Boolean is
         use Message_Vectors;

         Position : Cursor := First (MV);
         M        : Message;
      begin
         while Position /= No_Element loop
            M := Element (Position);

            if Should_Be_Displayed (M) then
               return True;
            end if;

            Next (Position);
         end loop;

         return False;
      end Has_Messages;

      --  Local variables

      M      : Message;

   --  Start of processing for Pretty_Print_Start_Line

   begin
      Pp.Exempted := Info.Exempted;

      --  When two coverage criteria are not met on the same line, only
      --  report errors for the "lowest" one. For example, if a decision is
      --  not covered for stmt coverage, it will certainly not be covered
      --  for decision coverage or MCDC; but report only the stmt coverage
      --  error.

      --  If error/warning messages have been attached to the line, they
      --  will be printed in the report; otherwise, fall back to a
      --  general error message.

      for Level in Coverage_Level loop
         if Info.State (Level) /= Covered
           and then Info.State (Level) /= No_Code
         then
            if not Has_Messages (Info.Messages)
              and then not Already_Reported (Level)
            then
               M := Default_Message (Level, Info.State (Level));

               if not Info.Exempted then
                  Pp.Put_Message (M);
               else
                  Pp.Exempted_Messages.Append (M);
               end if;
            end if;

            exit;
         end if;
      end loop;
   end Pretty_Print_Start_Line;

   -------------
   -- Section --
   -------------

   procedure Section
     (Pp    : in out Report_Pretty_Printer'Class;
      Title : String)
   is
      Output : constant File_Access := Get_Output;
   begin
      Pp.Current_Section := Pp.Current_Section + 1;
      Put_Line (Output.all,
                Img (Pp.Current_Chapter) & "."
                & Img (Pp.Current_Section) & ". "
                & Title);
      New_Line (Output.all);
   end Section;

   -------------------------
   -- Should_Be_Displayed --
   -------------------------

   function Should_Be_Displayed (M : Message) return Boolean is
   begin
      return M.Kind /= Notice;
   end Should_Be_Displayed;

end Annotations.Report;
