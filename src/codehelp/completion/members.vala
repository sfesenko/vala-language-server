/* completion/members.vala
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
    /**
     * Fill the completion list with members of {@result}
     * If scope is null, the current scope will be calculated.
     */
    void show_members (Server.ServiceProvider lang_serv, Project project,
                       Vala.SourceFile doc, Compilation compilation,
                       bool is_null_safe_access, bool is_pointer_access, bool in_oce,
                       Vala.CodeNode result, Vala.Scope? scope, Set<CompletionItem> completions,
                        bool retry_inner = true) {
        var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (doc) as CodeStyleAnalyzer;
        Vala.Scope? current_scope = scope ?? CodeHelp.get_scope_containing_node (result);
        if (current_scope == null)
            return;
        Vala.DataType? data_type = null;
        Vala.Symbol? symbol = null;
        // whether we are accessing `this` or `base` within a creation method
        bool is_cm_this_or_base_access = false;

        do {
            if (result is Vala.Expression) {
                data_type = ((Vala.Expression)result).value_type;
                symbol = ((Vala.Expression)result).symbol_reference;
                // walk up scopes, looking for a creation method
                Vala.CreationMethod? cm = null;
                for (var cm_scope = current_scope; cm_scope != null && cm == null; cm_scope = cm_scope.parent_scope)
                    cm = cm_scope.owner as Vala.CreationMethod;
                is_cm_this_or_base_access = cm != null &&
                    (result is Vala.BaseAccess ||
                        result is Vala.MemberAccess &&
                            ((Vala.MemberAccess)result).member_name == "this" &&
                            ((Vala.MemberAccess)result).inner == null);
            } else if (result is Vala.Symbol) {
                symbol = (Vala.Symbol) result;
            }

            if (data_type != null && data_type.type_symbol != null &&
                (data_type is Vala.PointerType == is_pointer_access) &&
                (!in_oce || !(is_null_safe_access || is_pointer_access)))
                add_completions_for_type (lang_serv, project, code_style,
                                          data_type, data_type.type_symbol,
                                          completions, current_scope, in_oce,
                                          is_cm_this_or_base_access,
                                          new HashSet<Vala.TypeSymbol> ());
            else if (symbol is Vala.Signal && !(is_null_safe_access || is_pointer_access))
                add_completions_for_signal (code_style, data_type, (Vala.Signal) symbol, current_scope, completions);
            else if (symbol is Vala.Namespace && !(is_null_safe_access || is_pointer_access))
                add_completions_for_ns (lang_serv, project, code_style,
                                        (Vala.Namespace) symbol,
                                        current_scope, completions, in_oce);
            else if (symbol is Vala.Method && ((Vala.Method) symbol).coroutine
                     && !(is_null_safe_access || is_pointer_access))
                add_completions_for_async_method (code_style, data_type,
                                                  (Vala.Method) symbol,
                                                  current_scope, completions);
            else if (data_type is Vala.ArrayType && !is_pointer_access)
                add_completions_for_array_type (code_style, (Vala.ArrayType) data_type, current_scope, completions);
            else if (symbol is Vala.TypeSymbol && !(is_null_safe_access || is_pointer_access))
                add_completions_for_type (lang_serv, project, code_style,
                                          null, (Vala.TypeSymbol)symbol,
                                          completions, current_scope, in_oce,
                                          is_cm_this_or_base_access,
                                          new HashSet<Vala.TypeSymbol> ());
            else {
                if (result is Vala.MemberAccess &&
                    ((Vala.MemberAccess)result).inner != null &&
                    // don't try inner if the outer expression already has a symbol reference
                    ((Vala.MemberAccess)result).inner.symbol_reference == null &&
                    // don't try inner if the MemberAccess was generted by SymbolExtractor
                    retry_inner) {
                    result = ((Vala.MemberAccess)result).inner;
                    Vls.Log.debug ("lsp", "trying MemberAccess.inner");
                    // (new Object ()).
                    in_oce = false;
                    // maybe our expression was wrapped in extra parentheses:
                    // (x as T). for example
                    continue;
                }
                if (result is Vala.ObjectCreationExpression &&
                    ((Vala.ObjectCreationExpression)result).member_name != null) {
                    result = ((Vala.ObjectCreationExpression)result).member_name;
                    Vls.Log.debug ("lsp", "trying ObjectCreationExpression.member_name");
                    in_oce = true;
                    // maybe our object creation expression contains a member access
                    // from a namespace or some other type
                    // new Vls. for example
                    continue;
                }
                if (is_pointer_access && data_type is Vala.PointerType) {
                    // unwrap pointer type
                    var base_type = ((Vala.PointerType)data_type).base_type;
                    Vls.Log.debug ("lsp", "unwrapping data type %s => %s", data_type.to_string (), base_type.to_string ());
                    result = base_type;
                    data_type = base_type;
                    is_pointer_access = false;
                    continue;
                }
                Vls.Log.debug ("lsp", "could not get datatype for %s",
                        result == null ? "(null)" : @"($(result.type_name)) $result");
            }
            break;      // break by default
        } while (true);
    }

    /**
     * Use this for accurate member access completions after the code context has been updated.
     */
    void show_members_with_updated_context (Server.ServiceProvider lang_serv, Project project,
                                            Jsonrpc.Client client, Variant id,
                                            Vala.SourceFile doc, Compilation compilation,
                                            bool is_null_safe_access, bool is_pointer_access,
                                            Position pos, Position? end_pos, Set<CompletionItem> completions) {
        string method = "textDocument/completion";
        // debug (@"[$method] FindSymbol @ $pos" + (end_pos != null ? @" -> $end_pos" : ""));
        Vala.CodeContext.push (compilation.code_context);

        var fs = new NodeSearch (doc, pos, true, end_pos);

        if (fs.result.size == 0) {
            Vls.Log.debug ("lsp", "no results found for member access");
            Server.cleanup_request (lang_serv.server, id);
            Server.reply_null (id, client, method);
            Vala.CodeContext.pop ();
            return;
        }

        bool in_oce = false;

        foreach (var res in fs.result) {
            // debug (@"[$method] found $(res.type_name) (semanalyzed = $(res.checked))");
            in_oce |= res is Vala.ObjectCreationExpression;
        }

        Vala.CodeNode result = Server.get_best (fs, doc);
        show_members (lang_serv, project, doc, compilation,
                      is_null_safe_access, is_pointer_access, in_oce,
                      result, null, completions);
        Vala.CodeContext.pop ();
    }

    /**
     * Determines whether the completion engine should suggest a particular
     * method when the expression is a {@link Vala.ObjectTypeSymbol} or
     * {@link Vala.Struct}.
     */
    bool should_show_method_for_object_or_struct (Vala.TypeSymbol type_symbol,
                                                  Vala.Method method_sym, Vala.Scope current_scope,
                                                  bool is_instance, bool in_oce,
                                                  bool is_cm_this_or_base_access) {
        if (method_sym.name == ".new") {
            return false;
        } else if (is_instance && !in_oce) {
            // for instance symbols, show only instance members
            // except for creation methods, which are treated as instance members
            if (!method_sym.is_instance_member () || method_sym is Vala.CreationMethod && !is_cm_this_or_base_access)
                return false;
        } else if (in_oce) {
            // only show creation methods for non-instance symbols within an OCE
            if (!(method_sym is Vala.CreationMethod))
                return false;
        } else /* if (!is_instance) */ {
            // for non-instance object symbols, only show static methods
            // for non-instance struct symbols, show static methods and creation methods
            if (!(type_symbol is Vala.Struct && method_sym is Vala.CreationMethod)
                && method_sym.binding != Vala.MemberBinding.STATIC)
                return false;
        }
        // check whether the symbol is accessible
        if (!CodeHelp.is_symbol_accessible (method_sym, current_scope))
            return false;
        return true;
    }
}
