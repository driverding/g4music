namespace G4 {

    public class PlayBar : Gtk.Box {
        private WaveformView _waveform = new WaveformView (WaveformView.DEFAULT_DATA_LENGTH);
        private Gtk.Label _positive = new Gtk.Label ("0:00");
        private Gtk.Label _negative = new Gtk.Label ("0:00");
        private Gtk.ToggleButton _repeat = new Gtk.ToggleButton ();
        private Gtk.Button _prev = new Gtk.Button ();
        private Gtk.Button _play = new Gtk.Button ();
        private Gtk.Button _next = new Gtk.Button ();
        private VolumeButton _volume = new VolumeButton ();
        private int _duration = 0;
        private int _position = 0;
        private bool _remain_progress = false;
        private double _pending_ratio = -1;
        private uint _seek_source = 0;

        /* Seeks are accurate and the waveform reports continuously while it is
           dragged, so the requests are coalesced into a single short delay. */
        private const uint SEEK_DELAY_MS = 120;

        public signal void position_seeked (double position);

        construct {
            orientation = Gtk.Orientation.VERTICAL;

            var app = (Application) GLib.Application.get_default ();
            var player = app.player;

            _waveform.hexpand = true;
            append (_waveform);
            setup_waveform (player);
            player.enable_spectrum ((int) _waveform.data_length);

            var times = new Gtk.CenterBox ();
            times.baseline_position = Gtk.BaselinePosition.CENTER;
            times.halign = Gtk.Align.FILL;
            times.set_start_widget (_positive);
            times.set_end_widget (_negative);
            append (times);

            _positive.halign = Gtk.Align.START;
            _positive.margin_start = 12;
            _positive.add_css_class ("dim-label");
            _positive.add_css_class ("numeric");

            _negative.halign = Gtk.Align.END;
            _negative.margin_end = 12;
            _negative.add_css_class ("dim-label");
            _negative.add_css_class ("numeric");

            make_widget_clickable (_negative).pressed.connect (() => remain_progress = ! remain_progress);

            var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 16);
            buttons.halign = Gtk.Align.CENTER;
            buttons.margin_top = 16;
            buttons.append (_repeat);
            buttons.append (_prev);
            buttons.append (_play);
            buttons.append (_next);
            buttons.append (_volume);
            append (buttons);

            _repeat.icon_name = "media-playlist-repeat-symbolic";
            _repeat.valign = Gtk.Align.CENTER;
            /* Translators: single loop the current music */
            _repeat.tooltip_text = _("Single Loop");
            _repeat.add_css_class ("flat");
            _repeat.toggled.connect (() => {
                _repeat.icon_name = _repeat.active ? "media-playlist-repeat-song-symbolic" : "media-playlist-repeat-symbolic";
                app.single_loop = ! app.single_loop;
            });

            _prev.valign = Gtk.Align.CENTER;
            _prev.action_name = ACTION_APP + ACTION_PREV;
            _prev.icon_name = "media-skip-backward-symbolic";
            _prev.tooltip_text = _("Play Previous");
            _prev.add_css_class ("circular");

            _play.valign = Gtk.Align.CENTER;
            _play.action_name = ACTION_APP + ACTION_PLAY_PAUSE;
            _play.icon_name = "media-playback-start-symbolic"; // media-playback-pause-symbolic
            _play.tooltip_text = _("Play/Pause");
            _play.add_css_class ("circular");
            _play.set_size_request (48, 48);

            _next.valign = Gtk.Align.CENTER;
            _next.action_name = ACTION_APP + ACTION_NEXT;
            _next.icon_name = "media-skip-forward-symbolic";
            _next.tooltip_text = _("Play Next");
            _next.add_css_class ("circular");

            _volume.valign = Gtk.Align.CENTER;
            player.bind_property ("volume", _volume, "value", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);

            player.duration_changed.connect (on_duration_changed);
            player.position_updated.connect (on_position_changed);
            player.state_changed.connect (on_state_changed);

            var settings = app.settings;
            settings.bind ("show-peak", _waveform, "peaks-visible", SettingsBindFlags.DEFAULT);
            settings.bind ("remain-progress", this, "remain-progress", SettingsBindFlags.DEFAULT);
        }

        public double position {
            get {
                return _position;
            }
        }

        public bool remain_progress {
            get {
                return _remain_progress;
            }
            set {
                _remain_progress = value;
                update_negative_label ();
            }
        }

        /** Sample count the waveform and the live spectrum are fed with. */
        public uint waveform_data_length {
            get {
                return _waveform.data_length;
            }
        }

        /** The loudness peaks of the track that is about to play. */
        public void set_waveform (double[] waveform) {
            _waveform.set_waveform (waveform);
        }

        /** One live FFT frame of the audio being played. */
        public void set_spectrum (double[] bands) {
            _waveform.set_spectrum (bands);
        }

        /** Drop the peaks, e.g. when there is nothing loaded. */
        public void clear_waveform () {
            _waveform.reset ();
        }

        public void on_size_changed (int bar_spacing) {
            get_last_child ()?.set_margin_top (bar_spacing);
        }

        private void on_duration_changed (Gst.ClockTime duration) {
            var value = GstPlayer.to_second (duration);
            _duration = (int) (value + 0.5);
            update_negative_label ();
        }

        private void on_position_changed (Gst.ClockTime position) {
            //  The pointer owns the marker while the waveform is being dragged
            if (_seek_source == 0) {
                update_position (position);
            }
        }

        private void on_state_changed (Gst.State state) {
            var playing = state == Gst.State.PLAYING;
            _play.icon_name = playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
        }

        private void setup_waveform (GstPlayer player) {
            _waveform.position_changed.connect ((ratio) => {
                if (_duration <= 0)
                    return;
                var pos = ratio * _duration;
                _position = (int) (pos + 0.5);
                _positive.label = format_time (_position);
                update_negative_label ();
                position_seeked (pos);
                schedule_seek (player, ratio);
            });
        }

        private void schedule_seek (GstPlayer player, double ratio) {
            _pending_ratio = ratio;
            if (_seek_source != 0)
                Source.remove (_seek_source);
            _seek_source = run_timeout_once (SEEK_DELAY_MS, () => {
                _seek_source = 0;
                player.seek (GstPlayer.from_second (_pending_ratio * _duration));
            });
        }

        private void update_negative_label () {
            if (_remain_progress)
                _negative.label = "-" + format_time (_duration - _position);
            else
                _negative.label = format_time (_duration);
        }

        private void update_position (Gst.ClockTime position) {
            var value = GstPlayer.to_second (position);
            if (_position != (int) value) {
                _position = (int) value;
                _positive.label = format_time (_position);
                if (_remain_progress)
                    _negative.label = "-" + format_time (_duration - _position);
            }
            _waveform.playing_position = _duration > 0 ? value / _duration : 0;
        }
    }

    public static string format_time (int seconds) {
        var sb = new StringBuilder ();
        var hours = seconds / 3600;
        var minutes = seconds / 60;
        seconds -= minutes * 60;
        if (hours > 0) {
            minutes -= hours * 60;
            sb.printf ("%d:%02d:%02d", hours, minutes, seconds);
        } else {
            sb.printf ("%d:%02d", minutes, seconds);
        }
        return sb.str;
    }

    public static Gtk.GestureClick make_widget_clickable (Gtk.Widget label) {
        var controller = new Gtk.GestureClick ();
        controller.button = Gdk.BUTTON_PRIMARY;
        label.add_controller (controller);
        label.set_cursor_from_name ("pointer");
        return controller;
    }
}
