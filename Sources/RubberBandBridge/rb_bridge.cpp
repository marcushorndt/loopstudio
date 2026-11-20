// Rubber Band Library (GPL v2 or later, see README.md), built as one compilation unit, and a C call
// for one offline stretch with a key frame map.
#include "rubberband/single/RubberBandSingle.cpp"
#include "rb_bridge.h"

#include <map>
#include <vector>
#include <algorithm>

using RubberBand::RubberBandStretcher;

long rb_stretch_offline(const float *const *input, int channels, long inFrames, double sampleRate,
                        float *const *output, long outFrames,
                        const long *keySource, const long *keyOutput, int keyCount,
                        const rb_settings *s)
{
    if (channels < 1 || inFrames < 1 || outFrames < 1 || sampleRate <= 0 || !s) return -1;
    try {
        RubberBandStretcher::Options options = RubberBandStretcher::OptionProcessOffline;
        options |= s->engine == 1 ? RubberBandStretcher::OptionEngineFiner : RubberBandStretcher::OptionEngineFaster;
        if (s->channelsTogether) options |= RubberBandStretcher::OptionChannelsTogether;
        if (s->formantPreserved) options |= RubberBandStretcher::OptionFormantPreserved;
        options |= RubberBandStretcher::OptionPitchHighQuality;
        if (s->engine == 0) {
            if (s->transients == 1) options |= RubberBandStretcher::OptionTransientsMixed;
            else if (s->transients == 2) options |= RubberBandStretcher::OptionTransientsSmooth;
        }
        const double ratio = double(outFrames) / double(inFrames);
        RubberBandStretcher rb(size_t(sampleRate), size_t(channels), options, ratio, s->pitch > 0 ? s->pitch : 1.0);
        if (s->engine == 1 && s->formantScale > 0) rb.setFormantScale(s->formantScale);
        rb.setExpectedInputDuration(size_t(inFrames));
        const size_t block = 4096;
        rb.setMaxProcessSize(block);

        std::vector<const float *> in(channels);
        for (long at = 0; at < inFrames; at += long(block)) {
            const size_t n = size_t(std::min<long>(long(block), inFrames - at));
            for (int c = 0; c < channels; ++c) in[c] = input[c] + at;
            rb.study(in.data(), n, at + long(n) >= inFrames);
        }
        if (keyCount > 0 && keySource && keyOutput) {
            std::map<size_t, size_t> map;
            for (int k = 0; k < keyCount; ++k) {
                if (keySource[k] <= 0 || keySource[k] >= inFrames || keyOutput[k] <= 0 || keyOutput[k] >= outFrames) continue;
                map[size_t(keySource[k])] = size_t(keyOutput[k]);
            }
            if (!map.empty()) rb.setKeyFrameMap(map);
        }

        long written = 0;
        std::vector<float *> out(channels);
        std::vector<std::vector<float>> spill(channels, std::vector<float>(block * 4));
        // Takes what the stretcher has ready. Returns available(): -1 once everything is out.
        auto drain = [&]() -> int {
            int avail;
            while ((avail = rb.available()) > 0) {
                const size_t want = std::min<size_t>(size_t(avail), block * 4);
                for (int c = 0; c < channels; ++c) out[c] = spill[c].data();
                const size_t got = rb.retrieve(out.data(), want);
                if (got == 0) break;
                const long keep = std::min<long>(long(got), std::max<long>(0, outFrames - written));
                for (int c = 0; c < channels; ++c) std::copy(spill[c].data(), spill[c].data() + keep, output[c] + written);
                written += keep;
            }
            return avail;
        };
        for (long at = 0; at < inFrames; at += long(block)) {
            const size_t n = size_t(std::min<long>(long(block), inFrames - at));
            for (int c = 0; c < channels; ++c) in[c] = input[c] + at;
            rb.process(in.data(), n, at + long(n) >= inFrames);
            drain();
        }
        drain();
        for (int c = 0; c < channels; ++c) std::fill(output[c] + written, output[c] + outFrames, 0.0f);
        return outFrames;
    } catch (...) {
        return -1;
    }
}
