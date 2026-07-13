/* documentsymbol.vala
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

namespace Vls.DocumentSymbolHandler {
    void document_symbol_outline (Server server, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams>(@params);

        server.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.reply_null (id, client, method);
                return;
            }

            Compilation compilation;
            Project project;
            Vala.SourceFile? file = server.find_file (p.textDocument.uri, out compilation, out project);
            if (file == null) {
                debug ("[%s] file `%s' not found", method, p.textDocument.uri);
                Server.reply_null (id, client, method);
                return;
            }

            Vala.CodeContext.push (compilation.code_context);

            var array = new Json.Array ();
            var syms = compilation.get_analysis_for_file<SymbolEnumerator> (file);
            if (server.init_params.capabilities.textDocument.documentSymbol.hierarchicalDocumentSymbolSupport)
                foreach (var dsym in syms) {
                    array.add_element (Json.gobject_serialize (dsym));
                }
            else {
                foreach (var dsym in syms.flattened ()) {
                    array.add_element (Json.gobject_serialize (dsym));
                }
            }

            try {
                Variant result = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (array), null);
                client.reply (id, result, Server.cancellable);
            } catch (Error e) {
                debug (@"[textDocument/documentSymbol] failed to reply to client: $(e.message)");
            }
            Vala.CodeContext.pop ();
        });
    }
}
