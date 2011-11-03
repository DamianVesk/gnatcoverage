------------------------------------------------------------------------------
--                                                                          --
--                              Couverture                                  --
--                                                                          --
--                     Copyright (C) 2008-2011, AdaCore                     --
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

with Ada.Containers.Hashed_Maps;
with Ada.Characters.Handling;
with Ada.Directories;

with Strings; use Strings;
with Outputs;

package body Files_Table is

   subtype Valid_Source_File_Index is
     Source_File_Index range First_Source_File .. Source_File_Index'Last;
   package File_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Valid_Source_File_Index,
      Element_Type => File_Info_Access);

   Files_Table : File_Vectors.Vector;

   procedure Expand_Line_Table (FI : File_Info_Access; Line : Positive);
   procedure Expand_Line_Table (File : Source_File_Index; Line : Positive);
   --  If Line is not in File's line table, expand this table and mark the new
   --  line as No_Code.

   package Filename_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => String_Access,
      Element_Type    => Source_File_Index,
      Hash            => Hash,
      Equivalent_Keys => Equal,
      "="             => "=");

   Simple_Name_Map : Filename_Maps.Map;
   Full_Name_Map : Filename_Maps.Map;

   Current_File_Line_Cache : File_Info_Access := null;
   --  Current file whose lines are cached in the file table. There is
   --  only one entry in the cache for now, which is reasonable for the
   --  use that we make: the line content is mostly needed by package
   --  Annotations, which only manipulates one source file at a time.

   --  Source rebase/search types

   type Source_Search_Entry;
   type Source_Search_Entry_Acc is access Source_Search_Entry;
   type Source_Search_Entry is record
      Prefix : String_Access;
      Next : Source_Search_Entry_Acc;
   end record;

   type Source_Rebase_Entry;
   type Source_Rebase_Entry_Acc is access Source_Rebase_Entry;
   type Source_Rebase_Entry is record
      Old_Prefix : String_Access;
      New_Prefix : String_Access;
      Next : Source_Rebase_Entry_Acc;
   end record;

   First_Source_Rebase_Entry : Source_Rebase_Entry_Acc := null;
   Last_Source_Rebase_Entry  : Source_Rebase_Entry_Acc := null;

   First_Source_Search_Entry : Source_Search_Entry_Acc := null;
   Last_Source_Search_Entry  : Source_Search_Entry_Acc := null;

   ----------------------------------
   -- Add_Line_For_Object_Coverage --
   ----------------------------------

   procedure Add_Line_For_Object_Coverage
     (File  : Source_File_Index;
      State : Line_State;
      Line  : Positive;
      Addrs : Addresses_Info_Acc;
      Base  : Traces_Base_Acc;
      Exec  : Exe_File_Acc)
   is
      FI   : constant File_Info_Access := Files_Table.Element (File);
      LI   : Line_Info_Access;
      Info : constant Object_Coverage_Info_Acc :=
               new Object_Coverage_Info'(State           => State,
                                         Instruction_Set => Addrs,
                                         Base            => Base,
                                         Exec            => Exec,
                                         Next            => null);

   begin
      FI.Has_Object_Coverage_Info := True;
      Expand_Line_Table (File, Line);
      LI := FI.Lines.Element (Line);

      if LI.Obj_First = null then
         LI.Obj_First := Info;
      else
         LI.Obj_Last.Next := Info;
      end if;

      LI.Obj_Last := Info;
   end Add_Line_For_Object_Coverage;

   ----------------------------------
   -- Add_Line_For_Source_Coverage --
   ----------------------------------

   procedure Add_Line_For_Source_Coverage
     (File : Source_File_Index;
      Line : Positive;
      SCO  : SCO_Id)
   is
      FI : constant File_Info_Access := Files_Table.Element (File);
   begin
      FI.Has_Source_Coverage_Info := True;
      Expand_Line_Table (File, Line);
      FI.Lines.Element (Line).all.SCOs.Append (SCO);
   end Add_Line_For_Source_Coverage;

   -----------------------
   -- Add_Source_Rebase --
   -----------------------

   procedure Add_Source_Rebase (Old_Prefix : String; New_Prefix : String) is
      E : Source_Rebase_Entry_Acc;
   begin
      E := new Source_Rebase_Entry'(Old_Prefix => new String'(Old_Prefix),
                                    New_Prefix => new String'(New_Prefix),
                                    Next => null);

      if First_Source_Rebase_Entry = null then
         First_Source_Rebase_Entry := E;
      else
         Last_Source_Rebase_Entry.Next := E;
      end if;

      Last_Source_Rebase_Entry := E;
   end Add_Source_Rebase;

   -----------------------
   -- Add_Source_Search --
   -----------------------

   procedure Add_Source_Search (Prefix : String)
   is
      E : Source_Search_Entry_Acc;
   begin
      E := new Source_Search_Entry'(Prefix => new String'(Prefix),
                                    Next => null);

      if First_Source_Search_Entry = null then
         First_Source_Search_Entry := E;
      else
         Last_Source_Search_Entry.Next := E;
      end if;

      Last_Source_Search_Entry := E;
   end Add_Source_Search;

   ---------------------
   -- End_Lex_Element --
   ---------------------

   function End_Lex_Element (Sloc : Source_Location) return Source_Location
   is
      use Ada.Characters.Handling;

      type Lex_Type is (String_Literal, Numeric_Literal, Other);

      Lex    : Lex_Type;
      Line   : constant String := Get_Line (Sloc);
      Column : Natural := Sloc.Column;
      Result : Source_Location := Sloc;
   begin

      --  If the column is out of range, the source files and the sloc
      --  information are probably not synchronized. So just return Sloc
      --  unchanged.

      if Column > Line'Last then
         return Sloc;
      end if;

      if Column + 1 <= Line'Last
        and then Line (Column) = '-'
        and then Line (Column + 1) = '-'
      then
         --  Comment; return the whole line
         Result.Column := Line'Last;
         return Result;

      elsif Column + 2 <= Line'Last
        and then Line (Column) = '''
        and then Line (Column + 2) = '''
      then
         --  Character literal; skip two character and return
         Result.Column := Column + 2;
         return Result;

      elsif Line (Column) = '"' then
         --  String literal
         Lex := String_Literal;

      elsif Is_Decimal_Digit (Line (Column))
        or else Line (Column) = '-'
      then
         --  Numeric literal
         Lex := Numeric_Literal;

      else
         --  Other: identifier, pragma, reserved word
         Lex := Other;
      end if;

      for J in Sloc.Column + 1 .. Line'Last loop
         case Lex is
            when String_Literal =>
               exit when Line (J) = '"';

            when Numeric_Literal =>
               exit when not Is_Decimal_Digit (Line (J))
                 and then Line (J) /= '#'
                 and then Line (J) /= 'E'
                 and then Line (J) /= '.'
                 and then Line (J) /= '_';

            when Other =>
               exit when not Is_Alphanumeric (Line (J))
                 and then Line (J) /= '_';

         end case;
         Column := J;
      end loop;

      Result.Column := Natural'Min (Column, Line'Last);
      return Result;
   end End_Lex_Element;

   -----------------------
   -- Expand_Line_Table --
   -----------------------

   procedure Expand_Line_Table (FI : File_Info_Access; Line : Positive) is
   begin
      while FI.Lines.Last_Index < Line loop
         FI.Lines.Append
           (new Line_Info'(State => (others => No_Code), others => <>));
      end loop;
   end Expand_Line_Table;

   procedure Expand_Line_Table (File : Source_File_Index; Line : Positive) is
      FI : File_Info_Access renames Files_Table.Element (File);
   begin
      Expand_Line_Table (FI, Line);
   end Expand_Line_Table;

   --------------------------
   --  Files_Table_Iterate --
   --------------------------

   procedure Files_Table_Iterate
     (Process : not null access procedure (Index : Source_File_Index)) is
   begin
      for Index in Files_Table.First_Index .. Files_Table.Last_Index loop
         Process (Index);
      end loop;
   end Files_Table_Iterate;

   ---------------------
   -- Fill_Line_Cache --
   ---------------------

   procedure Fill_Line_Cache (FI : File_Info_Access) is

      F          : File_Type;
      Has_Source : Boolean;
      Line       : Natural := 1;
      LI         : Line_Info_Access;

      --  Start of processing for Cache_Lines

   begin
      if FI = Current_File_Line_Cache then
         return;
      end if;

      Open (F, FI, Has_Source);

      if Has_Source then
         if Current_File_Line_Cache /= null then
            Invalidate_Line_Cache (Current_File_Line_Cache);
         end if;

         while not End_Of_File (F) loop
            Expand_Line_Table (FI, Line);
            LI := FI.Lines.Element (Line);

            if LI.Line_Cache /= null then
               Free (LI.Line_Cache);
            end if;

            LI.Line_Cache := new String'(Get_Line (F));
            Line := Line + 1;
         end loop;

         Current_File_Line_Cache := FI;
         Close (F);
      end if;
   end Fill_Line_Cache;

   --------------
   -- Get_File --
   --------------

   function Get_File (Index : Source_File_Index) return File_Info_Access is
   begin
      return Files_Table.Element (Index);
   end Get_File;

   -------------------
   -- Get_Full_Name --
   -------------------

   function Get_Full_Name (Index : Source_File_Index) return String is
      Full_Name : constant String_Access :=
        Files_Table.Element (Index).Full_Name;
   begin
      if Full_Name /= null then
         return Full_Name.all;
      else
         Outputs.Fatal_Error ("No full path name for "
                              & Files_Table.Element (Index).Simple_Name.all);
         return "";
      end if;
   end Get_Full_Name;

   ------------------------------
   -- Get_Index_From_Full_Name --
   ------------------------------

   function Get_Index_From_Full_Name
     (Full_Name : String;
      Insert    : Boolean := True) return Source_File_Index
   is
      use Filename_Maps;

      Cur  : Cursor;
      Res  : Source_File_Index;
      Info : File_Info_Access;
      Info_Simple : File_Info_Access;
   begin
      Cur := Full_Name_Map.Find (Full_Name'Unrestricted_Access);

      if Cur /= No_Element then
         Res := Element (Cur);
         return Res;
      end if;

      --  Here if full name not found, try again with simple name

      declare
         Simple_Name : constant String :=
                         Ada.Directories.Simple_Name (Full_Name);
      begin
         Cur := Simple_Name_Map.Find (Simple_Name'Unrestricted_Access);

         if Cur /= No_Element then
            Res := Element (Cur);
            Info_Simple := Files_Table.Element (Res);

            if Info_Simple.Full_Name = null then
               Info_Simple.Full_Name := new String'(Full_Name);
               Full_Name_Map.Insert (Info_Simple.Full_Name, Res);
               return Res;
            else
               if Info_Simple.Full_Name.all /= Full_Name then
                  Put_Line ("Warning: same base name for files:");
                  Put_Line ("  " & Full_Name);
                  Put_Line ("  " & Info_Simple.Full_Name.all);
               end if;
            end if;

         --  Here if not found by simple name, either

         elsif not Insert then
            return No_Source_File;

         else
            Info_Simple := null;
         end if;

         Info := new File_Info'
           (Full_Name                => new String'(Full_Name),
            Simple_Name              => new String'(Simple_Name),
            Has_Source               => True,
            Alias_Num                => 0,
            Lines                    => (Source_Line_Vectors.Empty_Vector
                                           with null record),
            Stats                    => (others => 0),
            Has_Source_Coverage_Info => False,
            Has_Object_Coverage_Info => False);

         Files_Table.Append (Info);
         Res := Files_Table.Last_Index;

         if Info_Simple = null then
            Simple_Name_Map.Insert (Info.Simple_Name, Res);
         else
            --  Set Alias_Num.
            --  The entry in Simple_Name_Map has always the highest index.

            if Info_Simple.Alias_Num = 0 then
               Info.Alias_Num := 1;
            else
               Info.Alias_Num := Info_Simple.Alias_Num;
            end if;

            Info_Simple.Alias_Num := Info.Alias_Num + 1;
         end if;

         Full_Name_Map.Insert (Info.Full_Name, Res);

         return Res;
      end;
   end Get_Index_From_Full_Name;

   --------------------------------
   -- Get_Index_From_Simple_Name --
   --------------------------------

   function Get_Index_From_Simple_Name
     (Simple_Name : String;
      Insert      : Boolean := True) return Source_File_Index
   is
      use Filename_Maps;

      Cur  : constant Cursor :=
               Simple_Name_Map.Find (Simple_Name'Unrestricted_Access);
      Res  : Source_File_Index;
      Info : File_Info_Access;
   begin
      if Cur /= No_Element then
         return Element (Cur);
      end if;

      if not Insert then
         return No_Source_File;
      end if;

      Info := new File_Info'(Simple_Name => new String'(Simple_Name),
                             Full_Name  => null,
                             Has_Source => True,
                             Alias_Num  => 0,
                             Lines      => (Source_Line_Vectors.Empty_Vector
                                              with null record),
                             Stats      => (others => 0),
                             Has_Source_Coverage_Info => False,
                             Has_Object_Coverage_Info => False);

      Files_Table.Append (Info);
      Res := Files_Table.Last_Index;
      Simple_Name_Map.Insert (Info.Simple_Name, Res);

      return Res;
   end Get_Index_From_Simple_Name;

   --------------
   -- Get_Line --
   --------------

   function Get_Line (Sloc : Source_Location) return Line_Info_Access is
   begin
      if Sloc = Slocs.No_Location then
         return null;
      end if;

      return Get_Line (Get_File (Sloc.Source_File), Sloc.Line);
   end Get_Line;

   function Get_Line
     (File  : File_Info_Access;
      Index : Positive) return Line_Info_Access
   is
   begin
      if Index in File.Lines.First_Index .. File.Lines.Last_Index then
         return File.Lines.Element (Index);
      else
         --  Get_Line may be called with no source information loaded, for
         --  example when emitting a diagnostic with sloc information based on
         --  SCOs only. In that case return a null pointer, since we do not
         --  have any available Line_Info structure.

         return null;
      end if;
   end Get_Line;

   function Get_Line (Sloc : Source_Location) return String is
   begin
      if Sloc = Slocs.No_Location then
         return "";
      end if;

      return Get_Line (Get_File (Sloc.Source_File), Sloc.Line);
   end Get_Line;

   function Get_Line
     (File  : File_Info_Access;
      Index : Positive) return String
   is
      Line : String_Access;
   begin
      if not File.Has_Source then
         return "";
      end if;

      Fill_Line_Cache (File);

      if Index in File.Lines.First_Index .. File.Lines.Last_Index then
         Line := File.Lines.Element (Index).Line_Cache;

         if Line /= null then
            return Line.all;
         else
            return "";
         end if;

      else
         return "";
      end if;
   end Get_Line;

   ---------------------
   -- Get_Simple_Name --
   ---------------------

   function Get_Simple_Name (Index : Source_File_Index) return String is
   begin
      return Files_Table.Element (Index).Simple_Name.all;
   end Get_Simple_Name;

   ---------------------------
   -- Invalidate_Line_Cache --
   ---------------------------

   procedure Invalidate_Line_Cache (FI : File_Info_Access) is

      procedure Free_Line_Cache (Index : Positive);
      --  Free cached line in FI at Index

      ----------------------
      -- Free_Cached_Line --
      ----------------------

      procedure Free_Line_Cache (Index : Positive) is
         LI : constant Line_Info_Access := Get_Line (FI, Index);
      begin
         if LI = null then
            return;
         end if;

         if LI.Line_Cache /= null then
            Free (LI.Line_Cache);
         end if;
      end Free_Line_Cache;

      --  Start of processing for Free_Line_Cache

   begin
      Iterate_On_Lines (FI, Free_Line_Cache'Access);
   end Invalidate_Line_Cache;

   ----------------------
   -- Iterate_On_Lines --
   ----------------------

   procedure Iterate_On_Lines
     (File    : File_Info_Access;
      Process : not null access procedure (Index : Positive)) is
   begin
      for Index in File.Lines.First_Index .. File.Lines.Last_Index loop
         Process (Index);
      end loop;
   end Iterate_On_Lines;

   ----------
   -- Open --
   ----------

   procedure Open
     (File    : in out File_Type;
      FI      : File_Info_Access;
      Success : out Boolean)
   is

      procedure Try_Open
        (File    : in out File_Type;
         Name    : String;
         Success : out Boolean);
      --  Try to open Name, with no rebase/search information. If it fails,
      --  set Success to False; otherwise, set it to True and return the
      --  handle in File.

      --------------
      -- Try_Open --
      --------------

      procedure Try_Open
        (File    : in out File_Type;
         Name    : String;
         Success : out Boolean) is
      begin
         Open (File, In_File, Name);
         Success := True;
      exception
         when Name_Error | Use_Error =>
            Success := False;
      end Try_Open;

      --  Local variables

      Name : String_Access;

      --  Start of processing for Open

   begin
      if not FI.Has_Source then
         Success := False;
         return;
      end if;

      Name := FI.Full_Name;

      if Name = null then
         Name := FI.Simple_Name;
      end if;

      --  Try original path

      Try_Open (File, Name.all, Success);

      --  Try to rebase

      if not Success then
         declare
            E : Source_Rebase_Entry_Acc := First_Source_Rebase_Entry;
            First : constant Positive := Name'First;
         begin
            while E /= null loop
               if Name'Length > E.Old_Prefix'Length
                 and then (Name (First .. First + E.Old_Prefix'Length - 1)
                           = E.Old_Prefix.all)
               then
                  Try_Open (File,
                            E.New_Prefix.all
                            & Name (First + E.Old_Prefix'Length
                                    .. Name'Last),
                            Success);
                  exit when Success;
               end if;

               E := E.Next;
            end loop;
         end;
      end if;

      --  Try source path

      if not Success then
         declare
            E : Source_Search_Entry_Acc := First_Source_Search_Entry;
         begin
            while E /= null loop
               Try_Open (File, E.Prefix.all & '/' & FI.Simple_Name.all,
                         Success);

               if Success then
                  FI.Full_Name :=
                    new String'(E.Prefix.all & '/' & FI.Simple_Name.all);
                  exit;
               end if;

               E := E.Next;
            end loop;
         end;
      end if;

      FI.Has_Source := Success;
   end Open;

   ----------------
   -- To_Display --
   ----------------

   function To_Display (File : File_Info_Access) return Boolean is
   begin
      if Object_Coverage_Enabled then
         return File.Has_Object_Coverage_Info;
      else
         return File.Has_Source_Coverage_Info;
      end if;
   end To_Display;

   -----------------------
   -- Warn_File_Missing --
   -----------------------

   procedure Warn_File_Missing (File : File_Info) is
   begin
      if File.Full_Name /= null then
         Outputs.Warn ("can't open " & File.Full_Name.all);
      else
         Outputs.Warn ("can't find " & File.Simple_Name.all
                       & " in source path");
      end if;
   end Warn_File_Missing;

end Files_Table;