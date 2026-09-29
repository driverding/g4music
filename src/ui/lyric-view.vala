// SPDX-FileCopyrightText: 2026 DriverDing
// SPDX-License-Identifier: GPL-3.0-or-later

namespace G4 {

    /**
     * An Apple Music style lyric view.
     *
     * Structure:
     * - LyricView: public container. Tracks the active line for a given playback
     *   position and relays clicks. Following the active line is a per-line
     *   cascade: the layout offset jumps to its target instantly and every line
     *   springs the jump back to zero, staggered by its viewport row so lines
     *   visibly travel upward one after another.
     * - LyricLayout: layout manager stacking one child per line with constant
     *   spacing plus generous top/bottom padding so any line can be centered.
     * - LyricLine: renders a single line with Pango; the sung portion is drawn
     *   in a highlight color on top of a dim pass, cut sharply at the current
     *   word position. An optional translation below is rendered statically.
     *   Scales up slightly while active.
     */
    public class LyricView : Gtk.Widget {

        /**
         * Emitted when the user clicks line `index`; connect to it to seek.
         */
        public signal void line_activated (uint index);

        public Lyric? lyric {
            get { return _lyric; }
            set { apply_lyric (value); }
        }

        /**
         * Playback position in milliseconds, matching Lyr timestamps.
         */
        public uint64 position {
            get { return _position; }
            set { apply_position (value); }
        }

        /**
         * Horizontal alignment of every line. Fonts stay under normal CSS
         * control (font-family/size/weight cascade to lyric-line).
         */
        public Gtk.Justification justify {
            get { return _justify; }
            set {
                if (value == _justify) {
                    return;
                }
                _justify = value;
                foreach (var lw in line_widgets) {
                    lw.justify = value;
                }
            }
        }

        private Lyric? _lyric;
        private uint64 _position = 0;
        private int _active_index = -1;
        private Gtk.Justification _justify = Gtk.Justification.CENTER;

        private LyricLine[] line_widgets = {};
        private LyricLayout line_layout;
        private Gtk.EventControllerScroll scroll_controller;

        /* Per-line cascade: each viewport row starts its spring this much later
         * than the row above it, capped so distant rows don't wait forever. */
        private const uint STAGGER_MS = 45;
        private const int MAX_STAGGER_ROWS = 14;

        /* After manual scrolling, auto-following resumes once this has passed. */
        private const int64 RESUME_US = 3 * GLib.TimeSpan.SECOND;
        private bool auto_scroll_paused = false;
        private int64 last_user_scroll_us = 0;

        class construct {
            set_css_name ("lyric-view");
        }

        construct {
            line_layout = new LyricLayout ();
            set_layout_manager (line_layout);

            scroll_controller = new Gtk.EventControllerScroll (Gtk.EventControllerScrollFlags.VERTICAL);
            scroll_controller.scroll.connect (on_user_scroll);
            add_controller (scroll_controller);
        }

        /* Clip children that cascade or scroll outside the view bounds. */
        public override void snapshot (Gtk.Snapshot snapshot) {
            int w = get_width ();
            int h = get_height ();
            if (w <= 0 || h <= 0) {
                return;
            }
            var clip = Graphene.Rect () {
                origin = Graphene.Point () { x = 0, y = 0 },
                size = Graphene.Size () { width = w, height = h }
            };
            snapshot.push_clip (clip);
            base.snapshot (snapshot);
            snapshot.pop ();
        }

        private bool on_user_scroll (double dx, double dy) {
            double amount = dy;
            if (scroll_controller.get_unit () == Gdk.ScrollUnit.WHEEL) {
                amount *= 48.0;
            }
            last_user_scroll_us = GLib.get_monotonic_time ();
            auto_scroll_paused = true;
            line_layout.adjust_scroll (amount);
            return true;
        }

        private void apply_lyric (Lyric? lyric) {
            foreach (var lw in line_widgets) {
                lw.unparent ();
            }
            _lyric = lyric;
            _active_index = -1;
            line_layout.scroll_offset = 0;

            if (lyric != null) {
                var lines = ((!) lyric).lines;
                int n = lines.size;
                line_widgets = new LyricLine[n];
                for (int i = 0; i < n; i++) {
                    var data = lines[i];
                    uint64 fallback = (i + 1 < n)
                        ? lines[i + 1].start_time
                        : data.start_time + 5000;
                    var lw = new LyricLine (data, (uint) i, fallback);
                    lw.justify = _justify;
                    lw.clicked.connect (() => { line_activated (lw.index); });
                    lw.offset_changed.connect (() => { line_layout.relayout (); });
                    lw.set_parent (this);
                    line_widgets[i] = lw;
                }
            } else {
                line_widgets = {};
            }

            apply_position (_position);
        }

        private void apply_position (uint64 pos) {
            _position = pos;
            foreach (var lw in line_widgets) {
                lw.update_position (pos);
            }

            int active = find_active_index (pos);
            if (active != _active_index) {
                if (_active_index >= 0 && _active_index < line_widgets.length) {
                    line_widgets[_active_index].animate_emphasis (0.0);
                }
                if (active >= 0) {
                    line_widgets[active].animate_emphasis (1.0);
                }
                _active_index = active;
                update_dim ();
                if (active >= 0 && !auto_scroll_paused) {
                    scroll_to_active ();
                }
            }
            if (auto_scroll_paused
                && GLib.get_monotonic_time () - last_user_scroll_us > RESUME_US) {
                auto_scroll_paused = false;
                if (_active_index >= 0) {
                    scroll_to_active ();
                }
            }
        }

        private int find_active_index (uint64 pos) {
            if (_lyric == null) {
                return -1;
            }
            int idx = -1;
            var lines = ((!) _lyric).lines;
            for (int i = 0; i < lines.size && lines[i].start_time <= pos; i++) {
                idx = i;
            }
            return idx;
        }

        private void update_dim () {
            for (int i = 0; i < line_widgets.length; i++) {
                if (_active_index < 0) {
                    line_widgets[i].dim = 0.6;
                } else {
                    int d = i - _active_index;
                    line_widgets[i].dim = double.max (0.30, 1.0 - 0.16 * (d < 0 ? -d : d));
                }
            }
        }

        private void scroll_to_active () {
            double target = line_layout.center_offset_for (_active_index);
            if (!get_realized ()) {
                line_layout.scroll_offset = target;
                return;
            }
            double delta = target - line_layout.scroll_offset;
            if (delta == 0) {
                return;
            }
            /* Jump the layout to its final offset instantly, then hand every line
             * that delta as its starting anim_offset so the picture doesn't move
             * yet. Each line springs its offset back to zero, staggered by its
             * distance from the leading viewport edge: content scrolling up is
             * led by the topmost visible line, content scrolling down (a seek
             * back, or auto-follow resuming) by the bottommost. */
            line_layout.scroll_offset = target;
            bool up = delta > 0;
            int anchor = up ? line_layout.first_visible_index ()
                            : line_layout.last_visible_index ();
            for (int i = 0; i < line_widgets.length; i++) {
                int row = (up ? i - anchor : anchor - i).clamp (0, MAX_STAGGER_ROWS);
                line_widgets[i].cascade (delta, row * STAGGER_MS);
            }
            line_layout.relayout ();
        }

        /**
         * Stacks all children top to bottom with constant spacing, inside a
         * padding of 42% of the viewport height on both ends so that the first
         * and last lines can still be centered. No virtualization: lyric line
         * counts are small enough that instantiating all of them is cheap.
         */
        private class LyricLayout : Gtk.LayoutManager {

            public double spacing { get; set; default = 30; }

            private double _scroll_offset = 0;
            public double scroll_offset {
                get { return _scroll_offset; }
                set {
                    if (value != _scroll_offset) {
                        _scroll_offset = value;
                        layout_changed ();
                    }
                }
            }

            public void adjust_scroll (double dy) {
                scroll_offset = _scroll_offset + dy;
            }

            /** Force a re-allocation pass (used while per-line offsets animate). */
            public void relayout () {
                layout_changed ();
            }

            private double max_offset = 0;
            private double pad_top = 0;
            private double viewport_height = 0;
            private double[] tops = {};
            private double[] heights = {};

            /**
             * Index of the topmost line whose body is still inside the viewport at
             * the current scroll offset, or the line count when none are visible.
             * Drives the top-to-bottom cascade stagger.
             */
            public int first_visible_index () {
                for (int i = 0; i < tops.length; i++) {
                    double y = pad_top + tops[i] - _scroll_offset;
                    if (y + heights[i] > 0) {
                        return i;
                    }
                }
                return tops.length;
            }

            /**
             * Index of the bottommost line that has any part inside the viewport
             * at the current scroll offset, or the last line when none are.
             */
            public int last_visible_index () {
                for (int i = tops.length - 1; i >= 0; i--) {
                    if (pad_top + tops[i] - _scroll_offset < viewport_height) {
                        return i;
                    }
                }
                return tops.length > 0 ? tops.length - 1 : 0;
            }

            /**
             * Scroll offset that centers line `index`, clamped to the scrollable
             * range computed during the last allocation.
             */
            public double center_offset_for (int index) {
                if (index < 0 || index >= tops.length) {
                    return 0;
                }
                double target = pad_top + tops[index] + heights[index] / 2.0
                                - viewport_height / 2.0;
                return target.clamp (0, max_offset);
            }

            public override Gtk.SizeRequestMode get_request_mode (Gtk.Widget widget) {
                return Gtk.SizeRequestMode.HEIGHT_FOR_WIDTH;
            }

            public override void measure (Gtk.Widget widget,
                                          Gtk.Orientation orientation,
                                          int for_size,
                                          out int minimum,
                                          out int natural,
                                          out int minimum_baseline,
                                          out int natural_baseline) {
                minimum_baseline = -1;
                natural_baseline = -1;
                if (orientation == Gtk.Orientation.HORIZONTAL) {
                    minimum = 0;
                    natural = 0;
                    return;
                }
                double total = 0;
                int n = 0;
                unowned Gtk.Widget? child = widget.get_first_child ();
                while (child != null) {
                    unowned Gtk.Widget line = (!) child;
                    int cmin, cnat;
                    line.measure (Gtk.Orientation.VERTICAL, for_size,
                                  out cmin, out cnat, null, null);
                    total += cnat;
                    n++;
                    child = line.get_next_sibling ();
                }
                if (n > 0) {
                    total += spacing * (n - 1);
                }
                minimum = 0;
                natural = (int) Math.ceil (total);
            }

            public override void allocate (Gtk.Widget widget,
                                           int width,
                                           int height,
                                           int baseline) {
                viewport_height = height;
                pad_top = height * 0.42;

                int n = 0;
                unowned Gtk.Widget? child = widget.get_first_child ();
                while (child != null) {
                    n++;
                    child = ((!) child).get_next_sibling ();
                }
                tops = new double[n];
                heights = new double[n];

                double y = 0;
                int i = 0;
                child = widget.get_first_child ();
                while (child != null && i < n) {
                    unowned Gtk.Widget line = (!) child;
                    int cmin, cnat;
                    line.measure (Gtk.Orientation.VERTICAL, width,
                                  out cmin, out cnat, null, null);
                    tops[i] = y;
                    heights[i] = cnat;
                    y += cnat + spacing;
                    i++;
                    child = line.get_next_sibling ();
                }

                double content = n > 0 ? y - spacing : 0;
                max_offset = double.max (0, content + 2 * pad_top - height);
                _scroll_offset = _scroll_offset.clamp (0, max_offset);

                y = pad_top - _scroll_offset;
                i = 0;
                child = widget.get_first_child ();
                while (child != null && i < n) {
                    unowned Gtk.Widget line = (!) child;
                    /* The transform carries the child's position: GTK4
                     * allocations have no x/y of their own. anim_offset adds the
                     * per-line cascade displacement on top of the stacked slot. */
                    double off = 0;
                    var lyric_line = line as LyricLine;
                    if (lyric_line != null) {
                        off = ((!) lyric_line).anim_offset;
                    }
                    var transform = (new Gsk.Transform ()).translate (Graphene.Point () {
                        x = 0, y = (float) (y + off)
                    });
                    line.allocate (width, (int) heights[i], -1, transform);
                    y += heights[i] + spacing;
                    i++;
                    child = line.get_next_sibling ();
                }
            }
        }

        /**
         * A single lyric line. Renders the main text plus an optional
         * translation; the sung portion is highlighted word by word.
         */
        private class LyricLine : Gtk.Widget {

            public Lyric.Line data { get; construct; }
            public uint index { get; construct; }
            /** End time to fall back to when data.end_time is unset. */
            public uint64 fallback_end { get; construct; }

            public signal void clicked ();

            /**
             * Vertical cascade displacement in pixels, added on top of this line's
             * stacked slot by the layout. Springs back to zero during a scroll.
             */
            public double anim_offset { get; private set; default = 0; }

            /** Emitted whenever anim_offset changes so the layout can re-place. */
            public signal void offset_changed ();

            private double _dim = 1.0;
            public double dim {
                get { return _dim; }
                set {
                    if (value != _dim) {
                        _dim = value;
                        queue_draw ();
                    }
                }
            }

            public Gtk.Justification justify {
                get { return _justify; }
                set {
                    if (value != _justify) {
                        _justify = value;
                        layout_width = int.MIN; /* force Pango rebuild */
                        queue_resize ();
                    }
                }
            }
            private Gtk.Justification _justify = Gtk.Justification.CENTER;

            private uint64 position = 0;
            private double last_progress = -1;
            private double emphasis = 0;
            private bool hover = false;
            private bool pressed = false;

            private Adw.TimedAnimation emphasis_anim;
            private Adw.SpringAnimation offset_spring;
            private uint pending_delay_id = 0;

            private string text = "";
            private int[] word_offsets = {};
            private uint64[] word_starts = {};
            private uint64[] word_ends = {};
            private uint64 eff_end = 0;

            private Pango.Layout? _main_layout = null;
            private Pango.Layout? trans_layout = null;

            /* Set by ensure_layout () before any measure or snapshot pass. */
            private unowned Pango.Layout main_layout {
                get { return (!) _main_layout; }
            }
            private int layout_width = int.MIN;
            private int text_x = 0;
            private double main_h = 0;
            private double trans_h = 0;

            private const double MAIN_FONT_SCALE = 1.5;
            private const double TRANS_FONT_SCALE = 1.0;
            private const double TRANS_GAP = 6;
            private const double EMPHASIS_SCALE = 0.10;
            private const int H_INSET = 16;

            public LyricLine (Lyric.Line data, uint index, uint64 fallback_end) {
                Object (data: data, index: index, fallback_end: fallback_end);
            }

            construct {
                set_css_name ("lyric-line");

                eff_end = data.end_time != 0 ? data.end_time : fallback_end;

                var words = data.words;
                int n = words.size;
                var sb = new StringBuilder ();
                word_offsets = new int[n + 1];
                word_starts = new uint64[n];
                word_ends = new uint64[n];
                for (int i = 0; i < n; i++) {
                    var w = words[i];
                    word_offsets[i] = (int) sb.len;
                    sb.append (w.text);
                    word_starts[i] = w.start_time;
                    word_ends[i] = w.end_time != 0
                        ? w.end_time
                        : (i + 1 < n ? words[i + 1].start_time : eff_end);
                }
                word_offsets[n] = (int) sb.len;
                text = sb.str;

                emphasis_anim = new Adw.TimedAnimation (this, 0.0, 1.0, 280,
                    new Adw.CallbackAnimationTarget ((value) => {
                        emphasis = value;
                        queue_draw ();
                    }));
                emphasis_anim.easing = Adw.Easing.EASE_OUT_QUART;

                offset_spring = new Adw.SpringAnimation (this, 0.0, 0.0,
                    new Adw.SpringParams (0.82, 1.0, 380.0),
                    new Adw.CallbackAnimationTarget ((value) => {
                        if (value != anim_offset) {
                            anim_offset = value;
                            offset_changed ();
                        }
                    }));

                var motion = new Gtk.EventControllerMotion ();
                motion.enter.connect ((x, y) => {
                    hover = true;
                    queue_draw ();
                });
                motion.leave.connect (() => {
                    hover = false;
                    pressed = false;
                    queue_draw ();
                });
                add_controller (motion);

                var click = new Gtk.GestureClick ();
                click.pressed.connect ((n_press, x, y) => {
                    pressed = true;
                    queue_draw ();
                });
                click.released.connect ((n_press, x, y) => {
                    pressed = false;
                    queue_draw ();
                    if (n_press == 1) {
                        clicked ();
                    }
                });
                add_controller (click);
            }

            public override Gtk.SizeRequestMode get_request_mode () {
                return Gtk.SizeRequestMode.HEIGHT_FOR_WIDTH;
            }

            public void animate_emphasis (double target) {
                if (!get_realized ()) {
                    emphasis = target;
                    queue_draw ();
                    return;
                }
                emphasis_anim.pause ();
                emphasis_anim.value_from = emphasis;
                emphasis_anim.value_to = target;
                emphasis_anim.play ();
            }

            /**
             * Kick off this line's part of a scroll cascade. `delta` is added to
             * the current offset immediately (holding the line visually still while
             * the layout jumps underneath it), then the offset springs back to
             * zero after `delay_ms`. Re-entrant: an in-flight line re-targets from
             * wherever it is, keeping its velocity for a smooth handoff.
             */
            public void cascade (double delta, uint delay_ms) {
                double from = anim_offset + delta;
                double vel = offset_spring.get_velocity ();
                cancel_pending ();
                offset_spring.pause ();
                anim_offset = from;

                if (!get_realized ()) {
                    anim_offset = 0;
                    return;
                }
                if (delay_ms == 0) {
                    start_offset_spring (from, vel);
                } else {
                    pending_delay_id = Timeout.add (delay_ms, () => {
                        pending_delay_id = 0;
                        start_offset_spring (from, 0);
                        return Source.REMOVE;
                    });
                }
            }

            private void start_offset_spring (double from, double vel) {
                offset_spring.value_from = from;
                offset_spring.value_to = 0.0;
                offset_spring.initial_velocity = vel;
                offset_spring.play ();
            }

            private void cancel_pending () {
                if (pending_delay_id != 0) {
                    Source.remove (pending_delay_id);
                    pending_delay_id = 0;
                }
            }

            public void update_position (uint64 pos) {
                double p = overall_progress_of (pos);
                position = pos;
                if (Math.fabs (p - last_progress) < 0.002) {
                    return;
                }
                last_progress = p;
                queue_draw ();
            }

            private double overall_progress_of (uint64 pos) {
                if (eff_end <= data.start_time) {
                    return pos >= eff_end ? 1.0 : 0.0;
                }
                if (pos <= data.start_time) {
                    return 0.0;
                }
                return (((double) pos - data.start_time) / (eff_end - data.start_time)).clamp (0, 1);
            }

            private void ensure_layout (int width) {
                if (_main_layout != null && layout_width == width) {
                    return;
                }
                layout_width = width;

                /* Inset the text block so the emphasis scale-up can never push
                 * glyphs outside the view. */
                int side = (int) (width * EMPHASIS_SCALE) / 2 + H_INSET;
                int inner = int.max (1, width - 2 * side);
                text_x = side;

                unowned Pango.FontDescription? font_desc = get_pango_context ().get_font_description ();
                if (font_desc == null) {
                    return;
                }

                var main_desc = ((!) font_desc).copy ();
                scale_font (main_desc, MAIN_FONT_SCALE);
                _main_layout = create_pango_layout (text);
                main_layout.set_font_description (main_desc);
                setup_common (main_layout, inner);
                main_h = layout_height (main_layout);

                var translation = data.translation;
                if (translation != null && ((!) translation).length > 0) {
                    var trans_desc = ((!) font_desc).copy ();
                    scale_font (trans_desc, TRANS_FONT_SCALE);
                    trans_layout = create_pango_layout ((!) translation);
                    var trans = (!) trans_layout;
                    trans.set_font_description (trans_desc);
                    setup_common (trans, inner);
                    trans_h = layout_height (trans);
                } else {
                    trans_layout = null;
                    trans_h = 0;
                }
            }

            private void setup_common (Pango.Layout layout, int width) {
                Pango.Alignment pa;
                switch (_justify) {
                    case Gtk.Justification.LEFT:
                        pa = Pango.Alignment.LEFT;
                        break;
                    case Gtk.Justification.RIGHT:
                        pa = Pango.Alignment.RIGHT;
                        break;
                    default:
                        pa = Pango.Alignment.CENTER;
                        break;
                }
                layout.set_alignment (pa);
                layout.set_wrap (Pango.WrapMode.WORD_CHAR);
                layout.set_width (width > 0 ? (int) (width * Pango.SCALE) : -1);
            }

            private static double layout_height (Pango.Layout layout) {
                Pango.Rectangle logical;
                layout.get_extents (null, out logical);
                return logical.height / (double) Pango.SCALE;
            }

            private static void scale_font (Pango.FontDescription? desc, double factor) {
                if (desc == null) {
                    return;
                }
                var font_desc = (!) desc;
                if (font_desc.get_size_is_absolute ()) {
                    font_desc.set_absolute_size (font_desc.get_size () * factor);
                } else {
                    font_desc.set_size ((int) (font_desc.get_size () * factor));
                }
            }

            public override void measure (Gtk.Orientation orientation,
                                          int for_size,
                                          out int minimum,
                                          out int natural,
                                          out int minimum_baseline,
                                          out int natural_baseline) {
                minimum_baseline = -1;
                natural_baseline = -1;
                if (orientation == Gtk.Orientation.HORIZONTAL) {
                    minimum = 0;
                    natural = 0;
                    return;
                }
                ensure_layout (for_size);
                natural = (int) Math.ceil (main_h
                         + (trans_layout != null ? TRANS_GAP + trans_h : 0));
                minimum = natural;
            }

            public override void snapshot (Gtk.Snapshot snapshot) {
                int w = get_width ();
                int h = get_height ();
                if (w <= 0 || h <= 0) {
                    return;
                }
                ensure_layout (w);

                Gdk.RGBA base_c = get_color ();

                if (hover || pressed) {
                    double a = pressed ? 0.14 : 0.07;
                    var bounds = Graphene.Rect () {
                        origin = Graphene.Point () { x = 8, y = 1 },
                        size = Graphene.Size () { width = w - 16, height = h - 2 }
                    };
                    Gsk.RoundedRect rr = Gsk.RoundedRect ();
                    rr.init_from_rect (bounds, 12f);
                    snapshot.push_rounded_clip (rr);
                    snapshot.append_color (with_alpha (base_c, base_c.alpha * a), bounds);
                    snapshot.pop ();
                }

                double s = 1.0 + EMPHASIS_SCALE * emphasis;
                if (s != 1.0) {
                    /* Gtk.Snapshot.translate/scale mutate the current state's
                     * transform in place; no pop needed. */
                    snapshot.translate (Graphene.Point () { x = w / 2.0f, y = h / 2.0f });
                    snapshot.scale ((float) s, (float) s);
                    snapshot.translate (Graphene.Point () { x = -w / 2.0f, y = -h / 2.0f });
                }

                /* Text block sits inside the side insets. */
                snapshot.translate (Graphene.Point () { x = (float) text_x, y = 0 });

                var dim_color = with_alpha (base_c,
                    base_c.alpha * 0.40 * _dim * (hover ? 1.2 : 1.0));
                var hi_color = with_alpha (base_c, base_c.alpha * _dim);

                snapshot.append_layout (main_layout, dim_color);
                draw_word_fill (snapshot, w, hi_color);

                if (trans_layout != null) {
                    snapshot.save ();
                    snapshot.translate (Graphene.Point () {
                        x = 0, y = (float) (main_h + TRANS_GAP)
                    });
                    snapshot.append_layout ((!) trans_layout,
                        with_alpha (base_c, base_c.alpha * 0.85 * _dim));
                    snapshot.restore ();
                }
            }

            private static Gdk.RGBA with_alpha (Gdk.RGBA color, double alpha) {
                color.alpha = (float) alpha;
                return color;
            }

            /**
             * Draws the sung portion of the main layout on top of the dim pass.
             * Fully sung layout lines are clipped whole; the line holding the
             * current word is clipped up to the interpolated word position, so
             * the highlight wipes across it with a sharp edge.
             */
            private void draw_word_fill (Gtk.Snapshot snapshot, int w, Gdk.RGBA hi_color) {
                int boundary_byte;
                double bx;
                bool full;
                compute_boundary (out boundary_byte, out bx, out full);

                if (full) {
                    snapshot.append_layout (main_layout, hi_color);
                    return;
                }

                int n_lines = main_layout.get_line_count ();
                for (int li = 0; li < n_lines; li++) {
                    unowned Pango.LayoutLine? line = main_layout.get_line_readonly (li);
                    if (line == null) {
                        break;
                    }
                    unowned Pango.LayoutLine ll = (!) line;
                    if (ll.start_index > boundary_byte) {
                        break;
                    }
                    Pango.Rectangle band_r = main_layout.index_to_pos (ll.start_index);
                    var clip = Graphene.Rect () {
                        origin = Graphene.Point () {
                            x = -text_x, y = band_r.y / (float) Pango.SCALE
                        },
                        size = Graphene.Size () {
                            width = w, height = band_r.height / (float) Pango.SCALE
                        }
                    };
                    /* The boundary byte can sit exactly at a layout line's start
                     * (first word, or a word opening a wrapped line); that line
                     * still carries the wipe edge. */
                    bool sung_line = ll.start_index + ll.length <= boundary_byte;
                    if (!sung_line) {
                        clip.size.width = (float) bx + text_x;
                        if (clip.size.width <= 0) {
                            break;
                        }
                    }
                    snapshot.push_clip (clip);
                    snapshot.append_layout (main_layout, hi_color);
                    snapshot.pop ();
                    if (!sung_line) {
                        break;
                    }
                }
            }

            /**
             * Byte index the highlight ends at, and its x position in widget
             * coordinates (interpolated inside the currently sung word).
             * `full` is set when the whole line has been sung.
             */
            private void compute_boundary (out int boundary_byte, out double bx, out bool full) {
                int n = word_starts.length;
                boundary_byte = text.length;
                bx = double.MAX;
                full = true;

                if (n == 0) {
                    if (position < eff_end) {
                        full = false;
                        boundary_byte = 0;
                        bx = 0;
                    }
                    return;
                }
                if (position >= eff_end) {
                    return;
                }
                for (int k = 0; k < n; k++) {
                    if (position < word_ends[k]) {
                        full = false;
                        boundary_byte = word_offsets[k];
                        uint64 ws = word_starts[k];
                        uint64 we = word_ends[k];
                        double frac = 0;
                        if (we > ws && position > ws) {
                            frac = (((double) position - ws) / (we - ws)).clamp (0, 1);
                        }
                        Pango.Rectangle r0 = main_layout.index_to_pos (word_offsets[k]);
                        Pango.Rectangle rs, rw;
                        main_layout.get_cursor_pos (word_offsets[k + 1], out rs, out rw);
                        if (rs.y != r0.y) {
                            /* Next word wrapped onto another line: wipe to this
                             * line's right edge instead of flying back to its
                             * left margin. */
                            rs.x = line_right_x (word_offsets[k]);
                        }
                        bx = (r0.x + (rs.x - r0.x) * frac) / (double) Pango.SCALE;
                        return;
                    }
                }
            }

            /**
             * Right edge (in layout coords) of the layout line containing
             * `byte_index`. Pango line extents are line-relative, so the line's
             * own origin must be added back.
             */
            private int line_right_x (int byte_index) {
                int nl = main_layout.get_line_count ();
                for (int li = 0; li < nl; li++) {
                    unowned Pango.LayoutLine? line = main_layout.get_line_readonly (li);
                    if (line == null) {
                        break;
                    }
                    unowned Pango.LayoutLine ll = (!) line;
                    if (byte_index < ll.start_index ||
                        byte_index >= ll.start_index + ll.length) {
                        continue;
                    }
                    Pango.Rectangle origin = main_layout.index_to_pos (ll.start_index);
                    Pango.Rectangle logical;
                    ll.get_extents (null, out logical);
                    return origin.x + logical.width;
                }
                return 0;
            }
        }
    }
}
