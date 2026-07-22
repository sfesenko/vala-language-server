/* projectmanager.vala
 *
 * Copyright 2024 Vala Language Server Contributors
 *
 * This file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation; either version 2.1 of the
 * License, or (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

using Vala;
using Lsp;
using Gee;

/**
 * Manages project lifecycle and file lookup.
 */
class Vls.ProjectManager : Object {
    public HashTable<Project, ulong> projects;
    public DefaultProject default_project;
    public FileCache file_cache;

    public signal void project_changed ();

    public ProjectManager () {
        projects = new HashTable<Project, ulong> (GLib.direct_hash, GLib.direct_equal);
        file_cache = new FileCache ();
    }

    public Vala.SourceFile? find_file (string uri,
                                       out Compilation? compilation = null,
                                       out Project? project = null) {
        var results = new Gee.ArrayList<Pair<Vala.SourceFile, Compilation>> ();
        Project? selected_project = null;
        foreach (var p in projects.get_keys_as_array ()) {
            results = p.lookup_compile_input_source_file (uri);
            if (!results.is_empty) {
                selected_project = p;
                break;
            }
        }
        if (selected_project == null) {
            results = default_project.lookup_compile_input_source_file (uri);
            if (!results.is_empty)
                selected_project = default_project;
        }

        if (selected_project != null) {
            project = selected_project;
            compilation = results[0].second;
            return results[0].first;
        }

        project = null;
        compilation = null;
        return null;
    }
}
