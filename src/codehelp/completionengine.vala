/* completionengine.vala
 *
 * Copyright 2020 Princeton Ferro <princetonferro@gmail.com>
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

using Lsp;
using Gee;

namespace Vls.CompletionEngine {
    class CompletionHandler : Server.RequestHandler {
        private Position pos;
        private CompletionContext? completion_context;

        public CompletionHandler (Server.RequestContext ctx, Position pos, CompletionContext? completion_context) {
            base (ctx);
            this.pos = pos;
            this.completion_context = completion_context;
        }

        public override void run () {
            Logger.debug ("lsp", "completion at %s", pos.to_string ());
            Server.ServiceProvider lang_serv = ctx.services;
            Project project = ctx.project;
            Jsonrpc.Client client = ctx.client;
            Variant id = ctx.id;
            string method = ctx.method;
            Vala.SourceFile doc = ctx.file;
            Compilation compilation = ctx.compilation;
            Position pos = this.pos;
            CompletionContext? completion_context = this.completion_context;

            // Bug #329: if cursor is in a comment, return empty completions
            // immediately to avoid NO_RESULT_CALLBACK_FOUND errors when typing
            // `.` or other completion triggers inside comments.
            if (cursor_in_comment (doc.content, pos)) {
                finish (ctx.server, client, id, new HashSet<CompletionItem> ());
                return;
            }

            bool is_pointer_access = false;
            long idx = (long) Vls.Foundation.byte_offset (doc.content, pos.line, pos.character);

        Position end_pos = pos.dup ();
        bool is_member_access = false;
        bool is_null_safe_access = false;

        // move back to the nearest member access if there is one
        long lb_idx = idx;

        // first, move back to the character we just inserted
        lb_idx--;

        // next, move back to the first non-space
        while (lb_idx > 0 && doc.content[lb_idx].isspace ())
            lb_idx--;

        // now attempt to find a member access
        while (lb_idx >= 0 && !doc.content[lb_idx].isspace ()) {
            // if we're at a member access operator, we're done
            if ((lb_idx >= 1 &&
                 ((doc.content[lb_idx-1] == '-' && doc.content[lb_idx] == '>') ||
                  (doc.content[lb_idx-1] == '?' && doc.content[lb_idx] == '.'))) ||
                doc.content[lb_idx] == '.') {
                var new_pos = pos.translate (0, (int) (lb_idx - idx));
                // debug ("[%s] moved cursor back from '%c'@%s -> '%c'@%s",
                //     method, doc.content[idx], pos.to_string (), doc.content[lb_idx], new_pos.to_string ());
                idx = lb_idx;
                pos = new_pos;
                end_pos = pos.dup ();
                break;
            } else if (!doc.content[lb_idx].isalnum() && doc.content[lb_idx] != '_') {
                // if this character does not belong to an identifier, break
                // debug ("[%s] breaking, since we could not find a member access", method);
                // var new_pos = pos.translate (0, (int) (lb_idx - idx));
                // debug ("[%s] moved cursor back from '%c'@%s -> '%c'@%s",
                //     method, doc.content[idx], pos.to_string (), doc.content[lb_idx], new_pos.to_string ());
                break;
            }
            lb_idx--;
        }

        var completions = new HashSet<CompletionItem> ();

        if (idx >= 1 && doc.content[idx-1] == '-' && doc.content[idx] == '>') {
            is_pointer_access = true;
            is_member_access = true;
            // debug (@"[$method] found pointer access @ $pos");
            // pos = pos.translate (0, -2);
        } else if (idx >= 1 && doc.content[idx-1] == '?' && doc.content[idx] == '.') {
            is_null_safe_access = true;
            is_member_access = true;
            // debug (@"[$method] found null-safe member access @ $pos");
            // pos = pos.translate (0, -2);
        } else if (doc.content[idx] == '.') {
            // pos = pos.translate (0, -1);
            // debug ("[%s] found member access", method);
            is_member_access = true;
        } else {
            // The editor requested a member access completion from a '>'.
            // This is a hack since the LSP doesn't allow us to specify a trigger string ("->" in this case)
            if (completion_context != null
                && completion_context.triggerKind == CompletionTriggerKind.TriggerCharacter) {
                // completion conditions are not satisfied
                finish (ctx.server, client, id, completions);
                return;
            }
            // TODO: incomplete completions
        }

        string prefix = extract_line_prefix (doc, pos);

        if (is_member_access) {
            // attempt SymbolExtractor first, and if that fails, then wait for
            // the next context update

            var se = new SymbolExtractor (pos, doc);
            if (se.extracted_expression != null)
                show_members (lang_serv, project, doc, compilation,
                              is_null_safe_access, is_pointer_access, se.in_oce,
                              se.extracted_expression, se.block.scope, completions, false);

            if (completions.is_empty) {
                // debug ("[%s] trying MA completion again after context update ...", method);
                lang_serv.wait_for_context_update (id, request_cancelled => {
                    if (request_cancelled) {
                        Server.cleanup_request (ctx.server, id);
                        Server.reply_null (id, client, method);
                        return;
                    }

                    // show_members_with_updated_context() uses
                    // Server.with_code_context() internally — the outer push/pop
                    // was redundant and unbalanced if the body threw.
                    show_members_with_updated_context (lang_serv, project,
                                                       client, id,
                                                       doc, compilation,
                                                       is_null_safe_access, is_pointer_access,
                                                       pos, end_pos, completions);
                    finish (ctx.server, client, id, completions);
                }, compilation);
            } else {
                finish (ctx.server, client, id, completions);
            }
        } else {
            Vala.Scope best_scope;
            Vala.Symbol nearest_symbol;
            /**
             * The expression inside a Vala `with(<expr>) { ... }` statement.
             */
            Vala.Expression? nearest_with_expression;
            bool in_loop;
            bool showing_override_suggestions = false;
            walk_up_current_scope (lang_serv, doc, pos,
                                   out best_scope, out nearest_symbol,
                                   out nearest_with_expression, out in_loop);
            if (nearest_with_expression != null) {
                show_members (lang_serv, project, doc, compilation,
                              false, false, false, nearest_with_expression, best_scope, completions);
            }
            if (nearest_symbol is Vala.Class) {
                if (!compilation.has_corrupted_symbols) {
                    var results = CodeHelp.gather_missing_prereqs_and_unimplemented_symbols ((Vala.Class) nearest_symbol);
                    // TODO: use missing prereqs (results.first)
                    list_implementable_symbols (lang_serv, project, compilation, doc,
                                                (Vala.Class) nearest_symbol, best_scope,
                                                results.second, completions, prefix);
                    showing_override_suggestions = !completions.is_empty;
                }
            } else if (nearest_symbol is Vala.Method) {
                // Bug #334: when cursor is at class level but scope resolves
                // to a method, walk up to find the enclosing class for override
                // completions.
                var enclosing = nearest_symbol.parent_symbol;
                while (enclosing != null && !(enclosing is Vala.Class))
                    enclosing = enclosing.parent_symbol;
                if (enclosing != null) {
                    var cl = (Vala.Class) enclosing;
                    if (!compilation.has_corrupted_symbols) {
                        var results = CodeHelp.gather_missing_prereqs_and_unimplemented_symbols (cl);
                        list_implementable_symbols (lang_serv, project, compilation, doc,
                                                    cl, best_scope,
                                                    results.second, completions, prefix);
                        showing_override_suggestions = !completions.is_empty;
                    }
                }
                // Also check for virtual methods not overridden (ObjectTypeSymbol)
                if (enclosing is Vala.ObjectTypeSymbol) {
                    list_implementable_symbols (lang_serv, project, compilation, doc,
                                                (Vala.ObjectTypeSymbol) enclosing, best_scope,
                                                CodeHelp.gather_base_virtual_symbols_not_overridden
                                                    ((Vala.ObjectTypeSymbol) enclosing),
                                                completions, prefix);
                }
            }
            if (nearest_symbol is Vala.ObjectTypeSymbol) {
                list_implementable_symbols (lang_serv, project, compilation, doc,
                                            (Vala.ObjectTypeSymbol) nearest_symbol, best_scope,
                                            CodeHelp.gather_base_virtual_symbols_not_overridden
                                                ((Vala.ObjectTypeSymbol) nearest_symbol),
                                            completions, prefix);
            }
            if (!showing_override_suggestions) {
                list_symbols (lang_serv, project, compilation, doc, pos, best_scope,
                             completions, (new SymbolExtractor (pos, doc)).in_oce);
                list_keywords (lang_serv, doc, nearest_symbol, in_loop, completions);
            }
            finish (ctx.server, client, id, completions);
        }
        }
    }
}
