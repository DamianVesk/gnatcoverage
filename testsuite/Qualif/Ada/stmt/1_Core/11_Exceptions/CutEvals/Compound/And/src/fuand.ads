package Fuand is
   function Andthen (A, B : Integer) return Boolean;

   -- Constants intended to map to False, True, or raise from explicit
   -- test or check failure

   F : constant := 0;
   T : constant := 1;
   R : constant := -1;
end;
