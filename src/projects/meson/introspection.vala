/* meson/introspection.vala
 *
 * Copyright 2020-2022 Princeton Ferro <princetonferro@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

namespace Vls.MesonIntrospection {
    /**
     * Load a Meson introspection JSON file, falling back to running
     * `meson introspect --{command}` if the file does not exist.
     */
    internal void load_introspection_json (Json.Parser parser, string build_dir, string command,
                                           Scheduler scheduler, Cancellable? cancellable = null) throws Error {
        // first, try to load the file in ${build_dir}/meson-info/intro-${command}.json
        try {
            var input_file = File.new_build_filename (build_dir, "meson-info", @"intro-$command.json");
            Vls.Log.debug ("compile", "loading file %s ...", Util.project_path (input_file.get_path ()));
            parser.load_from_stream (input_file.read (cancellable), cancellable);
        } catch (IOError e) {
            if (e is IOError.NOT_FOUND) {
                // retry with the other method: get output of `meson introspect --${command} ${build_dir}`
                string subst_command = command.replace("_", "-");
                string[] spawn_args = {"meson", "introspect", "--" + subst_command, "."};
                string proc_stdout = "";
                string proc_stderr = "";
                int proc_status = -1;

                string command_str = "";
                foreach (string part in spawn_args) {
                    if (command_str != "")
                        command_str += " ";
                    command_str += part;
                }

                Vls.Log.debug ("compile", "file does not exist, fallback to %s", command_str);

                proc_stdout = scheduler.run_sync<string> (() => {
                    string stdout_str;
                    int status;
                    Process.spawn_sync (
                        build_dir,
                        spawn_args,
                        null,
                        SpawnFlags.SEARCH_PATH,
                        null,
                        out stdout_str,
                        null,
                        out status);
                    proc_status = status;
                    return stdout_str;
                });

                if (proc_status != 0) {
                    Vls.Log.warn ("compile", "command `%s' in %s failed with exit code %d\n----stdout:\n%s\n----stderr:\n%s",
                             command_str, build_dir, proc_status, proc_stdout, proc_stderr);
                    throw new ProjectError.INTROSPECTION (@"meson command `$command_str' failed with exit code $proc_status");
                }

                parser.load_from_data (proc_stdout);
            } else {
                // otherwise, rethrow
                throw e;
            }
        }
    }

    /**
     * Check that the Meson version is at least 0.50.0.
     */
    internal void check_meson_version (string build_dir, Scheduler scheduler) throws Error {
        string meson_version_proc_stdout = "";
        string meson_version_proc_stderr = "";
        int meson_version_proc_status = -1;

        meson_version_proc_stdout = scheduler.run_sync<string> (() => {
            string stdout_str;
            Process.spawn_sync (
                build_dir,
                "meson --version".split (" "),
                null,
                SpawnFlags.SEARCH_PATH,
                null,
                out stdout_str,
                null,
                out meson_version_proc_status);
            return stdout_str;
        });

        if (meson_version_proc_status != 0) {
            Vls.Log.warn ("compile", "failed to get version, exit code %d\n----stdout:\n%s\n----stderr:\n%s",
                     meson_version_proc_status, meson_version_proc_stdout, meson_version_proc_stderr);
            throw new ProjectError.CONFIGURATION (@"meson --version failed with exit code $meson_version_proc_status");
        }

        meson_version_proc_stdout = meson_version_proc_stdout.strip ();

        if (Util.compare_versions (meson_version_proc_stdout, "0.50.0") < 0) {
            Vls.Log.warn ("compile", "meson < 0.50.0 not supported (version was '%s')", meson_version_proc_stdout);
            throw new ProjectError.VERSION_UNSUPPORTED ("meson < 0.50.0 not supported");
        }
    }
}
