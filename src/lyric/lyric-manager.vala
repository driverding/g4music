// SPDX-FileCopyrightText: 2026 DriverDing
// SPDX-License-Identifier: GPL-3.0-or-later

namespace G4 {

    public class LyricManager: GLib.Object {
        /**
         * Emitted when the lyric of `uri` is loaded, or found missing.
         */
        public signal void lyric_found (string uri, Lyric? lyric);

        private const string[] LYRIC_EXTS = { "lrc", "ttml", "tt", "xml" };

        private Gee.HashMap<string, Lyric> lyrics = new Gee.HashMap<string, Lyric> ();
        private Gee.HashSet<string> loading = new Gee.HashSet<string> ();
        private Gee.HashSet<string> missing = new Gee.HashSet<string> ();

        public Lyric? find (string uri) {
            if (! lyrics.has_key (uri))
                return null;
            return lyrics[uri];
        }

        /**
         * Load the lyric of a music uri in background, if not done yet.
         */
        public async void load (string uri) {
            if (uri.length == 0 || lyrics.has_key (uri)
                    || loading.contains (uri) || missing.contains (uri))
                return;

            loading.add (uri);
            var lyric = yield run_async <Lyric?> (() => parse_lyric (uri));
            loading.remove (uri);
            if (lyric != null) {
                lyrics[uri] = (!) lyric;
                lyric_found (uri, (!) lyric);
            } else if (! lyrics.has_key (uri)) {
                missing.add (uri);
                lyric_found (uri, null);
            }
        }

        /**
         * Take the lyrics text from the tags parsed while playing.
         */
        public void set_tag_list (string uri, Gst.TagList? tags) {
            if (uri.length == 0 || tags == null || lyrics.has_key (uri))
                return;
            unowned string? text = null;
            if (! ((!) tags).peek_string_index (Gst.Tags.LYRICS, 0, out text) || text == null)
                return;
            var lyric = parse_lyric_text ((!) text);
            if (lyric != null) {
                missing.remove (uri);
                loading.remove (uri);
                lyrics[uri] = (!) lyric;
                lyric_found (uri, (!) lyric);
            }
        }

        private static Lyric? parse_lyric (string uri) {
            var file = File.new_for_uri (uri);
            if (! file.is_native ())
                return null;

            //  1. Try the lyrics embedded in the music tags
            var tags = parse_gst_tags (file);
            unowned string? text = null;
            if (tags != null && ((!) tags).peek_string_index (Gst.Tags.LYRICS, 0, out text)
                    && text != null) {
                var lyric = parse_lyric_text ((!) text);
                if (lyric != null)
                    return lyric;
            }

            //  2. Try the lyric file having the same name as the music
            var sidecar = find_sidecar (file);
            if (sidecar == null)
                return null;
            var lyric_file = (!) sidecar;
            uint8[] data;
            try {
                lyric_file.load_contents (null, out data, null);
            } catch (Error e) {
                var name = lyric_file.get_basename () ?? "";
                print (@"Load lyric $(name) failed: $(e.message)\n");
                return null;
            }
            return parse_lyric_text (bytes_to_text (data));
        }

        private static File? find_sidecar (File file) {
            var parent = file.get_parent ();
            if (parent == null)
                return null;
            var dir = (!) parent;
            var name = file.get_basename () ?? "";
            var dot = name.last_index_of_char ('.');
            if (dot > 0)
                name = name.substring (0, dot);

            foreach (var ext in LYRIC_EXTS) {
                var candidates = new string[] { @"$name.$ext", @"$name.$(ext.up ())" };
                foreach (var candidate in candidates) {
                    var sidecar = dir.get_child (candidate);
                    if (sidecar.query_exists ())
                        return sidecar;
                }
            }
            return null;
        }

        /**
         * Decode the lyric file content, which could be encoded as UTF-8,
         * UTF-16 or a legacy Chinese encoding.
         */
        private static string? bytes_to_text (uint8[] data) {
            if (data.length < 2)
                return null;
            unowned char[] chars = (char[]) data;
            var from_codeset = "UTF-8";
            var skip = 0;
            if (data[0] == 0xFF && data[1] == 0xFE) {
                from_codeset = "UTF-16LE";
                skip = 2;
            } else if (data[0] == 0xFE && data[1] == 0xFF) {
                from_codeset = "UTF-16BE";
                skip = 2;
            } else if (data.length > 2 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) {
                skip = 3;
            }
            try {
                return GLib.convert_with_fallback ((string) chars[skip:data.length],
                                                   (ssize_t) (data.length - skip),
                                                   "UTF-8", from_codeset, "GB18030");
            } catch (ConvertError e) {
                print (@"Convert lyric encoding failed: $(e.message)\n");
                return null;
            }
        }
    }
}
