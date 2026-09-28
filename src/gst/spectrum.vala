namespace G4 {

    /**
     * A stateful real-time band analyzer. {@link GstPlayer} feeds it mono float
     * sample blocks from the live audio tap; every fft_size samples it runs a
     * Hann-windowed FFT and folds the magnitude spectrum into logarithmically
     * spaced bands, returned as 0..1 amplitudes. No temporal smoothing here:
     * {@link WaveformView} owns the attack/decay animation.
     */
    public class Spectrum : Object {
        public const int DEFAULT_BANDS = 256;
        public const int DEFAULT_FFT_SIZE = 2048;

        private const double F_MIN = 55.0;
        private const double F_MAX = 15000.0;
        private const double FLOOR_DB = -80.0;

        public int bands { get; construct; }
        public int fft_size { get; construct; }

        private float[] fill;
        private int fill_len = 0;
        private float[] window;

        private float[] re;
        private float[] im;

        public Spectrum (int bands, int fft_size = DEFAULT_FFT_SIZE) {
            Object (bands: bands, fft_size: next_pow2 (fft_size));
        }

        private static int next_pow2 (int v) {
            int p = 2;
            while (p < v) p <<= 1;
            return p;
        }

        construct {
            fill = new float[fft_size];
            window = new float[fft_size];
            re = new float[fft_size];
            im = new float[fft_size];
            /* Hann window */
            int n = fft_size;
            for (int i = 0; i < n; i++)
                window[i] = (float) (0.5 - 0.5 * Math.cos (2.0 * Math.PI * i / (n - 1)));
        }

        /* reset so a track change / seek doesn't splice unrelated audio */
        public void flush () {
            fill_len = 0;
        }

        /**
         * Append a mono sample block; returns a freshly computed band frame
         * (length == bands) when a full FFT window was completed, else null.
         */
        public double[]? push (float[] samples, int rate) {
            int n = fft_size;
            double[]? frame = null;
            for (int i = 0; i < samples.length; i++) {
                fill[fill_len++] = samples[i] * window[fill_len];
                if (fill_len >= n) {
                    frame = analyze (rate);
                    fill_len = 0;
                }
            }
            return frame;
        }

        private double[] analyze (int rate) {
            int n = fft_size;
            for (int i = 0; i < n; i++) {
                re[i] = fill[i];
                im[i] = 0.0f;
            }
            fft_inplace (re, im);

            int half = n / 2;
            double f_max = double.min (F_MAX, rate / 2.0 * 0.999);
            if (f_max <= F_MIN) f_max = F_MIN * 2.0;
            double log_lo = Math.log (F_MIN);
            double log_hi = Math.log (f_max);
            double log_range = log_hi - log_lo;

            var sum = new double[bands];
            var cnt = new int[bands];
            double bin_hz = (double) rate / n;

            for (int k = 1; k < half; k++) {   /* skip DC */
                double f = k * bin_hz;
                if (f < F_MIN || f > f_max) continue;
                double t = (Math.log (f) - log_lo) / log_range;   /* 0..1 */
                int b = (int) (t * bands);
                if (b < 0) b = 0;
                if (b >= bands) b = bands - 1;
                double mag = Math.sqrt ((double) re[k] * re[k] + (double) im[k] * im[k]);
                sum[b] += mag;
                cnt[b] += 1;
            }

            var frame = new double[bands];
            double norm = n / 2.0;
            for (int b = 0; b < bands; b++) {
                if (cnt[b] == 0) { frame[b] = 0.0; continue; }
                double amp = (sum[b] / cnt[b]) / norm;          /* ~ peak amplitude */
                double db = 20.0 * Math.log10 (amp + 1e-9);
                double v = (db - FLOOR_DB) / (0.0 - FLOOR_DB);   /* -80..0 dB -> 0..1 */
                frame[b] = v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
            }
            return frame;
        }

        /** Minimal in-place iterative radix-2 complex FFT, no external dependencies. */
        private static void fft_inplace (float[] re, float[] im) {
            int n = re.length;
            if (n < 2 || (n & (n - 1)) != 0)
                return;   /* length must be a power of two */

            /* bit-reversal permutation */
            for (int i = 1, j = 0; i < n; i++) {
                int bit = n >> 1;
                for (; (j & bit) != 0; bit >>= 1)
                    j ^= bit;
                j ^= bit;
                if (i < j) {
                    float tr = re[i]; re[i] = re[j]; re[j] = tr;
                    float ti = im[i]; im[i] = im[j]; im[j] = ti;
                }
            }

            /* butterflies */
            for (int len = 2; len <= n; len <<= 1) {
                double ang = -2.0 * Math.PI / len;
                double wr = Math.cos (ang);
                double wi = Math.sin (ang);
                int half = len >> 1;
                for (int i = 0; i < n; i += len) {
                    double cr = 1.0, ci = 0.0;
                    for (int k = 0; k < half; k++) {
                        int u = i + k;
                        int v = u + half;
                        double xr = cr * re[v] - ci * im[v];
                        double xi = cr * im[v] + ci * re[v];
                        re[v] = (float) (re[u] - xr);
                        im[v] = (float) (im[u] - xi);
                        re[u] = (float) (re[u] + xr);
                        im[u] = (float) (im[u] + xi);
                        double ncr = cr * wr - ci * wi;
                        ci = cr * wi + ci * wr;
                        cr = ncr;
                    }
                }
            }
        }
    }
}
