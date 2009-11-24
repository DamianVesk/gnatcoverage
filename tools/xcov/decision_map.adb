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

with Ada.Containers.Ordered_Sets;
with Ada.Text_IO;       use Ada.Text_IO;
with Interfaces;        use Interfaces;
with System.Storage_Elements;

with GNAT.Strings;      use GNAT.Strings;

with Diagnostics;       use Diagnostics;
with Elf_Disassemblers; use Elf_Disassemblers;
with Execs_Dbase;       use Execs_Dbase;
with Hex_Images;        use Hex_Images;
with Qemu_Traces;
with Slocs;             use Slocs;
with Strings;           use Strings;
with Switches;          use Switches;
with Traces_Dbase;      use Traces_Dbase;
with Traces_Files;      use Traces_Files;
with Traces_Names;      use Traces_Names;

package body Decision_Map is

   use Ada.Containers;

   Decision_Map_Base : Traces_Base;
   --  The decision map is a list of code addresses, so we manage it as a
   --  trace database.

   package Decision_Occurrence_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Decision_Occurrence_Access);
   use type Decision_Occurrence_Vectors.Vector;
   --  A list of decision occurrences, used for Decision_Occurrence_Maps below,
   --  and also to maintain the stack of open decision occurrences while
   --  analysing object code.

   package Decision_Occurrence_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type     => SCO_Id,
      Element_Type => Decision_Occurrence_Vectors.Vector);
   Decision_Occurrence_Map : Decision_Occurrence_Maps.Map;
   --  The decision occurrence map lists all object code occurrences of each
   --  source decision (identified by its SCO_Id).

   --  A basic block in object code

   type Basic_Block is record
      From, To  : Pc_Type := No_PC;
      --  Start and end PCs

      --  Properties of the branch instruction at the end of the basic block:

      Dest      : Pc_Type := No_PC;
      --  Destination

      Branch    : Branch_Kind := Br_None;
      --  Branch kind

      Cond      : Boolean;
      --  True if conditional branch

      Condition : SCO_Id := No_SCO_Id;
      --  If this is a conditional branch testing a condition, identifies it
   end record;

   No_Basic_Block : constant Basic_Block := (others => <>);

   function "<" (L, R : Basic_Block) return Boolean;
   --  Order by From

   package Basic_Block_Sets is new Ada.Containers.Ordered_Sets (Basic_Block);

   function Find_Basic_Block
     (Basic_Blocks : Basic_Block_Sets.Set;
      PC           : Pc_Type) return Basic_Block;
   --  Return the basic block containing PC from the given set, or
   --  No_Basic_Block if none.

   type Cond_Branch_Context is limited record
      Decision_Stack : Decision_Occurrence_Vectors.Vector;
      --  The stack of open decision occurrences

      Basic_Blocks   : Basic_Block_Sets.Set;
   end record;

   procedure Analyze_Routine
     (Name  : String_Access;
      Exec  : Exe_File_Acc;
      Insns : Binary_Content);
   --  Build decision map for the given subprogram

   procedure Analyze_Conditional_Branch
     (Exec              : Exe_File_Acc;
      Insn              : Binary_Content;
      Branch_Dest       : Pc_Type;
      Fallthrough_Dest  : Pc_Type;
      Ctx               : in out Cond_Branch_Context;
      BB                : in out Basic_Block);
   --  Process one conditional branch instruction: identify relevant source
   --  coverable construct, and record association in the decision map. Sets
   --  BB.Condition if applicable.

   procedure Analyze_Decision_Occurrence
     (Exe   : Exe_File_Acc;
      Ctx   : Cond_Branch_Context;
      D_Occ : Decision_Occurrence_Access);
   --  Perform logical structure analysis of the given decision occurrence

   procedure Append_Decision_Occurrence (D_Occ : Decision_Occurrence_Access);
   --  Record association of D_Occ with its decision

   function Image (BB : Basic_Block) return String;
   pragma Unreferenced (Image);
   --  For debugging purposes

   procedure Write_Map (Filename : String);
   --  Write the contents of the decision map to the named file

   ---------
   -- "<" --
   ---------

   function "<" (L, R : Basic_Block) return Boolean is
   begin
      return L.From < R.From;
   end "<";

   function "<" (L, R : Cond_Branch_Loc) return Boolean is
      use System.Storage_Elements;
   begin
      return To_Integer (L.Exe.all'Address) < To_Integer (R.Exe.all'Address)
        or else (L.Exe = R.Exe and then L.PC < R.PC);
   end "<";

   -------------
   -- Analyze --
   -------------

   procedure Analyze (Exe_File : Exe_File_Acc) is
      Sym_It : Addresses_Iterator;
      Sym    : Addresses_Info_Acc;
      Sec    : Addresses_Info_Acc;

      First_Symbol_Occurrence : Boolean;
   begin
      Build_Debug_Lines (Exe_File.all);

      --  Add routine names of interest to routines database

      Routine_Names_From_Lines (Exe_File, Has_SCO'Access);

      --  Analyze control flow graph

      Init_Iterator (Exe_File.all, Symbol_Addresses, Sym_It);
      loop
         Next_Iterator (Sym_It, Sym);
         exit when Sym = null;

         if Is_In (Sym.Symbol_Name) then
            Sec := Sym.Parent;
            Load_Section_Content (Exe_File.all, Sec);

            Add_Code
              (Sym.Symbol_Name,
               Exe_File,
               Sec.Section_Content (Sym.First .. Sym.Last),
               First_Symbol_Occurrence);

            --  Build decision map for routine based on referenced instance

            if First_Symbol_Occurrence then
               Analyze_Routine
                 (Sym.Symbol_Name,
                  Exe_File,
                  Sec.Section_Content (Sym.First .. Sym.Last));

               --  Load sloc information

               Build_Source_Lines_For_Section
                 (Exe_File,
                  null,
                  Sec.Section_Content (Sym.First .. Sym.Last));
            end if;
         end if;
      end loop;
   end Analyze;

   --------------------------------
   -- Analyze_Conditional_Branch --
   --------------------------------

   procedure Analyze_Conditional_Branch
     (Exec              : Exe_File_Acc;
      Insn              : Binary_Content;
      Branch_Dest       : Pc_Type;
      Fallthrough_Dest  : Pc_Type;
      Ctx               : in out Cond_Branch_Context;
      BB                : in out Basic_Block)
   is
      Sloc : constant Source_Location := Get_Sloc (Exec.all, Insn'First);
      --  Source location of Insn

      SCO : SCO_Id;

   begin
      if Sloc = Slocs.No_Location then
         --  No associated source, so no further processing required for source
         --  coverage analysis.

         return;
      end if;

      --  Look up SCO

      SCO := Sloc_To_SCO (Sloc);

      if SCO = No_SCO_Id or else Kind (SCO) /= Condition then
         return;
      end if;

      --  Here for conditional branches that have an associated Condition SCO

      --  Mark instruction address for full (historical) traces collection
      --  (for MC/DC source coverage analysis) if required by decision
      --  structure (presence of multiple paths) or if Debug_Full_History is
      --  set.

      if Has_Diamond (Parent (SCO)) or else Debug_Full_History then
         Add_Entry
           (Base  => Decision_Map_Base,
            First => Insn'First,
            Last  => Insn'Last,
            Op    => 0);
      end if;

      --  Record address in SCO descriptor

      Add_Address (SCO, Insn'First);

      --  Update control flow information

      Process_Condition :
      declare
         D_SCO : constant SCO_Id := Parent (SCO);
         --  Corresponding decision

         Parent_SCO : SCO_Id;
         --  Parent SCO of D_SCO, if appropriate

         Enclosing_D_SCO : SCO_Id;
         --  For a nested decision, the enclosing decision

         DS_Top : Decision_Occurrence_Access;
         --  Innermost currently open decision

         Cond_Index : constant Condition_Index := Index (SCO);
         --  Index of SCO in D_SCO

         function Is_Expected_Condition
           (CI                   : Condition_Index;
            Report_If_Unexpected : Boolean := False) return Boolean;
         --  Check whether we expect to evaluate CI: either we remain in the
         --  current condition (case of a condition that requires multiple
         --  branches), or we move to the next one.

         procedure Check_Condition_Index (CI : Condition_Index);
         --  Check whether CI is an expected condition, and if not, report an
         --  error.

         ---------------------------
         -- Is_Expected_Condition --
         ---------------------------

         function Is_Expected_Condition
           (CI                   : Condition_Index;
            Report_If_Unexpected : Boolean := False) return Boolean
         is
            Current_CI : Condition_Index renames DS_Top.Seen_Condition;
         begin
            if CI in Current_CI .. Current_CI + 1 then
               return True;
            end if;

            if Report_If_Unexpected then
               Report
                 (Exec, Insn'First,
                  "evaluation of unexpected condition" & CI'Img
                  & " (expected"
                  & Condition_Index'Image (Current_CI)
                  & " or"
                  & Condition_Index'Image (Current_CI + 1) & ")"
                  & " in decision " & Image (DS_Top.Decision));
            end if;
            return False;
         end Is_Expected_Condition;

         ---------------------------
         -- Check_Condition_Index --
         ---------------------------

         procedure Check_Condition_Index (CI : Condition_Index) is
            Dummy : Boolean;
            pragma Unreferenced (Dummy);
         begin
            Dummy := Is_Expected_Condition (CI, Report_If_Unexpected => True);
         end Check_Condition_Index;

      --  Start of processing for Process_Condition

      begin
         Parent_SCO := Parent (D_SCO);
         if Kind (Parent_SCO) = Condition then
            Enclosing_D_SCO := Parent (Parent_SCO);
         else
            Enclosing_D_SCO := No_SCO_Id;
         end if;

         --  Flush completed decisions from the Decision_Stack

         while Ctx.Decision_Stack.Length > 0 loop
            DS_Top := Ctx.Decision_Stack.Last_Element;
            exit when DS_Top.Decision = D_SCO
              and then Is_Expected_Condition (Cond_Index);

            if DS_Top.Decision = Enclosing_D_SCO then
               Check_Condition_Index (Index (Parent_SCO));
               DS_Top :=  null;
               exit;
            end if;

            Analyze_Decision_Occurrence (Exec, Ctx, DS_Top);
            Ctx.Decision_Stack.Delete_Last;
            DS_Top := null;
         end loop;

         if DS_Top = null then
            --  Push new context

            DS_Top := new Decision_Occurrence'
                            (Last_Cond_Index => Last_Cond_Index (D_SCO),
                             Decision        => D_SCO,
                             others          => <>);
            Ctx.Decision_Stack.Append (DS_Top);
         end if;

         --  Here after pushing context for current decision, if needed

         pragma Assert (DS_Top.Decision = D_SCO);
         Check_Condition_Index (Cond_Index);

         --  Record condition occurrence

         Report
           (Exec, Insn'First,
            "cond branch for " & Image (SCO)
            & " (" & Img (Integer (Index (SCO))) & ")",
            Kind => Notice);
         BB.Condition := SCO;

         if Cond_Index > DS_Top.Seen_Condition then
            DS_Top.Seen_Condition := Cond_Index;
         end if;

         DS_Top.Conditional_Branches.Append (Insn'First);

         Cond_Branch_Map.Insert
           ((Exec, Insn'First),
            Cond_Branch_Info'
              (Decision_Occurrence => DS_Top,
               Condition           => SCO,
               Edges               =>
                 (Branch      =>
                    (Destination => Branch_Dest,
                     others      => <>),
                  Fallthrough =>
                    (Destination => Fallthrough_Dest,
                     others      => <>))));
      end Process_Condition;
   end Analyze_Conditional_Branch;

   ---------------------------------
   -- Analyze_Decision_Occurrence --
   ---------------------------------

   procedure Analyze_Decision_Occurrence
     (Exe   : Exe_File_Acc;
      Ctx   : Cond_Branch_Context;
      D_Occ : Decision_Occurrence_Access)
   is
      Last_Seen_Condition_PC : constant Pc_Type :=
                                 D_Occ.Conditional_Branches.Last_Element;

      --  Note: all the analysis is done under control of an initial check that
      --    D_Occ.Seen_Condition = D_Occ.Last_Condition_Index

      Last_CBI : constant Cond_Branch_Info :=
                   Cond_Branch_Map.Element ((Exe, Last_Seen_Condition_PC));

      Known_Outcome : array (Boolean) of Pc_Type := (others => No_PC);
      --  When set, each element of this array is the destination of the first
      --  edge corresponding to each outcome of the decision.

      procedure Trace_Destination (Edge : in out Cond_Edge_Info);
      --  Inspect the basic block containing Edge's destination, and if
      --  necessary any basic block we unconditionally branch to from there,
      --  until we find a conditional branch or a call to an exception-raising
      --  routine.

      procedure Label_Destination
        (Cond_Branch_PC : Pc_Type;
         CBI            : in out Cond_Branch_Info;
         Edge           : Edge_Kind);
      --  First pass of control flow analysis: test if Edge's destination
      --  matches either of Last_CBI's edges' destination, and if so mark it as
      --  an outcome destination.

      procedure Label_From_Opposite
        (Cond_Branch_PC : Pc_Type;
         CBI            : in out Cond_Branch_Info;
         Edge           : Edge_Kind);
      --  Second pass of control flow analysis: if Edge is not qualified yet,
      --  but the opposite destination of CBI is, deduce qualification for Edge
      --  from that information.

      procedure Label_Destinations
        (CB_Loc : Cond_Branch_Loc;
         CBI    : in out Cond_Branch_Info);
      --  Identify destination kind of each edge of CBI

      -----------------------
      -- Label_Destination --
      -----------------------

      procedure Label_Destination
        (Cond_Branch_PC : Pc_Type;
         CBI            : in out Cond_Branch_Info;
         Edge           : Edge_Kind)
      is
         Edge_Name         : constant String := Edge'Img;
         Edge_Info         : Cond_Edge_Info renames CBI.Edges (Edge);

      begin
         pragma Assert (Edge_Info.Dest_Kind = Unknown);

         Trace_Destination (Edge_Info);

         --  Check for outcome destination

         --  HYP: a branch destination is an outcome when it is equal to one
         --  of the branch destinations of the last conditional branch in
         --  the decision. Note: some outcome destinations do not satisfy
         --  this property (but there is no indication that any non-outcome
         --  destination does satisfy it).

         --  HYP: a branch destination is an outcome when it branches past
         --  the conditional branch instruction for the last condition.

         if Edge_Info.Dest_Kind = Unknown
           and then
             (Edge_Info.Destination
                = Last_CBI.Edges (Branch).Destination
              or else Edge_Info.Destination
                        = Last_CBI.Edges (Fallthrough).Destination
              or else Edge_Info.Destination > Last_Seen_Condition_PC)
         then
            Edge_Info.Dest_Kind := Outcome;

            --  Check that there is a possible outcome from this condition

            declare
               Outcome_Seen   : Boolean;
               --  Set True when there is a value of the condition that
               --  determines an outcome of the decision.

               Outcome_Origin : Tristate := Unknown;
               --  The value of the condition that determines this outcome,
               --  if there is only one such value. Reset to Unknown when
               --  both values of the condition determine outcomes (case of the
               --  last condition in a decision).

            begin
               --  Check whether either valuation of the current condition
               --  determines the decision outcome.

               for J in Boolean'Range loop
                  if Outcome (CBI.Condition, J) /= Unknown then
                     Outcome_Seen := True;
                     if Outcome_Origin = Unknown then
                        Outcome_Origin := To_Tristate (J);
                     else
                        Outcome_Origin := Unknown;
                     end if;
                  end if;
               end loop;

               if not Outcome_Seen then
                  --  Case of a destination that we identified as an outcome
                  --  but whose condition cannot determine the outcome of the
                  --  decision according to the BDD.

                  Report
                    (Exe, Cond_Branch_PC,
                     Edge_Name & " destination unexpectedly out of condition");

               elsif Outcome_Origin /= Unknown then
                  --  If there is only one outcome edge (and the other is a
                  --  condition), then Outcome_Origin is the valuation of the
                  --  condition that causes it to be taken.

                  Edge_Info.Origin := Outcome_Origin;
                  Edge_Info.Outcome :=
                    Outcome (CBI.Condition, To_Boolean (Outcome_Origin));
                  pragma Assert (Edge_Info.Outcome /= Unknown);

                  --  If this was the first destination identified to represent
                  --  this value of the decision outcome, record it.

                  declare
                     Known_Outcome_Dest : Pc_Type
                       renames Known_Outcome (To_Boolean (Edge_Info.Outcome));
                  begin
                     if Known_Outcome_Dest = No_PC then
                        Known_Outcome_Dest := Edge_Info.Destination;
                     end if;
                  end;

               else
                  --  Case of the last condition in the decision: both values
                  --  of the condition determine the outcome, so try to label
                  --  the outcome, and its origin, using Known_Outcomes.

                  for J in Boolean'Range loop
                     declare
                        O : constant Boolean :=
                              To_Boolean (Outcome (CBI.Condition, J));
                     begin
                        if Edge_Info.Destination = Known_Outcome (O) then
                           Edge_Info.Origin  := To_Tristate (J);
                           Edge_Info.Outcome := To_Tristate (O);
                        end if;
                     end;
                  end loop;
               end if;
            end;

         --  Check for internal destination

         elsif Edge_Info.Dest_Kind = Condition then

            --  Check that the next condition is a possible successor, and
            --  label edge origin (that is, the valuation of the tested
            --  condition that causes the successor in question to be evaluated
            --  next).

            for J in Boolean'Range loop
               declare
                  Next_C : constant SCO_Id :=
                             Next_Condition (CBI.Condition, J);
               begin
                  if Next_C /= No_SCO_Id
                    and then Index (Next_C) = Edge_Info.Next_Condition
                  then
                     Edge_Info.Origin := To_Tristate (J);
                     exit;
                  end if;
               end;
            end loop;

            --  Report failure to identify successor if neither going to a
            --  possible successor nor remaining in the same condition.

            if Edge_Info.Origin = Unknown
              and then Edge_Info.Next_Condition /= Index (CBI.Condition)
            then
               Report
                 (Exe, Cond_Branch_PC,
                  Edge_Name
                  & " does not branch to a possible successor"
                  & " condition");
            end if;
         end if;

         --  Report destinations we can't label (warning only, maybe we can
         --  infer branch kind later).

         if Edge_Info.Dest_Kind = Unknown then
            Report (Exe, Cond_Branch_PC,
                    "unable to label " & Edge_Name
                    & " destination " & Hex_Image (Edge_Info.Destination),
                    Kind => Warning);
         end if;
      end Label_Destination;

      -------------------------
      -- Label_From_Opposite --
      -------------------------

      procedure Label_From_Opposite
        (Cond_Branch_PC : Pc_Type;
         CBI            : in out Cond_Branch_Info;
         Edge           : Edge_Kind)
      is
         pragma Unreferenced (Cond_Branch_PC);
         This_CBE     : Cond_Edge_Info renames CBI.Edges (Edge);
         Opposite_CBE : Cond_Edge_Info renames
                          CBI.Edges (Edge_Kind'Val (1 - Edge_Kind'Pos (Edge)));
         O : Boolean;
      begin
         if This_CBE.Origin /= Unknown
              or else
            Opposite_CBE.Origin = Unknown
         then
            return;
         end if;

         O := not To_Boolean (Opposite_CBE.Origin);
         This_CBE.Origin := To_Tristate (O);
         This_CBE.Outcome := Outcome (CBI.Condition, O);
      end Label_From_Opposite;

      ------------------------
      -- Label_Destinations --
      ------------------------

      procedure Label_Destinations
        (CB_Loc : Cond_Branch_Loc;
         CBI    : in out Cond_Branch_Info)
      is
         Cond_Branch_PC : Pc_Type renames CB_Loc.PC;

         function Dest_Image (Edge : Edge_Kind) return String;
         --  Return string representation of the given edge of CBI

         ----------------
         -- Dest_Image --
         ----------------

         function Dest_Image (Edge : Edge_Kind) return String is
            Edge_Info : Cond_Edge_Info renames CBI.Edges (Edge);

            function Additional_Info_Image return String;
            --  Edge_Info.Next_Condition if Dest_Kind is Condition,
            --  Edge_Info.Outcome image if Dest_Kind is Outcome,
            --  else an empty string.

            ---------------------------
            -- Additional_Info_Image --
            ---------------------------

            function Additional_Info_Image return String is
            begin
               case Edge_Info.Dest_Kind is
                  when Condition =>
                     return " ("
                       & Img (Integer (Edge_Info.Next_Condition))
                       & ")";

                  when Outcome =>
                     return " (" & Edge_Info.Outcome'Img & ")";

                  when others =>
                     return "";
               end case;
            end Additional_Info_Image;

         --  Start of processing for Dest_Image

         begin
            return Edge_Info.Origin'Img & "->" & Edge'Img
              & " = " & Hex_Image (Edge_Info.Destination)
              & " " & Edge_Info.Dest_Kind'Img & Additional_Info_Image;
         end Dest_Image;

      --  Start of processing for Label_Destinations

      begin
         --  Label each destination

         Label_Destination (Cond_Branch_PC, CBI, Branch);
         Label_Destination (Cond_Branch_PC, CBI, Fallthrough);

         --  So far we have looked at each destination in isolation. Now try
         --  to further qualify each destination by deducing its properties
         --  from those known on the other.

         Label_From_Opposite (Cond_Branch_PC, CBI, Branch);
         Label_From_Opposite (Cond_Branch_PC, CBI, Fallthrough);

         Report
           (Exe, Cond_Branch_PC,
            Dest_Image (Branch) & " / " & Dest_Image (Fallthrough),
            Kind => Notice);
      end Label_Destinations;

      -----------------------
      -- Trace_Destination --
      -----------------------

      procedure Trace_Destination (Edge : in out Cond_Edge_Info)
      is
         Next_PC : Pc_Type := Edge.Destination;
         BB      : Basic_Block;
      begin
         <<Follow_Jump>>
         BB := Find_Basic_Block (Ctx.Basic_Blocks, Next_PC);

         case BB.Branch is
            when Br_Jmp =>
               if BB.Cond then
                  if BB.Condition /= No_SCO_Id
                    and then Parent (BB.Condition) = D_Occ.Decision
                  then
                     --  Edge evaluates a condition in the current decision

                     Edge.Dest_Kind := Condition;
                     Edge.Next_Condition := Index (BB.Condition);
                  end if;

               elsif BB.Dest > Next_PC then
                  --  Unconditional branch forward (we never follow backward
                  --  branches to avoid loops).

                  Next_PC := BB.Dest;
                  goto Follow_Jump;
               end if;

            when Br_Call =>
               declare
                  Sym : constant Addresses_Info_Acc :=
                          Get_Symbol (Exe.all, BB.Dest);
                  Sym_Name : String_Access;
               begin
                  if Sym /= null then
                     Sym_Name := Sym.Symbol_Name;
                  end if;

                  if Sym_Name /= null
                       and then
                     (Sym_Name.all = "__gnat_last_chance_handler"
                        or else
                      Has_Prefix (Sym_Name.all, Prefix => "__gnat_rcheck_"))
                  then
                     Edge.Dest_Kind := Raise_Exception;
                  end if;
               end;

            when others =>
               null;
         end case;
      end Trace_Destination;

   --  Start of processing for Analyze_Decision_Occurrence

   begin
      if D_Occ.Last_Cond_Index /= D_Occ.Seen_Condition then
         --  Report PC of last seen condition in decision occurrence, if it is
         --  not the final condition of the decision (indicates a decision
         --  occurrence being flushed before it was completely seen).

         Report (Exe, Last_Seen_Condition_PC,
                 "incomplete occurrence of " & Image (D_Occ.Decision));
         return;
      end if;

      --  Label edge destinations

      for J in D_Occ.Conditional_Branches.First_Index
            .. D_Occ.Conditional_Branches.Last_Index
      loop
         declare
            use Cond_Branch_Maps;
            Cur : constant Cond_Branch_Maps.Cursor :=
                    Cond_Branch_Map.Find
                      ((Exe, D_Occ.Conditional_Branches.Element (J)));
         begin
            Cond_Branch_Map.Update_Element (Cur, Label_Destinations'Access);
         end;
      end loop;

      --  Record decision occurrence

      Append_Decision_Occurrence (D_Occ);
   end Analyze_Decision_Occurrence;

   ---------------------
   -- Analyze_Routine --
   ---------------------

   procedure Analyze_Routine
     (Name  : String_Access;
      Exec  : Exe_File_Acc;
      Insns : Binary_Content)
   is
      PC       : Pc_Type;
      Insn_Len : Natural;

      Current_Basic_Block_Start : Pc_Type;
      Context : Cond_Branch_Context;

   --  Start of processing for Analyze_Routine

   begin
      if Verbose then
         Put_Line ("Building decision map for " & Name.all);
      end if;

      --  Iterate over instructions, looking for conditional branches

      PC := Insns'First;
      Current_Basic_Block_Start := PC;
      while PC < Insns'Last loop
         Insn_Len :=
           Disa_For_Machine (Machine).
             Get_Insn_Length (Insns (PC .. Insns'Last));

         declare
            Insn : Binary_Content renames
                     Insns (PC .. PC + Pc_Type (Insn_Len) - 1);

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

            if Branch /= Br_None then
               declare
                  BB : Basic_Block :=
                         (From      => Current_Basic_Block_Start,
                          To        => PC,
                          Dest      => Dest,
                          Branch    => Branch,
                          Cond      => Flag_Cond,
                          Condition => No_SCO_Id);
               begin
                  if Branch = Br_Jmp and then Flag_Cond then
                     Analyze_Conditional_Branch
                       (Exec,
                        Insn             => Insn,
                        Branch_Dest      => Dest,
                        Fallthrough_Dest => Insn'Last + 1,
                        Ctx              => Context,
                        BB               => BB);
                  end if;
                  Context.Basic_Blocks.Insert (BB);
               end;
            end if;

            PC := PC + Pc_Type (Insn_Len);

            --  Handle case where PC wraps

            exit when PC = 0;

            if Branch /= Br_None then
               Current_Basic_Block_Start := PC;
            end if;
         end;
      end loop;

      --  Flush pending decisions

      for J in reverse Context.Decision_Stack.First_Index
                    .. Context.Decision_Stack.Last_Index
      loop
         Analyze_Decision_Occurrence
           (Exec, Context, Context.Decision_Stack.Element (J));
      end loop;

   end Analyze_Routine;

   --------------------------------
   -- Append_Decision_Occurrence --
   --------------------------------

   procedure Append_Decision_Occurrence (D_Occ : Decision_Occurrence_Access) is

      procedure Update_Element
        (SCO : SCO_Id;
         V   : in out Decision_Occurrence_Vectors.Vector);
      --  Append D_Occ to V

      --------------------
      -- Update_Element --
      --------------------

      procedure Update_Element
        (SCO : SCO_Id;
         V   : in out Decision_Occurrence_Vectors.Vector)
      is
         pragma Unreferenced (SCO);
      begin
         V.Append (D_Occ);
      end Update_Element;

      use Decision_Occurrence_Maps;
      Cur : constant Cursor := Decision_Occurrence_Map.Find (D_Occ.Decision);

   --  Start of processing for Append_Decision_Occurrence

   begin
      if Cur = Decision_Occurrence_Maps.No_Element then
         Decision_Occurrence_Map.Insert
           (Key      => D_Occ.Decision,
            New_Item => Decision_Occurrence_Vectors.To_Vector (D_Occ, 1));
      else
         Decision_Occurrence_Map.Update_Element (Cur, Update_Element'Access);
      end if;
   end Append_Decision_Occurrence;

   ------------------------
   -- Build_Decision_Map --
   ------------------------

   procedure Build_Decision_Map (Exec_Name : String)
   is
      Exec : Exe_File_Acc;

      Decision_Map_Filename     : String_Access := null;
      Decision_Map_Suffix       : constant String := ".dmap";
      --  Decision map filename is constructed by appending the suffix to the
      --  executable image name.

   --  Start of processing for Build_Decision_Map

   begin
      Decision_Map_Filename :=
        new String'(Exec_Name & Decision_Map_Suffix);
      Open_Exec (Exec_Name, Exec);

      Init_Base (Decision_Map_Base);
      Analyze (Exec);
      Decision_Map.Write_Map (Decision_Map_Filename.all);

      Close_File (Exec.all);
   end Build_Decision_Map;

   ----------------------
   -- Find_Basic_Block --
   ----------------------

   function Find_Basic_Block
     (Basic_Blocks : Basic_Block_Sets.Set;
      PC           : Pc_Type) return Basic_Block
   is
      use Basic_Block_Sets;
      PC_Block : constant Basic_Block := (From => PC, others => <>);
      Cur : constant Cursor := Basic_Blocks.Floor (PC_Block);
   begin
      if Cur /= No_Element and then PC <= Element (Cur).To then
         return Element (Cur);
      else
         return No_Basic_Block;
      end if;
   end Find_Basic_Block;

   -----------
   -- Image --
   -----------

   function Image (BB : Basic_Block) return String is
      Cond_Char : constant array (Boolean) of Character :=
                    (False => ' ', True => '?');
   begin
      return Hex_Image (BB.From) & "-" & Hex_Image (BB.To)
               & " " & BB.Branch'Img & Cond_Char (BB.Cond) & " "
               & Hex_Image (BB.Dest);
   end Image;

   ---------------
   -- Write_Map --
   ---------------

   procedure Write_Map (Filename : String) is
      Trace_File : Trace_File_Type;
   begin
      Create_Trace_File (Qemu_Traces.Decision_Map, Trace_File);
      Write_Trace_File (Filename, Trace_File, Decision_Map_Base);
   end Write_Map;

end Decision_Map;
