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
   procedure initialize (testmode  : Boolean);

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

   --  For every single port to be built, the build need to first be created
   --  and then destroyed when the build is complete.
   procedure launch_slave  (id : builders; need_procfs : Boolean := False);
   procedure destroy_slave (id : builders; need_procfs : Boolean := False);

   --  After the build phase, the toolchain is removed.  This detects building during
   --  installation phases.  Sequence: launch_slave, unhook_toolchain, destroy_slave
   procedure unhook_toolchain (id : builders);

private

   package HT  renames HelperText;
   package TIO renames Ada.Text_IO;
   package UTL renames Utilities;

   smp_cores      : cpu_range := cpu_range'First;
   developer_mode : Boolean;
   abn_log_ready  : Boolean;
   abnormal_log   : TIO.File_Type;
   ravenbase      : HT.Text;

   abnormal_cmd_logname : constant String := "05_abnormal_command_output.log";

   raven_sysroot   : constant String := host_localbase & "/share/raven-sysroot/" &
                                         UTL.mixed_opsys (platform_type);

   type mount_mode is (readonly, readwrite);
   type folder_operation is (lock, unlock);
   type folder is (bin, libexec, usr,
                   xports, packages, distfiles,
                   dev, etc, etc_default, etc_rcd, home,
                   proc, root, tmp, var, toolchain, wrkdirs, port, localbase, ccache);
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
   root_port        : constant String := "/port";
   root_xports      : constant String := "/xports";
   root_libexec     : constant String := "/libexec";
   root_toolchain   : constant String := "/toolchain";
   root_wrkdirs     : constant String := "/construction";
   root_packages    : constant String := "/packages";
   root_distfiles   : constant String := "/distfiles";
   root_ccache      : constant String := "/ccache";
   bsd_localbase    : constant String := "/usr/local";

   chroot           : constant String := "/usr/sbin/chroot ";  -- localhost

   --  Query configuration to determine the master and slave mounts
   function get_master_mount return String;
   function get_slave_mount (id : builders) return String;

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

   --  mount procfs on a per-port basis (less than 3 need it)
   procedure mount_procfs (path_to_proc : String);
   procedure unmount_procfs (path_to_proc : String);

   --  Throws exception if directory was not successfully created
   procedure forge_directory (target : String);

   --  Return the full path of the mount point
   function location (mount_base : String; point : folder) return String;
   function mount_target (point : folder) return String;

   --  locks and unlocks folders, even from root
   procedure folder_access (path : String; operation : folder_operation);

   --  returns "SLXX" where XX is a zero-padded integer (01 .. 32)
   function slave_name (id : builders) return String;

   --  create slave's /var directory tree.  Path should be an empty directory.
   procedure populate_var_folder (path : String);

   --  Install default rc.conf file, if available
   procedure copy_rc_default (path_to_etc : String);

   --  copy host's /etc/resolv.conf to slave
   procedure copy_resolv_conf (path_to_etc : String);

   --  Install user and group databases
   procedure install_passwd_and_group (path_to_etc : String);

   --  create minimal /etc/services
   procedure create_etc_services (path_to_etc : String);

   --  create /etc/shells, required by install scripts of some packages
   procedure create_etc_shells (path_to_etc : String);

    --  create /etc/make.conf in slave
   procedure create_make_conf (path_to_etc : String);

      --  Concatentation used for per-profile make.conf fragments (if they exist)
   procedure concatenate_makeconf (makeconf_handle : TIO.File_Type; target_name : String);

end Replicant;