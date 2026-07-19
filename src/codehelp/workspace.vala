/* workspace.vala
 *
 * Copyright 2017-2020 Princeton Ferro <princetonferro@gmail.com>
 *
 * This file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation; either version 2.1 of the
 * License, or (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

using Vala;
using Lsp;

namespace Vls.Workspace {
    class WorkspaceSymbolHandler : Server.RequestHandler {
        private string query;

        public WorkspaceSymbolHandler (Server.RequestContext ctx, string query) {
            base (ctx);
            this.query = query;
        }

        public override void run () {
            var json_array = new Json.Array ();
            Project[] all_projects = ctx.server.projects.get_keys_as_array ();
            all_projects += ctx.server.default_project;
            foreach (var project in all_projects) {
                project.for_each_project_source_file ((text_document, compilation) => {
                    Vala.CodeContext.push (compilation.code_context);
                    var symbol_enumerator = compilation.get_analysis_for_file<SymbolEnumerator> (text_document);
                    if (symbol_enumerator != null) {
                        symbol_enumerator
                            .flattened ()
                            .filter (dsym => query.match_string (dsym.name, true))
                            .foreach (dsym => {
                                json_array.add_element (Json.gobject_serialize (dsym));
                                return true;
                            });
                    }
                    Vala.CodeContext.pop ();
                });
            }

            debug (@"[%s] found $(json_array.get_length ()) element(s) matching `$query'", ctx.method);
            reply_json_array (json_array);
        }
    }

    void search_workspace_symbols (Server server, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var query = (string) @params.lookup_value ("query", VariantType.STRING);

        server.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.reply_null (id, client, method);
                return;
            }

            var ctx = new Server.RequestContext (server, client, id, method,
                                                 null, null, null);
            var handler = new WorkspaceSymbolHandler (ctx, query);
            handler.run ();
        });
    }
}
