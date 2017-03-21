--  This file is covered by the Internet Software Consortium (ISC) License
--  Reference: ../License.txt

with Unix;
with Signals;
with Ada.Exceptions;
with Ada.Directories;
with Ada.Characters.Latin_1;
with PortScan.Log;
with PortScan.Buildcycle;

package body PortScan.Operations is

   package EX  renames Ada.Exceptions;
   package DIR renames Ada.Directories;
   package LAT renames Ada.Characters.Latin_1;
   package LOG renames PortScan.Log;
   package CYC renames PortScan.Buildcycle;

   --------------------------------------------------------------------------------------------
   --  initialize_hooks
   --------------------------------------------------------------------------------------------
   procedure initialize_hooks is
   begin
      for hook in hook_type'Range loop
         declare
            script : constant String := HT.USS (hook_location (hook));
         begin
            active_hook (hook) := DIR.Exists (script) and then file_is_executable (script);
         end;
      end loop;
   end initialize_hooks;


   --------------------------------------------------------------------------------------------
   --  run_hook
   --------------------------------------------------------------------------------------------
   procedure run_hook (hook : hook_type; envvar_list : String)
   is
      function nvpair (name : String; value : HT.Text) return String;
      function nvpair (name : String; value : HT.Text) return String is
      begin
         return
           name & LAT.Equals_Sign & LAT.Quotation & HT.USS (value) & LAT.Quotation & LAT.Space;
      end nvpair;
      common_env : constant String :=
        nvpair ("PROFILE", PM.configuration.profile) &
        nvpair ("DIR_PACKAGES", PM.configuration.dir_packages) &
        nvpair ("DIR_LOCALBASE", PM.configuration.dir_localbase) &
        nvpair ("DIR_CONSPIRACY", PM.configuration.dir_conspiracy) &
        nvpair ("DIR_CUSTOM_PORTS", PM.configuration.dir_unkindness) &
        nvpair ("DIR_DISTFILES", PM.configuration.dir_distfiles) &
        nvpair ("DIR_LOGS", PM.configuration.dir_logs) &
        nvpair ("DIR_BUILDBASE", PM.configuration.dir_buildbase);
      --  The follow command works on every platform
      command : constant String := "/usr/bin/env -i " & common_env &
        envvar_list & " " & HT.USS (hook_location (hook));
   begin
      if not active_hook (hook) then
         return;
      end if;
      if Unix.external_command (command) then
         null;
      end if;
   end run_hook;


   --------------------------------------------------------------------------------------------
   --  run_start_hook
   --------------------------------------------------------------------------------------------
   procedure run_start_hook is
   begin
      run_hook (run_start, "PORTS_QUEUED=" & HT.int2str (queue_length) & " ");
   end run_start_hook;


   --------------------------------------------------------------------------------------------
   --  run_hook_after_build
   --------------------------------------------------------------------------------------------
   procedure run_hook_after_build (built : Boolean; id : port_id) is
   begin
      if built then
         run_package_hook (pkg_success, id);
      else
         run_package_hook (pkg_failure, id);
      end if;
   end run_hook_after_build;


   --------------------------------------------------------------------------------------------
   --  run_hook_after_build
   --------------------------------------------------------------------------------------------
   procedure run_package_hook (hook : hook_type; id : port_id)
   is
      tail : String := " ORIGIN=" & get_port_variant (id);
   begin
      case hook is
         when pkg_success => run_hook (hook, "RESULT=success" & tail);
         when pkg_failure => run_hook (hook, "RESULT=failure" & tail);
         when pkg_ignored => run_hook (hook, "RESULT=ignored" & tail);
         when pkg_skipped => run_hook (hook, "RESULT=skipped" & tail);
         when others => null;
      end case;
   end run_package_hook;


   --------------------------------------------------------------------------------------------
   --  file_is_executable
   --------------------------------------------------------------------------------------------
   function file_is_executable (filename : String) return Boolean
   is
      function spit_command return String;
      function spit_command return String is
      begin
         case platform_type is
         when dragonfly | freebsd | netbsd | openbsd | macos | linux =>
            return "/usr/bin/file -b -L -e ascii -e encoding -e tar -e compress " &
                LAT.Quotation & filename & LAT.Quotation;
         when sunos =>
            return "/usr/bin/file " & LAT.Quotation & filename & LAT.Quotation;
         end case;
      end spit_command;

      status : Integer;
      cmdout : String := HT.USS (Unix.piped_command (spit_command, status));
   begin
      if status = 0 then
         return HT.contains (cmdout, "executable");
      else
         return False;
      end if;
   end file_is_executable;


   --------------------------------------------------------------------------------------------
   --  delete_existing_web_history_files
   --------------------------------------------------------------------------------------------
   procedure delete_existing_web_history_files
   is
      search    : DIR.Search_Type;
      dirent    : DIR.Directory_Entry_Type;
      pattern   : constant String := "*_history.json";
      filter    : constant DIR.Filter_Type := (DIR.Ordinary_File => True, others => False);
      reportdir : constant String := HT.USS (PM.configuration.dir_logs);
   begin
      if not DIR.Exists (reportdir) then
         return;
      end if;
      DIR.Start_Search (Search    => search,
                       Directory => reportdir,
                       Pattern   => pattern,
                       Filter    => filter);
      while DIR.More_Entries (search) loop
         DIR.Get_Next_Entry (search, dirent);
         DIR.Delete_File (reportdir & "/" & DIR.Simple_Name (dirent));
      end loop;
   exception
      when DIR.Name_Error => null;
   end delete_existing_web_history_files;


   --------------------------------------------------------------------------------------------
   --  delete_existing_packages_of_ports_list
   --------------------------------------------------------------------------------------------
   procedure delete_existing_packages_of_ports_list
   is
      procedure force_delete (plcursor : portkey_crate.Cursor);
      procedure force_delete (plcursor : portkey_crate.Cursor)
      is
         procedure delete_subpackage (position : subpackage_crate.Cursor);

         origin : HT.Text := portkey_crate.Key (plcursor);
         pndx   : constant port_index := ports_keys.Element (origin);
         repo   : constant String := HT.USS (PM.configuration.dir_repository);

         procedure delete_subpackage (position : subpackage_crate.Cursor)
         is
            rec        : subpackage_record renames subpackage_crate.Element (position);
            subpackage : constant String := HT.USS (rec.subpackage);
            tball      : constant String := repo &
                         PortScan.calculate_package_name (pndx, subpackage) & arc_ext;
         begin
            if DIR.Exists (tball) then
               DIR.Delete_File (tball);
            end if;
         end delete_subpackage;

      begin
         all_ports (pndx).subpackages.Iterate (delete_subpackage'Access);
      end force_delete;

   begin
      portlist.Iterate (Process => force_delete'Access);
   end delete_existing_packages_of_ports_list;


   --------------------------------------------------------------------------------------------
   --  next_ignored_port
   --------------------------------------------------------------------------------------------
   function next_ignored_port return port_id
   is
      list_len : constant Integer := Integer (rank_queue.Length);
      cursor   : ranking_crate.Cursor;
      QR       : queue_record;
      result   : port_id := port_match_failed;
   begin
      if list_len = 0 then
         return result;
      end if;
      cursor := rank_queue.First;
      for k in 1 .. list_len loop
         QR := ranking_crate.Element (Position => cursor);
         if all_ports (QR.ap_index).ignored then
            result := QR.ap_index;
            DPY.insert_history (CYC.assemble_history_record (1, QR.ap_index, DPY.action_ignored));
            run_package_hook (pkg_ignored, QR.ap_index);
            exit;
         end if;
         cursor := ranking_crate.Next (Position => cursor);
      end loop;
      return result;
   end next_ignored_port;


   --------------------------------------------------------------------------------------------
   --  assimulate_substring
   --------------------------------------------------------------------------------------------
   procedure assimulate_substring (history : in out progress_history; substring : String)
   is
      first : constant Positive := history.last_index + 1;
      last  : constant Positive := history.last_index + substring'Length;
   begin
      --  silently fail (this shouldn't be practically possible)
      if last < kfile_content'Last then
         history.content (first .. last) := substring;
      end if;
      history.last_index := last;
   end assimulate_substring;


   --------------------------------------------------------------------------------------------
   --  nv #1
   --------------------------------------------------------------------------------------------
   function nv (name, value : String) return String is
   begin
      return
        LAT.Quotation & name & LAT.Quotation & LAT.Colon &
        LAT.Quotation & value & LAT.Quotation;
   end nv;


   --------------------------------------------------------------------------------------------
   --  nv #2
   --------------------------------------------------------------------------------------------
   function nv (name : String; value : Integer) return String is
   begin
      return LAT.Quotation & name & LAT.Quotation & LAT.Colon & HT.int2str (value);
   end nv;


   --------------------------------------------------------------------------------------------
   --  handle_first_history_entry
   --------------------------------------------------------------------------------------------
   procedure handle_first_history_entry is
   begin
      if history.segment_count = 1 then
         assimulate_substring (history, "[" & LAT.LF & " {" & LAT.LF);
      else
         assimulate_substring (history, " ,{" & LAT.LF);
      end if;
   end handle_first_history_entry;


   --------------------------------------------------------------------------------------------
   --  write_history_json
   --------------------------------------------------------------------------------------------
   procedure write_history_json
   is
      jsonfile : TIO.File_Type;
      filename : constant String := HT.USS (PM.configuration.dir_logs) &
                 "/" & HT.zeropad (history.segment, 2) & "_history.json";
   begin
      if history.segment_count = 0 then
         return;
      end if;
      if history.last_written = history.last_index then
         return;
      end if;
      TIO.Create (File => jsonfile,
                  Mode => TIO.Out_File,
                  Name => filename);
      TIO.Put (jsonfile, history.content (1 .. history.last_index));
      TIO.Put (jsonfile, "]");
      TIO.Close (jsonfile);
      history.last_written := history.last_index;
   exception
      when others =>
         if TIO.Is_Open (jsonfile) then
            TIO.Close (jsonfile);
         end if;
   end write_history_json;


   --------------------------------------------------------------------------------------------
   --  check_history_segment_capacity
   --------------------------------------------------------------------------------------------
   procedure check_history_segment_capacity is
   begin
      if history.segment_count = 1 then
         history.segment := history.segment + 1;
         return;
      end if;
      if history.segment_count < kfile_units_limit then
         return;
      end if;
      write_history_json;

      history.last_index    := 0;
      history.last_written  := 0;
      history.segment_count := 0;
   end check_history_segment_capacity;


   --------------------------------------------------------------------------------------------
   --  record_history_ignored
   --------------------------------------------------------------------------------------------
   procedure record_history_ignored
     (elapsed   : String;
      origin    : String;
      reason    : String;
      skips     : Natural)
   is
      cleantxt : constant String := HT.strip_control (reason);
      info : constant String :=
        HT.replace_char
          (HT.replace_char (cleantxt, LAT.Quotation, "&nbsp;"), LAT.Reverse_Solidus, "&#92;")
          & ":|:" & HT.int2str (skips);
   begin
      history.log_entry := history.log_entry + 1;
      history.segment_count := history.segment_count + 1;
      handle_first_history_entry;

      assimulate_substring (history, "   " & nv ("entry", history.log_entry) & LAT.LF);
      assimulate_substring (history, "  ," & nv ("elapsed", elapsed) & LAT.LF);
      assimulate_substring (history, "  ," & nv ("ID", "--") & LAT.LF);
      assimulate_substring (history, "  ," & nv ("result", "ignored") & LAT.LF);
      assimulate_substring (history, "  ," & nv ("origin", origin) & LAT.LF);
      assimulate_substring (history, "  ," & nv ("info", info) & LAT.LF);
      assimulate_substring (history, "  ," & nv ("duration", "--:--:--") & LAT.LF);
      assimulate_substring (history, " }" & LAT.LF);

      check_history_segment_capacity;
   end record_history_ignored;


   --------------------------------------------------------------------------------------------
   --  record_history_skipped
   --------------------------------------------------------------------------------------------
   procedure record_history_skipped
     (elapsed   : String;
      origin    : String;
      reason    : String)
   is
   begin
      history.log_entry := history.log_entry + 1;
      history.segment_count := history.segment_count + 1;
      handle_first_history_entry;

      assimulate_substring (history, "   " & nv ("entry", history.log_entry) & LAT.LF);
      assimulate_substring (history, "  ," & nv ("elapsed", elapsed) & LAT.LF);
      assimulate_substring (history, "  ," & nv ("ID", "--") & LAT.LF);
      assimulate_substring (history, "  ," & nv ("result", "skipped") & LAT.LF);
      assimulate_substring (history, "  ," & nv ("origin", origin) & LAT.LF);
      assimulate_substring (history, "  ," & nv ("info", reason) & LAT.LF);
      assimulate_substring (history, "  ," & nv ("duration", "--:--:--") & LAT.LF);
      assimulate_substring (history, " }" & LAT.LF);

      check_history_segment_capacity;
   end record_history_skipped;


   --------------------------------------------------------------------------------------------
   --  skip_verified
   --------------------------------------------------------------------------------------------
   function skip_verified (id : port_id) return Boolean is
   begin
      if id = port_match_failed then
         return False;
      end if;
      return not all_ports (id).unlist_failed;
   end skip_verified;


   --------------------------------------------------------------------------------------------
   --  delete_rank
   --------------------------------------------------------------------------------------------
   procedure delete_rank (id : port_id)
   is
      rank_cursor : ranking_crate.Cursor := rank_arrow (id);
      use type ranking_crate.Cursor;
   begin
      if rank_cursor /= ranking_crate.No_Element then
         rank_queue.Delete (Position => rank_cursor);
      end if;
   end delete_rank;


   --------------------------------------------------------------------------------------------
   --  still_ranked
   --------------------------------------------------------------------------------------------
   function still_ranked (id : port_id) return Boolean
   is
      rank_cursor : ranking_crate.Cursor := rank_arrow (id);
      use type ranking_crate.Cursor;
   begin
      return rank_cursor /= ranking_crate.No_Element;
   end still_ranked;


   --------------------------------------------------------------------------------------------
   --  unlist_port
   --------------------------------------------------------------------------------------------
   procedure unlist_port (id : port_id) is
   begin
      if id = port_match_failed then
         return;
      end if;
      if still_ranked (id) then
         delete_rank (id);
      else
         --  don't raise exception.  Since we don't prune all_reverse as
         --  we go, there's no guarantee the reverse dependency hasn't already
         --  been removed (e.g. when it is a common reverse dep)
         all_ports (id).unlist_failed := True;
      end if;
   end unlist_port;


   --------------------------------------------------------------------------------------------
   --  rank_arrow
   --------------------------------------------------------------------------------------------
   function rank_arrow (id : port_id) return ranking_crate.Cursor
   is
      rscore : constant port_index := all_ports (id).reverse_score;
      seek_target : constant queue_record := (ap_index      => id,
                                              reverse_score => rscore);
   begin
      return rank_queue.Find (seek_target);
   end rank_arrow;


   --------------------------------------------------------------------------------------------
   --  skip_next_reverse_dependency
   --------------------------------------------------------------------------------------------
   function skip_next_reverse_dependency (pinnacle : port_id) return port_id
   is
      rev_cursor : block_crate.Cursor;
      next_dep : port_index;
   begin
      if all_ports (pinnacle).all_reverse.Is_Empty then
         return port_match_failed;
      end if;
      rev_cursor := all_ports (pinnacle).all_reverse.First;
      next_dep := block_crate.Element (rev_cursor);
      unlist_port (id => next_dep);
      all_ports (pinnacle).all_reverse.Delete (rev_cursor);

      return next_dep;
   end skip_next_reverse_dependency;


   --------------------------------------------------------------------------------------------
   --  cascade_failed_build
   --------------------------------------------------------------------------------------------
   procedure cascade_failed_build (id : port_id; numskipped : out Natural)
   is
      purged  : PortScan.port_id;
      culprit : constant String := get_port_variant (id);
   begin
      numskipped := 0;
      loop
         purged := skip_next_reverse_dependency (id);
         exit when purged = port_match_failed;
         if skip_verified (purged) then
            numskipped := numskipped + 1;
            LOG.scribe (PortScan.total, "           Skipped: " & get_port_variant (purged), False);
            LOG.scribe (PortScan.skipped, get_port_variant (purged) & " by " & culprit, False);
            DPY.insert_history (CYC.assemble_history_record (1, purged, DPY.action_skipped));
            record_history_skipped (elapsed => LOG.elapsed_now,
                                    origin  => get_port_variant (purged),
                                    reason  => culprit);
            run_package_hook (pkg_skipped, purged);
         end if;
      end loop;
      unlist_port (id);
   end cascade_failed_build;


   --------------------------------------------------------------------------------------------
   --  cascade_successful_build
   --------------------------------------------------------------------------------------------
   procedure cascade_successful_build (id : port_id)
   is
      procedure cycle (cursor : block_crate.Cursor);
      procedure cycle (cursor : block_crate.Cursor)
      is
         target : constant port_index := block_crate.Element (cursor);
      begin
         if all_ports (target).blocked_by.Contains (Key => id) then
            all_ports (target).blocked_by.Delete (Key => id);
         else
            raise seek_failure
              with  get_port_variant (target) & " was expected to be blocked by " &
              get_port_variant (id);
         end if;
      end cycle;
   begin
      all_ports (id).blocks.Iterate (cycle'Access);
      delete_rank (id);
   end cascade_successful_build;


   --------------------------------------------------------------------------------------------
   --  integrity_intact
   --------------------------------------------------------------------------------------------
   function integrity_intact return Boolean
   is
      procedure check_dep (cursor : block_crate.Cursor);
      procedure check_rank (cursor : ranking_crate.Cursor);

      intact : Boolean := True;
      procedure check_dep (cursor : block_crate.Cursor)
      is
         did : constant port_index := block_crate.Element (cursor);
      begin
         if not still_ranked (did) then
            intact := False;
         end if;
      end check_dep;

      procedure check_rank (cursor : ranking_crate.Cursor)
      is
         QR : constant queue_record := ranking_crate.Element (cursor);
      begin
         if intact then
            all_ports (QR.ap_index).blocked_by.Iterate (check_dep'Access);
         end if;
      end check_rank;
   begin
      rank_queue.Iterate (check_rank'Access);
      return intact;
   end integrity_intact;


   --------------------------------------------------------------------------------------------
   --  limited_cached_options_check
   --------------------------------------------------------------------------------------------
   function limited_cached_options_check return Boolean
   is
      --  TODO: Implement options
   begin
      return True;
   end limited_cached_options_check;


   --------------------------------------------------------------------------------------------
   --  located_external_repository
   --------------------------------------------------------------------------------------------
   function located_external_repository return Boolean
   is
      command : constant String := host_pkg8 & " -vv";
      found   : Boolean := False;
      inspect : Boolean := False;
      status  : Integer;
   begin
      declare
         dump    : String := HT.USS (Unix.piped_command (command, status));
         markers : HT.Line_Markers;
         linenum : Natural := 0;
      begin
         if status /= 0 then
            return False;
         end if;
         HT.initialize_markers (dump, markers);
         loop
            exit when not HT.next_line_present (dump, markers);
            declare
               line : constant String := HT.extract_line (dump, markers);
               len  : constant Natural := line'Length;
            begin
               if inspect then
                  if len > 7 and then
                    line (1 .. 2) = "  " and then
                    line (len - 3 .. len) = ": { " and then
                    line (3 .. len - 4) /= "ravenadm"
                  then
                     found := True;
                     external_repository := HT.SUS (line (3 .. len - 4));
                     exit;
                  end if;
               else
                  if line = "Repositories:" then
                     inspect := True;
                  end if;
               end if;
            end;
         end loop;
      end;
      return found;
   end located_external_repository;


   --------------------------------------------------------------------------------------------
   --  top_external_repository
   --------------------------------------------------------------------------------------------
   function top_external_repository return String is
   begin
      return HT.USS (external_repository);
   end top_external_repository;


   --------------------------------------------------------------------------------------------
   --  establish_package_architecture
   --------------------------------------------------------------------------------------------
   function isolate_arch_from_file_type (fileinfo : String) return filearch
   is
      --  DF: ELF 64-bit LSB executable, x86-64
      --  FB: ELF 64-bit LSB executable, x86-64
      --  FB: ELF 32-bit LSB executable, Intel 80386
      --  NB: ELF 64-bit LSB executable, x86-64
      --   L: ELF 64-bit LSB executable, x86-64
      --  NATIVE Solaris (we use our own file)
      --  /usr/bin/sh:    ELF 64-bit LSB executable AMD64 Version 1
   begin
      return fileinfo (fileinfo'First + 27 .. fileinfo'First + 37);
   end isolate_arch_from_file_type;


   --------------------------------------------------------------------------------------------
   --  establish_package_architecture
   --------------------------------------------------------------------------------------------
   procedure establish_package_architecture
   is
      function newsuffix (arch : filearch) return String;
      function suffix    (arch : filearch) return String;
      function get_major (fileinfo : String; OS : String) return String;
      function even      (fileinfo : String) return String;

      sysroot : constant String := HT.USS (PM.configuration.dir_sysroot);
      command : constant String := sysroot & "/usr/bin/file -b " & sysroot & "/bin/sh";
      status  : Integer;
      arch    : filearch;
      UN      : HT.Text;

      function suffix (arch : filearch) return String is
      begin
         if arch (arch'First .. arch'First + 5) = "x86-64" or else
           arch (arch'First .. arch'First + 4) = "AMD64"
         then
            return "x86:64";
         elsif arch = "Intel 80386" then
            return "x86:32";
         else
            return "unknown:" & arch;
         end if;
      end suffix;

      function newsuffix (arch : filearch) return String is
      begin
         if arch (arch'First .. arch'First + 5) = "x86-64" or else
           arch (arch'First .. arch'First + 4) = "AMD64"
         then
            return "amd64";
         elsif arch = "Intel 80386" then
            return "i386";
         else
            return "unknown:" & arch;
         end if;
      end newsuffix;

      function even (fileinfo : String) return String
      is
         --  DF  4.5-DEVELOPMENT: ... DragonFly 4.0.501
         --  DF 4.10-RELEASE    : ... DragonFly 4.0.1000
         --  DF 4.11-DEVELOPMENT: ... DragonFly 4.0.1102
         --
         --  Alternative future format (file version 2.0)
         --  DFV 400702: ... DragonFly 4.7.2
         --  DFV 401117: ..  DragonFly 4.11.17
         rest  : constant String := HT.part_2 (fileinfo, "DragonFly ");
         major : constant String := HT.specific_field (rest, 1, ".");
         part2 : constant String := HT.specific_field (rest, 2, ".");
         part3 : constant String := HT.part_1 (HT.specific_field (rest, 3, "."), ",");
         minor : String (1 .. 2) := "00";
         point : Character;
      begin
         if part2 = "0" then
            --  version format in October 2016
            declare
               mvers : String (1 .. 4) := "0000";
               lenp3 : constant Natural := part3'Length;
            begin
               mvers (mvers'Last - lenp3 + 1 .. mvers'Last) := part3;
               minor := mvers (1 .. 2);
            end;
         else
            --  Alternative future format (file version 2.0)
            declare
               lenp2 : constant Natural := part2'Length;
            begin
               minor (minor'Last - lenp2 + 1 .. minor'Last) := part2;
            end;
         end if;

         point := minor (2);
         case point is
            when '1' => minor (2) := '2';
            when '3' => minor (2) := '4';
            when '5' => minor (2) := '6';
            when '7' => minor (2) := '8';
            when '9' => minor (2) := '0';
                        minor (1) := Character'Val (Character'Pos (minor (1)) + 1);
            when others => null;
         end case;
         if minor (1) = '0' then
            return major & "." & minor (2);
         else
            return major & "." & minor (1 .. 2);
         end if;

      end even;

      function get_major (fileinfo : String; OS : String) return String
      is
         --  FreeBSD 10.2, stripped
         --  FreeBSD 11.0 (1100093), stripped
         --  NetBSD 7.0.1, not stripped
         rest  : constant String := HT.part_2 (fileinfo, OS);
         major : constant String := HT.part_1 (rest, ".");
      begin
         return major;
      end get_major;

   begin
      UN   := Unix.piped_command (command, status);
      arch := isolate_arch_from_file_type (HT.USS (UN));
      case platform_type is
         when dragonfly =>
            declare
               dfly    : constant String := "dragonfly:";
               release : constant String := even (HT.USS (UN));
            begin
               abi_formats.calculated_abi := HT.SUS (dfly);
               HT.SU.Append (abi_formats.calculated_abi, release & ":");
               abi_formats.calc_abi_noarch := abi_formats.calculated_abi;
               HT.SU.Append (abi_formats.calculated_abi, suffix (arch));
               HT.SU.Append (abi_formats.calc_abi_noarch, "*");
               abi_formats.calculated_alt_abi  := abi_formats.calculated_abi;
               abi_formats.calc_alt_abi_noarch := abi_formats.calc_abi_noarch;
            end;
         when freebsd =>
            declare
               fbsd1   : constant String := "FreeBSD:";
               fbsd2   : constant String := "freebsd:";
               release : constant String := get_major (HT.USS (UN), "FreeBSD ");
            begin
               abi_formats.calculated_abi     := HT.SUS (fbsd1);
               abi_formats.calculated_alt_abi := HT.SUS (fbsd2);
               HT.SU.Append (abi_formats.calculated_abi, release & ":");
               HT.SU.Append (abi_formats.calculated_alt_abi, release & ":");
               abi_formats.calc_abi_noarch     := abi_formats.calculated_abi;
               abi_formats.calc_alt_abi_noarch := abi_formats.calculated_alt_abi;
               HT.SU.Append (abi_formats.calculated_abi, newsuffix (arch));
               HT.SU.Append (abi_formats.calculated_alt_abi, suffix (arch));
               HT.SU.Append (abi_formats.calc_abi_noarch, "*");
               HT.SU.Append (abi_formats.calc_alt_abi_noarch, "*");
            end;
         when netbsd =>
            declare
               net1     : constant String := "NetBSD:";
               net2     : constant String := "netbsd:";
               release  : constant String := get_major (HT.USS (UN), "NetBSD ");
            begin
               abi_formats.calculated_abi     := HT.SUS (net1);
               abi_formats.calculated_alt_abi := HT.SUS (net2);
               HT.SU.Append (abi_formats.calculated_abi, release & ":");
               HT.SU.Append (abi_formats.calculated_alt_abi, release & ":");
               abi_formats.calc_abi_noarch     := abi_formats.calculated_abi;
               abi_formats.calc_alt_abi_noarch := abi_formats.calculated_alt_abi;
               HT.SU.Append (abi_formats.calculated_abi, newsuffix (arch));
               HT.SU.Append (abi_formats.calculated_alt_abi, suffix (arch));
               HT.SU.Append (abi_formats.calc_abi_noarch, "*");
               HT.SU.Append (abi_formats.calc_alt_abi_noarch, "*");
            end;
         when linux   => null;  --  TBD (check ABI first)
         when sunos   => null;  --  TBD (check ABI first)
         when macos   => null;
         when openbsd => null;
      end case;
   end establish_package_architecture;


   --------------------------------------------------------------------------------------------
   --  limited_sanity_check
   --------------------------------------------------------------------------------------------
   procedure limited_sanity_check
     (repository      : String;
      dry_run         : Boolean;
      suppress_remote : Boolean)
   is
      procedure prune_packages (cursor : ranking_crate.Cursor);
      procedure check_package (cursor : ranking_crate.Cursor);
      procedure prune_queue (cursor : subqueue.Cursor);
      procedure print (cursor : subqueue.Cursor);
      procedure fetch (cursor : subqueue.Cursor);
      procedure check (cursor : subqueue.Cursor);
      procedure set_delete  (Element : in out subpackage_record);
      procedure kill_remote (Element : in out subpackage_record);

      already_built : subqueue.Vector;
      fetch_list    : subqueue.Vector;
      fetch_fail    : Boolean := False;
      clean_pass    : Boolean := False;
      listlog       : TIO.File_Type;
      goodlog       : Boolean;
      using_screen  : constant Boolean := Unix.screen_attached;
      filename      : constant String := "/tmp/synth_prefetch_list.txt";
      package_list  : HT.Text := HT.blank;

      procedure set_delete (Element : in out subpackage_record) is
      begin
         Element.deletion_due := True;
      end set_delete;

      procedure kill_remote (Element : in out subpackage_record) is
      begin
         Element.remote_pkg := False;
      end kill_remote;

      procedure check_package (cursor : ranking_crate.Cursor)
      is
         procedure check_subpackage (position : subpackage_crate.Cursor);

         target : port_id := ranking_crate.Element (cursor).ap_index;

         procedure check_subpackage (position : subpackage_crate.Cursor)
         is
            rec        : subpackage_record renames subpackage_crate.Element (position);
            subpackage : constant String  := HT.USS (rec.subpackage);
            pkgname    : constant String  := calculate_package_name (target, subpackage);
            available  : constant Boolean :=
                         (rec.remote_pkg or else rec.pkg_present) and then not rec.deletion_due;
         begin
            if not available then
               return;
            end if;

            if passed_dependency_check (query_result => rec.pkg_dep_query, id => target) then
               already_built.Append (New_Item => target);
               if rec.remote_pkg then
                  fetch_list.Append (New_Item => target);
               end if;
            else
               if rec.remote_pkg then
                  --  silently fail, remote packages are a bonus anyway
                  all_ports (target).subpackages.Update_Element (Position => position,
                                                                 Process  => kill_remote'Access);
               else
                  TIO.Put_Line (pkgname & " failed dependency check.");
                  all_ports (target).subpackages.Update_Element (Position => position,
                                                                 Process  => set_delete'Access);
               end if;
               clean_pass := False;
            end if;
         end check_subpackage;
      begin
         all_ports (target).subpackages.Iterate (check_subpackage'Access);
      end check_package;

      procedure prune_queue (cursor : subqueue.Cursor)
      is
         id : constant port_index := subqueue.Element (cursor);
      begin
         cascade_successful_build (id);
      end prune_queue;

      procedure prune_packages (cursor : ranking_crate.Cursor)
      is
         procedure check_subpackage (position : subpackage_crate.Cursor);

         target : port_id := ranking_crate.Element (cursor).ap_index;

         procedure check_subpackage (position : subpackage_crate.Cursor)
         is
            rec        : subpackage_record renames subpackage_crate.Element (position);
            delete_it  : Boolean := rec.deletion_due;
         begin
            if delete_it then
               declare
                  subpackage : constant String  := HT.USS (rec.subpackage);
                  pkgname    : constant String  := calculate_package_name (target, subpackage);
                  fullpath   : constant String := repository & "/" & pkgname & arc_ext;
               begin
                  DIR.Delete_File (fullpath);
               exception
                  when others => null;
               end;
            end if;
         end check_subpackage;

      begin
         all_ports (target).subpackages.Iterate (check_subpackage'Access);
      end prune_packages;

      procedure print (cursor : subqueue.Cursor)
      is
         function postinfo return String;

         id   : constant port_index := subqueue.Element (cursor);

         function postinfo return String
         is
            scount : Natural := Natural (all_ports (id).subpackages.Length);
         begin
            if scount = 1 then
               return " (1 subpackage)";
            else
               return " (" & HT.int2str (scount) & " subpackages)";
            end if;
         end postinfo;

         line : constant String := get_port_variant (all_ports (id)) & postinfo;
      begin
         TIO.Put_Line ("  => " & line);
         if goodlog then
            TIO.Put_Line (listlog, line);
         end if;
      end print;

      procedure fetch (cursor : subqueue.Cursor)
      is
         id  : constant port_index := subqueue.Element (cursor);
      begin
         HT.SU.Append (package_list, " " & id2pkgname (id));
      end fetch;

      procedure check (cursor : subqueue.Cursor)
      is
         id   : constant port_index := subqueue.Element (cursor);
         name : constant String := HT.USS (all_ports (id).package_name);
         loc  : constant String := HT.USS (PM.configuration.dir_repository) & "/" & name;
      begin
         if not DIR.Exists (loc) then
            TIO.Put_Line ("Download failed: " & name);
            fetch_fail := True;
         end if;
      end check;
   begin
      if Unix.env_variable_defined ("WHYFAIL") then
         activate_debugging_code;
      end if;
      establish_package_architecture;
      original_queue_len := rank_queue.Length;
      for m in scanners'Range loop
         mq_progress (m) := 0;
      end loop;
      LOG.start_obsolete_package_logging;
      parallel_package_scan (repository, False, using_screen);

      if Signals.graceful_shutdown_requested then
         LOG.stop_obsolete_package_logging;
         return;
      end if;

      while not clean_pass loop
         clean_pass := True;
         already_built.Clear;
         rank_queue.Iterate (check_package'Access);
      end loop;
      if not suppress_remote and then PM.configuration.defer_prebuilt then
         --  The defer_prebuilt options has been elected, so check all the
         --  missing and to-be-pruned ports for suitable prebuilt packages
         --  So we need to an incremental scan (skip valid, present packages)
         for m in scanners'Range loop
            mq_progress (m) := 0;
         end loop;
         parallel_package_scan (repository, True, using_screen);

         if Signals.graceful_shutdown_requested then
            LOG.stop_obsolete_package_logging;
            return;
         end if;

         clean_pass := False;
         while not clean_pass loop
            clean_pass := True;
            already_built.Clear;
            fetch_list.Clear;
            rank_queue.Iterate (check_package'Access);
         end loop;
      end if;
      LOG.stop_obsolete_package_logging;
      if Signals.graceful_shutdown_requested then
         return;
      end if;
      if dry_run then
         if not fetch_list.Is_Empty then
            begin
               TIO.Create (File => listlog, Mode => TIO.Out_File, Name => filename);
               goodlog := True;
            exception
               when others => goodlog := False;
            end;
            TIO.Put_Line ("These are the packages that would be fetched:");
            fetch_list.Iterate (print'Access);
            TIO.Put_Line ("Total packages that would be fetched:" & fetch_list.Length'Img);
            if goodlog then
               TIO.Close (listlog);
               TIO.Put_Line ("The complete build list can also be found at:"
                             & LAT.LF & filename);
            end if;
         else
            if PM.configuration.defer_prebuilt then
               TIO.Put_Line ("No packages qualify for prefetching from " &
                               "official package repository.");
            end if;
         end if;
      else
         rank_queue.Iterate (prune_packages'Access);
         fetch_list.Iterate (fetch'Access);
         if not HT.equivalent (package_list, HT.blank) then
            declare
               cmd : constant String := host_pkg8 & " fetch -r " &
                 HT.USS (external_repository) & " -U -y --output " &
                 HT.USS (PM.configuration.dir_packages) & HT.USS (package_list);
            begin
               if Unix.external_command (cmd) then
                  null;
               end if;
            end;
            fetch_list.Iterate (check'Access);
         end if;
      end if;
      if fetch_fail then
         TIO.Put_Line ("At least one package failed to fetch, aborting build!");
         rank_queue.Clear;
      else
         already_built.Iterate (prune_queue'Access);
      end if;
   end limited_sanity_check;


   --------------------------------------------------------------------------------------------
   --  passed_dependency_check
   --------------------------------------------------------------------------------------------
   function result_of_dependency_query
     (repository : String;
      id         : port_id;
      subpackage : String) return HT.Text
   is
      rec : port_record renames all_ports (id);

      pkg_base : constant String := PortScan.calculate_package_name (id, subpackage);
      fullpath : constant String := repository & "/" & pkg_base & arc_ext;
      pkg8     : constant String := HT.USS (PM.configuration.sysroot_pkg8);
      command  : constant String := pkg8 & " query -F "  & fullpath & " %dn-%dv@%do";
      remocmd  : constant String := pkg8 & " rquery -r " & HT.USS (external_repository) &
                                    " -U %dn-%dv@%do " & pkg_base;
      status   : Integer;
      comres   : HT.Text;
   begin
      if repository = "" then
         comres := Unix.piped_command (remocmd, status);
      else
         comres := Unix.piped_command (command, status);
      end if;
      if status = 0 then
         return comres;
      else
         return HT.blank;
      end if;
   end result_of_dependency_query;


   --------------------------------------------------------------------------------------------
   --  activate_debugging_code
   --------------------------------------------------------------------------------------------
   procedure activate_debugging_code is
   begin
      debug_opt_check := True;
      debug_dep_check := True;
   end activate_debugging_code;


   --------------------------------------------------------------------------------------------
   --  passed_dependency_check
   --------------------------------------------------------------------------------------------
   function passed_dependency_check (query_result : HT.Text; id : port_id) return Boolean
   is
      content  : String := HT.USS (query_result);
      req_deps : constant Natural := Natural (all_ports (id).run_deps.Length);
      headport : constant String := get_port_variant (all_ports (id));
      counter  : Natural := 0;
      markers  : HT.Line_Markers;
   begin
      HT.initialize_markers (content, markers);
      loop
         exit when not HT.next_line_present (content, markers);
         declare
            line   : constant String := HT.extract_line (content, markers);
            deppkg : constant String := HT.part_1 (line, "@");
            origin : constant String := HT.part_2 (line, "@");
         begin
            exit when line = "";
            declare
               procedure set_available (position : subpackage_crate.Cursor);

               portkey    : String := convert_origin_to_portkey (origin);
               subpackage : String := subpackage_from_origin (origin);
               target_id  : port_index := ports_keys.Element (HT.SUS (portkey));
               target_pkg : String := HT.replace_all (origin, LAT.Colon, LAT.Hyphen) &
                                      LAT.Hyphen & HT.USS (all_ports (target_id).pkgversion);
               found      : Boolean := False;
               available  : Boolean;

               procedure set_available (position : subpackage_crate.Cursor)
               is
                  rec : subpackage_record renames subpackage_crate.Element (position);
               begin
                  if not found and then
                    HT.USS (rec.subpackage) = subpackage
                  then
                     available := (rec.remote_pkg or else rec.pkg_present) and then
                       rec.deletion_due;
                     found := True;
                  end if;
               end set_available;
            begin
               if valid_port_id (target_id) then
                  all_ports (target_id).subpackages.Iterate (set_available'Access);
               else
                  --  package seems to have a dependency that has been removed from the conspiracy
                  LOG.obsolete_notice
                    (message         => portkey & " has been removed from Ravenports",
                     write_to_screen => debug_dep_check);
                  return False;
               end if;

               counter := counter + 1;
               if counter > req_deps then
                  --  package has more dependencies than we are looking for
                  LOG.obsolete_notice
                    (write_to_screen => debug_dep_check,
                     message         => headport & " package has more dependencies than the " &
                       "port requires (" & HT.int2str (req_deps) & ")" & LAT.LF &
                       "Query: " & HT.USS (query_result) & LAT.LF &
                       "Tripped on: " & line);
                  return False;
               end if;

               if deppkg /= target_pkg then
                  --  The version that the package requires differs from the
                  --  version that Ravenports will now produce
                  LOG.obsolete_notice
                    (write_to_screen => debug_dep_check,
                     message         =>  "Current " & headport & " package depends on " &
                       deppkg & ", but this is a different version than requirement of " &
                       target_pkg & " (from " & origin & ")");
                  return False;
               end if;

               if not available then
                  --  Even if all the versions are matching, we still need
                  --  the package to be in repository.
                  LOG.obsolete_notice
                    (write_to_screen => debug_dep_check,
                     message         => headport & " package depends on " & target_pkg &
                       " which doesn't exist or has been scheduled for deletion");
                  return False;
               end if;
            end;
         end;
      end loop;

      if counter < req_deps then
         --  The ports tree requires more dependencies than the existing package does
         LOG.obsolete_notice
           (write_to_screen => debug_dep_check,
            message         => headport & " package has less dependencies than the port " &
              "requires (" & HT.int2str (req_deps) & ")" & LAT.LF &
              "Query: " & HT.USS (query_result));
         return False;
      end if;

      --  If we get this far, the package dependencies match what the
      --  port tree requires exactly.  This package passed sanity check.
      return True;

   exception
      when issue : others =>
         LOG.obsolete_notice
           (write_to_screen => debug_dep_check,
            message         => "Dependency check exception" & LAT.LF &
              EX.Exception_Message (issue));
         return False;
   end passed_dependency_check;


   --------------------------------------------------------------------------------------------
   --  package_scan_progress
   --------------------------------------------------------------------------------------------
   function package_scan_progress return String
   is
      type percent is delta 0.01 digits 5;
      complete : port_index := 0;
      pc : percent;
      total : constant Float := Float (pkgscan_total);
   begin
      for k in scanners'Range loop
         complete := complete + pkgscan_progress (k);
      end loop;
      pc := percent (100.0 * Float (complete) / total);
      return " progress:" & pc'Img & "%              " & LAT.CR;
   end package_scan_progress;


   --------------------------------------------------------------------------------------------
   --  passed_abi_check
   --------------------------------------------------------------------------------------------
   function passed_abi_check
     (repository       : String;
      id               : port_id;
      subpackage       : String;
      skip_exist_check : Boolean := False) return Boolean
   is
      rec : port_record renames all_ports (id);

      pkg_base : constant String := PortScan.calculate_package_name (id, subpackage);
      fullpath : constant String := repository & "/" & pkg_base & arc_ext;
      pkg8     : constant String := HT.USS (PM.configuration.sysroot_pkg8);
      command  : constant String := pkg8 & " query -F "  & fullpath & " %q";
      remocmd  : constant String := pkg8 & " rquery -r " & HT.USS (external_repository) &
                                    " -U %q " & pkg_base;
      status : Integer;
      comres : HT.Text;
   begin
      if not skip_exist_check and then not DIR.Exists (Name => fullpath)
      then
         return False;
      end if;

      if repository = "" then
         comres := Unix.piped_command (remocmd, status);
      else
         comres := Unix.piped_command (command, status);
      end if;
      if status /= 0 then
         return False;
      end if;
      declare
         topline : String := HT.first_line (HT.USS (comres));
      begin
         if HT.equivalent (abi_formats.calculated_abi, topline) or else
           HT.equivalent (abi_formats.calculated_alt_abi, topline) or else
           HT.equivalent (abi_formats.calc_abi_noarch, topline) or else
           HT.equivalent (abi_formats.calc_alt_abi_noarch, topline)
         then
            return True;
         end if;
      end;
      return False;
   end passed_abi_check;


   --------------------------------------------------------------------------------------------
   --  passed_option_check
   --------------------------------------------------------------------------------------------
   function passed_option_check
     (repository       : String;
      id               : port_id;
      subpackage       : String;
      skip_exist_check : Boolean := False) return Boolean
   is
      rec : port_record renames all_ports (id);

      pkg_base : constant String := PortScan.calculate_package_name (id, subpackage);
      fullpath : constant String := repository & "/" & pkg_base & arc_ext;
      pkg8     : constant String := HT.USS (PM.configuration.sysroot_pkg8);
      command  : constant String := pkg8 & " query -F "  & fullpath & " %Ok:%Ov";
      remocmd  : constant String := pkg8 & " rquery -r " & HT.USS (external_repository) &
                                    " -U %Ok:%Ov " & pkg_base;
      status   : Integer;
      comres   : HT.Text;
      counter  : Natural := 0;
      required : constant Natural := Natural (all_ports (id).options.Length);
   begin
      if id = port_match_failed or else
        not all_ports (id).scanned or else
        (not skip_exist_check and then not DIR.Exists (fullpath))
      then
         return False;
      end if;

      if repository = "" then
         comres := Unix.piped_command (remocmd, status);
      else
         comres := Unix.piped_command (command, status);
      end if;
      if status /= 0 then
         return False;
      end if;

      declare
         command_result : constant String := HT.USS (comres);
         markers  : HT.Line_Markers;
      begin
         HT.initialize_markers (command_result, markers);
         loop
            exit when not HT.next_line_present (command_result, markers);
            declare
               line     : constant String := HT.extract_line (command_result, markers);
               namekey  : constant String := HT.part_1 (line, ":");
               knob     : constant String := HT.part_2 (line, ":");
               nametext : HT.Text := HT.SUS (namekey);
               knobval  : Boolean;
            begin
               exit when line = "";
               if HT.count_char (line, LAT.Colon) /= 1 then
                  raise unknown_format with line;
               end if;
               if knob = "on" then
                  knobval := True;
               elsif knob = "off" then
                  knobval := False;
               else
                  raise unknown_format with "knob=" & knob & "(" & line & ")";
               end if;

               counter := counter + 1;
               if counter > required then
                  --  package has more options than we are looking for
                  LOG.obsolete_notice
                    (write_to_screen => debug_opt_check,
                     message => "options " & namekey & LAT.LF & pkg_base &
                       " has more options than required (" & HT.int2str (required) & ")");
                  return False;
               end if;

               if all_ports (id).options.Contains (nametext) then
                  if knobval /= all_ports (id).options.Element (nametext) then
                     --  port option value doesn't match package option value
                     if knobval then
                        LOG.obsolete_notice
                          (write_to_screen => debug_opt_check,
                           message => pkg_base & " " & namekey &
                             " is ON but specifcation says it must be OFF");
                     else
                        LOG.obsolete_notice
                          (write_to_screen => debug_opt_check,
                           message => pkg_base & " " & namekey &
                             " is OFF but specifcation says it must be ON");
                     end if;
                     return False;
                  end if;
               else
                  --  Name of package option not found in port options
                  LOG.obsolete_notice
                    (write_to_screen => debug_opt_check,
                     message => pkg_base & " option " & namekey &
                       " is no longer present in the specification");
                  return False;
               end if;
            end;
         end loop;

         if counter < required then
            --  The ports tree has more options than the existing package
            LOG.obsolete_notice
              (write_to_screen => debug_opt_check,
               message => pkg_base & " has less options than required (" &
                 HT.int2str (required) & ")");
            return False;
         end if;

         --  If we get this far, the package options must match port options
         return True;
      end;
   exception
      when issue : others =>
         LOG.obsolete_notice
           (write_to_screen => debug_opt_check,
            message => "option check exception" & LAT.LF & EX.Exception_Message (issue));
         return False;
   end passed_option_check;


   --------------------------------------------------------------------------------------------
   --  initial_package_scan
   --------------------------------------------------------------------------------------------
   procedure initial_package_scan (repository : String; id : port_id; subpackage : String)
   is
      procedure set_position (position : subpackage_crate.Cursor);
      procedure set_delete   (Element : in out subpackage_record);
      procedure set_present  (Element : in out subpackage_record);
      procedure set_query    (Element : in out subpackage_record);

      subpackage_position : subpackage_crate.Cursor := subpackage_crate.No_Element;
      query_result        : HT.Text;

      procedure set_position (position : subpackage_crate.Cursor)
      is
         rec : subpackage_record renames subpackage_crate.Element (position);
      begin
         if HT.USS (rec.subpackage) = subpackage then
            subpackage_position := position;
         end if;
      end set_position;
      procedure set_delete (Element : in out subpackage_record) is
      begin
         Element.deletion_due := True;
      end set_delete;
      procedure set_present (Element : in out subpackage_record) is
      begin
         Element.pkg_present := True;
      end set_present;
      procedure set_query (Element : in out subpackage_record) is
      begin
         Element.pkg_dep_query := query_result;
      end set_query;

      use type subpackage_crate.Cursor;
   begin
      if id = port_match_failed or else
        not all_ports (id).scanned
      then
           return;
      end if;

      all_ports (id).subpackages.Iterate (set_position'Access);
      if subpackage_position = subpackage_crate.No_Element then
         return;
      end if;

      declare
         pkgname  : constant String := calculate_package_name (id, subpackage);
         fullpath : constant String := repository & "/" & pkgname & arc_ext;
         msg_opt  : constant String := pkgname & " failed option check.";
         msg_abi  : constant String := pkgname & " failed architecture (ABI) check.";
      begin
         if DIR.Exists (fullpath) then
            all_ports (id).subpackages.Update_Element (subpackage_position, set_present'Access);
         else
            return;
         end if;
         if not passed_option_check (repository, id, subpackage, True) then
            LOG.obsolete_notice (msg_opt, True);
            all_ports (id).subpackages.Update_Element (subpackage_position, set_delete'Access);
            return;
         end if;
         if not passed_abi_check (repository, id, subpackage, True) then
            LOG.obsolete_notice (msg_abi, True);
            all_ports (id).subpackages.Update_Element (subpackage_position, set_delete'Access);
            return;
         end if;
      end;
      query_result := result_of_dependency_query (repository, id, subpackage);
      all_ports (id).subpackages.Update_Element (subpackage_position, set_query'Access);
   end initial_package_scan;


   --------------------------------------------------------------------------------------------
   --  remote_package_scan
   --------------------------------------------------------------------------------------------
   procedure remote_package_scan (id : port_id; subpackage : String)
   is
      procedure set_position   (position : subpackage_crate.Cursor);
      procedure set_remote_on  (Element : in out subpackage_record);
      procedure set_remote_off (Element : in out subpackage_record);
      procedure set_query      (Element : in out subpackage_record);

      subpackage_position : subpackage_crate.Cursor := subpackage_crate.No_Element;
      query_result        : HT.Text;

      procedure set_position (position : subpackage_crate.Cursor)
      is
         rec : subpackage_record renames subpackage_crate.Element (position);
      begin
         if HT.USS (rec.subpackage) = subpackage then
            subpackage_position := position;
         end if;
      end set_position;
      procedure set_remote_on (Element : in out subpackage_record) is
      begin
         Element.remote_pkg := True;
      end set_remote_on;
      procedure set_remote_off (Element : in out subpackage_record) is
      begin
         Element.remote_pkg := False;
      end set_remote_off;
      procedure set_query (Element : in out subpackage_record) is
      begin
         Element.pkg_dep_query := query_result;
      end set_query;

      use type subpackage_crate.Cursor;
   begin
      all_ports (id).subpackages.Iterate (set_position'Access);
      if subpackage_position = subpackage_crate.No_Element then
         return;
      end if;

      if passed_abi_check (repository       => "",
                           id               => id,
                           subpackage       => subpackage,
                           skip_exist_check => True)
      then
         all_ports (id).subpackages.Update_Element (subpackage_position, set_remote_on'Access);
      else
         return;
      end if;
      if not passed_option_check (repository       => "",
                                  id               => id,
                                  subpackage       => subpackage,
                                  skip_exist_check => True)
      then
         all_ports (id).subpackages.Update_Element (subpackage_position, set_remote_off'Access);
         return;
      end if;
      query_result := result_of_dependency_query ("", id, subpackage);
      all_ports (id).subpackages.Update_Element (subpackage_position, set_query'Access);
   end remote_package_scan;


   --------------------------------------------------------------------------------------------
   --  parallel_package_scan
   --------------------------------------------------------------------------------------------
   procedure parallel_package_scan
     (repository    : String;
      remote_scan   : Boolean;
      show_progress : Boolean)
   is
      task type scan (lot : scanners);
      finished : array (scanners) of Boolean := (others => False);
      combined_wait : Boolean := True;
      label_shown   : Boolean := False;
      aborted       : Boolean := False;

      task body scan
      is
         procedure populate (cursor : subqueue.Cursor);
         procedure populate (cursor : subqueue.Cursor)
         is
            procedure check_subpackage (position : subpackage_crate.Cursor);

            target_port : port_index := subqueue.Element (cursor);
            important   : constant Boolean := all_ports (target_port).scanned;

            procedure check_subpackage (position : subpackage_crate.Cursor)
            is
               rec        : subpackage_record renames subpackage_crate.Element (position);
               subpackage : String := HT.USS (rec.subpackage);
            begin
               if not aborted and then important then
                  if remote_scan and then
                    not rec.never_remote
                  then
                     if not rec.pkg_present or else
                       rec.deletion_due
                     then
                        remote_package_scan (target_port, subpackage);
                     end if;
                  else
                     initial_package_scan (repository, target_port, subpackage);
                  end if;
               end if;
            end check_subpackage;

         begin
            all_ports (target_port).subpackages.Iterate (check_subpackage'Access);
            mq_progress (lot) := mq_progress (lot) + 1;
         end populate;
      begin
         make_queue (lot).Iterate (populate'Access);
         finished (lot) := True;
      end scan;

      scan_01 : scan (lot => 1);
      scan_02 : scan (lot => 2);
      scan_03 : scan (lot => 3);
      scan_04 : scan (lot => 4);
      scan_05 : scan (lot => 5);
      scan_06 : scan (lot => 6);
      scan_07 : scan (lot => 7);
      scan_08 : scan (lot => 8);
      scan_09 : scan (lot => 9);
      scan_10 : scan (lot => 10);
      scan_11 : scan (lot => 11);
      scan_12 : scan (lot => 12);
      scan_13 : scan (lot => 13);
      scan_14 : scan (lot => 14);
      scan_15 : scan (lot => 15);
      scan_16 : scan (lot => 16);
      scan_17 : scan (lot => 17);
      scan_18 : scan (lot => 18);
      scan_19 : scan (lot => 19);
      scan_20 : scan (lot => 20);
      scan_21 : scan (lot => 21);
      scan_22 : scan (lot => 22);
      scan_23 : scan (lot => 23);
      scan_24 : scan (lot => 24);
      scan_25 : scan (lot => 25);
      scan_26 : scan (lot => 26);
      scan_27 : scan (lot => 27);
      scan_28 : scan (lot => 28);
      scan_29 : scan (lot => 29);
      scan_30 : scan (lot => 30);
      scan_31 : scan (lot => 31);
      scan_32 : scan (lot => 32);
   begin
      while combined_wait loop
         delay 1.0;
         combined_wait := False;
         for j in scanners'Range loop
            if not finished (j) then
               combined_wait := True;
               exit;
            end if;
         end loop;
         if combined_wait then
            if not label_shown then
               label_shown := True;
               TIO.Put_Line ("Scanning existing packages.");
            end if;
            if show_progress then
               TIO.Put (scan_progress);
            end if;
            if Signals.graceful_shutdown_requested then
               aborted := True;
            end if;
         end if;
      end loop;
   end parallel_package_scan;


end PortScan.Operations;
