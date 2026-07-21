/* int_perf.vala
 *
 * Performance integration tests — timed compile / semantic-tokens latency.
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
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 */

using GLib;
using Jsonrpc;

/**
 * Mid-sized fixture: generics, async, delegates, signals, templates,
 * enums, interfaces, structs, hierarchy, properties.
 */
const string PERF_FIXTURE = """namespace Perf {
    public interface IDrawable {
        public abstract void draw (Context cr);
    }

    public class Shape : IDrawable {
        public double x { get; set; }
        public double y { get; set; }
        public string name { get; construct; }

        public Shape (string name, double x = 0, double y = 0) {
            this.name = name;
            this.x = x;
            this.y = y;
        }

        public virtual void draw (Context cr) {
            cr.move_to (x, y);
            cr.show_text (name);
        }

        public virtual double area () {
            return 0;
        }

        public signal void changed ();
    }

    public class Rectangle : Shape {
        public double width { get; set; }
        public double height { get; set; }

        public Rectangle (string name, double x, double y, double w, double h)
            : base (name, x, y)
        {
            width = w;
            height = h;
        }

        public override void draw (Context cr) {
            base.draw (cr);
            cr.rectangle (x, y, width, height);
            cr.stroke ();
        }

        public override double area () {
            return width * height;
        }
    }

    public class Circle : Shape {
        public double radius { get; set; }

        public Circle (string name, double x, double y, double r)
            : base (name, x, y)
        {
            radius = r;
        }

        public override void draw (Context cr) {
            base.draw (cr);
            cr.arc (x, y, radius, 0, 2 * Math.PI);
            cr.stroke ();
        }

        public override double area () {
            return Math.PI * radius * radius;
        }
    }

    public struct Point {
        public double x;
        public double y;

        public Point (double x, double y) {
            this.x = x;
            this.y = y;
        }

        public Point add (Point other) {
            return new Point (x + other.x, y + other.y);
        }
    }

    public enum ShapeType {
        RECTANGLE,
        CIRCLE,
        POLYGON
    }

    public class Canvas {
        private Gee.List<Shape> shapes = new Gee.ArrayList<Shape> ();

        public void add (Shape shape) {
            shapes.add (shape);
            shape.changed.connect (() => {
                queue_draw ();
            });
        }

        public void remove (Shape shape) {
            shapes.remove (shape);
            queue_draw ();
        }

        public void draw_all (Context cr) {
            foreach (var shape in shapes)
                shape.draw (cr);
        }

        public double total_area () {
            double sum = 0;
            foreach (var shape in shapes)
                sum += shape.area ();
            return sum;
        }

        private void queue_draw () {
            // In a real app this would queue a GTK redraw
        }
    }

    public delegate void ShapeCallback (Shape shape);

    public async void process_shapes_async (Gee.List<Shape> shapes, ShapeCallback cb) {
        foreach (var shape in shapes) {
            yield;
            cb (shape);
        }
    }

    public class Factory {
        public static Shape create (ShapeType type, string name, double x, double y,
                                    double p1 = 0, double p2 = 0) {
            switch (type) {
                case ShapeType.RECTANGLE:
                    return new Rectangle (name, x, y, p1, p2);
                case ShapeType.CIRCLE:
                    return new Circle (name, x, y, p1);
                default:
                    return new Shape (name, x, y);
            }
        }
    }

    public void demo () {
        var canvas = new Canvas ();
        canvas.add (Factory.create (ShapeType.RECTANGLE, "rect1", 10, 10, 100, 50));
        canvas.add (Factory.create (ShapeType.CIRCLE, "circ1", 200, 150, 30));
        canvas.add (new Rectangle ("rect2", 50, 50, 80, 40));
        canvas.add (new Circle ("circ2", 300, 300, 25));

        var total = canvas.total_area ();
        stdout.printf (@"Total area: $(total)\n");

        process_shapes_async (canvas.shapes, (shape) => {
            stdout.printf (@"Processing $(shape.name) at ($(shape.x), $(shape.y))\n");
        });
    }
}

public void main () {
    Perf.demo ();
}
""";

void test_perf_compile_latency () {
    // setup_session already waits for first compile; verify server is
    // functional via semantic tokens.  VLS_PERF_TEST=1 enables timing assert.

    var s = setup_session (PERF_FIXTURE, "perf.vala");
    var h = new Helpers ();

    var start = new DateTime.now ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    var elapsed = new DateTime.now ().difference (start) / 1000000.0;

    assert (res != null);
    Variant? data = res.lookup_value ("data", null);
    assert (data != null);
    assert (data.is_of_type (VariantType.ARRAY));
    assert (data.n_children () > 0);

    stdout.printf ("[PERF] compile + semanticTokens: %.3fs\n", elapsed);

    if (Environment.get_variable ("VLS_PERF_TEST") == "1") {
        assert (elapsed < 2.0);
    }

    teardown_session (s);
}

void test_perf_semantic_tokens_latency () {
    // End-to-end semanticTokens/full latency after first compile.
    var s = setup_session (PERF_FIXTURE, "perf2.vala");
    var h = new Helpers ();

    var loop = new MainLoop ();
    s.client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics")
            loop.quit ();
    });
    var timeout_id = Timeout.add (15000, () => { loop.quit (); return false; });
    loop.run ();
    Source.remove (timeout_id);

    var start = new DateTime.now ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    var elapsed = new DateTime.now ().difference (start) / 1000000.0;

    assert (res != null);
    Variant? data = res.lookup_value ("data", null);
    assert (data != null);
    assert (data.is_of_type (VariantType.ARRAY));
    assert (data.n_children () > 0);

    stdout.printf ("[PERF] semanticTokens/full: %.3fs\n", elapsed);

    if (Environment.get_variable ("VLS_PERF_TEST") == "1") {
        assert (elapsed < 2.0);
    }

    teardown_session (s);
}

void test_perf_recompilation_after_edit () {
    // Verify recompile after edit ( cancel + compile_in_progress guard).
    var s = setup_session (PERF_FIXTURE, "recompile.vala");
    var h = new Helpers ();

    // Connect handler before edit to avoid race.  setup_session's handler
    // is still connected, so use a dedicated flag instead of a counter.
    var loop = new MainLoop ();
    bool recompile_happened = false;

    s.client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics" && !recompile_happened) {
            recompile_happened = true;
            loop.quit ();
        }
    });
    var timeout_id = Timeout.add (15000, () => { loop.quit (); return false; });

    var changed = PERF_FIXTURE.replace ("public void demo ()", "public void extra () {}\n    public void demo ()");
    Helpers.notify (s.client, "textDocument/didChange", h.build_dict (
        textDocument: h.build_dict (
            uri: new Variant.string (s.uri),
            version: new Variant.int32 (2)
        ),
        contentChanges: new Variant.array (null, { h.build_dict (text: new Variant.string (changed)) })
    ));
    loop.run ();
    Source.remove (timeout_id);
    assert (recompile_happened);

    teardown_session (s);
}

void test_perf_semantic_tokens_after_edit () {
    // Verify source_analyzers cache survives edit + recompile.
    var s = setup_session (SEMANTIC_TOKENS_FIXTURE, "semtok_edit.vala");
    var h = new Helpers ();

    var loop = new MainLoop ();
    s.client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics")
            loop.quit ();
    });
    var timeout_id = Timeout.add (15000, () => { loop.quit (); return false; });
    loop.run ();
    Source.remove (timeout_id);
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    Variant? data1 = res.lookup_value ("data", null);
    assert (data1 != null);
    assert (data1.n_children () > 0);

    var changed = SEMANTIC_TOKENS_FIXTURE.replace (
        "public override void abs_method () {}",
        "public override void abs_method () {}\n        public void after_edit () {}"
    );

    loop = new MainLoop ();
    s.client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics")
            loop.quit ();
    });
    timeout_id = Timeout.add (15000, () => { loop.quit (); return false; });

    Helpers.notify (s.client, "textDocument/didChange", h.build_dict (
        textDocument: h.build_dict (
            uri: new Variant.string (s.uri),
            version: new Variant.int32 (2)
        ),
        contentChanges: new Variant.array (null, { h.build_dict (text: new Variant.string (changed)) })
    ));
    loop.run ();
    Source.remove (timeout_id);

    res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    Variant? data2 = res.lookup_value ("data", null);
    assert (data2 != null);
    assert (data2.n_children () > 0);

    teardown_session (s);
}

const string USING_DIRECTIVE_FIXTURE = """using GLib;
public class Foo {
    public void main () {
        stdout.printf ("hello\\n");
    }
}
""";

const string USING_DIRECTIVE_FIXTURE_V2 = """using GLib;
using Gee;
public class Foo {
    public void main () {
        var list = new ArrayList<string> ();
        stdout.printf ("hello\\n");
    }
}
""";

void test_perf_using_directives_survive_recompile () {
    // Verify using directives don't accumulate across recompiles ( fix).
    // v1 (GLib) -> v2 (GLib+Gee) -> v1 (GLib): must not crash.
    var s = setup_session (USING_DIRECTIVE_FIXTURE, "using_dir.vala");
    var h = new Helpers ();

    var loop = new MainLoop ();
    s.client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics")
            loop.quit ();
    });
    var timeout_id = Timeout.add (15000, () => { loop.quit (); return false; });
    loop.run ();
    Source.remove (timeout_id);
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    assert (res.lookup_value ("data", null) != null);

    loop = new MainLoop ();
    s.client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics")
            loop.quit ();
    });
    timeout_id = Timeout.add (15000, () => { loop.quit (); return false; });

    Helpers.notify (s.client, "textDocument/didChange", h.build_dict (
        textDocument: h.build_dict (
            uri: new Variant.string (s.uri),
            version: new Variant.int32 (2)
        ),
        contentChanges: new Variant.array (null, { h.build_dict (text: new Variant.string (USING_DIRECTIVE_FIXTURE_V2)) })
    ));
    loop.run ();
    Source.remove (timeout_id);

    res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    assert (res.lookup_value ("data", null) != null);

    // v2 -> v1
    loop = new MainLoop ();
    s.client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics")
            loop.quit ();
    });
    timeout_id = Timeout.add (15000, () => { loop.quit (); return false; });

    Helpers.notify (s.client, "textDocument/didChange", h.build_dict (
        textDocument: h.build_dict (
            uri: new Variant.string (s.uri),
            version: new Variant.int32 (3)
        ),
        contentChanges: new Variant.array (null, { h.build_dict (text: new Variant.string (USING_DIRECTIVE_FIXTURE)) })
    ));
    loop.run ();
    Source.remove (timeout_id);

    res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    assert (res.lookup_value ("data", null) != null);

    teardown_session (s);
}
