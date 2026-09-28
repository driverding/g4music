namespace G4 {

    /** Growable peak buffer: {@link Waveform.analyze} fills it from a bus watch. */
    internal class PeakBuffer : Object {
        private double[] _values = new double[1024];
        private int _length = 0;

        public void add (double value) {
            if (_length == _values.length)
                _values.resize (_values.length * 2);
            _values[(_length++)] = value;
        }

        public double[] to_array () {
            var result = new double[_length];
            for (int i = 0; i < _length; i++)
                result[i] = _values[i];
            return result;
        }
    }

    /**
     * Offline loudness waveform analysis.
     *
     * A throwaway GStreamer pipeline (uridecodebin -> audioconvert -> level ->
     * fakesink) decodes the file as fast as possible, collecting one linear peak
     * value per LEVEL_INTERVAL_NS. The peaks are normalized to 0..1 and bucketed
     * down to RESOLUTION samples, then cached on disk keyed by uri and file time
     * so re-opening a track is instant.
     */
    public class Waveform : Object {
        /** Canonical sample count kept in memory/cache, independent of widget size. */
        public const int RESOLUTION = 512;

        /* one level message per this interval (~10 Hz meter) */
        private const uint64 LEVEL_INTERVAL_NS = 100 * Gst.MSECOND;

        private const int CACHE_VERSION = 1;

        /* ---- pure math ------------------------------------------------------- */

        private static double db_to_linear (double db) {
            if (db != db)            /* NaN */
                return 0.0;
            if (db <= -100.0)        /* level reports -inf / very low for silence */
                return 0.0;
            double lin = Math.pow (10.0, db / 20.0);
            if (lin != lin || lin < 0.0)
                return 0.0;
            return lin;
        }

        /** Divide every sample by the track peak so the loudest bar reaches 1.0. */
        public static void normalize (double[] samples) {
            double max = 0.0;
            foreach (var s in samples)
                if (s > max) max = s;
            if (max <= 0.0) return;
            for (int i = 0; i < samples.length; i++)
                samples[i] = samples[i] / max;
        }

        /** Bucket-average (or replicate) resample to exactly out_len samples. */
        public static double[] resample (double[] input, int out_len) {
            var result = new double[out_len];
            int n = input.length;
            if (n == 0) return result;
            if (n == out_len) {
                for (int i = 0; i < out_len; i++) result[i] = input[i];
                return result;
            }
            for (int i = 0; i < out_len; i++) {
                int start = (int) ((double) i * n / out_len);
                int end = (int) ((double) (i + 1) * n / out_len);
                if (end <= start) end = start + 1;
                if (end > n) end = n;
                double sum = 0.0;
                int count = end - start;
                for (int j = start; j < end; j++) sum += input[j];
                result[i] = sum / count;
            }
            return result;
        }

        /* ---- disk cache ------------------------------------------------------ */

        private static File cache_file (string key) {
            var dir = File.new_build_filename (Environment.get_user_cache_dir (),
                                                Config.APP_ID, "waveforms");
            try {
                dir.make_directory_with_parents ();
            } catch (Error e) {
            }
            var hash = Checksum.compute_for_string (ChecksumType.SHA1, key);
            return dir.get_child (hash + ".txt");
        }

        private static async double[]? load_cached (string key) {
            string? contents = null;
            try {
                FileUtils.get_contents (cache_file (key).get_path () ?? "", out contents);
            } catch (Error e) {
                return null;
            }
            if (contents == null) return null;

            string[] lines = ((!) contents).split ("\n");
            if (lines.length < 3) return null;
            if (int.parse (lines[0]) != CACHE_VERSION) return null;
            int len = int.parse (lines[1]);
            if (len <= 0 || len > 100000) return null;

            string[] parts = lines[2].split (",");
            if (parts.length != len) return null;

            var samples = new double[len];
            for (int i = 0; i < len; i++)
                samples[i] = double.parse (parts[i]);
            return samples;
        }

        private static async void save_cached (string key, double[] samples) {
            var sb = new StringBuilder ();
            sb.append_printf ("%d\n%d\n", CACHE_VERSION, samples.length);
            for (int i = 0; i < samples.length; i++) {
                sb.append_printf ("%.6f", samples[i]);
                if (i + 1 < samples.length) sb.append_c (',');
            }
            try {
                FileUtils.set_contents (cache_file (key).get_path () ?? "", sb.str);
            } catch (Error e) {
                warning ("Waveform cache save failed: %s", e.message);
            }
        }

        /* ---- analysis -------------------------------------------------------- */

        /**
         * Normalized loudness waveform of @bands samples (0..1) for @music, read
         * from the disk cache when possible, or null when analysis is impossible.
         */
        public static async double[]? load (Music music, int bands) {
            if (bands <= 0 || music.uri.length == 0) return null;

            /* the analyzer would download a remote track whole */
            if (!File.new_for_uri (music.uri).is_native ()) return null;

            string key = @"$(music.uri)|$(music.modified_time)";
            double[] samples;
            double[]? cached = yield load_cached (key);
            if (cached != null) {
                samples = (!) cached;
            } else {
                double[]? analyzed = yield analyze (music.uri);
                if (analyzed == null) return null;
                samples = (!) analyzed;
                save_cached.begin (key, samples, null);
            }
            return resample (samples, bands);
        }

        /**
         * Decode @uri as fast as possible and return a normalized waveform of
         * RESOLUTION samples (0..1), or null when analysis is impossible.
         */
        private static async double[]? analyze (string uri) {
            var peaks = new PeakBuffer ();

            var pipe = new Gst.Pipeline ("g4-waveform");
            var decoder = Gst.ElementFactory.make ("uridecodebin", "decoder");
            var convert = Gst.ElementFactory.make ("audioconvert", "conv");
            var level = Gst.ElementFactory.make ("level", "level");
            var sink = Gst.ElementFactory.make ("fakesink", "sink");
            if (decoder == null || convert == null || level == null || sink == null) {
                pipe.set_state (Gst.State.NULL);
                return null;
            }

            /* The checks above make them usable, but Vala keeps the nullable types */
            var decoder_bin = (!) decoder;
            var conv = (!) convert;
            var lvl = (!) level;
            var snk = (!) sink;

            decoder_bin.set_property ("uri", uri);
            lvl.set_property ("post-messages", true);
            lvl.set_property ("interval", LEVEL_INTERVAL_NS);
            snk.set_property ("sync", false);
            snk.set_property ("qos", false);
            snk.set_property ("async", false);

            pipe.add (decoder_bin);
            pipe.add (conv);
            pipe.add (lvl);
            pipe.add (snk);
            if (!conv.link (lvl) || !lvl.link (snk)) {
                pipe.set_state (Gst.State.NULL);
                return null;
            }

            /* uridecodebin hands us its audio pad at runtime */
            decoder_bin.pad_added.connect ((pad) => {
                var pad_caps = pad.get_current_caps ();
                if (pad_caps == null) pad_caps = pad.query_caps (null);
                if (pad_caps == null) return;
                unowned var structure = ((!) pad_caps).get_structure (0);
                if (!structure.get_name ().has_prefix ("audio/")) return;

                var sink_pad = conv.get_static_pad ("sink");
                if (sink_pad != null && !((!) sink_pad).is_linked ())
                    pad.link ((!) sink_pad);
            });

            bool finished = false;
            SourceFunc resume = analyze.callback;

            uint watch = pipe.get_bus ().add_watch (Priority.DEFAULT, (bus, msg) => {
                switch (msg.type) {
                    case Gst.MessageType.ELEMENT:
                        unowned var structure = msg.get_structure ();
                        if (structure == null || ((!) structure).get_name () != "level")
                            break;
                        unowned var peak_value = ((!) structure).get_value ("peak");
                        if (peak_value == null)
                            break;
                        unowned GLib.ValueArray peak_list = (GLib.ValueArray) peak_value;
                        double mono = 0.0;
                        for (uint i = 0; i < peak_list.n_values; i++) {
                            unowned var value = peak_list.get_nth (i);
                            double lin = db_to_linear (((!) value).get_double ());
                            if (lin > mono) mono = lin;
                        }
                        peaks.add (mono);
                        break;

                    case Gst.MessageType.EOS:
                    case Gst.MessageType.ERROR:
                        if (!finished) {
                            finished = true;
                            Idle.add (() => { resume (); return false; });
                        }
                        return false;

                    default:
                        break;
                }
                return true;
            });

            pipe.set_state (Gst.State.PLAYING);
            yield;

            pipe.set_state (Gst.State.NULL);
            /* the watch unrefs itself when it resumed us above */
            if (watch != 0 && !finished)
                Source.remove (watch);

            double[] raw = peaks.to_array ();
            if (raw.length == 0) return null;

            double[] bucketed = resample (raw, RESOLUTION);
            normalize (bucketed);
            return bucketed;
        }
    }
}
