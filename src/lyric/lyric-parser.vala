// SPDX-FileCopyrightText: 2026 DriverDing
// SPDX-License-Identifier: GPL-3.0-or-later

namespace G4 {

    /**
     * Parse lyric text, whose format is detected by the leading '<' of TTML.
     */
    public static Lyric? parse_lyric_text (string? text) {
        if (text == null)
            return null;
        var str = ((!) text).strip ();
        if (str.length == 0)
            return null;
        try {
            if (str.has_prefix ("<")) {
                var parser = new TtmlParser ();
                return parser.parse (str);
            }
            var parser = new LrcParser ();
            return parser.parse (str);
        } catch (Error e) {
            print (@"Parse lyric failed: $(e.message)\n");
            return null;
        }
    }

    /**
     * A minimal LRC parser based on regex.
     * Repeating Lyric is NOT supported. Standard A2 extension is supported.
     */
    public class LrcParser: Object {
        private Regex offset_regex = /\[offset:([+-]?\d+)\]/;
        private Regex line_regex = /\[(\d{2}):(\d{2})\.(\d{2,3})\]([^\[\n]*)/;
        private Regex word_regex = /<(\d{2}):(\d{2})\.(\d{2,3})>\s*([^<\n]*)/;

        private uint64 shift_time (uint64 time, int64 offset) {
            if (offset == 0)
                return time;
            var adjusted = (int64) time + offset;
            return adjusted >= 0 ? (uint64) adjusted : 0;
        }

        public Lyric parse (string str) throws GLib.Error {
            int64 offset = 0;
            MatchInfo offset_match;
            if (offset_regex.match (str, 0, out offset_match)) {
                int64.from_string (fetch_group (offset_match, 1), out offset);
            }

            var lines = new Gee.ArrayList<Lyric.Line> ();
            MatchInfo line_match;
            line_regex.match (str, 0, out line_match);
            while (line_match.matches ()) {
                var line_start_time = shift_time (fetch_time (line_match), offset);
                var line_text = fetch_group (line_match, 4).strip ();
                var words = new Gee.ArrayList<Lyric.Word> ();

                MatchInfo word_match;
                if (word_regex.match (line_text, 0, out word_match)) {
                    while (word_match.matches ()) {
                        // Don't strip the text for spaces.
                        words.add (new Lyric.Word (shift_time (fetch_time (word_match), offset),
                                                   fetch_group (word_match, 4)));
                        word_match.next ();
                    }
                }
                if (words.is_empty) {
                    words.add (new Lyric.Word (line_start_time, line_text));
                }

                lines.add (new Lyric.Line (line_start_time, words));
                line_match.next ();
            }

            return new Lyric (lines);
        }
    }

    /**
     * A minimal TTML parser based on GXml.
     */
    public class TtmlParser: Object {
        private Regex time_regex = /(\d{2}):(\d{2})\.(\d{2,3})/;

        private uint64 parse_time (string? str) {
            if (str == null)
                return 0;
            MatchInfo mi;
            if (! time_regex.match ((!) str, 0, out mi) || ! mi.matches ())
                return 0;
            return fetch_time (mi);
        }

        public Lyric parse (string str) throws GLib.Error {
            Root root = new Root ();
            root.read_from_string (str);

            var lines = new Gee.ArrayList<Lyric.Line> ();
            var body = root.body;
            if (body == null)
                return new Lyric (lines);

            foreach (var div_dom in ((!) body).divs) {
                var div = (Div) div_dom;
                foreach (var p_dom in div.ps) {
                    var p = (P) p_dom;
                    var line_start_time = parse_time (p.begin);
                    var line_end_time = parse_time (p.end);
                    var words = new Gee.ArrayList<Lyric.Word> ();

                    string? translation = null;
                    foreach (var span_dom in p.spans) {
                        var span = (Span) span_dom;
                        if (span.role == "x-translation") {
                            translation = span.text_content;
                        } else if (span.begin != null) {
                            words.add (new Lyric.Word (parse_time (span.begin),
                                                       span.text_content ?? "",
                                                       parse_time (span.end)));
                        }
                    }
                    if (words.is_empty) {
                        words.add (new Lyric.Word (line_start_time, p.text_content ?? "",
                                                   line_end_time));
                    }

                    lines.add (new Lyric.Line (line_start_time, words, line_end_time, translation));
                }
            }

            return new Lyric (lines);
        }

        private class Root: GXml.Element {
            public Body? body { get; set; }

            construct {
                try {
                    initialize ("tt");
                } catch (GLib.Error e) {
                    print (@"Init TTML root failed: $(e.message)\n");
                }
            }
        }

        private class Body: GXml.Element {
            public Divs divs { get; set; }

            construct {
                try {
                    initialize ("body");
                    set_instance_property ("divs");
                } catch (GLib.Error e) {
                    print (@"Init TTML body failed: $(e.message)\n");
                }
            }
        }

        private class Divs: GXml.ArrayList {
            construct {
                try {
                    initialize (typeof (Div));
                } catch (GLib.Error e) {
                    print (@"Init TTML divs failed: $(e.message)\n");
                }
            }
        }

        private class Div: GXml.Element {
            public Ps ps { get; set; }

            construct {
                try {
                    initialize ("div");
                    set_instance_property ("ps");
                } catch (GLib.Error e) {
                    print (@"Init TTML div failed: $(e.message)\n");
                }
            }
        }

        private class Ps: GXml.ArrayList {
            construct {
                try {
                    initialize (typeof (P));
                } catch (GLib.Error e) {
                    print (@"Init TTML ps failed: $(e.message)\n");
                }
            }
        }

        private class P: GXml.Element {
            [Description (nick="::begin")]
            public string? begin { get; set; }
            [Description (nick="::end")]
            public string? end { get; set; }

            public Spans spans { get; set; }

            construct {
                try {
                    initialize ("p");
                    set_instance_property ("spans");
                } catch (GLib.Error e) {
                    print (@"Init TTML p failed: $(e.message)\n");
                }
            }
        }

        private class Spans: GXml.ArrayList {
            construct {
                try {
                    initialize (typeof (Span));
                } catch (GLib.Error e) {
                    print (@"Init TTML spans failed: $(e.message)\n");
                }
            }
        }

        private class Span: GXml.Element {
            [Description (nick="::begin")]
            public string? begin { get; set; }
            [Description (nick="::end")]
            public string? end { get; set; }

            [Description (nick="::ttm:role")]
            public string? role { get; set; }

            construct {
                try {
                    initialize ("span");
                } catch (GLib.Error e) {
                    print (@"Init TTML span failed: $(e.message)\n");
                }
            }
        }
    }

    /**
     * Get the text of a matched group, or empty if it is not matched.
     */
    private static string fetch_group (MatchInfo mi, int group) {
        string? str = mi.fetch (group);
        return str ?? "";
    }

    /**
     * Get the milliseconds of a matched time, which is like "mm:ss.ff".
     */
    private static uint64 fetch_time (MatchInfo mi) {
        int64 m = 0, s = 0, f = 0;
        var fraction = fetch_group (mi, 3);
        try {
            int64.from_string (fetch_group (mi, 1), out m, 10);
            int64.from_string (fetch_group (mi, 2), out s, 10);
            int64.from_string (fraction, out f, 10);
        } catch (NumberParserError e) {
            return 0;
        }
        if (fraction.length == 2)
            f *= 10;
        return (uint64) (m * 60000 + s * 1000 + f);
    }
}
