// Prints what transcribe.cpp reports about one GGUF model as a single JSON
// line. Spike diagnostic only: usage `transcribe-probe /path/model.gguf`.
#include "transcribe.h"

#include <chrono>
#include <cstdio>

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s model.gguf\n", argv[0]);
    return 2;
  }
  const auto started = std::chrono::steady_clock::now();
  struct transcribe_model_load_params load;
  transcribe_model_load_params_init(&load);
  struct transcribe_model *model = nullptr;
  if (transcribe_model_load_file(argv[1], &load, &model) != TRANSCRIBE_OK) {
    std::fprintf(stderr, "load failed\n");
    return 1;
  }
  const double load_ms = std::chrono::duration<double, std::milli>(
                             std::chrono::steady_clock::now() - started)
                             .count();
  struct transcribe_capabilities caps;
  transcribe_capabilities_init(&caps);
  transcribe_model_get_capabilities(model, &caps);
  static const char *const feature_names[] = {"initial_prompt",
                                              "temperature_fallback",
                                              "long_form",
                                              "cancellation",
                                              "pnc",
                                              "itn",
                                              "diarization",
                                              "vocabulary",
                                              "context_prompt",
                                              "instruct",
                                              "transcript_prefix"};
  std::printf("{\"arch\":\"%s\",\"variant\":\"%s\",\"backend\":\"%s\",\"load_"
              "ms\":%.1f,\"sample_rate\":%d,"
              "\"n_languages\":%d,\"language_detect\":%s,\"translate\":%s,"
              "\"streaming\":%s,\"max_audio_ms\":%lld,"
              "\"features\":{",
              transcribe_model_arch_string(model),
              transcribe_model_variant_string(model),
              transcribe_model_backend(model), load_ms, caps.native_sample_rate,
              caps.n_languages,
              caps.supports_language_detect ? "true" : "false",
              caps.supports_translate ? "true" : "false",
              caps.supports_streaming ? "true" : "false",
              static_cast<long long>(caps.max_audio_ms));
  for (int i = 0; i <= TRANSCRIBE_FEATURE_TRANSCRIPT_PREFIX; ++i) {
    std::printf(
        "%s\"%s\":%s", i ? "," : "", feature_names[i],
        transcribe_model_supports(model, static_cast<transcribe_feature>(i))
            ? "true"
            : "false");
  }
  std::printf("}}\n");
  transcribe_model_free(model);
  return 0;
}
