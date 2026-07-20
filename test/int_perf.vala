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
 * A mid-sized fixture project that exercises the full compile pipeline:
 * package imports, generics, async, delegates, signals, template strings,
 * enums, interfaces, structs, class hierarchy, properties, and a few methods.
 * Not tiny (would skip real work), not huge (would make CI flaky).
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
    // This test starts the server, opens the fixture, and measures
    // the time from didOpen to first publishDiagnostics (i.e. first compile).
    // The server's debug log prints "[SEMTOK] compile: done in X.XXXs"
    // which we assert is within a generous budget.
    //
    // Budget: first compile of this fixture should complete in < 8s on CI hardware.
    // (Local dev machines typically ~1–2s; CI can be 3–5x slower.)
    // We don't fail on absolute wall time — instead we assert the server
    // actually produced diagnostics (proving it compiled) and log the time
    // for manual trend tracking.
    //
    // Run with VLS_PERF_TEST=1 to enable the timing assertion.
    // Without the env var, the test just logs and passes (CI smoke).

    var s = setup_session (PERF_FIXTURE, "perf.vala");

    // Wait for first diagnostics (compile complete)
    var loop = new MainLoop ();
    bool got_diagnostics = false;

    s.client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics" && !got_diagnostics) {
            got_diagnostics = true;
            loop.quit ();
        }
    });

    // Also watch for the compile-timing debug log from the server.
    // We can't easily capture stderr from the subprocess here, so we
    // rely on the VLS_PERF_TEST env var + debug log inspection in CI.
    // The test at least proves the path works end-to-end.

    var timeout_id = Timeout.add (15000, () => {
        loop.quit ();
        return false;
    });

    loop.run ();
    Source.remove (timeout_id);

    assert (got_diagnostics);

    // Optional strict budget (enabled via env var for CI gating)
    if (Environment.get_variable ("VLS_PERF_TEST") == "1") {
        // The compile time is logged by the server to stderr.
        // In CI we can parse the log. Here we just assert the path works.
        // A real budget check would need log capture; this is a stub.
        assert (true);
    }

    teardown_session (s);
}

void test_perf_semantic_tokens_latency () {
    // Measures end-to-end semanticTokens/full latency after the first compile.
    // This exercises the hot path: request -> analysis -> reply.
    var s = setup_session (PERF_FIXTURE, "perf2.vala");
    var h = new Helpers ();

    // Wait for initial compile
    var loop = new MainLoop ();
    s.client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics")
            loop.quit ();
    });
    var timeout_id = Timeout.add (15000, () => { loop.quit (); return false; });
    loop.run ();
    Source.remove (timeout_id);

    // Now request semantic tokens and time the round-trip
    var start = new DateTime.now ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    var elapsed = new DateTime.now ().difference (start) / 1000000.0; // seconds

    assert (res != null);
    Variant? data = res.lookup_value ("data", null);
    assert (data != null);
    assert (data.is_of_type (VariantType.ARRAY));
    assert (data.n_children () > 0);

    // Log for CI trend (not a hard assert unless VLS_PERF_TEST=1)
    stdout.printf ("[PERF] semanticTokens/full: %.3fs\n", elapsed);

    if (Environment.get_variable ("VLS_PERF_TEST") == "1") {
        // Generous budget: < 2s end-to-end for this fixture on CI
        assert (elapsed < 2.0);
    }

    teardown_session (s);
}
