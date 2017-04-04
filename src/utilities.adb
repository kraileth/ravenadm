--  This file is covered by the Internet Software Consortium (ISC) License
--  Reference: ../License.txt

with GNAT.SHA1;
with Ada.Characters.Latin_1;

package body Utilities is

   package HT  renames HelperText;
   package LAT renames Ada.Characters.Latin_1;

   --------------------------------------------------------------------------------------------
   --  lower_opsys
   --------------------------------------------------------------------------------------------
   function lower_opsys (opsys : supported_opsys) return String is
   begin
      case opsys is
         when dragonfly => return "dragonfly";
         when freebsd   => return "freebsd";
         when netbsd    => return "netbsd";
         when openbsd   => return "openbsd";
         when sunos     => return "sunos";
         when linux     => return "linux";
         when macos     => return "darwin";
      end case;
   end lower_opsys;


   --------------------------------------------------------------------------------------------
   --  mixed_opsys
   --------------------------------------------------------------------------------------------
   function mixed_opsys (opsys : supported_opsys) return String is
   begin
      case opsys is
         when dragonfly => return "DragonFly";
         when freebsd   => return "FreeBSD";
         when netbsd    => return "NetBSD";
         when openbsd   => return "OpenBSD";
         when sunos     => return "SunOS";
         when linux     => return "Linux";
         when macos     => return "Darwin";
      end case;
   end mixed_opsys;


   --------------------------------------------------------------------------------------------
   --  cpu_arch
   --------------------------------------------------------------------------------------------
   function cpu_arch (arch : supported_arch) return String is
   begin
      case arch is
         when x86_64  => return "x86_64";
         when i386    => return "i386";
         when aarch64 => return "aarch64";
      end case;
   end cpu_arch;


   --------------------------------------------------------------------------------------------
   --  mixed_opsys
   --------------------------------------------------------------------------------------------
   function valid_lower_opsys (candidate : String) return Boolean is
   begin
      for opsys in supported_opsys'Range loop
         if candidate = lower_opsys (opsys) then
            return True;
         end if;
      end loop;
      return False;
   end valid_lower_opsys;


   --------------------------------------------------------------------------------------------
   --  valid_cpu_arch
   --------------------------------------------------------------------------------------------
   function valid_cpu_arch (candidate : String) return Boolean is
   begin
      for arch in supported_arch'Range loop
         if candidate = cpu_arch (arch) then
            return True;
         end if;
      end loop;
      return False;
   end valid_cpu_arch;


   --------------------------------------------------------------------------------------------
   --  convert_cpu_arch
   --------------------------------------------------------------------------------------------
   function convert_cpu_arch (archstr : String) return supported_arch is
   begin
      if archstr = "x86_64" then
         return x86_64;
      elsif archstr = "i386" then
         return i386;
      elsif archstr = "aarch64" then
         return aarch64;
      else
         raise bad_input;
      end if;
   end convert_cpu_arch;


   --------------------------------------------------------------------------------------------
   --  bucket
   --------------------------------------------------------------------------------------------
   function bucket (palabra : String) return String
   is
      hashstr : String := GNAT.SHA1.Digest (palabra);
   begin
      return HelperText.uppercase (hashstr (hashstr'First .. hashstr'First + 1));
   end bucket;


   --------------------------------------------------------------------------------------------
   --  apply_cbc_string
   --------------------------------------------------------------------------------------------
   procedure apply_cbc_string (value : in out HT.Text)
   is
      opening : Natural;
      closing : Natural;
      wrkstr  : HT.Text;
   begin
      loop
         opening := HT.SU.Index (value, "{{");
         if opening = 0 then
            return;
         end if;
         closing := HT.SU.Index (value, "}}");
         if closing < opening then
            --  covers the closing = 0 case too
            return;
         end if;
         declare
            wrkstr : String := HT.SU.Slice (value, 1, opening - 1) & "${" &
              HT.SU.Slice (value, opening + 2, closing - 1) & "}" &
              HT.SU.Slice (value, closing + 2, HT.SU.Length (value));
         begin
            value := HT.SUS (wrkstr);
         end;
      end loop;
   end apply_cbc_string;


   --------------------------------------------------------------------------------------------
   --  mask_quoted_string
   --------------------------------------------------------------------------------------------
   function mask_quoted_string (raw : String) return String
   is
      mask    : String := raw;
      Qopened : Boolean := False;
      switch  : Boolean;
   begin
      --  Check for multiple space error or leading space error
      --  We start by masking all spaces between quotations so we can accurately detect them
      for x in mask'Range loop
         switch := False;
         if mask (x) = LAT.Quotation then
            if not Qopened then
               switch := True;
            else
               --  We must be at least mask'First + 1 if we are here
               if not (mask (x - 1) = LAT.Reverse_Solidus) then
                  switch := True;
               end if;
            end if;
         end if;

         if switch then
            Qopened := not Qopened;
         elsif mask (x) = LAT.Space then
            if Qopened then
               mask (x) := 'X';
            end if;
         end if;
      end loop;

      return mask;

   end mask_quoted_string;

end Utilities;
