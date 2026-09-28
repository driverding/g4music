namespace G4 {

    /**
     * A waveform that doubles as the seek bar: static loudness peaks from
     * offline analysis, live FFT bands while playing, and a drag gesture that
     * seeks. Ported from the Lyricala player (same author, same licence).
     */
    public class WaveformView : Gtk.Widget {
        public const int DEFAULT_DATA_LENGTH = 256;

        public uint data_length { get; construct; }

        /** Show the loudness bars, or only the flat progress baseline. */
        public bool peaks_visible {
            get {
                return _peaks_visible;
            }
            set {
                if (_peaks_visible != value) {
                    _peaks_visible = value;
                    queue_draw ();
                }
            }
        }
        private bool _peaks_visible = true;

        private double _playing_position = 0.0;
        public double playing_position {
            get {
                return _playing_position;
            }
            set {
                var pos = value.clamp (0.0, 1.0);
                if (pos != _playing_position) {
                    _playing_position = pos;
#if GTK_4_10
                    update_accessible_values ({ Gtk.AccessibleProperty.VALUE_NOW }, { pos });
#endif
                    queue_draw ();
                }
            }
        }

        /* Not a GObject property: Vala cannot map nullable types onto one, and the
         * position is only ever driven by pointer motion on the widget itself. */
        private double? _hover_position;
        private void set_hover_position (double? position) {
            if (position == null) {
                _hover_position = null;
                queue_draw ();
                return;
            }
            var pos = ((!) position).clamp (0.0, 1.0);
            if (pos != _hover_position) {
                _hover_position = pos;
                queue_draw ();
            }
        }

        public signal void position_changed (double position);

        private double[] current_values;
        private double[] target_waveform;
        private double[] previous_waveform;
        private double[] target_spectrum;

        class construct {
            set_css_name ("waveformview");
#if GTK_4_10
            set_accessible_role (Gtk.AccessibleRole.SLIDER);
#endif
        }

        public WaveformView (uint data_length) {
            Object (data_length: data_length);
        }

        construct {
            current_values = new double[data_length];
            target_waveform = new double[data_length];
            previous_waveform = new double[data_length];
            target_spectrum = new double[data_length];

            this.focusable = true;
            setup_gestures ();

#if GTK_4_10
            update_accessible_values ({ Gtk.AccessibleProperty.VALUE_MIN,
                                        Gtk.AccessibleProperty.VALUE_MAX },
                                      { 0.0, 1.0 });
#endif
        }

        /**
         * Set the peaks to a waveform with a transition animation. The waveform
         * is expected to be stationary.
         */
        public void set_waveform (double[] waveform) {
            if (waveform.length != data_length) {
                critical ("Unmatched length");
                return;
            }

            stop_decay ();
            for (uint i = 0; i < data_length; i++) {
                previous_waveform[i] = current_values[i];
            }
            target_waveform = waveform;

            start_swap_animation ();
        }

        /**
         * Set the peaks to a spectrum. The spectrum is expected to be fast changing,
         * and periodically set at high frequency.
         */
        public void set_spectrum (double[] spectrum) {
            if (spectrum.length != data_length) {
                critical ("Unmatched length");
                return;
            }

            stop_swap_animation ();

            target_spectrum = spectrum;
            start_decay ();
        }

        /** Clear the peaks, e.g. when nothing is playing any more. */
        public void reset () {
            stop_swap_animation ();
            stop_decay ();
            for (uint i = 0; i < data_length; i++) {
                current_values[i] = 0;
                target_waveform[i] = 0;
                previous_waveform[i] = 0;
                target_spectrum[i] = 0;
            }
            playing_position = 0;
            set_hover_position (null);
        }

        /* Accessibility **************************************/

#if GTK_4_10
        private void update_accessible_values (Gtk.AccessibleProperty[] properties, double[] values) {
            var g_values = new GLib.Value[values.length];
            for (uint i = 0; i < values.length; i++) {
                g_values[i].init (typeof (double));
                g_values[i].set_double (values[i]);
            }
            this.update_property_value (properties, g_values);
        }
#endif

        /* Gestures *******************************************/

        private Gtk.GestureDrag drag_gesture = new Gtk.GestureDrag ();
        private Gtk.EventControllerMotion motion_controller = new Gtk.EventControllerMotion ();

        private void setup_gestures () {
            drag_gesture.name = "waveform-drag";
            drag_gesture.button = 0;
            drag_gesture.drag_begin.connect (drag_begin);
            drag_gesture.drag_update.connect (drag_update);
            this.add_controller (drag_gesture);

            motion_controller.name = "waveform-motion";
            motion_controller.motion.connect (motion);
            motion_controller.leave.connect (leave);
            this.add_controller (motion_controller);
        }

        private void drag_begin (Gtk.GestureDrag gesture, double start_x, double start_y) {
            if (!this.has_focus) { this.grab_focus (); }
            gesture.set_state (Gtk.EventSequenceState.CLAIMED);

            var width = this.get_width ();
            if (width <= 0) { return; }

            double pos = start_x / width;
            if (this.get_direction () == Gtk.TextDirection.RTL) { pos = 1.0 - pos; }
            seek_and_emit (pos);
        }

        private void drag_update (Gtk.GestureDrag gesture, double offset_x, double offset_y) {
            if (!this.has_focus) { this.grab_focus (); }
            gesture.set_state (Gtk.EventSequenceState.CLAIMED);

            var width = this.get_width ();
            if (width <= 0) { return; }

            double start_x = 0;
            gesture.get_start_point (out start_x, null);
            double current_x = start_x + offset_x;

            double pos = current_x / width;
            if (this.get_direction () == Gtk.TextDirection.RTL) { pos = 1.0 - pos; }
            seek_and_emit (pos);
        }

        private void motion (double x, double y) {
            double width = this.get_width ();
            if (width <= 0) { return; }

            double pos = x / width;
            if (this.get_direction () == Gtk.TextDirection.RTL) { pos = 1.0 - pos; }
            set_hover_position (pos);
        }

        private void leave () {
            set_hover_position (null);
        }

        private void seek_and_emit (double position) {
            var pos = position.clamp (0.0, 1.0);
            // Keep the hover marker under the pointer while dragging: motion events
            // go to the drag gesture, so a stale hover would keep a span lit up.
            set_hover_position (pos);
            this.playing_position = pos;
            this.position_changed (pos);
        }

        /* Animations *****************************************/
        private const double SWAP_ANIMATION_USECS = 250000.0; // 250ms
        private const double DECAY_ANIMATION_MULTIPLIER = 5.0;
        private const double DECAY_SETTLE_EPSILON = 0.001;

        private bool animations_enabled () {
            return this.get_settings ().gtk_enable_animations;
        }

        private void snap_to (double[] source) {
            for (uint i = 0; i < data_length; i++) {
                current_values[i] = source[i];
            }
        }

        public override void dispose () {
            stop_swap_animation ();
            stop_decay ();
            base.dispose ();
        }

        /* Swap */
        private uint swap_tick_id = 0;
        private int64? swap_first_frame_time = null;

        private void start_swap_animation () {
            stop_swap_animation ();

            if (!animations_enabled ()) {
                snap_to (target_waveform);
                queue_draw ();
                return;
            }
            swap_tick_id = this.add_tick_callback (swap_callback);
        }

        private void stop_swap_animation () {
            if (swap_tick_id != 0) {
                this.remove_tick_callback (swap_tick_id);
                swap_tick_id = 0;
            }
            swap_first_frame_time = null;
        }

        private bool swap_callback (Gtk.Widget widget, Gdk.FrameClock clock) {
            if (swap_first_frame_time == null) {
                swap_first_frame_time = clock.get_frame_time ();
                return true;
            }

            int64 first = (!) swap_first_frame_time;
            double progress = ((double) (clock.get_frame_time () - first) / SWAP_ANIMATION_USECS).clamp (0.0, 1.0);

            if (progress >= 1.0) {
                snap_to (target_waveform);
                // Returning false drops the tick, so no remove_tick_callback here.
                swap_tick_id = 0;
                swap_first_frame_time = null;
                queue_draw ();
                return false;
            }

            // The old peaks collapse onto the center line, then the new ones grow
            // out of it, which reads as a flip instead of a crossfade.
            if (progress < 0.5) {
                double factor = 1.0 - ease_out_cubic (progress * 2.0);
                for (uint i = 0; i < data_length; i++) {
                    current_values[i] = previous_waveform[i] * factor;
                }
            } else {
                double factor = ease_out_cubic (progress * 2.0 - 1.0);
                for (uint i = 0; i < data_length; i++) {
                    current_values[i] = target_waveform[i] * factor;
                }
            }

            queue_draw ();
            return true;
        }

        /* Decay */
        private uint decay_tick_id = 0;
        private int64? decay_previous_frame_time = null;

        private void start_decay () {
            if (decay_tick_id != 0) {
                return;
            }

            if (!animations_enabled ()) {
                snap_to (target_spectrum);
                queue_draw ();
                return;
            }

            decay_previous_frame_time = null;
            decay_tick_id = this.add_tick_callback (decay_callback);
        }

        private void stop_decay () {
            if (decay_tick_id != 0) {
                this.remove_tick_callback (decay_tick_id);
                decay_tick_id = 0;
            }
            decay_previous_frame_time = null;
        }

        private bool decay_callback (Gtk.Widget widget, Gdk.FrameClock clock) {
            int64 current = clock.get_frame_time ();
            // First Frame
            if (decay_previous_frame_time == null) {
                decay_previous_frame_time = current;
                return true;
            }

            int64 previous = (!) decay_previous_frame_time;

            double dt = (double) (current - previous) / 1000000.0;
            double factor = GLib.Math.exp (-DECAY_ANIMATION_MULTIPLIER * dt);

            bool settled = true;
            for (uint i = 0; i < current_values.length; i++) {
                double c = current_values[i];
                double t = target_spectrum[i];

                if (c < t) {
                    current_values[i] = t;
                } else if (c > t) {
                    double decayed = t + (c - t) * factor;
                    if (decayed - t < DECAY_SETTLE_EPSILON) {
                        current_values[i] = t;
                    } else {
                        current_values[i] = decayed;
                        settled = false;
                    }
                }
            }

            decay_previous_frame_time = current;
            queue_draw ();

            if (settled) {
                // Nothing moves anymore; the next set_spectrum () wakes us up.
                decay_tick_id = 0;
                return false;
            }
            return true;
        }

        /* Render *********************************************/
        private const int BAR_SIZE = 2;
        private const int SPACE_SIZE = 2;
        private const int BLOCK_SIZE = BAR_SIZE + SPACE_SIZE;

        private const int MIN_BAR_COUNT = 8;
        private const int MIN_BAR_HEIGHT = 2;
        private const int MIN_HEIGHT = 16;
        private const int NATURAL_HEIGHT = 48;

        public override void measure (Gtk.Orientation orientation, int for_size,
                                      out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = -1;
            natural_baseline = -1;

            if (orientation == Gtk.Orientation.HORIZONTAL) {
                minimum = MIN_BAR_COUNT * BLOCK_SIZE;
                natural = int.max (minimum, (int) data_length);
            } else {
                minimum = MIN_HEIGHT;
                natural = NATURAL_HEIGHT;
            }
        }

        public override void snapshot (Gtk.Snapshot snapshot) {
            int w = this.get_width ();
            int h = this.get_height ();
            if (w < BLOCK_SIZE || h <= 0) {
                return;
            }

            float center_y = h / 2.0f;

            bool hc = Adw.StyleManager.get_default ().get_high_contrast ();
#if GTK_4_10
            Gdk.RGBA color = this.get_color ();
#else
            Gdk.RGBA color = this.get_style_context ().get_color ();
#endif

            double empty_opacity = hc ? 0.4 : 0.2;
            double hover_opacity = hc ? 0.7 : 0.45;

            var empty_color = Gdk.RGBA () {
                red = color.red,
                green = color.green,
                blue = color.blue,
                alpha = (float) (color.alpha * empty_opacity),
            };
            var hover_color = Gdk.RGBA () {
                red = color.red,
                green = color.green,
                blue = color.blue,
                alpha = (float) (color.alpha * hover_opacity),
            };

            bool is_rtl = this.get_direction () == Gtk.TextDirection.RTL;

            int bar_count = w / BLOCK_SIZE;
            double[] interpolated_values = resample (current_values, (uint) bar_count);

            int playing_point = (int) (playing_position * bar_count);
            int hover_point = playing_point;
            if (_hover_position != null) {
                hover_point = (int) ((!) _hover_position * bar_count);
            }
            int seek_start = int.min (playing_point, hover_point);
            int seek_end = int.max (playing_point, hover_point);

            for (int i = 0; i < bar_count; i += 1) {
                // Peaks are 0.0 - 1.0; scale them onto the center line and keep a
                // floor so silence still reads as the dotted placeholder row.
                double value = peaks_visible ? interpolated_values[i] : 0.0;
                float amplitude = (float) value.clamp (0.0, 1.0) * center_y;
                float height = float.max (2.0f * amplitude, MIN_BAR_HEIGHT);

                var bar = Graphene.Rect () {
                    origin = Graphene.Point () {
                        x = is_rtl ? (float) (w - SPACE_SIZE - i * BLOCK_SIZE)
                                   : (float) (SPACE_SIZE + i * BLOCK_SIZE),
                        y = center_y - height / 2.0f,
                    },
                    size = Graphene.Size () {
                        width = (float) BAR_SIZE,
                        height = height,
                    },
                };

                // The bar under the cursor keeps the played color; everything between
                // it and the hover point is the seek preview, in both directions.
                bool in_seek_span = i != playing_point && i >= seek_start && i <= seek_end;
                var bar_color = in_seek_span ? hover_color
                                             : i <= playing_point ? color : empty_color;
                snapshot.append_color (bar_color, bar);
            }
        }

        private static double ease_out_cubic (double t) {
            double p = t - 1.0;
            return p * p * p + 1.0;
        }

        /**
         * Bucket Averaging Interpolation
         * @param values Raw values, expected longer than length
         * @param length Target length, expected smaller than then length of values
         */
        private double[] resample (double[] values, uint length) {
            var result = new double[length];
            double step = (double) values.length / length;

            for (uint i = 0; i < length; i++) {
                uint start = (uint) (i * step);
                uint end = (uint) ((i + 1) * step);
                if (end <= start) {
                    end = start + 1;
                }
                if (end > values.length) {
                    end = values.length;
                }

                double sum = 0.0;
                uint count = end - start;
                for (uint j = start; j < end; j += 1) {
                    sum += values[j];
                }
                result[i] = sum / count;
            }

            return result;
        }
    }
}
