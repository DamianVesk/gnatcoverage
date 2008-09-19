------------------------------------------------------------------------------
--                                                                          --
--                              Couverture                                  --
--                                                                          --
--                        Copyright (C) 2008, AdaCore                       --
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
with Ada.Integer_Text_IO;
with Ada.Directories;

package body Traces_Sources.Html is
   type String_Cst_Acc is access constant String;
   subtype S is String;
   
   type Strings_Arr is array (Natural range <>) of String_Cst_Acc;
   
   procedure Put (F : File_Type; Strings : Strings_Arr) is
   begin
      for I in Strings'Range loop
	 Put_Line (F, Strings (I).all);
      end loop;
   end Put;
   
   type Html_Pretty_Printer is new Pretty_Printer with record
      Html_File : Ada.Text_IO.File_Type;
      Index_File : Ada.Text_IO.File_Type;
      Global_Pourcentage : Pourcentage;
   end record;

   procedure Pretty_Print_Start (Pp : in out Html_Pretty_Printer);
   procedure Pretty_Print_Finish (Pp : in out Html_Pretty_Printer);

   procedure Pretty_Print_File (Pp : in out Html_Pretty_Printer;
                                Source_Filename : String;
                                Stats : Stat_Array;
                                Skip : out Boolean);

   procedure Pretty_Print_Line (Pp : in out Html_Pretty_Printer;
                                Line_Num : Natural;
                                State : Line_State;
                                Line : String);

   procedure Pretty_Print_End_File (Pp : in out Html_Pretty_Printer);
   
   procedure Plh (Pp : in out Html_Pretty_Printer; Str : String) is
   begin
      Put_Line (Pp.Html_File, Str);
   end Plh;
   
   procedure Wrh (Pp : in out Html_Pretty_Printer; Str : String) is
   begin
      Put (Pp.Html_File, Str);
   end Wrh;

   --  Return the string S with '>', '<' and '&' replaced by XML entities.
   function To_Xml_String (S : String) return String
   is
      function Xml_Length (S : String) return Natural
      is
         Add : Natural := 0;
      begin
         for I in S'Range loop
            case S (I) is
               when '>' | '<' =>
                  Add := Add + 3;
               when '&' =>
                  Add := Add + 4;
               when others =>
                  null;
            end case;
         end loop;
         return S'Length + Add;
      end Xml_Length;

      Res : String (1 .. Xml_Length (S));
      Idx : Natural;
   begin
      Idx := Res'First;
      for I in S'Range loop
         case S (I) is
            when '>' =>
               Res (Idx .. Idx + 3) := "&gt;";
               Idx := Idx + 4;
            when '<' =>
               Res (Idx .. Idx + 3) := "&lt;";
               Idx := Idx + 4;
            when '&' =>
               Res (Idx .. Idx + 4) := "&amp;";
               Idx := Idx + 5;
            when others =>
               Res (Idx) := S (I);
               Idx := Idx + 1;
         end case;
      end loop;
      pragma Assert (Idx = S'Last + 1);
      return Res;
   end To_Xml_String;
   
   CSS : constant Strings_Arr :=
     (
      new S'("tr.covered { background-color: #80ff80; }"),
      new S'("tr.not_covered { background-color: red; }"),
      new S'("tr.partially_covered { background-color: orange; }"),
      new S'("tr.no_code_odd { }"),
      new S'("tr.no_code_even { background-color: #f0f0f0; }"),
      new S'("table.SumTable td { background-color: #B0C4DE; }"),
      new S'("td.SumHead { color: white; }"),
      new S'("td.SumFile { color: green; }"),
      new S'("td.SumNoFile { color: grey; }"),
      new S'("table.SumTable td.SumBarCover { background-color: green; }"),
      new S'("table.SumTable td.SumBarNoCover { background-color: red; }"),
      new S'("td.SumPourcent, td.SumLineCov { text-align: right; }"),
      new S'("table.SourceFile td pre { margin: 0; }")
     );

   procedure Generate_Css_File
   is
      F : File_Type;
   begin
      Create (F, Out_File, "xcov.css");
      Put (F, CSS);
      Close (F);
   exception
      when Name_Error =>
         Put_Line (Standard_Error, "warning: cannot create xcov.css file");
         return;
   end Generate_Css_File;
   
   procedure Pretty_Print_Start (Pp : in out Html_Pretty_Printer)
   is
      procedure P (S : String) is
      begin
         Put_Line (Pp.Index_File, S);
      end P;
   begin
      begin
         Create (Pp.Index_File, Out_File, "index.html");
      exception
         when Ada.Text_IO.Name_Error =>
            Put_Line (Standard_Error,
                      "cannot open index.html");
            raise;
      end;

      Pp.Global_Pourcentage := (0, 0);

      Generate_Css_File;

      P ("<html lang=""en"">");
      P ("<head>");
      P ("  <title>Coverage results</title>");
      P ("  <link rel=""stylesheet"" type=""text/css"" href=""xcov.css"">");
      P ("</head>");
      P ("<body>");
      P ("<h1 align=""center"">XCOV coverage report</h1>");
      P ("  <table width=""80%"" cellspacing=""1"" class=""SumTable"""
           & " align=""center"">");
      P ("    <tr>");
      P ("      <td class=""SumHead"" width=""60%"">Filename</td>");
      P ("      <td class=""SumHead"" colspan=""3"">Coverage</td>");
      P ("    </tr>");
   end Pretty_Print_Start;

   procedure Pretty_Print_Finish (Pp : in out Html_Pretty_Printer) is
   begin
      Put_Line (Pp.Index_File, "  </table>");
      Put_Line (Pp.Index_File, "</body>");
      Put_Line (Pp.Index_File, "</html>");
      Close (Pp.Index_File);
   end Pretty_Print_Finish;

   procedure Pretty_Print_File (Pp : in out Html_Pretty_Printer;
                                Source_Filename : String;
                                Stats : Stat_Array;
                                Skip : out Boolean)
   is
      use Ada.Integer_Text_Io;
      use Ada.Directories;

      Simple_Source_Filename : constant String :=
        Simple_Name (Source_Filename);

      Output_Filename : constant String := Simple_Source_Filename & ".html";
      Exist : constant Boolean :=
        Flag_Show_Missing or else Exists (Source_Filename);
      P : constant Pourcentage := Get_Pourcentage (Stats);
      Pc : Natural;
      
      procedure Pi (S : String) is
      begin
	 Put (Pp.Index_File, S);
      end Pi;
   
      procedure Ni is
      begin
	 New_Line (Pp.Index_File);
      end Ni;
   begin
      Skip := True;

      Pi ("    <tr>"); Ni;

      --  First column: file name
      Pi ("      <td title=""" & Source_Filename & '"');
      if Exist then
         Pi (" class=""SumFile""><a href=""" & Output_Filename & """ >"
               & Simple_Source_Filename & "</a>");
      else
         Pi (" class=""SumNoFile"">" & Simple_Source_Filename);
      end if;
      Pi ("</td>"); Ni;

      -- Second column: bar
      Pi ("      <td class=""SumBar"" align=""center"" width=""15%"">"); Ni;
      Pi ("        <table border=""0"" cellspacing=""0"">"
            & "<tr height=""10"">");
      if P.Total = 0 or P.Nbr = 0 then
         Pi ("<td class=""SumBarNocover"" width=""100""></td>");
      elsif P.Nbr = P.Total then
         Pi ("<td class=""SumBarCover"" width=""100""></td>");
      else
         Pc := P.Nbr * 100 / P.Total;
         Pi ("<td class=""SumBarCover"" width=""");
         Put (Pp.Index_File, Pc, 0);
         Pi ("""></td>");
         Pi ("<td class=""SumBarNoCover"" width=""");
         Put (Pp.Index_File, 100 - Pc, 0);
         Pi ("""></td>");
      end if;
      Pi ("</tr></table>"); Ni;
      Pi ("      </td>"); Ni;

      --  Third column: pourcentage
      Pi ("      <td class=""SumPourcent"" width=""10%"">");
      if P.Total = 0 then
         Pi ("no code");
      else
         Put (Pp.Index_File, P.Nbr * 100 / P.Total, 0);
         Pi (" %");
      end if;
      Pi ("</td>"); Ni;

      --  Fourth column: lines figure
      Pi ("      <td class=""SumLineCov"" width=""15%"">");
      Put (Pp.Index_File, P.Nbr, 0);
      Pi (" / ");
      Put (Pp.Index_File, P.Total, 0);
      Pi (" lines</td>"); Ni;

      Pi ("    </tr>"); Ni;

      --  Do not try to process files whose source is not available.
      if not Exist then
         return;
      end if;

      begin
         Create (Pp.Html_File, Out_File, Output_Filename);
      exception
         when Ada.Text_IO.Name_Error =>
            Put_Line (Standard_Error,
                      "cannot open " & Output_Filename);
            return;
      end;

      Skip := False;

      Plh (Pp, "<html lang=""en"">");
      Plh (Pp, "<head>");
      Plh (Pp, "  <title>Coverage of "
                & To_Xml_String (Simple_Source_Filename) & "</title>");
      Plh (Pp, "  <link rel=""stylesheet"" type=""text/css"" "
                  & "href=""xcov.css"">");
      Plh (Pp, "</head>");
      Plh (Pp, "<body>");
      Plh (Pp, "<h1 align=""center"">" & Simple_Source_Filename & "</h1>");
      Plh (Pp, Get_Stat_String (Stats));
      Plh (Pp, "<table width=""100%"" cellpadding=""0"" class=""SourceFile"">");
      --Plh (Pp, "<pre>");
   end Pretty_Print_File;

   procedure Pretty_Print_Line (Pp : in out Html_Pretty_Printer;
                                Line_Num : Natural;
                                State : Line_State;
                                Line : String)
   is
      use Ada.Integer_Text_IO;
   begin
      Put (Pp.Html_File, "  <tr class=");
      case State is
         when Not_Covered =>
            Wrh (Pp, """not_covered""");
         when Partially_Covered
           | Branch_Taken
           | Branch_Fallthrough
           | Covered =>
            Wrh (Pp, """partially_covered""");
         when Branch_Covered
           | Covered_No_Branch =>
            Wrh (Pp, """covered""");
         when No_Code =>
            if Line_Num mod 2 = 1 then
               Wrh (Pp, """no_code_odd""");
            else
               Wrh (Pp, """no_code_even""");
            end if;
      end case;
      Plh(Pp, ">");
      
      Wrh (Pp, "    <td><pre>");
      Put (Pp.Html_File, Line_Num, 0);
      Plh (Pp, "</pre></td>");
      Wrh (pp, "    <td><pre>");
      Put (Pp.Html_File, State_Char (State));
      Plh (Pp, "</pre></td>");
      Wrh (Pp, "    <td><pre>");
      Wrh (Pp, To_Xml_String (Line));
      Plh (Pp, "</pre></td>");
      Plh (Pp, "  </tr>");
   end Pretty_Print_Line;

   procedure Pretty_Print_End_File (Pp : in out Html_Pretty_Printer) is
   begin
      Plh (Pp, "</body>");
      Plh (Pp, "</html>");
      Close (Pp.Html_File);
   end Pretty_Print_End_File;

   procedure Generate_Report
   is
      Html : Html_Pretty_Printer;
   begin
      Traces_Sources.Disp_Line_State (Html);
   end Generate_Report;
end Traces_Sources.Html;
