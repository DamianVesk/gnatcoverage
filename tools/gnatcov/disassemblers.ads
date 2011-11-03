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

--  Abstract support for disassembly engines

with Traces;         use Traces;
with Traces_Elf;     use Traces_Elf;
with Disa_Symbolize; use Disa_Symbolize;

package Disassemblers is

   type Disassembler is limited interface;

   function Get_Insn_Length
     (Self     : Disassembler;
      Insn_Bin : Binary_Content) return Positive is abstract;
   --  Return the length of the instruction at the beginning of Insn_Bin

   procedure Disassemble_Insn
     (Self     : Disassembler;
      Insn_Bin : Binary_Content;
      Pc       : Pc_Type;
      Line     : out String;
      Line_Pos : out Natural;
      Insn_Len : out Natural;
      Sym      : Symbolizer'Class) is abstract;
   --  Disassemble instruction at ADDR, and put the result in LINE/LINE_POS.
   --  LINE_POS is the index of the next character to be written (ie line
   --  length if Line'First = 1).

   procedure Get_Insn_Properties
     (Self        : Disassembler;
      Insn_Bin    : Binary_Content;
      Pc          : Pc_Type;
      Branch      : out Branch_Kind;
      Flag_Indir  : out Boolean;
      Flag_Cond   : out Boolean;
      Dest        : out Pc_Type;
      Fallthrough : out Pc_Type) is abstract;
   --  Determine whether the given instruction, located at PC, is a branch
   --  instruction of some kind (indicated by Branch).
   --  For a branch, indicate whether it is indirect (Flag_Indir) and whether
   --  it is conditional (Flag_Cond), and determine its destination (Dest);
   --  if it is conditional, determine the destination if the condition is
   --  no verified (Fallthrough).

end Disassemblers;