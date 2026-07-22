/* documentmanager.vala
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
using Gee;

/**
 * Manages open/discarded file tracking for document notifications.
 */
class Vls.DocumentManager : Object {
    private Gee.HashSet<string> open_files;
    private Gee.HashSet<string> discarded_files;

    public DocumentManager () {
        open_files = new Gee.HashSet<string> ();
        discarded_files = new Gee.HashSet<string> ();
    }

    public void add_open_file (string uri) {
        open_files.add (uri);
    }

    public void add_discarded_file (string uri) {
        discarded_files.add (uri);
    }

    public Gee.ArrayList<string> get_open_files () {
        var result = new Gee.ArrayList<string> ();
        foreach (var file in open_files)
            result.add (file);
        return result;
    }

    public Gee.ArrayList<string> get_discarded_files () {
        var result = new Gee.ArrayList<string> ();
        foreach (var file in discarded_files)
            result.add (file);
        return result;
    }

    public void remove_discarded_files (Gee.ArrayList<string> files) {
        foreach (var file in files)
            discarded_files.remove (file);
    }
}
