/* meson/substitutions.vala
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

using Gee;

namespace Vls.MesonSubstitutions {
    /**
     * Substitute special arguments like `@INPUT@` and `@OUTPUT@` as they
     * appear in Meson targets.
     */
    internal string[] substitute_target_args (Meson.TargetInfo meson_target_info,
                                            Meson.TargetSourceInfo target_source,
                                            string[] args, string? src_relative_path,
                                            string build_dir, string root_path,
                                            ArrayList<BuildTarget> build_targets) throws RegexError {
        var substituted_args = new LinkedList<string> ();
        for (int i = 0; i < args.length; i++) {
            MatchInfo match_info;
            if (/^@([A-Za-z_]+)@$/.match (args[i], 0, out match_info)) {
                // replace the whole argument with potentially multiple arguments
                string special_arg_name = match_info.fetch (1);

                if (special_arg_name == "INPUT") {
                    string substitute = "";
                    foreach (string input_arg in target_source.sources) {
                        substituted_args.add (input_arg);
                        if (substitute != "")
                            substitute += " ";
                        substitute += input_arg;
                    }

                    Logger.debug ("compile", "for target %s, source #0, subtituted arg #%d (%s) with %s",
                           meson_target_info.id, i, args[i], substitute);
                } else if (special_arg_name == "OUTPUT") {
                    string substitute = "";
                    foreach (string output_arg in meson_target_info.filename) {
                        substituted_args.add (output_arg);
                        if (substitute != "")
                            substitute += " ";
                        substitute += output_arg;
                    }

                    Logger.debug ("compile", "for target %s, source #0, subtituted arg #%d (%s) with %s",
                           meson_target_info.id, i, args[i], substitute);
                } else if (special_arg_name == "OUTDIR") {
                    string substitute;
                    if (src_relative_path == null) {
                        Logger.warn ("compile", "for target %s, source #0, could not substitute special arg with null source relative dir",
                                 meson_target_info.id);
                        substitute = build_dir;
                    } else {
                        substitute = Path.build_filename (build_dir, src_relative_path);
                    }
                    substituted_args.add (substitute);
                    Logger.debug ("compile", "for target %s, source #0, subtituted arg #%d (%s) with %s",
                           meson_target_info.id, i, args[i], substitute);
                } else if (special_arg_name == "CURRENT_SOURCE_DIR") {
                    // use the defined-in directory
                    substituted_args.add (Path.get_dirname (meson_target_info.defined_in));
                } else if (special_arg_name == "PRIVATE_DIR") {
                    string substitute = meson_target_info.filename[0] + ".p";
                    substituted_args.add (substitute);
                    Logger.debug ("compile", "for target %s, source #0, subtituted arg #%d (%s) with %s",
                           meson_target_info.id, i, args[i], substitute);
                } else {
                    Logger.warn ("compile", "for target %s, source #0, could not substitute special arg `%s'",
                             meson_target_info.id, special_arg_name);
                    substituted_args.add (match_info.fetch (0));
                }
            } else {
                // replace a substring in args[i]
                string substitute = args[i];
                bool replaced = false;
                var regex1 = /@PRIVATE_OUTDIR_ABS_?(\S*)@/;
                substitute = regex1.replace_eval (substitute, substitute.length, 0, 0, (match, result) => {
                    string? build_id = match.fetch (1);

                    if (build_id == null || build_id == meson_target_info.id) {
                        result.append (meson_target_info.id);
                        replaced = true;
                    } else {
                        BuildTarget? found = build_targets.first_match (t => t.id == build_id);
                        if (found != null) {
                            result.append (found.output_dir);
                        } else {
                            Logger.warn ("compile", "for target %s, source #0, could not substitute special arg `%s' (could not find build target with ID %s)",
                                     meson_target_info.id, match.get_string (), build_id);
                        }
                    }

                    return false;
                });
                var regex2 = /@([A-Za-z0-9_]+?)(\d+)?@/;
                substitute = regex2.replace_eval (substitute, substitute.length, 0, 0, (match, result) => {
                    string special_arg_name = match.fetch (1);
                    string? arg_num_str = match.fetch (2);
                    int arg_num = 0;
                    bool has_arg_num = arg_num_str == null ? false : int.try_parse (arg_num_str, out arg_num);

                    if (special_arg_name == "BUILD_ROOT") {
                        result.append (build_dir);
                        replaced = true;
                    } else if (special_arg_name == "SOURCE_ROOT") {
                        result.append (root_path);
                        replaced = true;
                    } else if (special_arg_name == "INPUT") {
                        if (has_arg_num) {
                    if (arg_num < target_source.sources.length) {
                                result.append (target_source.sources[arg_num]);
                                replaced = true;
                            } else {
                                Logger.warn ("compile", "for target %s, source #0, could not substitute special arg `%s'",
                                         meson_target_info.id, match.fetch (0));
                                result.append (match.fetch (0));
                                return true;
                            }
                        } else {
                            if (target_source.sources.length == 1) {
                                result.append (target_source.sources[0]);
                                replaced = true;
                            } else {
                                Logger.warn ("compile", "for target %s, source #0, could not substitute special arg `%s' with multiple sources",
                                         meson_target_info.id, match.fetch (0));
                                result.append (match.fetch (0));
                                return true;
                            }
                        }
                    } else if (special_arg_name == "OUTPUT") {
                        if (has_arg_num) {
                            if (arg_num < meson_target_info.filename.length) {
                                result.append (meson_target_info.filename[arg_num]);
                                replaced = true;
                            } else {
                                Logger.warn ("compile", "for target %s, source #0, could not substitute special arg `%s'",
                                         meson_target_info.id, match.fetch (0));
                                result.append (match.fetch (0));
                                return true;
                            }
                        } else {
                            if (meson_target_info.filename.length == 1) {
                                result.append (meson_target_info.filename[0]);
                                replaced = true;
                            } else {
                                Logger.warn ("compile", "for target %s, source #0, could not substitute special arg `%s' with multiple sources",
                                         meson_target_info.id, match.fetch (0));
                                result.append (match.fetch (0));
                                return true;
                            }
                        }
                    } else if (special_arg_name == "OUTDIR") {
                        if (src_relative_path == null) {
                            Logger.warn ("compile", "for target %s, source #0, could not substitute special arg with null source relative dir",
                                     meson_target_info.id);
                            result.append (match.fetch (0));
                            return true;
                        }
                        result.append (Path.build_filename (build_dir, src_relative_path));
                        replaced = true;
                    } else if (special_arg_name == "CURRENT_SOURCE_DIR") {
                        result.append (Path.get_dirname (meson_target_info.defined_in));
                        replaced = true;
                    } else {
                                Logger.warn ("compile", "for target %s, source #0, could not substitute special arg `%s'",
                                         meson_target_info.id, match.fetch (0));
                        result.append (match.fetch (0));
                        return true;
                    }
                    return false;
                });
                if (replaced) {
                    Logger.debug ("compile", "for target %s, source #0, subtituted arg #%d (%s) with %s",
                    meson_target_info.id, i, args[i], substitute);
                }
                substituted_args.add (substitute);
            }
        }
        return substituted_args.to_array ();
    }
}
