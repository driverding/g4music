// SPDX-FileCopyrightText: 2026 DriverDing
// SPDX-License-Identifier: GPL-3.0-or-later

namespace G4 {

    /**
     * Datatype representing a lyric.
     * Can be created with LrcParser or TtmlParser.
     */
    public class Lyric: GLib.Object {
        public Gee.ArrayList<Line> lines { get; set; }

        public Lyric (Gee.ArrayList<Line> lines) {
            Object (lines: lines);
        }

        public class Word: Object {
            public uint64 start_time { get; set; }
            public uint64 end_time   { get; set; }
            public string text       { get; set; }
            public string? ruby      { get; set; }

            public Word (uint64  start_time,
                         string  text,
                         uint64  end_time = 0,
                         string? ruby = null) {
                Object (start_time: start_time,
                        end_time: end_time,
                        text: text,
                        ruby: ruby);
            }
        }

        public class Line: Object {
            public uint64 start_time          { get; set; }
            public uint64 end_time            { get; set; }
            public Gee.ArrayList<Word> words { get; set; }
            public string? translation       { get; set; }
            public string? phonetic          { get; set; }

            public bool is_background        { get; set; }
            public bool is_duet              { get; set; }

            public Line (uint64  start_time,
                         Gee.ArrayList<Word> words,
                         uint64  end_time = 0,
                         string? translation = null,
                         string? phonetic = null,
                         bool is_background = false,
                         bool is_duet = false) {
                Object (start_time: start_time,
                        end_time: end_time,
                        words: words,
                        translation: translation,
                        phonetic: phonetic,
                        is_background: is_background,
                        is_duet: is_duet);
            }
        }
    }
}
