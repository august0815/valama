/*
 * src/buildsystem/cmake.vala
 * Copyright (C) 2013, Valama development team
 *
 * Valama is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Valama is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

using GLib;

public class BuilderCMake : BuildSystem {
    string projectinfo;

    public override string get_executable() {
        return project.project_name.down();
    }

    public override inline string get_name() {
        return "CMake";
    }

    public override inline string get_name_id() {
        return "cmake";
    }

    public override bool check_buildsystem_file (string filename) {
        return (filename.has_suffix (".cmake") ||
                Path.get_basename (filename) == ("CMakeLists.txt"));
    }

    public override bool preparate() throws BuildError.INITIALIZATION_FAILED {
        if (buildpath == null)
            throw new BuildError.INITIALIZATION_FAILED (_("Build directory not set."));
        if (project == null)
            throw new BuildError.INITIALIZATION_FAILED (_("Valama project not initialized."));
        projectinfo = Path.build_path (Path.DIR_SEPARATOR_S,
                                       project.project_path,
                                       "cmake",
                                       "project.cmake");
        init_dir (buildpath);
        init_dir (Path.get_dirname (projectinfo));
        return true;
    }

    public override bool initialize (out int? exit_status = null)
                                        throws BuildError.INITIALIZATION_FAILED {
        exit_status = null;
        initialized = false;
        if (!preparate())
            return false;
        initialize_started();

        var strb_pkgs = new StringBuilder ("set(required_pkgs\n");
        foreach (var pkgmap in get_pkgmaps().values) {
            if (pkgmap.choice_pkg != null && !pkgmap.check)
                strb_pkgs.append (@"  \"$((pkgmap as PackageInfo))\"\n");
            else
                strb_pkgs.append (@"  \"$pkgmap\"\n");
        }
        strb_pkgs.append (")\n");

        var strb_files = new StringBuilder ("set(srcfiles\n");
        var strb_vapis = new StringBuilder ("set(vapifiles\n");
        foreach (var filepath in project.files) {
            var fname = project.get_relative_path (filepath);
            if (filepath.has_suffix (".vapi"))
                strb_vapis.append (@"  \"$fname\"\n");
            else
                strb_files.append (@"  \"$fname\"\n");
        }
        strb_files.append (")\n");
        strb_vapis.append (")\n");

        var strb_uis = new StringBuilder ("set(uifiles\n");
        foreach (var filepath in project.u_files)
            strb_uis.append (@"  \"$(project.get_relative_path (filepath))\"\n");
        strb_uis.append (")\n");

        try {
            var file_stream = File.new_for_path (projectinfo).replace (
                                                    null,
                                                    false,
                                                    FileCreateFlags.REPLACE_DESTINATION);
            var data_stream = new DataOutputStream (file_stream);
            /*
             * Don't translate this part to make collaboration with VCS and
             * multiple locales easier.
             */
            data_stream.put_string ("# This file was auto generated by Valama %s. Do not modify it.\n".printf (Config.PACKAGE_VERSION));
            //TODO: Check if file needs changes and set date accordingly.
            // var time = new DateTime.now_local();
            // data_stream.put_string ("# Last change: %s\n".printf (time.format ("%F %T %z")));
            data_stream.put_string (@"set(project_name \"$(project.project_name)\")\n");
            data_stream.put_string (@"set($(project.project_name)_VERSION \"$(project.version_major).$(project.version_minor).$(project.version_patch)\")\n");
            data_stream.put_string (strb_pkgs.str);
            data_stream.put_string (strb_files.str);
            data_stream.put_string (strb_vapis.str);
            data_stream.put_string (strb_uis.str);

            data_stream.close();
        } catch (GLib.IOError e) {
            throw new BuildError.INITIALIZATION_FAILED (_("Could not read file: %s\n"), e.message);
        } catch (GLib.Error e) {
            throw new BuildError.INITIALIZATION_FAILED (_("Could not open file: %s\n"), e.message);
        }

        exit_status = 0;
        initialized = true;
        initialize_finished();
        return true;
    }

    public override bool configure (out int? exit_status = null) throws BuildError.INITIALIZATION_FAILED,
                                            BuildError.CONFIGURATION_FAILED {
        exit_status = null;
        if (!initialized && !initialize (out exit_status))
            return false;

        exit_status = null;
        configured = false;
        configure_started();

        var cmdline = new string[] {"cmake", ".."};

        Pid? pid;
        if (!call_cmd (cmdline, out pid)) {
            configure_finished();
            throw new BuildError.CONFIGURATION_FAILED (_("configure command failed"));
        }

        int? exit = null;
        ChildWatch.add (pid, (intpid, status) => {
            exit = get_exit (status);
            Process.close_pid (intpid);
            builder_loop.quit();
        });

        builder_loop.run();
        exit_status = exit;
        configured = true;
        configure_finished();
        return exit_status == 0;
    }

    public override bool build (out int? exit_status = null) throws BuildError.INITIALIZATION_FAILED,
                                        BuildError.CONFIGURATION_FAILED,
                                        BuildError.BUILD_FAILED {
        exit_status = null;
        if (!configured && !configure (out exit_status))
            return false;

        exit_status = null;
        built = false;
        build_started();
        var cmdline = new string[] {"make", "-j2"};

        Pid? pid;
        int? pstdout, pstderr;
        if (!call_cmd (cmdline, out pid, true, out pstdout, out pstderr)) {
            build_finished();
            throw new BuildError.CONFIGURATION_FAILED (_("build command failed"));
        }

        var chn = new IOChannel.unix_new (pstdout);
        chn.add_watch (IOCondition.IN | IOCondition.HUP, (source, condition) => {
            bool ret;
            var output = channel_output_read_line (source, condition, out ret);
            Regex r = /^\[(?P<percent>.*)\%\].*$/;
            MatchInfo info;
            if (r.match (output, 0, out info)) {
                var percent_string = info.fetch_named ("percent");
                build_progress (int.parse (percent_string));
            }
            build_output (output);
            return ret;
        });

        var chnerr = new IOChannel.unix_new (pstderr);
        chnerr.add_watch (IOCondition.IN | IOCondition.HUP, (source, condition) => {
            bool ret;
            build_output (channel_output_read_line (source, condition, out ret));
            return ret;
        });

        int? exit = null;
        ChildWatch.add (pid, (intpid, status) => {
            exit = get_exit (status);
            Process.close_pid (intpid);
            builder_loop.quit();
        });

        builder_loop.run();
        exit_status = exit;
        built = true;
        build_finished();
        return exit_status == 0;
    }

    public override bool check_existance() {
        var f = File.new_for_path (buildpath);
        return f.query_exists();
    }

    public override bool clean (out int? exit_status = null)
                                        throws BuildError.CLEAN_FAILED {
        exit_status = null;
        // cleaned = false;
        clean_started();

        if (!check_existance()) {
            build_output (_("No data to clean.\n"));
            clean_finished();
            return true;
        }

        var cmdline = new string[] {"make", "clean"};

        Pid? pid;
        if (!call_cmd (cmdline, out pid)) {
            clean_finished();
            throw new BuildError.CLEAN_FAILED (_("clean command failed"));
        }

        int? exit = null;
        ChildWatch.add (pid, (intpid, status) => {
            exit = get_exit (status);
            Process.close_pid (intpid);
            builder_loop.quit();
        });

        builder_loop.run();
        exit_status = exit;
        // cleaned = true;
        clean_finished();
        return exit_status == 0;
    }

    public override bool distclean (out int? exit_status = null)
                                            throws BuildError.CLEAN_FAILED {
        exit_status = null;
        // distcleaned = false;
        distclean_started();
        project.enable_defines_all();

        if (!check_existance()) {
            build_output (_("No data to clean.\n"));
            clean_finished();
            return true;
        }

        try {
            remove_recursively (buildpath, true, false);
            exit_status = 0;
        } catch (GLib.Error e) {
            exit_status = 1;
            throw new BuildError.CLEAN_FAILED (_("distclean command failed: %s"), e.message);
        }

        // distcleaned = true;
        distclean_finished();
        return exit_status == 0;
    }
}

// vim: set ai ts=4 sts=4 et sw=4
