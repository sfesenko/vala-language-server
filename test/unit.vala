/* unit.vala
 *
 * Unit tests for VLS utility functions, using GLib.Test.
 *
 * Copyright 2026 Sergii Fesenko
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

using Vls.Util;
using Json;

class TestSerializable : GLib.Object, Serializable {
    public string name { get; set; }
    public int value { get; set; }
}

void test_compare_versions () {
    assert (compare_versions ("1.2.3", "1.2.4") < 0);
    assert (compare_versions ("1.2.4", "1.2.3") > 0);
    assert (compare_versions ("1.2.3", "1.2.3") == 0);
    assert (compare_versions ("1.0", "1.0.0") < 0);
    assert (compare_versions ("2.0", "1.9.9") > 0);
}

void test_get_string_pos () {
    size_t pos = get_string_pos ("line0\nline1\nline2", 1, 2);
    assert (pos == 8);
    pos = get_string_pos ("abc", 0, 0);
    assert (pos == 0);
}

void test_count_chars_in_string () {
    int last = -1;
    assert (count_chars_in_string ("a.b.c", '.', out last) == 2);
    assert (last == 3);
    assert (count_chars_in_string ("no dots", '.', out last) == 0);
}

void test_get_arguments_from_command_str () {
    try {
        var args = get_arguments_from_command_str ("vala --pkg gtk4 'my file.vala'");
        assert (args.length == 4);
        assert (args[0] == "vala");
        assert (args[1] == "--pkg");
        assert (args[2] == "gtk4");
        assert (args[3] == "my file.vala");
    } catch (RegexError e) {
        assert_not_reached ();
    }
}

void test_is_newline () {
    assert (is_newline ('\n'));
    assert (is_newline ('\r'));
    assert (!is_newline ('a'));
}

void test_arg_is_vala_file () {
    assert (arg_is_vala_file ("foo.vala"));
    assert (arg_is_vala_file ("foo.vapi"));
    assert (arg_is_vala_file ("foo.gir"));
    assert (!arg_is_vala_file ("foo.c"));
    assert (!arg_is_vala_file ("foo.txt"));
}

void test_serialize_roundtrip () {
    var obj = new TestSerializable ();
    obj.name = "hello";
    obj.value = 42;
    try {
        Variant v = object_to_variant (obj);
        var back = parse_variant<TestSerializable> (v);
        assert (back.name == "hello");
        assert (back.value == 42);
    } catch (Error e) {
        assert_not_reached ();
    }
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/vls/util/compare_versions", test_compare_versions);
    Test.add_func ("/vls/util/get_string_pos", test_get_string_pos);
    Test.add_func ("/vls/util/count_chars_in_string", test_count_chars_in_string);
    Test.add_func ("/vls/util/get_arguments_from_command_str", test_get_arguments_from_command_str);
    Test.add_func ("/vls/util/is_newline", test_is_newline);
    Test.add_func ("/vls/util/arg_is_vala_file", test_arg_is_vala_file);
    Test.add_func ("/vls/util/serialize_roundtrip", test_serialize_roundtrip);
    return Test.run ();
}
