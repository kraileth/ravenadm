--  This file is covered by the Internet Software Consortium (ISC) License
--  Reference: ../License.txt

with Parameters;
with HelperText;
with Unix;
with File_Operations;
with Ada.Directories;
with Ada.Text_IO;

package body Ravenports is

   package PM  renames Parameters;
   package HT  renames HelperText;
   package FOP renames File_Operations;
   package TIO renames Ada.Text_IO;
   package DIR renames Ada.Directories;

   --------------------------------------------------------------------------------------------
   --  check_version_available
   --------------------------------------------------------------------------------------------
   procedure check_version_available
   is
      consdir       : constant String := HT.USS (PM.configuration.dir_conspiracy);
      version_loc   : constant String := consdir & conspiracy_version;
   begin
      if DIR.Exists (version_loc) then
         if fetch_latest_version_info (temporary_ver_loc) then
            declare
               currentver : constant String := FOP.head_n1 (version_loc);
               latestver  : constant String := FOP.head_n1 (temporary_ver_loc);
            begin
               if latestver = currentver then
                  TIO.Put_Line ("The latest version of Ravenports, " & latestver &
                                  ", is currently installed.");
               else
                  TIO.Put_Line ("A newer version of Ravenports is available: " & latestver);
                  TIO.Put_Line ("The " & currentver & " version is currently installed.");
               end if;
            end;
            DIR.Delete_File (temporary_ver_loc);
         end if;
      else
         TIO.Put_Line ("It appears that Ravenports has not been installed at " & consdir);
      end if;
   exception
      when others => null;
   end check_version_available;


   --------------------------------------------------------------------------------------------
   --  fetch_latest_version_info
   --------------------------------------------------------------------------------------------
   function fetch_latest_version_info (tmp_location : String) return Boolean
   is
      sysroot       : constant String := HT.USS (PM.configuration.dir_sysroot);
      fetch_program : constant String := sysroot & "/usr/bin/fetch";
      cmd_output    : HT.Text;
      cmd           : constant String := fetch_program & " -q --no-verify-peer " &
                                         remote_version & " -o " & tmp_location;
      use type DIR.File_Kind;
   begin
      if not DIR.Exists ("/tmp") or else
        DIR.Kind ("/tmp") /= DIR.Directory
      then
         TIO.Put_Line ("The /tmp directory does not exist, bailing ...");
         return False;
      end if;
      if not DIR.Exists (fetch_program) then
         TIO.Put_Line ("It appears that the system root has not yet been installed at " & sysroot);
         TIO.Put_Line ("This must be rectified before Ravenports can be checked or fetched.");
         return False;
      end if;

      return Unix.piped_mute_command (cmd, cmd_output);
   end fetch_latest_version_info;


   --------------------------------------------------------------------------------------------
   --  fetch_latest_tarball
   --------------------------------------------------------------------------------------------
   function fetch_latest_tarball (latest_version : String) return Boolean
   is
      sysroot       : constant String := HT.USS (PM.configuration.dir_sysroot);
      fetch_program : constant String := sysroot & "/usr/bin/fetch";
      tarball       : constant String := github_archive & "/" & latest_version & ".tar.gz";
      cmd_output    : HT.Text;
      cmd : constant String := fetch_program & " -q " & tarball & " -o /tmp";
   begin
      --  covered by previous existence checks of fetch_latest_version_info
      return Unix.piped_mute_command (cmd, cmd_output);
   end fetch_latest_tarball;


   --------------------------------------------------------------------------------------------
   --  later_version_available
   --------------------------------------------------------------------------------------------
   function later_version_available (available : out Boolean) return String
   is
      consdir     : constant String := HT.USS (PM.configuration.dir_conspiracy);
      version_loc : constant String := consdir & conspiracy_version;
   begin
      available := True;
      --  We know consdir exists because we couldn't get here if it didn't.
      if fetch_latest_version_info (temporary_ver_loc) then
         declare
            latestver  : constant String := FOP.head_n1 (temporary_ver_loc);
         begin
            DIR.Delete_File (temporary_ver_loc);
            if DIR.Exists (version_loc) then
               declare
                  currentver : constant String := FOP.head_n1 (version_loc);
               begin
                  if latestver = currentver then
                     available := False;
                  end if;
               end;
            end if;
            return latestver;
         end;
      else
         available := False;
         TIO.Put_Line ("Failed to fetch latest version information from Github");
         return "";
      end if;
   end later_version_available;


   --------------------------------------------------------------------------------------------
   --  retrieve_latest_ravenports
   --------------------------------------------------------------------------------------------
   procedure retrieve_latest_ravenports
   is
      available      : Boolean;
      latest_version : constant String := later_version_available (available);
   begin
      if not available then
         TIO.Put_Line ("Ravenports update skipped as no new version is available.");
         return;
      end if;

      clean_up (latest_version);
      if not fetch_latest_tarball (latest_version) then
         TIO.Put_Line ("Ravenports update skipped as tarball download failed.");
         return;
      end if;

      if relocate_existing_ravenports and then
        explode_tarball_into_conspiracy (latest_version)
      then
         clean_up (latest_version);
      end if;
   end retrieve_latest_ravenports;


   --------------------------------------------------------------------------------------------
   --  retrieve_latest_ravenports
   --------------------------------------------------------------------------------------------
   function relocate_existing_ravenports return Boolean
   is
      consdir : constant String := HT.USS (PM.configuration.dir_conspiracy);
      consdir_old : constant String := consdir & ".old";
   begin
      DIR.Rename (Old_Name => consdir, New_Name => consdir_old);
      return True;
   exception
      when others =>
         return False;
   end relocate_existing_ravenports;


   --------------------------------------------------------------------------------------------
   --  explode_tarball_into_conspiracy
   --------------------------------------------------------------------------------------------
   function explode_tarball_into_conspiracy (latest_version : String) return Boolean
   is
      sysroot       : constant String := HT.USS (PM.configuration.dir_sysroot);
      consdir       : constant String := HT.USS (PM.configuration.dir_conspiracy);
      mv_program    : constant String := sysroot & "/bin/mv ";
      tar_program   : constant String := sysroot & "/usr/bin/tar ";
      find_program  : constant String := sysroot & "/usr/bin/find ";
      chmod_program : constant String := sysroot & "/bin/chmod ";
      tarball       : constant String := "/tmp/" & latest_version & ".tar.gz";
      extract_dir   : constant String := "/tmp/Ravenports-" & latest_version;
      cmd_output    : HT.Text;
      command       : constant String := tar_program & "-C /tmp -xf " & tarball;
      command2      : constant String := mv_program & extract_dir & " " & consdir;
      command3      : constant String := find_program & consdir & " -type d -exec " &
                                         chmod_program & "555 {} +";
   begin
      if Unix.piped_mute_command (command, cmd_output) and then
        Unix.piped_mute_command (command2, cmd_output)
      then
         return Unix.piped_mute_command (command3, cmd_output);
      else
         return False;
      end if;
   end explode_tarball_into_conspiracy;


   --------------------------------------------------------------------------------------------
   --  clean_up
   --------------------------------------------------------------------------------------------
   procedure clean_up (latest_version : String)
   is
      sysroot     : constant String := HT.USS (PM.configuration.dir_sysroot);
      consdir     : constant String := HT.USS (PM.configuration.dir_conspiracy);
      consdir_old : constant String := consdir & ".old";
      extract_old : constant String := "/tmp/Ravenports-" & latest_version;
      command     : constant String := sysroot & "/bin/rm -rf " & consdir_old;
      command2    : constant String := sysroot & "/bin/rm -rf " & extract_old;
      tarball     : constant String := "/tmp/" & latest_version & ".tar.gz";
      cmd_output  : HT.Text;
      success     : Boolean;
   begin
      if DIR.Exists (consdir_old) then
         success := Unix.piped_mute_command (command, cmd_output);
      end if;
      if DIR.Exists (tarball) then
         DIR.Delete_File (tarball);
      end if;
      if DIR.Exists (extract_old) then
         success := Unix.piped_mute_command (command2, cmd_output);
      end if;
   exception
      when others => null;
   end clean_up;

end Ravenports;
