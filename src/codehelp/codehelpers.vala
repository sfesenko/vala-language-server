/* codehelpers.vala
 *
 * Miscellaneous CodeHelp utilities. Extracted from codehelp.vala.
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

namespace Vls.CodeHelp {
    bool namespaces_equal (Vala.CodeNode node1, Vala.CodeNode node2) {
        var ns1 = node1 as Vala.Namespace;
        var ns2 = node2 as Vala.Namespace;

        if (ns1 == null || ns2 == null)
            return false;

        if (ns1.name == ns2.name) {
            if ((ns1.parent_symbol == null || ns1.parent_symbol.get_full_name () == null) !=
                    (ns2.parent_symbol == null || ns2.parent_symbol.get_full_name () == null))
                return false;
            if ((ns1.parent_symbol == null || ns1.parent_symbol.get_full_name () == null) &&
                    (ns2.parent_symbol == null || ns2.parent_symbol.get_full_name () == null))
                return true;
            return namespaces_equal (ns1.parent_symbol, ns2.parent_symbol);
        }

        return false;
    }

    static bool base_method_requires_override (Vala.Method m) {
        return m.is_virtual || m.is_abstract
            && m.parent_symbol is Vala.Class && ((Vala.Class)m.parent_symbol).is_abstract;
    }

    static bool base_property_requires_override (Vala.Property p) {
        return p.is_virtual || p.is_abstract
            && p.parent_symbol is Vala.Class && ((Vala.Class)p.parent_symbol).is_abstract;
    }

    void get_all_prerequisites (Vala.DataType iface_type, Vala.Collection<Vala.DataType> prereqs)
        requires (iface_type.type_symbol is Vala.Interface) {
        foreach (Vala.DataType prereq in ((Vala.Interface)iface_type.type_symbol).get_prerequisites ()) {
            Vala.TypeSymbol? type_symbol = prereq.type_symbol;
            if (type_symbol == null) {
                continue;
            }

            var prereq_actual = prereq.get_actual_type (iface_type, null, null);
            if (!prereqs.contains (prereq_actual))
                prereqs.add (prereq_actual);

            if (type_symbol is Vala.Interface) {
                get_all_prerequisites (prereq_actual, prereqs);
            }
        }
    }

    Vala.List<Vala.Symbol> get_virtual_symbols (Vala.ObjectTypeSymbol tsym) {
        var symbols = new Vala.ArrayList<Vala.Symbol> ();

        if (tsym is Vala.Class) {
            foreach (var method in ((Vala.Class)tsym).get_methods ()) {
                if (method.is_virtual)
                    symbols.add (method);
            }
            foreach (var property in ((Vala.Class)tsym).get_properties ()) {
                if (property.is_virtual)
                    symbols.add (property);
            }
        } else if (tsym is Vala.Interface) {
            foreach (var method in ((Vala.Interface)tsym).get_methods ()) {
                if (method.is_virtual)
                    symbols.add (method);
            }
            foreach (var property in ((Vala.Interface)tsym).get_properties ()) {
                if (property.is_virtual)
                    symbols.add (property);
            }
        }

        return symbols;
    }

    Vala.List<Pair<Vala.DataType?,Vala.Symbol>> gather_base_virtual_symbols_not_overridden
        (Vala.ObjectTypeSymbol tsym) {
        var implemented_symbols = new Vala.ArrayList<Vala.Symbol> ();
        var virtual_symbols = new Vala.ArrayList<Pair<Vala.DataType?,Vala.Symbol>> ();
        var base_types = new Vala.ArrayList<Vala.DataType> ();

        if (tsym is Vala.Class) {
            base_types.add_all (((Vala.Class) tsym).get_base_types ());
        } else if (tsym is Vala.Interface) {
            base_types.add_all (((Vala.Interface) tsym).get_prerequisites ());
        }

        foreach (var method in tsym.get_methods ())
            if (method.base_method != null && method.base_method != method ||
                method.base_interface_method != null && method.base_interface_method != method)
                implemented_symbols.add (method.base_method ?? method.base_interface_method);

        foreach (var property in tsym.get_properties ())
            if (property.base_property != null && property.base_property != property ||
                property.base_interface_property != null && property.base_interface_property != property)
                implemented_symbols.add (property.base_property ?? property.base_interface_property);

        foreach (var type in base_types)
            if (type.type_symbol is Vala.ObjectTypeSymbol) {
                foreach (var symbol in get_virtual_symbols ((Vala.ObjectTypeSymbol)type.type_symbol))
                    if (!(symbol in implemented_symbols)) {
                        virtual_symbols.add (new Pair<Vala.DataType?,Vala.Symbol> (type, symbol));
                    }
            }

        return virtual_symbols;
    }

    Vala.DataType? get_base_class_type (Vala.Class csym) {
        foreach (Vala.DataType base_type in csym.get_base_types ()) {
            if (base_type.type_symbol == csym.base_class)
                return base_type;
        }
        return null;
    }

    Vala.Symbol? get_hidden_symbol (Vala.Symbol symbol) {
        if (symbol.parent_symbol is Vala.Class) {
            var parent_class = (Vala.Class)symbol.parent_symbol;
            foreach (var base_type in parent_class.get_base_types ()) {
                var base_member = base_type.type_symbol.scope.lookup (symbol.name);
                if (base_member != null && base_member.type_name == symbol.type_name)
                    return base_member;
            }
        } else if (symbol.parent_symbol is Vala.Interface) {
            var parent_iface = (Vala.Interface)symbol.parent_symbol;
            foreach (var base_type in parent_iface.get_prerequisites ()) {
                var base_member = base_type.type_symbol.scope.lookup (symbol.name);
                if (base_member != null && base_member.type_name == symbol.type_name)
                    return base_member;
            }
        } else if (symbol.parent_symbol is Vala.Struct) {
            return symbol.get_hidden_member ();
        }
        return null;
    }

    Pair<Vala.List<Vala.DataType>, Vala.List<Pair<Vala.DataType, Vala.Symbol>>>
        gather_missing_prereqs_and_unimplemented_symbols (Vala.Class csym) {
        var prerequisites = new Vala.ArrayList<Vala.DataType> ((dt1, dt2) => dt1.equals (dt2));
        foreach (Vala.DataType base_type in csym.get_base_types ()) {
            if (base_type.type_symbol is Vala.Interface && !csym.is_compact) {
                get_all_prerequisites (base_type, prerequisites);
            }
        }
        var missing_prereqs = new Vala.ArrayList<Vala.DataType> ();
        foreach (Vala.DataType prereq in prerequisites) {
            if (!csym.is_a ((Vala.ObjectTypeSymbol) prereq.type_symbol)) {
                missing_prereqs.add (prereq);
            }
        }

        var missing_symbols = new Vala.ArrayList<Pair<Vala.DataType, Vala.Symbol>> ();
        if (csym.source_type == Vala.SourceFileType.SOURCE) {
            var base_types = new Vala.ArrayList<Vala.DataType> (Vala.DataType.equals);
            base_types.add_all (csym.get_base_types ());
            base_types.add_all (missing_prereqs);
            base_types.sort ((dt1, dt2) => {
                if (dt1.compatible (dt2))
                    return -1;
                if (dt2.compatible (dt1))
                    return 1;
                return 0;
            });
            var hidden_symbols = new Vala.HashSet<Vala.Symbol> ();
            foreach (Vala.DataType base_type in base_types) {
                if (base_type.type_symbol is Vala.Interface && !csym.is_compact) {
                    unowned Vala.Interface iface = (Vala.Interface) base_type.type_symbol;

                    if (csym.base_class != null && csym.base_class.is_subtype_of (iface)) {
                        break;
                    }

                    foreach (Vala.Method m in iface.get_methods ()) {
                        if (m.is_abstract && !(m in hidden_symbols)) {
                            var implemented = false;
                            unowned Vala.Class? base_class = csym;
                            while (base_class != null && !implemented) {
                                foreach (var impl in base_class.get_methods ()) {
                                    if (impl.base_interface_method == m || (base_class != csym
                                                                            && impl.base_interface_method == null && impl.name == m.name
                                                                            && (impl.base_interface_type == null || impl.base_interface_type.type_symbol == iface)
                                                                            && impl.compatible_no_error (m))) {
                                        implemented = true;
                                        break;
                                    }
                                }
                                base_class = base_class.base_class;
                            }
                            if (!implemented) {
                                missing_symbols.add (new Pair<Vala.DataType,Vala.Symbol> (base_type, m));
                                var hidden = get_hidden_symbol (m);
                                if (hidden != null)
                                    hidden_symbols.add (hidden);
                            }
                        }
                    }

                    foreach (Vala.Property prop in iface.get_properties ()) {
                        if (prop.is_abstract && !(prop in hidden_symbols)) {
                            Vala.Symbol sym = null;
                            unowned Vala.Class? base_class = csym;
                            while (base_class != null && !(sym is Vala.Property)) {
                                sym = base_class.scope.lookup (prop.name);
                                base_class = base_class.base_class;
                            }
                            if (!(sym is Vala.Property)) {
                                missing_symbols.add (new Pair<Vala.DataType,Vala.Symbol> (base_type, prop));
                                var hidden = get_hidden_symbol (prop);
                                if (hidden != null)
                                    hidden_symbols.add (hidden);
                            }
                        }
                    }
                }
            }

            if (!csym.is_abstract) {
                unowned Vala.Class? base_class = csym.base_class;
                while (base_class != null && base_class.is_abstract) {
                    var base_type = get_base_class_type (csym);
                    foreach (Vala.Method base_method in base_class.get_methods ()) {
                        if (base_method.is_abstract && !(base_method in hidden_symbols)) {
                            var override_method = Vala.SemanticAnalyzer.symbol_lookup_inherited (csym, base_method.name) as Vala.Method;
                            if (override_method == null || !override_method.overrides) {
                                missing_symbols.add (new Pair<Vala.DataType, Vala.Symbol> (base_type, base_method));
                                var hidden = get_hidden_symbol (base_method);
                                if (hidden != null)
                                    hidden_symbols.add (hidden);
                            }
                        }
                    }
                    foreach (Vala.Property base_property in base_class.get_properties ()) {
                        if (base_property.is_abstract && !(base_property in hidden_symbols)) {
                            var override_property = Vala.SemanticAnalyzer.symbol_lookup_inherited (csym, base_property.name) as Vala.Property;
                            if (override_property == null || !override_property.overrides) {
                                missing_symbols.add (new Pair<Vala.DataType, Vala.Symbol> (base_type, base_property));
                                var hidden = get_hidden_symbol (base_property);
                                if (hidden != null)
                                    hidden_symbols.add (hidden);
                            }
                        }
                    }
                    base_class = base_class.base_class;
                }
            }
        }

        return new Pair<Vala.List<Vala.DataType>, Vala.List<Pair<Vala.DataType, Vala.Symbol>>>
            (missing_prereqs, missing_symbols);
    }

    Vala.ArrayList<Vala.Symbol> get_visible_members (Vala.TypeSymbol container) {
        var visible_members = new Vala.ArrayList<Vala.Symbol> ();

        if (container.source_reference == null)
            return visible_members;

        var seen = new Vala.HashSet<Vala.Symbol> (
            sym => sym.source_reference.to_string ().hash (),
            (sym1, sym2) => Util.source_ref_equal (sym1.source_reference, sym2.source_reference));

        if (container is Vala.ObjectTypeSymbol) {
            foreach (var member in ((Vala.Class)container).get_members ()) {
                if (!Util.source_ref_equal (member.source_reference, container.source_reference) && !seen.contains (member))
                    visible_members.add (member);
            }
        } else if (container is Vala.Struct) {
            foreach (var field in ((Vala.Struct)container).get_fields ())
                if (!Util.source_ref_equal (field.source_reference, container.source_reference) && !seen.contains (field))
                    visible_members.add (field);
            foreach (var method in ((Vala.Struct)container).get_methods ())
                if (!Util.source_ref_equal (method.source_reference, container.source_reference) && !seen.contains (method))
                    visible_members.add (method);
            foreach (var constant in ((Vala.Struct)container).get_constants ())
                if (!Util.source_ref_equal (constant.source_reference, container.source_reference) && !seen.contains (constant))
                    visible_members.add (constant);
            foreach (var property in ((Vala.Struct)container).get_properties ())
                if (!Util.source_ref_equal (property.source_reference, container.source_reference) && !seen.contains (property))
                    visible_members.add (property);
        } else if (container is Vala.Enum) {
            foreach (var evalue in ((Vala.Enum)container).get_values ())
                if (!Util.source_ref_equal (evalue.source_reference, container.source_reference) && !seen.contains (evalue))
                    visible_members.add (evalue);
            foreach (var constant in ((Vala.Enum)container).get_constants ())
                if (!Util.source_ref_equal (constant.source_reference, container.source_reference) && !seen.contains (constant))
                    visible_members.add (constant);
            foreach (var method in ((Vala.Enum)container).get_methods ())
                if (!Util.source_ref_equal (method.source_reference, container.source_reference) && !seen.contains (method))
                    visible_members.add (method);
        } else if (container is Vala.ErrorDomain) {
            foreach (var ecode in ((Vala.ErrorDomain)container).get_codes ())
                if (!Util.source_ref_equal (ecode.source_reference, container.source_reference) && !seen.contains (ecode))
                    visible_members.add (ecode);
            foreach (var method in ((Vala.ErrorDomain)container).get_methods ())
                if (!Util.source_ref_equal (method.source_reference, container.source_reference) && !seen.contains (method))
                    visible_members.add (method);
        }

        return visible_members;
    }
}
