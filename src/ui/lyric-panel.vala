// SPDX-FileCopyrightText: 2026 DriverDing
// SPDX-License-Identifier: GPL-3.0-or-later

namespace G4 {

    /**
     * The lyric page of the playing music, which follows the playback
     * position while visible, and seeks when a line is clicked.
     */
    public class LyricPanel: Gtk.Box {
        private LyricView _view = new LyricView ();
        private GstPlayer _player;
        private bool _mapped = false;
        private bool _playing = false;
        private uint _tick_handler = 0;

        public Lyric? lyric {
            get {
                return _view.lyric;
            }
            set {
                _view.lyric = value;
                if (value != null) {
                    set_position (_player.position);
                }
            }
        }

        construct {
            _player = ((Application) GLib.Application.get_default ()).player;

            hexpand = true;
            vexpand = true;
            _view.hexpand = true;
            _view.vexpand = true;
            _view.line_activated.connect (on_line_activated);
            append (_view);

            map.connect (on_page_mapped);
            unmap.connect (on_page_unmapped);

            _player.state_changed.connect (on_state_changed);
            _player.position_updated.connect (on_position_updated);
        }

        private void on_page_mapped () {
            _mapped = true;
            update_ticking ();
        }

        private void on_page_unmapped () {
            _mapped = false;
            update_ticking ();
        }

        private void on_state_changed (Gst.State state) {
            _playing = state == Gst.State.PLAYING;
            update_ticking ();
        }

        private void on_position_updated (Gst.ClockTime position) {
            //  Emitted only ~10 times per second, so the frame clock is used
            //  while playing to make the word highlight smooth.
            if (_tick_handler == 0) {
                set_position (position);
            }
        }

        private void on_line_activated (uint index) {
            var lyric = _view.lyric;
            if (lyric == null)
                return;
            var lines = ((!) lyric).lines;
            var i = (int) index;
            if (i < 0 || i >= lines.size)
                return;
            _player.seek ((Gst.ClockTime) lines[i].start_time * Gst.MSECOND);
        }

        private void update_ticking () {
            var need_tick = _mapped && _playing;
            if (need_tick && _tick_handler == 0) {
                _tick_handler = add_tick_callback (on_tick_callback);
            } else if (!need_tick && _tick_handler != 0) {
                remove_tick_callback (_tick_handler);
                _tick_handler = 0;
            }
        }

        private bool on_tick_callback (Gtk.Widget widget, Gdk.FrameClock clock) {
            set_position (_player.query_position ());
            return true;
        }

        private void set_position (Gst.ClockTime position) {
            if (position != Gst.CLOCK_TIME_NONE) {
                _view.position = (uint64) (position / Gst.MSECOND);
            }
        }
    }
}
