// Spike benchmark for transcribe.cpp, shaped like a retained helper process.
// Loads one model once, then transcribes the same 16 kHz mono WAV N times in
// that process. Emits JSONL on stdout: one "load" row, then one "run" row per
// call with wall time and transcript. Usage:
//   transcribe-spike-bench model.gguf audio-16k.wav [repetitions=4]
//   [language=en|auto]
#include "transcribe.h"
#include "wav.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {

using clock_type = std::chrono::steady_clock;

double seconds_since(clock_type::time_point start) {
  return std::chrono::duration<double>(clock_type::now() - start).count();
}

// Minimal JSON string escaping for transcript text.
std::string escaped(const char *text) {
  std::string out;
  for (const char *c = text; c && *c; ++c) {
    switch (*c) {
    case '"':
      out += "\\\"";
      break;
    case '\\':
      out += "\\\\";
      break;
    case '\n':
      out += "\\n";
      break;
    default:
      out += *c;
    }
  }
  return out;
}

} // namespace

int main(int argc, char **argv) {
  if (argc < 3 || argc > 5) {
    std::fprintf(
        stderr,
        "usage: %s model.gguf audio-16k.wav [repetitions] [language|auto]\n",
        argv[0]);
    return 2;
  }
  const int repetitions = argc > 3 ? std::atoi(argv[3]) : 4;
  const std::string language = argc > 4 ? argv[4] : "en";
  std::vector<float> pcm;
  std::string error;
  if (repetitions < 1 ||
      !transcribe_cli::load_wav_mono_16k(argv[2], pcm, error)) {
    std::fprintf(stderr, "bad arguments or audio: %s\n", error.c_str());
    return 2;
  }
  const double audio_seconds = static_cast<double>(pcm.size()) / 16000.0;

  const auto load_started = clock_type::now();
  struct transcribe_model_load_params load;
  transcribe_model_load_params_init(&load);
  struct transcribe_model *model = nullptr;
  if (transcribe_model_load_file(argv[1], &load, &model) != TRANSCRIBE_OK) {
    std::fprintf(stderr, "model load failed\n");
    return 1;
  }
  struct transcribe_session *session = nullptr;
  if (transcribe_session_init(model, nullptr, &session) != TRANSCRIBE_OK) {
    std::fprintf(stderr, "session init failed\n");
    transcribe_model_free(model);
    return 1;
  }
  std::printf("{\"mode\":\"load\",\"backend\":\"%s\",\"audioSeconds\":%.3f,"
              "\"totalSeconds\":%.4f}\n",
              transcribe_model_backend(model), audio_seconds,
              seconds_since(load_started));

  struct transcribe_capabilities caps;
  transcribe_capabilities_init(&caps);
  transcribe_model_get_capabilities(model, &caps);
  struct transcribe_run_params params;
  transcribe_run_params_init(&params);
  // Match the MLX adapter, which always requests English. Models without a
  // language list reject hints, so only pass one when the model lists
  // languages.
  if (language != "auto" && caps.n_languages > 1) {
    params.language = language.c_str();
  }
  int status = 0;
  for (int iteration = 1; iteration <= repetitions; ++iteration) {
    const auto started = clock_type::now();
    const transcribe_status result = transcribe_run(
        session, pcm.data(), static_cast<int>(pcm.size()), &params);
    const double elapsed = seconds_since(started);
    if (result != TRANSCRIBE_OK) {
      std::fprintf(stderr, "run %d failed: %s\n", iteration,
                   transcribe_status_string(result));
      status = 1;
      break;
    }
    std::printf("{\"mode\":\"run\",\"iteration\":%d,\"audioSeconds\":%.3f,"
                "\"totalSeconds\":%.4f,\"text\":\"%s\"}\n",
                iteration, audio_seconds, elapsed,
                escaped(transcribe_full_text(session)).c_str());
    std::fflush(stdout);
  }
  transcribe_session_free(session);
  transcribe_model_free(model);
  return status;
}
