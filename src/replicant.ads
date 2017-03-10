--  This file is covered by the Internet Software Consortium (ISC) License
--  Reference: ../License.txt

with Definitions;   use Definitions;

private with Ada.Text_IO;
private with HelperText;
private with Utilities;

package Replicant is

   scenario_unexpected : exception;

   --  This procedure needs to be run once and sets key variables.
   --  It creates a set of files that each slave will copy in during launch.
   --  It also creates the password database
   procedure initialize
     (testmode  : Boolean;
      num_cores : cpu_range;
      localbase : String);

   --  This removes the password database
   procedure finalize;

   --  Returns True if any mounts are detected (used by pilot)
   function ravenadm_mounts_exist return Boolean;

   --  Returns True if any _work/_localbase dirs are detected (used by pilot)
   function disk_workareas_exist return Boolean;

   --  Returns True if the attempt to clear mounts is successful.
   function clear_existing_mounts return Boolean;

   --  Returns True if the attempt to remove the disk work areas is successful
   function clear_existing_workareas return Boolean;

private

   package HT  renames HelperText;
   package TIO renames Ada.Text_IO;
   package UTL renames Utilities;

   smp_cores      : cpu_range       := cpu_range'First;
   developer_mode : Boolean;
   abn_log_ready  : Boolean;
   abnormal_log   : TIO.File_Type;
   ravenbase      : HT.Text;

   abnormal_cmd_logname : constant String := "05_abnormal_command_output.log";

   raven_sysroot    : constant String := host_localbase & "/share/raven-sysroot/" &
                                         UTL.mixed_opsys (platform_type);

   type mount_mode is (readonly, readwrite);
   type folder is (bin, libexec, usr,
                   xports, packages, distfiles,
                   dev, etc, etc_default, etc_rcd, home,
                   proc, root, tmp, var, wrkdirs, localbase, ccache);
   subtype subfolder is folder range bin .. usr;
   subtype filearch is String (1 .. 11);

   --  home and root need to be set readonly
   reference_base   : constant String := "Base";
   root_bin         : constant String := "/bin";
   root_usr         : constant String := "/usr";
   root_dev         : constant String := "/dev";
   root_etc         : constant String := "/etc";
   root_etc_default : constant String := "/etc/defaults";
   root_etc_rcd     : constant String := "/etc/rc.d";
   root_lib         : constant String := "/lib";
   root_tmp         : constant String := "/tmp";
   root_var         : constant String := "/var";
   root_home        : constant String := "/home";
   root_root        : constant String := "/root";
   root_proc        : constant String := "/proc";
   root_xports      : constant String := "/xports";
   root_libexec     : constant String := "/libexec";
   root_wrkdirs     : constant String := "/construction";
   root_packages    : constant String := "/packages";
   root_distfiles   : constant String := "/distfiles";
   root_ccache      : constant String := "/ccache";

   chroot           : constant String := "/usr/sbin/chroot ";  -- localhost

   --  Query configuration to determine the master mount
   function get_master_mount return String;

   --  capture unexpected output while setting up builders (e.g. mount)
   procedure start_abnormal_logging;
   procedure stop_abnormal_logging;

   --  generic command, throws exception if exit code is not 0
   procedure execute (command : String);
   procedure silent_exec (command : String);
   function internal_system_command (command : String) return HT.Text;

   --  Wrapper for rm -rf <directory>
   procedure annihilate_directory_tree (tree : String);

   --  Used to generic mtree exclusion files
   procedure create_mtree_exc_preconfig (path_to_mm : String);
   procedure create_mtree_exc_preinst (path_to_mm : String);
   procedure write_common_mtree_exclude_base (mtreefile : TIO.File_Type);
   procedure write_preinstall_section (mtreefile : TIO.File_Type);

   --  platform-specific localhost command "umount"
   --  Throws exception if unmount attempt was unsuccessful
   procedure unmount (device_or_node : String);

   --  Throws exception if mount attempt was unsuccessful or if nullfs is unsupported
   procedure mount_nullfs (target, mount_point : String; mode : mount_mode := readonly);

   --  Throws exception if mount attempt was unsuccessful of if tmpfs is unsupported
   procedure mount_tmpfs (mount_point : String; max_size_M : Natural := 0);

   --  platform-specific localhost command "df"
   function df_command return String;

   --  mount the devices
   procedure mount_devices (path_to_dev : String);
   procedure unmount_devices (path_to_dev : String);

end Replicant;
